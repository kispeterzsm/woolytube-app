import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../pages/lyrics_page.dart';
import '../pages/playlist_detail_page.dart';
import '../player/player_layout.dart';
import '../player/player_shell.dart';
import '../player/player_widgets.dart';
import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/chapter_playback.dart';
import '../services/chapters.dart';
import '../services/youtube_links.dart';
import 'segment_mark_button.dart';
import 'sleep_timer_button.dart';

const _sheetBackground = Color(0xFF2A2A2A);
const _muted = Color(0xFF888888);

/// The context and ref that sheets and flows started from the player use.
///
/// The audio panel leaves the tree when the player collapses, so anything
/// that can outlive a tap (a rename dialog, a replacement, a snackbar after
/// a share) runs on the player shell, which lives as long as the app.
(BuildContext, WidgetRef) _playerHost(BuildContext context, WidgetRef ref) {
  final shell = PlayerShell.maybeOf(context);
  if (shell == null || !shell.mounted) return (context, ref);
  return (shell.context, shell.ref);
}

/// The playing file's own row. While a chapter plays as its own track,
/// [currentTrackProvider] holds a copy titled after the chapter; actions on
/// the file (rename, lyrics, share) must never see that copy.
Track? _playingFile(WidgetRef ref) =>
    ref.read(currentPlaybackItemProvider).valueOrNull?.track ??
    ref.read(currentTrackProvider).valueOrNull;

/// 'Queue': opens Up next, the songs queued by hand, with their count.
class QueueButton extends ConsumerWidget {
  const QueueButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      upNextQueueProvider.select((queue) => queue.valueOrNull?.length ?? 0),
    );
    return PlayerActionButton(
      key: const ValueKey('player-queue-button'),
      icon: Icons.queue_music_rounded,
      label: 'Queue',
      tooltip: count == 0 ? 'Queue' : 'Queue ($count)',
      badge:
          count == 0
              ? null
              : Container(
                key: const ValueKey('player-queue-count'),
                constraints: const BoxConstraints(minWidth: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: PlayerLayout.activeToggle,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  count > 99 ? '99+' : count.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      onPressed: () => showUpNextSheet(_playerHost(context, ref).$1),
    );
  }
}

/// The last slot of the audio panel's bottom row: 'More' opens the less
/// used actions. While a skip segment is being marked it is 'End segment'
/// instead, which asks for the segment's category (or discards it).
class PlayerMoreButton extends ConsumerWidget {
  const PlayerMoreButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marking =
        ref.watch(pendingSegmentMarkStartProvider).valueOrNull != null;
    if (marking) {
      return PlayerActionButton(
        key: const ValueKey('player-end-segment'),
        icon: Icons.bookmark,
        label: 'End segment',
        tooltip: 'End segment: mark where the part to skip ends',
        toggled: true,
        onPressed: () {
          final (hostContext, hostRef) = _playerHost(context, ref);
          unawaited(finishSkipSegment(hostContext, hostRef));
        },
      );
    }
    final sleeping =
        ref.watch(sleepTimerRemainingProvider).valueOrNull != null ||
        (ref.watch(stopAfterCurrentProvider).valueOrNull ?? false);
    return PlayerActionButton(
      key: const ValueKey('player-more-button'),
      icon: Icons.more_vert_rounded,
      label: 'More',
      tooltip: sleeping ? 'More (sleep timer on)' : 'More',
      badge:
          sleeping
              ? Container(
                key: const ValueKey('player-more-sleep-dot'),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: PlayerLayout.activeToggle,
                  shape: BoxShape.circle,
                ),
              )
              : null,
      onPressed: () => _showMoreSheet(context, ref),
    );
  }
}

void _showMoreSheet(BuildContext context, WidgetRef ref) {
  final (hostContext, hostRef) = _playerHost(context, ref);
  showModalBottomSheet<void>(
    context: hostContext,
    backgroundColor: _sheetBackground,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder:
        (sheetContext) => Consumer(
          builder:
              (sheetContext, sheetRef, _) => ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
                ),
                child: ListView(
                  key: const ValueKey('player-more-list'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: _moreTiles(
                    sheetContext,
                    sheetRef,
                    hostContext,
                    hostRef,
                  ),
                ),
              ),
        ),
  );
}

List<Widget> _moreTiles(
  BuildContext sheetContext,
  WidgetRef sheetRef,
  BuildContext hostContext,
  WidgetRef hostRef,
) {
  final item = sheetRef.watch(currentPlaybackItemProvider).valueOrNull;
  // Watched so the sheet follows a track change, but never used for the
  // file's own actions (see _playingFile).
  sheetRef.watch(currentTrackProvider);
  final track = _playingFile(sheetRef);
  final currentPlaylist = sheetRef.watch(currentPlaylistProvider).valueOrNull;
  final playlist =
      track == null || currentPlaylist?.id == track.playlistId
          ? currentPlaylist
          : sheetRef
              .watch(playlistsProvider)
              .valueOrNull
              ?.where((playlist) => playlist.id == track.playlistId)
              .firstOrNull;
  final sleepStatus = sleepTimerStatus(sheetRef);
  final audioOnly = sheetRef.watch(audioOnlyModeProvider).valueOrNull ?? false;
  final service = sheetRef.read(playbackServiceProvider);
  final shareChapter =
      track == null ? null : _chapterToShare(item, track, service.position);

  void close() => Navigator.pop(sheetContext);

  Widget tile({
    required Key key,
    required IconData icon,
    required String title,
    String? subtitle,
    Color iconColor = Colors.white70,
    VoidCallback? onTap,
  }) {
    return ListTile(
      key: key,
      leading: Icon(icon, color: onTap == null ? _muted : iconColor),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle:
          subtitle == null
              ? null
              : Text(subtitle, style: const TextStyle(color: _muted)),
      enabled: onTap != null,
      onTap: onTap,
    );
  }

  return [
    tile(
      key: const ValueKey('player-more-add-segment'),
      icon: Icons.bookmark_add_outlined,
      title: 'Add skip segment',
      subtitle: 'Marks where the part starts; tap End segment where it ends',
      onTap:
          track == null
              ? null
              : () {
                // Marked before the sheet closes: the start is the moment of
                // the tap.
                unawaited(startSkipSegment(hostContext, hostRef));
                close();
              },
    ),
    tile(
      key: const ValueKey('player-more-lyrics'),
      icon: Icons.lyrics_outlined,
      title: lyricsMenuTitle(playlist?.lyricsMode),
      subtitle: lyricsMenuSubtitle(playlist?.lyricsMode),
      onTap:
          track == null
              ? null
              : () {
                close();
                Navigator.of(hostContext).push(
                  MaterialPageRoute<void>(
                    builder:
                        (_) => LyricsPage(
                          track: track,
                          chapterId: item?.chapter?.id,
                        ),
                  ),
                );
              },
    ),
    if (track != null && hasYouTubeTimeline(track))
      tile(
        key: const ValueKey('player-more-share'),
        icon: Icons.share,
        title: 'Share',
        subtitle:
            shareChapter == null
                ? 'Share the YouTube link'
                : 'Share a link to "${shareChapter.title}"',
        onTap: () {
          close();
          unawaited(_share(hostContext, track, shareChapter));
        },
      ),
    tile(
      key: const ValueKey('player-more-sleep-timer'),
      icon: sleepStatus == null ? Icons.bedtime_outlined : Icons.bedtime,
      iconColor:
          sleepStatus == null ? Colors.white70 : PlayerLayout.activeToggle,
      title: 'Sleep timer',
      subtitle: sleepStatus ?? 'Off',
      onTap: () {
        close();
        unawaited(showSleepTimerSheet(hostContext, hostRef));
      },
    ),
    if (item?.chapter != null)
      tile(
        key: const ValueKey('player-more-next-file'),
        icon: Icons.last_page_rounded,
        title: 'Next file',
        subtitle: 'Skip the remaining chapters of this file',
        onTap: () {
          close();
          unawaited(service.nextFile());
        },
      ),
    if (currentPlaylist?.audioOnly == false)
      tile(
        key: const ValueKey('player-more-audio-only'),
        icon: Icons.headphones_rounded,
        iconColor: audioOnly ? PlayerLayout.activeToggle : Colors.white70,
        title: 'Audio only',
        subtitle:
            audioOnly
                ? 'On: tap to play the video'
                : 'Off: tap to hide the video',
        onTap: () {
          close();
          unawaited(service.toggleAudioOnlyMode());
        },
      ),
    const Divider(height: 1, color: Color(0xFF3A3A3A)),
    tile(
      key: const ValueKey('player-more-other-settings'),
      icon: Icons.tune_rounded,
      title: 'Other settings…',
      subtitle: 'Every option for this file, as in its playlist',
      onTap:
          track == null
              ? null
              : () {
                close();
                showTrackActionsSheet(hostContext, hostRef, track);
              },
    ),
  ];
}

/// The chapter a share should start at: the chapter playing as its own
/// track, or the chapter of the whole file that [position] is in.
MediaChapter? _chapterToShare(
  PlaybackItem? item,
  Track track,
  Duration position,
) {
  final chapter = item?.chapter;
  if (chapter != null) return chapter;
  if (item != null && item.track.id != track.id) return null;
  final ms = position.inMilliseconds;
  for (final chapter in ChapterData.decode(track.chaptersJson).active) {
    if (chapter.startMs <= ms && ms < chapter.endMs) return chapter;
  }
  return null;
}

Future<void> _share(
  BuildContext context,
  Track track,
  MediaChapter? chapter,
) async {
  try {
    if (chapter == null) {
      await shareYouTubeVideo(track);
    } else {
      await shareYouTubeChapter(track, chapter);
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
  }
}
