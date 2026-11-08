part of '../playlist_detail_page.dart';

const _sheetTitleStyle = TextStyle(color: Colors.white);
const _sheetSubtitleStyle = TextStyle(color: _muted);

/// The track options sheet and everything it starts. A mixin so the page
/// file stays about the list.
mixin _TrackActions on ConsumerState<PlaylistDetailPage> {
  /// The playlist row as currently known (live when available).
  Playlist? get _playlist;

  String _videoUrl(Track track) =>
      'https://www.youtube.com/watch?v=${track.videoId}';

  /// One flat sheet: header, the common actions, then labelled File and
  /// YouTube sections. Nothing is nested.
  void _showTrackActions(Track track) {
    bool? alwaysSkipOverride;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder:
          (sheetContext) => Consumer(
            builder: (sheetContext, sheetRef, _) {
              // Live row, so a download finishing or a rename shows here.
              final live =
                  sheetRef.watch(
                    tracksProvider(widget.playlistId).select(
                      (tracks) =>
                          tracks.valueOrNull
                              ?.where((t) => t.id == track.id)
                              .firstOrNull,
                    ),
                  ) ??
                  track;
              // Not offered when the video is in Temporary or already
              // downloaded as video; unknown until loaded counts as blocked.
              final saveToTemporaryBlocked = sheetRef.watch(
                temporarySaveBlockedVideoIdsProvider.select(
                  (ids) => ids.valueOrNull?.contains(live.videoId) ?? true,
                ),
              );
              return StatefulBuilder(
                builder: (sheetContext, setSheetState) {
                  final alwaysSkip = alwaysSkipOverride ?? live.alwaysSkip;
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TrackSheetHeader(track: live),
                        const Divider(height: 1, color: Color(0xFF3A3A3A)),
                        Flexible(
                          child: ListView(
                            key: const ValueKey('track-actions-list'),
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 16),
                            children: _trackActionTiles(
                              sheetContext,
                              live,
                              saveToTemporaryBlocked: saveToTemporaryBlocked,
                              alwaysSkip: alwaysSkip,
                              onAlwaysSkipChanged: (value) async {
                                setSheetState(() => alwaysSkipOverride = value);
                                try {
                                  await ref
                                      .read(playbackServiceProvider)
                                      .setAlwaysSkip(live, value);
                                } catch (e) {
                                  if (sheetContext.mounted) {
                                    setSheetState(
                                      () => alwaysSkipOverride = !value,
                                    );
                                  }
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Could not save: $e'),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
    );
  }

  List<Widget> _trackActionTiles(
    BuildContext sheetContext,
    Track track, {
    required bool saveToTemporaryBlocked,
    required bool alwaysSkip,
    required ValueChanged<bool> onAlwaysSkipChanged,
  }) {
    final isDownloaded = track.status == 'complete' && track.filePath != null;
    final isDownloading = track.status == 'downloading';
    final hasError = track.status == 'error' && track.lastError != null;
    // Local replacements and kept local files for unavailable videos are
    // only swapped for the original through the replacement-conflict flow.
    final canRedownload =
        !track.isLocalReplacement &&
        !(track.status == 'complete' && track.unavailableReason != null);
    final canDownloadOriginal =
        track.isLocalReplacement &&
        !track.replaceRequested &&
        track.unavailableReason == null &&
        !PlaylistService.isForcedInsertVideoId(track.videoId);
    final isYouTubeVideo =
        !PlaylistService.isForcedInsertVideoId(track.videoId);
    final removedFromYouTube =
        track.unavailableReason == removedFromYouTubeReason;
    final playlist = _playlist;
    final canChooseQuality =
        playlist != null &&
        !playlist.audioOnly &&
        isYouTubeVideo &&
        !track.isLocalReplacement &&
        !isDownloading;
    final inTemporaryPlaylist = playlist?.isTemporary ?? false;
    final canSaveToTemporary =
        playlist != null &&
        !inTemporaryPlaylist &&
        isYouTubeVideo &&
        !saveToTemporaryBlocked;

    void close() => Navigator.pop(sheetContext);

    Widget tile({
      required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      Color iconColor = Colors.white70,
      TextStyle subtitleStyle = _sheetSubtitleStyle,
      VoidCallback? onTap,
    }) {
      return ListTile(
        key: key,
        leading: Icon(icon, color: onTap == null ? _muted : iconColor),
        title: Text(title, style: _sheetTitleStyle),
        subtitle:
            subtitle == null
                ? null
                : Text(
                  subtitle,
                  style: subtitleStyle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
        enabled: onTap != null,
        onTap: onTap,
      );
    }

    return [
      if (removedFromYouTube && !isDownloading) ...[
        tile(
          key: const ValueKey('track-actions-retry-removed-now'),
          icon: Icons.refresh,
          iconColor: _accent,
          title: 'Try again now',
          subtitle:
              isDownloaded
                  ? 'YouTube said it was removed. Your file stays unless a '
                      'new copy downloads'
                  : 'YouTube said it was removed. Download it if it is back',
          onTap: () {
            close();
            unawaited(_startTrackDownload(track));
          },
        ),
        tile(
          key: const ValueKey('track-actions-retry-removed'),
          icon: Icons.schedule,
          title: 'Try again on the next update',
          subtitle: 'Updates skip it until then',
          onTap: () {
            close();
            unawaited(_retryRemovedOnNextUpdate(track));
          },
        ),
      ],
      // Get the track first when it has no file yet.
      if (!isDownloaded &&
          canRedownload &&
          !isDownloading &&
          !removedFromYouTube)
        tile(
          key: const ValueKey('track-actions-download'),
          icon: hasError ? Icons.refresh : Icons.download,
          iconColor: _accent,
          title: hasError ? 'Retry download' : 'Download now',
          subtitle:
              hasError
                  ? friendlyDownloadError(track.lastError!)
                  : 'Download this track from YouTube',
          subtitleStyle:
              hasError
                  ? const TextStyle(color: Color(0xFFAA6666))
                  : _sheetSubtitleStyle,
          onTap: () {
            close();
            unawaited(_startTrackDownload(track));
          },
        ),
      if (hasError)
        tile(
          key: const ValueKey('track-actions-error-details'),
          icon: Icons.error_outline,
          title: 'Show error details',
          subtitle: 'The full message from the downloader',
          onTap: () {
            close();
            unawaited(_showErrorDetails(track));
          },
        ),
      if (isDownloaded)
        tile(
          key: const ValueKey('track-actions-play-next'),
          icon: Icons.playlist_play,
          iconColor: const Color(0xFF64B5F6),
          title: 'Play next',
          subtitle:
              alwaysSkip
                  ? 'Turn off Always skip to play it next'
                  : 'Plays right after the current song',
          onTap:
              alwaysSkip
                  ? null
                  : () {
                    close();
                    unawaited(_addToQueue(track, next: true));
                  },
        ),
      if (isDownloaded)
        tile(
          key: const ValueKey('track-actions-add-to-queue'),
          icon: Icons.queue_music,
          iconColor: const Color(0xFF64B5F6),
          title: 'Add to queue',
          subtitle:
              alwaysSkip
                  ? 'Turn off Always skip to queue this track'
                  : 'Plays after everything in Up next',
          onTap:
              alwaysSkip
                  ? null
                  : () {
                    close();
                    unawaited(_addToQueue(track));
                  },
        ),
      SwitchListTile(
        key: const ValueKey('track-actions-always-skip'),
        secondary: Icon(
          Icons.skip_next,
          color: alwaysSkip ? const Color(0xFFE57373) : Colors.white70,
        ),
        title: const Text('Always skip', style: _sheetTitleStyle),
        subtitle: const Text(
          'Autoplay and shuffle pass over it; tap it to play it anyway',
          style: _sheetSubtitleStyle,
        ),
        value: alwaysSkip,
        onChanged: onAlwaysSkipChanged,
      ),
      tile(
        key: const ValueKey('track-actions-chapters'),
        icon: Icons.list_alt,
        title: 'Chapters…',
        subtitle: 'Play, mark and edit chapters',
        onTap: () {
          close();
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ChaptersPage(track: track)));
        },
      ),
      tile(
        key: const ValueKey('track-actions-skip-segments'),
        icon: Icons.bookmarks,
        title: 'Skip segments…',
        subtitle: 'See, edit or hide the parts that are skipped',
        onTap: () {
          close();
          unawaited(_showSkipSegments(track));
        },
      ),
      const _SheetSection('File'),
      tile(
        key: const ValueKey('track-actions-rename'),
        icon: Icons.edit,
        title: 'Edit title & file name',
        subtitle: 'Change the name shown here or the file’s name',
        onTap: () {
          close();
          unawaited(_showOverrideDialog(track));
        },
      ),
      tile(
        key: const ValueKey('track-actions-replace'),
        icon: Icons.file_upload,
        title: 'Replace with a file from this phone',
        subtitle: 'Use your own audio or video file for this track',
        onTap: () {
          close();
          unawaited(_pickLocalReplacement(track));
        },
      ),
      if ((!isDownloaded || track.unavailableReason != null) &&
          !isDownloading &&
          isYouTubeVideo)
        tile(
          key: const ValueKey('track-actions-replace-reupload'),
          icon: Icons.link,
          title: 'Replace with a reupload',
          subtitle: 'Paste a link to a copy of this video and download it',
          onTap: () {
            close();
            unawaited(_replaceWithReupload(track));
          },
        ),
      if ((!isDownloaded || track.unavailableReason != null) &&
          !isDownloading &&
          isYouTubeVideo)
        tile(
          key: const ValueKey('track-actions-replace-archived'),
          icon: Icons.history,
          title: 'Download archived copy',
          subtitle:
              'Get the copy the Wayback Machine saved, the one '
              'quiteaplaylist.com offers',
          onTap: () {
            close();
            unawaited(_replaceWithArchivedCopy(track));
          },
        ),
      if (isDownloaded && canRedownload)
        tile(
          key: const ValueKey('track-actions-redownload'),
          icon: Icons.refresh,
          title: 'Download a new copy',
          subtitle: 'Your current file stays until the new one is finished',
          onTap: () {
            close();
            unawaited(_redownloadTrack(track));
          },
        ),
      if (canChooseQuality)
        tile(
          key: const ValueKey('track-actions-video-quality'),
          icon: Icons.high_quality_outlined,
          title: 'Video quality',
          subtitle:
              track.videoQuality == null
                  ? 'Playlist default (${videoQualityLabel(playlist.videoQuality)})'
                  : videoQualityLabel(track.videoQuality),
          onTap: () {
            close();
            unawaited(_chooseTrackVideoQuality(track));
          },
        ),
      if (inTemporaryPlaylist && !isDownloading)
        tile(
          key: const ValueKey('track-actions-remove-temporary'),
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFE57373),
          title: 'Remove from Temporary',
          subtitle: 'Deletes its file',
          onTap: () {
            close();
            unawaited(_removeFromTemporary(track));
          },
        ),
      if (canDownloadOriginal)
        tile(
          key: const ValueKey('track-actions-download-original'),
          icon: Icons.cloud_download,
          title: 'Download original',
          subtitle:
              'Get the YouTube version on the next update; your file is '
              'kept',
          onTap: () async {
            close();
            await ref
                .read(playlistServiceProvider)
                .requestOriginalDownload(track);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'The original downloads on the next update. Your file is '
                  'kept until then.',
                ),
              ),
            );
          },
        ),
      if (isYouTubeVideo) ...[
        const _SheetSection('YouTube'),
        if (canSaveToTemporary)
          tile(
            key: const ValueKey('track-actions-save-temporary'),
            icon: Icons.watch_later_outlined,
            title: 'Save to Temporary playlist',
            subtitle: 'Download this video for watching offline',
            onTap: () {
              close();
              unawaited(_saveToTemporary(track));
            },
          ),
        tile(
          key: const ValueKey('track-actions-open-youtube'),
          icon: Icons.open_in_new,
          title: 'Open on YouTube',
          onTap: () {
            close();
            launchUrl(Uri.parse(_videoUrl(track)));
          },
        ),
        tile(
          key: const ValueKey('track-actions-share'),
          icon: Icons.share,
          title: 'Share link',
          subtitle: 'Share the YouTube link',
          onTap: () {
            close();
            unawaited(_shareTrack(track));
          },
        ),
        tile(
          key: const ValueKey('track-actions-copy-id'),
          icon: Icons.copy,
          title: 'Copy video ID',
          subtitle: track.videoId,
          onTap: () {
            Clipboard.setData(ClipboardData(text: track.videoId));
            close();
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Video ID copied')));
          },
        ),
        tile(
          key: const ValueKey('track-actions-find-quietaplaylist'),
          icon: Icons.travel_explore,
          title: 'Find in web archives',
          subtitle: 'Search quiteaplaylist.com for this video',
          onTap: () {
            close();
            launchUrl(
              Uri.https('quiteaplaylist.com', '/search', {
                'url': _videoUrl(track),
              }),
            );
          },
        ),
      ],
    ];
  }

  Future<void> _addToQueue(Track track, {bool next = false}) async {
    final playbackService = ref.read(playbackServiceProvider);
    final added =
        next
            ? await playbackService.playNext(track)
            : await playbackService.addToUpNextQueue(track);
    if (!mounted) return;
    if (!added) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That track cannot be added to the queue'),
        ),
      );
      return;
    }
    final started = await playbackService.startUpNextQueueIfIdle();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started
              ? 'Playing "${track.title}"'
              : next
              ? 'Plays next'
              : 'Added to Up next',
        ),
      ),
    );
  }

  Future<void> _retryRemovedOnNextUpdate(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(playlistServiceProvider).retryRemovedTrack(track.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('The next update tries it again')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save: ${_errorText(e)}')),
      );
    }
  }

  Future<void> _shareTrack(Track track) async {
    try {
      await SharePlus.instance.share(
        ShareParams(uri: Uri.parse(_videoUrl(track)), title: track.title),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }

  Future<void> _pickLocalReplacement(Track track) async {
    final playlist = _playlist;
    if (playlist == null) return;

    if (!await Directory(playlist.outputPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playlist folder not found')),
        );
      }
      return;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'm4a',
          'mp3',
          'opus',
          'ogg',
          'flac',
          'wav',
          'mp4',
          'mkv',
          'webm',
          'avi',
          'mov',
        ],
        withData: false,
      );
    } catch (_) {
      // Some platforms reject FileType.custom — fall back to any file.
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
    }
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final sourcePath = picked.path;
    if (sourcePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not access picked file')),
        );
      }
      return;
    }

    final currentPath = track.filePath;
    var explanation = '"${picked.name}" becomes the file of "${track.title}".';
    if (currentPath != null && await File(currentPath).exists()) {
      explanation +=
          "\n\nThe current file is not deleted: it is kept in this playlist's "
          'replaced-files folder (.woolytube_replaced).';
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Use this file?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              explanation,
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('local-replacement-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final updated = await ref
          .read(playlistServiceProvider)
          .replaceWithLocalFile(
            trackId: track.id,
            sourcePath: sourcePath,
            sourceFileName: picked.name,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Replaced with ${p.basename(updated.filePath!)}'),
          ),
        );
      }
    } on LibraryBusyException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Replacement failed: ${_errorText(e)}')),
        );
      }
    }
  }

  /// Downloads a link the owner pastes (a reupload of a removed video) and
  /// uses it as this track's file, like [_pickLocalReplacement] does with a
  /// file from the phone.
  Future<void> _replaceWithReupload(Track track) async {
    if (_playlist == null) return;

    String? clipboard;
    try {
      clipboard = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      // Prefilling is a convenience only.
    }
    if (!mounted) return;
    final prefill =
        clipboard != null &&
                PlaylistService.parseReuploadUrl(clipboard) != null &&
                !clipboard.contains(track.videoId)
            ? clipboard.trim()
            : '';
    final hasFile =
        track.filePath != null && await File(track.filePath!).exists();
    if (!mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder:
          (_) => _ReuploadLinkDialog(
            title: track.title,
            initialUrl: prefill,
            keepsCurrentFile: hasFile,
          ),
    );
    if (url == null || !mounted) return;
    await _downloadReplacement(track, url, source: 'the reupload');
  }

  /// Downloads the Wayback Machine's saved copy of the video and uses it as
  /// this track's file.
  Future<void> _replaceWithArchivedCopy(Track track) async {
    final hasFile =
        track.filePath != null && await File(track.filePath!).exists();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Download archived copy?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              'The copy of this video saved by the Wayback Machine '
              '(web.archive.org) becomes the file of "${track.title}". '
              'The track keeps its place and title.'
              '${hasFile ? "\n\nThe current file is not deleted: it is kept "
                      "in this playlist's replaced-files folder "
                      "(.woolytube_replaced)." : ""}',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('archived-copy-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Download'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    await _downloadReplacement(
      track,
      PlaylistService.archivedCopyUrl(track.videoId),
      source: 'the archived copy',
    );
  }

  /// Downloads [url] and makes it [track]'s file, like a file picked with
  /// [_pickLocalReplacement]. [source] names it in messages.
  Future<void> _downloadReplacement(
    Track track,
    String url, {
    required String source,
  }) async {
    final playlist = _playlist;
    if (playlist == null) return;
    final downloadService = ref.read(downloadServiceProvider);
    void showMessage(String message) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }

    if (downloadService.isDownloading) {
      showMessage('A download is already in progress');
      return;
    }
    if (explainDownloadsUnavailable(context, ref)) return;
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    if (downloadService.isDownloading) {
      showMessage('A download is already in progress');
      return;
    }

    showMessage('Downloading $source of "${track.title}"');
    final playlistService = ref.read(playlistServiceProvider);
    unawaited(
      downloadService
          .downloadReupload(
            playlist,
            track,
            url,
            adopt:
                (media) => playlistService.replaceWithReuploadFile(
                  trackId: track.id,
                  downloadedPath: media.path,
                ),
          )
          .then(
            (done) => showMessage(
              done
                  ? 'Replaced "${track.title}" with $source'
                  : 'Stopped; nothing was changed',
            ),
            onError:
                (Object e, StackTrace _) => showMessage(
                  'Could not download $source: '
                  '${friendlyDownloadError(_errorText(e))}',
                ),
          ),
    );
  }

  Future<void> _showOverrideDialog(Track track) async {
    if (_playlist == null) return;

    final filePath = track.filePath;
    final hasFile = filePath != null && await File(filePath).exists();
    final currentBasename = hasFile ? p.basenameWithoutExtension(filePath) : '';
    // Strip leading "<digits>_" so the field shows just the editable portion.
    final nameWithoutPrefix = currentBasename.replaceFirst(
      RegExp(r'^\d+_'),
      '',
    );
    if (!mounted) return;

    final edit = await showDialog<_TrackRenameResult>(
      context: context,
      builder:
          (_) => _TrackRenameDialog(
            title: track.title,
            fileName: nameWithoutPrefix,
            hasFile: hasFile,
          ),
    );
    if (edit == null || !mounted) return;

    final newFilename = edit.fileName.trim();
    String message;
    try {
      // The service renames inside the library gate, so a running download
      // or update cannot attach the file to the wrong track meanwhile.
      final changed = await ref
          .read(playlistServiceProvider)
          .overrideTrack(
            trackId: track.id,
            title: edit.title,
            // An untouched field must not rename a file whose name the
            // sanitizer would spell differently.
            fileName:
                hasFile && newFilename != nameWithoutPrefix
                    ? newFilename
                    : null,
          );
      message = changed ? 'Saved' : 'Nothing changed';
    } on LibraryBusyException catch (e) {
      message = e.message;
    } on StateError catch (e) {
      message = e.message;
    } catch (e) {
      message = 'Rename failed: $e';
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showErrorDetails(Track track) async {
    final raw = track.lastError ?? '';
    final isAgeGate = isAgeGateDownloadError(raw);

    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFAA6666)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    friendlyDownloadError(raw),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      raw,
                      style: const TextStyle(
                        color: Color(0xFFCCCCCC),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (isAgeGate) ...[
                      const SizedBox(height: 16),
                      const Divider(color: Color(0xFF444444), height: 1),
                      const SizedBox(height: 12),
                      const Text(
                        'This video requires a signed-in session to confirm age. '
                        'WoolyTube automatically tries to bypass this using '
                        "YouTube's TV client, but this particular video can't be "
                        'fetched without cookies from a logged-in browser.',
                        style: TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _startTrackDownload(track);
                },
                child: const Text('Retry'),
              ),
            ],
          ),
    );
  }

  /// Downloads one track now. For a downloaded track this fetches a fresh
  /// copy; the service replaces the current file only once the new one is
  /// complete, so a failed download changes nothing.
  Future<void> _startTrackDownload(Track track) async {
    final playlist = _playlist;
    if (playlist == null) return;

    final downloadService = ref.read(downloadServiceProvider);
    void showBusy() {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A download is already in progress')),
      );
    }

    if (downloadService.isDownloading) {
      showBusy();
      return;
    }
    if (explainDownloadsUnavailable(context, ref)) return;

    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      return;
    }
    // downloadTrack ignores a call while another download runs, which
    // could have started during the dialog above.
    if (downloadService.isDownloading) {
      showBusy();
      return;
    }

    final hadFile = track.status == 'complete' && track.filePath != null;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloading "${track.title}"')));
    }

    unawaited(
      downloadService
          .downloadTrack(playlist, track)
          .then(
            (downloaded) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    downloaded
                        ? 'Downloaded "${track.title}"'
                        : 'Stopped; nothing was changed',
                  ),
                ),
              );
            },
            onError: (Object e, StackTrace _) {
              // The service throws the recorded yt-dlp reason itself.
              final reason = friendlyDownloadError(_errorText(e));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    hadFile
                        ? 'Could not download a new copy of "${track.title}"; '
                            'the current file was kept. $reason'
                        : 'Download failed: $reason',
                  ),
                ),
              );
            },
          ),
    );
  }

  Future<void> _redownloadTrack(Track track) async {
    final hasFile = track.status == 'complete' && track.filePath != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Download a new copy?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              hasFile
                  ? 'A fresh copy of "${track.title}" is downloaded from '
                      'YouTube. The current file is replaced only once the '
                      'new one has finished downloading. If the download '
                      'fails, nothing changes.'
                  : '"${track.title}" will be downloaded from YouTube.',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Download'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    await _startTrackDownload(track);
  }

  /// Saves this video (as a video, whatever this playlist downloads) to the
  /// temporary playlist and downloads it.
  Future<void> _saveToTemporary(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      message = await saveVideoToTemporary(context, ref, {
        'id': track.videoId,
        'title': track.title,
        'thumbnail': track.thumbnailUrl,
        'duration': track.durationSeconds,
      });
    } catch (e) {
      message = 'Could not save: ${_errorText(e)}';
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Takes a video out of the temporary playlist and deletes its file.
  Future<void> _removeFromTemporary(Track track) async {
    final downloads = ref.read(downloadServiceProvider);
    final downloading =
        downloads.isDownloading &&
        downloads.activePlaylistId == widget.playlistId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text(
              'Remove from Temporary?',
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              '"${track.title}" is removed and its file is deleted.'
              '${downloading ? ' The running download stops for a moment.' : ''}',
              style: const TextStyle(color: Color(0xFFCCCCCC)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('remove-temporary-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await removeTemporaryVideos(ref, widget.playlistId, {
      track.id,
    });
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? 'Removed "${track.title}"')),
    );
  }

  /// Saves this video's own quality, then offers to download it again when
  /// its file would change.
  Future<void> _chooseTrackVideoQuality(Track track) async {
    final playlist = _playlist;
    if (playlist == null) return;
    final picked = await showVideoQualityPicker(
      context,
      current: track.videoQuality,
      forTrack: true,
      playlistQuality: playlist.videoQuality,
    );
    if (picked == null || !mounted || picked.value == track.videoQuality) {
      return;
    }
    void showMessage(String message) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }

    final playlists = ref.read(playlistServiceProvider);
    final updated = track.copyWith(videoQuality: Value(picked.value));
    final List<Track> affected;
    try {
      await playlists.setTrackVideoQuality(track.id, picked.value);
      affected = await playlists.tracksAffectedByQualityChange(
        playlist,
        oldMax: effectiveMaxHeight(playlist, track),
        newMax: effectiveMaxHeight(playlist, updated),
        only: [updated],
      );
    } catch (e) {
      showMessage('Could not save: ${_errorText(e)}');
      return;
    }
    if (affected.isEmpty || !mounted) return;
    final newMax = effectiveMaxHeight(playlist, updated);
    if (!await confirmQualityRedownload(
          context,
          count: 1,
          maxHeight: newMax,
          singleTrack: true,
        ) ||
        !mounted) {
      return;
    }
    final downloads = ref.read(downloadServiceProvider);
    if (!downloads.isDownloading) {
      await _startTrackDownload(updated);
      return;
    }
    // Another download runs: the new copy follows it.
    try {
      await playlists.requestRedownload(playlist.id, [track.id]);
    } catch (e) {
      showMessage('Could not save: ${_errorText(e)}');
      return;
    }
    if (!mounted || explainDownloadsUnavailable(context, ref)) return;
    if (!await confirmManualDownload(
      context,
      ref.read(downloadNetworkPolicyProvider),
    )) {
      showMessage('"${track.title}" downloads again at the next update');
      return;
    }
    final fresh = await ref
        .read(databaseProvider)
        .getPlaylistOrNull(playlist.id);
    if (fresh == null) return;
    unawaited(
      downloads
          .downloadPlaylist(fresh, sourceChecked: false)
          .catchError((Object _) => DownloadStart.started),
    );
    showMessage('"${track.title}" downloads again after the current download');
  }

  Future<void> _showSkipSegments(Track track) async {
    final db = ref.read(databaseProvider);
    final playback = ref.read(playbackServiceProvider);
    final segments = await db.getSegmentsForTrack(track.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder:
          (_) => _SkipSegmentsSheet(
            track: track,
            db: db,
            initialSegments: segments,
            onChanged: playback.refreshCurrentSegments,
            onError: (message) {
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(message)));
            },
          ),
    );
  }
}

/// Asks for the link of a reupload. Pops with the link, or null.
class _ReuploadLinkDialog extends StatefulWidget {
  const _ReuploadLinkDialog({
    required this.title,
    required this.initialUrl,
    required this.keepsCurrentFile,
  });

  final String title;
  final String initialUrl;
  final bool keepsCurrentFile;

  @override
  State<_ReuploadLinkDialog> createState() => _ReuploadLinkDialogState();
}

class _ReuploadLinkDialogState extends State<_ReuploadLinkDialog> {
  late final _controller = TextEditingController(text: widget.initialUrl);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (PlaylistService.parseReuploadUrl(text) == null) {
      setState(
        () =>
            _error =
                text.isEmpty
                    ? 'Paste a link'
                    : 'Paste a link to one video, not a playlist',
      );
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    var explanation =
        'The video at this link is downloaded and becomes the file of '
        '"${widget.title}". The track keeps its place and title.';
    if (widget.keepsCurrentFile) {
      explanation +=
          "\n\nThe current file is not deleted: it is kept in this playlist's "
          'replaced-files folder (.woolytube_replaced).';
    }
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text(
        'Replace with a reupload',
        style: TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(explanation, style: const TextStyle(color: Color(0xFFCCCCCC))),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('reupload-link-field'),
              controller: _controller,
              autofocus: widget.initialUrl.isEmpty,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Link to the reupload',
                hintText: 'https://www.youtube.com/watch?v=…',
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final text =
                        (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                    if (text == null || !mounted) return;
                    setState(() {
                      _controller.text = text.trim();
                      _error = null;
                    });
                  },
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('reupload-link-confirm'),
          onPressed: _submit,
          child: const Text('Download'),
        ),
      ],
    );
  }
}

class _SheetSection extends StatelessWidget {
  const _SheetSection(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          color: _accent,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Artwork, title and '#index · duration · status' at the top of the
/// track options sheet.
class _TrackSheetHeader extends StatelessWidget {
  const _TrackSheetHeader({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final state = _TrackState.of(track);
    final duration = _formatDuration(track.durationSeconds);
    final status = switch (track.status) {
      'complete' when state.hasLocalFile =>
        '${_unavailableLabel(track.unavailableReason)} (local file)',
      'complete' when track.isLocalReplacement => 'Your own file',
      'complete' => 'Downloaded',
      'downloading' => 'Downloading…',
      'error' => 'Download failed',
      'unavailable' => _unavailableLabel(track.unavailableReason),
      _ => 'Not downloaded',
    };
    final details = [
      '#${track.index}',
      if (duration.isNotEmpty) duration,
      status,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            height: 63,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _TrackArtwork(track: track, logicalWidth: 112),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.title,
                  key: const ValueKey('track-actions-title'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  details,
                  key: const ValueKey('track-actions-details'),
                  style: TextStyle(
                    color:
                        state.hasError || state.isUnavailable
                            ? const Color(0xFFAA6666)
                            : _muted,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
