/// Writing the app's own files into a playlist folder's `.woolytube_info`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes [content] to [path], a file directly inside a playlist folder's
/// info folder, unless it already holds exactly that. Returns whether it
/// wrote.
///
/// The content goes to a temporary file first and is then renamed into
/// place, so a file is never left half written. The info folder (with a
/// `.nomedia`) is created when missing, but the playlist folder never is:
/// when it is gone (deleted or moved meanwhile) nothing is written.
Future<bool> writeInfoFile(String path, String content) async {
  final target = File(path);
  try {
    if (await target.exists() && await target.readAsString() == content) {
      return false;
    }
  } catch (_) {
    // Unreadable: replaced below.
  }
  final infoDir = Directory(p.dirname(path));
  if (!await infoDir.parent.exists()) {
    throw FileSystemException('The playlist folder is gone', infoDir.path);
  }
  await infoDir.create();
  final noMedia = File(p.join(infoDir.path, '.nomedia'));
  if (!await noMedia.exists()) await noMedia.create();
  final tmp = File('$path.tmp');
  try {
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // Replaced by the next write.
    }
    rethrow;
  }
  return true;
}

/// The JSON object in the file at [path], or null when it is missing or
/// unreadable.
Future<Map<String, dynamic>?> readInfoJson(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}
