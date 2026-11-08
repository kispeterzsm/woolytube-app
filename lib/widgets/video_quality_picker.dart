import 'package:flutter/material.dart';

import '../services/video_quality.dart';

/// The choice "follow the playlist" in the picker's radio group.
const _inherit = -1;

/// Asks for a video quality. Returns null when cancelled, otherwise the
/// chosen value in a record (whose value may itself be null).
///
/// For a playlist ([forTrack] false) the value is null for the best or the
/// height cap. For one video ([forTrack] true) it is null to follow the
/// playlist ([playlistQuality]), 0 for the best, or the height cap.
Future<({int? value})?> showVideoQualityPicker(
  BuildContext context, {
  required int? current,
  bool forTrack = false,
  int? playlistQuality,
}) async {
  final selected = forTrack ? (current ?? _inherit) : (current ?? 0);
  final picked = await showDialog<int>(
    context: context,
    builder:
        (ctx) => SimpleDialog(
          key: const ValueKey('video-quality-picker'),
          title: const Text('Video quality'),
          children: [
            if (forTrack)
              RadioListTile<int>(
                key: const ValueKey('video-quality-option-inherit'),
                value: _inherit,
                groupValue: selected,
                title: const Text('Playlist default'),
                subtitle: Text(videoQualityLabel(playlistQuality)),
                onChanged: (value) => Navigator.pop(ctx, value),
              ),
            RadioListTile<int>(
              key: const ValueKey('video-quality-option-best'),
              value: 0,
              groupValue: selected,
              title: Text(videoQualityLabel(null)),
              onChanged: (value) => Navigator.pop(ctx, value),
            ),
            for (final cap in videoQualityCaps)
              RadioListTile<int>(
                key: ValueKey('video-quality-option-$cap'),
                value: cap,
                groupValue: selected,
                title: Text(videoQualityLabel(cap)),
                onChanged: (value) => Navigator.pop(ctx, value),
              ),
          ],
        ),
  );
  if (picked == null) return null;
  if (picked == _inherit) return (value: null);
  if (picked == 0) return (value: forTrack ? 0 : null);
  return (value: picked);
}

/// Asks whether to download [count] videos again now that their quality is
/// [maxHeight] (null = the best). True means download them again.
/// [singleTrack] asks about the one video whose own quality changed.
Future<bool> confirmQualityRedownload(
  BuildContext context, {
  required int count,
  required int? maxHeight,
  bool singleTrack = false,
}) async {
  final videos =
      singleTrack ? 'this video' : '$count ${count == 1 ? 'video' : 'videos'}';
  final answer = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          key: const ValueKey('video-quality-redownload-dialog'),
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text(
            'Download $videos again at ${videoQualityShortLabel(maxHeight)}?',
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            singleTrack
                ? 'The current file stays until the new copy is finished. '
                    'If you keep it, the new quality is used the next time '
                    'this video is downloaded.'
                : 'Each file stays until its new copy is finished. If you '
                    'skip this, only new downloads use the new quality.',
            style: const TextStyle(color: Color(0xFFCCCCCC)),
          ),
          actions: [
            TextButton(
              key: const ValueKey('video-quality-keep'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                singleTrack ? 'Keep current file' : 'Only new downloads',
              ),
            ),
            TextButton(
              key: const ValueKey('video-quality-redownload'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download again'),
            ),
          ],
        ),
  );
  return answer == true;
}
