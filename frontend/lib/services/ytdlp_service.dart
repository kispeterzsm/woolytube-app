import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

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

  Future<void> download({
    required String url,
    required String outputPath,
    String? formatOption,
    bool audioOnly = false,
    bool embedThumbnail = true,
    String? outputTemplate,
  }) async {
    await _methodChannel.invokeMethod('download', {
      'url': url,
      'outputPath': outputPath,
      if (formatOption != null) 'format': formatOption,
      'audioOnly': audioOnly,
      'embedThumbnail': embedThumbnail,
      if (outputTemplate != null) 'outputTemplate': outputTemplate,
    });
  }

  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    final result = await _methodChannel.invokeMethod<String>('getVideoInfo', {
      'url': url,
    });
    return jsonDecode(result!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPlaylistInfo(String url) async {
    final result =
        await _methodChannel.invokeMethod<String>('getPlaylistInfo', {
      'url': url,
    });
    return jsonDecode(result!) as Map<String, dynamic>;
  }

  Future<void> cancelDownload(String processId) async {
    await _methodChannel.invokeMethod('cancelDownload', {
      'processId': processId,
    });
  }

  Future<void> updateYtDlp() async {
    await _methodChannel.invokeMethod('updateYtDlp');
  }
}
