import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woolytube/services/media_thumbnail_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('woolytube_thumb_cache_');
  });

  tearDown(() async {
    forgetThumbnailsUnder(tempDir.path);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a cover found once is not looked up on disk again', () async {
    final path = p.join(tempDir.path, 'a.jpg');
    expect(existingThumbnailPath(path), isNull);

    // A missing answer is not remembered: the cover shows once it exists.
    await File(path).writeAsBytes(const [1]);
    expect(existingThumbnailPath(path), path);

    // Deleted behind the app's back: still answered from memory (the image
    // widgets fall back on a load error) ...
    await File(path).delete();
    expect(existingThumbnailPath(path), path);
    // ... until the app learns about it.
    expect(await thumbnailFileExists(path), isFalse);
    expect(existingThumbnailPath(path), isNull);
  });

  test('writes and removals keep the memory up to date', () async {
    final path = p.join(tempDir.path, 'covers', 'b.jpg');
    noteThumbnailWritten(path);
    expect(existingThumbnailPath(path), path);
    noteThumbnailRemoved(path);
    expect(existingThumbnailPath(path), isNull);

    noteThumbnailWritten(path);
    forgetThumbnailsUnder(tempDir.path);
    expect(existingThumbnailPath(path), isNull);
    expect(existingThumbnailPath(null), isNull);
    expect(existingThumbnailPath(''), isNull);
  });
}
