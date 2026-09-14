import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/ytdlp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.woolytube/ytdlp');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native downloads receive subtitle options and exclude audio downloads',
    () async {
      final service = YtDlpService();
      for (final audioOnly in [false, true]) {
        await service.download(
          url: 'https://www.youtube.com/watch?v=test',
          outputPath: '/downloads',
          audioOnly: audioOnly,
          downloadSubtitles: true,
          subtitleLanguages: 'en,hu',
        );
        expect(calls.last.method, 'download');
        expect(calls.last.arguments['downloadSubtitles'], !audioOnly);
        expect(calls.last.arguments['subtitleLanguages'], 'en,hu');
      }
    },
  );
}
