import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:woolytube/services/media_thumbnail_service.dart';
import 'package:woolytube/services/ytdlp_service.dart';

/// One call of [FakeYtDlpService.download] with every option it received.
class FakeDownloadCall {
  FakeDownloadCall({
    required this.url,
    required this.outputPath,
    required this.audioOnly,
    required this.embedThumbnail,
    required this.writeThumbnail,
    required this.embedMetadata,
    required this.metadataAlbum,
    required this.metadataTrackNumber,
    required this.downloadSubtitles,
    required this.subtitleLanguages,
    required this.outputTemplate,
    this.maxHeight,
  });

  final String url;
  final String outputPath;
  final bool audioOnly;
  final bool embedThumbnail;
  final bool writeThumbnail;
  final bool embedMetadata;
  final String? metadataAlbum;
  final int? metadataTrackNumber;
  final bool downloadSubtitles;
  final String subtitleLanguages;
  final String? outputTemplate;
  final int? maxHeight;

  String get videoId => Uri.parse(url).queryParameters['v'] ?? '';
}

/// Stands in for yt-dlp. A successful download leaves what yt-dlp leaves at
/// the output template: the media file, a `.jpg` cover when asked to keep
/// one, and an `.info.json`.
class FakeYtDlpService extends YtDlpService {
  final calls = <FakeDownloadCall>[];

  List<String> get downloadedUrls => [for (final c in calls) c.url];
  List<String> get outputTemplates => [
    for (final c in calls) c.outputTemplate ?? '',
  ];
  List<(bool, String)> get subtitleRequests => [
    for (final c in calls) (c.downloadSubtitles, c.subtitleLanguages),
  ];

  Map<String, dynamic> playlistInfo = {'entries': <dynamic>[]};
  final requestedPlaylistUrls = <String>[];

  Completer<void>? downloadCompleter;
  Completer<void>? downloadStarted;
  bool cancelCalled = false;

  /// Thrown before anything is written.
  Object? downloadError;

  /// Decides per call whether to fail before anything is written.
  Object? Function(FakeDownloadCall call)? errorFor;

  /// Thrown after the files were written, like a failed post-processing
  /// step that leaves a complete file behind.
  Object? errorAfterOutput;

  bool createOutputFile = true;
  bool createThumbnailFile = true;
  bool createInfoJson = true;
  String title = 'Title';
  String mediaContent = 'media';
  Map<String, dynamic> Function(FakeDownloadCall call)? infoFor;

  /// Media files written so far, in order.
  final writtenMedia = <String>[];

  static final _titleField = RegExp(r'%\(title\)(?:\.\d+B|s)');

  /// Expands the yt-dlp fields the app uses in its output template.
  static String expandTemplate(
    String template, {
    required String title,
    required String ext,
  }) => template
      .replaceAll(_titleField, title)
      .replaceAll('%(ext)s', ext)
      .replaceAll('%%', '%');

  Map<String, dynamic> defaultInfo(FakeDownloadCall call) => {
    'id': call.videoId,
    'title': title,
    'uploader': 'Uploader',
    'upload_date': '20240101',
    'description': 'Kept because YouTube may delete it',
    'duration': 60,
    'formats': [
      {'format_id': '140', 'url': 'https://example.com/stream'},
    ],
    'thumbnails': [
      {'url': 'https://example.com/thumb.jpg'},
    ],
    'http_headers': {'User-Agent': 'x'},
  };

  @override
  Stream<Map<String, dynamic>> get progressStream =>
      const Stream<Map<String, dynamic>>.empty();

  @override
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
    final call = FakeDownloadCall(
      url: url,
      outputPath: outputPath,
      audioOnly: audioOnly,
      embedThumbnail: embedThumbnail,
      writeThumbnail: writeThumbnail,
      embedMetadata: embedMetadata,
      metadataAlbum: metadataAlbum,
      metadataTrackNumber: metadataTrackNumber,
      downloadSubtitles: downloadSubtitles,
      subtitleLanguages: subtitleLanguages,
      outputTemplate: outputTemplate,
      maxHeight: maxHeight,
    );
    calls.add(call);
    final started = downloadStarted;
    if (started != null && !started.isCompleted) started.complete();
    final error = downloadError ?? errorFor?.call(call);
    if (error != null) throw error;
    if (downloadCompleter != null) await downloadCompleter!.future;
    if (createOutputFile && outputTemplate != null) {
      final media = expandTemplate(
        outputTemplate,
        title: title,
        ext: audioOnly ? 'm4a' : 'mp4',
      );
      await File(media).parent.create(recursive: true);
      await File(media).writeAsString(mediaContent);
      writtenMedia.add(media);
      final base = p.withoutExtension(media);
      if (writeThumbnail && createThumbnailFile) {
        await File('$base.jpg').writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
      }
      if (createInfoJson) {
        final info = infoFor?.call(call) ?? defaultInfo(call);
        await File('$base.info.json').writeAsString(jsonEncode(info));
      }
    }
    if (errorAfterOutput != null) throw errorAfterOutput!;
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    requestedPlaylistUrls.add(url);
    return playlistInfo;
  }

  @override
  Future<void> cancelDownloads() async {
    cancelCalled = true;
    if (downloadCompleter != null && !downloadCompleter!.isCompleted) {
      downloadCompleter!.completeError(StateError('cancelled'));
    }
  }

  @override
  Future<bool> hasActiveDownloads() async => false;

  @override
  Future<void> startDownloadService(String playlistName) async {}

  @override
  Future<void> updateDownloadServiceProgress({
    required String playlistName,
    required int currentTrack,
    required int totalTracks,
    required int progress,
  }) async {}

  /// Runs when the service stops the download notification; a test can
  /// return a future to hold the end of a run there.
  Future<void> Function()? onStopDownloadService;

  @override
  Future<void> stopDownloadService() async {
    await onStopDownloadService?.call();
  }
}

/// Writes `<targetStem>.jpg` like the native extractor when the media file
/// is supposed to carry a cover.
class FakeMediaThumbnailService extends MediaThumbnailService {
  bool hasEmbeddedThumbnail = false;
  final requests = <({String mediaPath, String targetStem})>[];

  List<String> get requestedMediaPaths => [
    for (final r in requests) r.mediaPath,
  ];

  @override
  Future<String?> extractEmbeddedThumbnail({
    required String mediaPath,
    required String targetStem,
  }) async {
    requests.add((mediaPath: mediaPath, targetStem: targetStem));
    if (!hasEmbeddedThumbnail) return null;
    final thumbnail = File('$targetStem.jpg');
    await thumbnail.parent.create(recursive: true);
    await thumbnail.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    return thumbnail.path;
  }
}
