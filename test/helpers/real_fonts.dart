import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads Roboto, the font the app uses on Android, from the Flutter SDK,
/// so text in a test is as wide as on a phone instead of the test font's
/// one-square-per-letter. Call it from `setUpAll`.
Future<void> loadRoboto() async {
  final dir = Directory('${_flutterRoot()}/bin/cache/artifacts/material_fonts');
  final loader = FontLoader('Roboto');
  for (final file in dir.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.startsWith('Roboto-') || !name.endsWith('.ttf')) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(
      Future.value(ByteData.sublistView(Uint8List.fromList(bytes))),
    );
  }
  await loader.load();
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  // flutter_tester lives in <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('Flutter SDK not found');
}

/// A 411 × 914 dp phone at 420 dpi, like the owner's.
void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1080 / 411;
  addTearDown(tester.view.reset);
}

/// Fails when any text under [finder] is cut with "…" or loses lines.
void expectNotCut(WidgetTester tester, Finder finder) {
  final elements = finder.evaluate().toList();
  expect(elements, isNotEmpty, reason: 'nothing found for $finder');
  for (final element in elements) {
    final paragraphs = <RenderParagraph>[];
    void collect(RenderObject object) {
      if (object is RenderParagraph) paragraphs.add(object);
      object.visitChildren(collect);
    }

    collect(element.renderObject!);
    expect(paragraphs, isNotEmpty, reason: 'no text in $finder');
    for (final paragraph in paragraphs) {
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '"${paragraph.text.toPlainText()}" is cut',
      );
    }
  }
}
