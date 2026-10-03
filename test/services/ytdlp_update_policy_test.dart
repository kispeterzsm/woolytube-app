import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/providers/providers.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/download_network_policy.dart';
import 'package:woolytube/services/ytdlp_service.dart';

class FakeYtDlpService extends YtDlpService {
  bool active = false;

  @override
  Future<bool> hasActiveDownloads() async => active;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeYtDlpService ytdlp;
  late AppSettingsService settings;
  var connectivity = [ConnectivityResult.wifi];
  final now = DateTime(2026, 10, 3, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ytdlp = FakeYtDlpService();
    settings = AppSettingsService();
    connectivity = [ConnectivityResult.wifi];
  });

  Future<bool> shouldRun() => shouldRunYtDlpSelfUpdate(
    ytdlp: ytdlp,
    settings: settings,
    networkPolicy: DownloadNetworkPolicy(
      settings,
      checkConnectivity: () async => connectivity,
    ),
    now: now,
  );

  test('runs on Wi-Fi when it has never run', () async {
    expect(await shouldRun(), isTrue);
  });

  test('runs at most once a day', () async {
    await settings.setLastYtDlpUpdateAttempt(
      now.subtract(const Duration(hours: 23)),
    );
    expect(await shouldRun(), isFalse);

    await settings.setLastYtDlpUpdateAttempt(
      now.subtract(const Duration(hours: 25)),
    );
    expect(await shouldRun(), isTrue);
  });

  test('never swaps the binary under a running download', () async {
    ytdlp.active = true;
    expect(await shouldRun(), isFalse);
  });

  test('respects the mobile-data preference', () async {
    connectivity = [ConnectivityResult.mobile];
    expect(await shouldRun(), isFalse);

    await settings.setAutoDownloadWithMobileData(true);
    expect(await shouldRun(), isTrue);
  });

  test('skips while offline', () async {
    connectivity = [ConnectivityResult.none];
    expect(await shouldRun(), isFalse);
  });
}
