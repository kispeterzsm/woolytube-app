import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';

/// Answers at least this long are decoded on a worker isolate. The flat
/// listing of a 600-video playlist is several hundred kilobytes, and
/// decoding it on the UI isolate drops frames.
const backgroundJsonDecodeThreshold = 64 * 1024;

/// Decodes a yt-dlp JSON answer, off the UI isolate when it is large.
Future<Map<String, dynamic>> decodeYtDlpJson(String raw) {
  if (raw.length < backgroundJsonDecodeThreshold) {
    return Future.value(jsonDecode(raw) as Map<String, dynamic>);
  }
  return Isolate.run(() => jsonDecode(raw) as Map<String, dynamic>);
}

class YtDlpService {
  static const _methodChannel = MethodChannel('com.woolytube/ytdlp');
  static const _eventChannel = EventChannel('com.woolytube/ytdlp_progress');

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Stream<Map<String, dynamic>>? _progressStream;

  Stream<Map<String, dynamic>> get progressStream {
    _progressStream ??= _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => Map<String, dynamic>.from(event as Map));
    return _progressStream!;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _methodChannel.invokeMethod('initialize');
        _initialized = true;
        return;
      } on MissingPluginException {
        if (attempt == 4) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  /// Runs one yt-dlp download.
  ///
  /// [writeThumbnail] keeps the cover as a JPEG beside the media,
  /// [embedMetadata] writes title/artist/date/URL tags into the file, and
  /// [metadataAlbum]/[metadataTrackNumber] tag it as track N of the playlist
  /// so other players keep the playlist together and in order.
  /// [maxHeight] caps the video resolution (720 = up to 720p); null takes
  /// the best. It is ignored for audio.
  Future<void> download({
    required String url,
    required String outputPath,
    String? formatOption,
    bool audioOnly = false,
    bool embedThumbnail = true,
    bool writeThumbnail = false,
    bool embedMetadata = false,
    String? metadataAlbum,
    int? metadataTrackNumber,
    bool downloadSubtitles = false,
    String subtitleLanguages = 'en',
    String? outputTemplate,
    int? maxHeight,
  }) async {
    await _methodChannel.invokeMethod('download', {
      'url': url,
      'outputPath': outputPath,
      if (formatOption != null) 'format': formatOption,
      'audioOnly': audioOnly,
      'embedThumbnail': embedThumbnail,
      'writeThumbnail': writeThumbnail,
      'embedMetadata': embedMetadata,
      if (metadataAlbum != null) 'metadataAlbum': metadataAlbum,
      if (metadataTrackNumber != null)
        'metadataTrackNumber': metadataTrackNumber,
      'downloadSubtitles': downloadSubtitles && !audioOnly,
      'subtitleLanguages': subtitleLanguages,
      if (outputTemplate != null) 'outputTemplate': outputTemplate,
      if (maxHeight != null && maxHeight > 0 && !audioOnly)
        'maxHeight': maxHeight,
    });
  }

  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    final result = await _methodChannel.invokeMethod<String>('getVideoInfo', {
      'url': url,
    });
    return decodeYtDlpJson(result!);
  }

  /// Info for lyrics and transcripts: `id`, `title`, `duration`,
  /// `language`, `description`, `uploader`, `channel`, `artist`, `track`,
  /// `alt_title`, and `subtitles` / `automatic_captions` trimmed to one
  /// json3 entry (`{ext, url, name}`) per manual language and per `-orig`
  /// speech-to-text track. Caption URLs expire after a few hours.
  Future<Map<String, dynamic>> getCaptionInfo(String url) async {
    final result = await _methodChannel.invokeMethod<String>('getCaptionInfo', {
      'url': url,
    });
    return decodeYtDlpJson(result!);
  }

  /// A video's whole description for its kept `.info.json` (uploader,
  /// upload date, description, tags, chapters, ...), without the
  /// download-only parts. Downloads nothing.
  Future<Map<String, dynamic>> getVideoInfoToKeep(String url) async {
    final result = await _methodChannel.invokeMethod<String>(
      'getVideoInfoToKeep',
      {'url': url},
    );
    return decodeYtDlpJson(result!);
  }

  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    final result = await _methodChannel.invokeMethod<String>(
      'getPlaylistInfo',
      {'url': url},
    );
    return decodeYtDlpJson(result!);
  }

  Future<void> cancelDownloads() async {
    await _methodChannel.invokeMethod('cancelDownloads');
  }

  Future<bool> hasActiveDownloads() async {
    return await _methodChannel.invokeMethod<bool>('hasActiveDownloads') ??
        false;
  }

  Future<void> updateYtDlp() async {
    await _methodChannel.invokeMethod('updateYtDlp');
  }

  Future<void> startDownloadService(String playlistName) async {
    await _methodChannel.invokeMethod('startDownloadService', {
      'playlistName': playlistName,
    });
  }

  Future<void> updateDownloadServiceProgress({
    required String playlistName,
    required int currentTrack,
    required int totalTracks,
    required int progress,
    String? trackTitle,
  }) async {
    await _methodChannel.invokeMethod('updateDownloadServiceProgress', {
      'playlistName': playlistName,
      'currentTrack': currentTrack,
      'totalTracks': totalTracks,
      'progress': progress,
      // Shown instead of "Track n of total" when given.
      if (trackTitle != null) 'trackTitle': trackTitle,
    });
  }

  Future<void> stopDownloadService() async {
    await _methodChannel.invokeMethod('stopDownloadService');
  }
}
