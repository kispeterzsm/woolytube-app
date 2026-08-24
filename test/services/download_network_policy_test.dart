import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/download_network_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  DownloadNetworkPolicy policyFor(List<ConnectivityResult> results) {
    return DownloadNetworkPolicy(
      AppSettingsService(),
      checkConnectivity: () async => results,
    );
  }

  test('Wi-Fi downloads are allowed with the default setting', () async {
    final policy = policyFor([ConnectivityResult.wifi]);

    expect(await policy.manualDownloadDecision(), ManualDownloadDecision.allow);
  });

  test('mobile data requires confirmation by default', () async {
    final policy = policyFor([ConnectivityResult.mobile]);

    expect(
      await policy.manualDownloadDecision(),
      ManualDownloadDecision.confirmMobileData,
    );
  });

  test('mobile data is allowed when the setting is enabled', () async {
    SharedPreferences.setMockInitialValues({
      AppSettingsService.autoDownloadWithMobileDataKey: true,
    });
    final policy = policyFor([ConnectivityResult.mobile]);

    expect(await policy.manualDownloadDecision(), ManualDownloadDecision.allow);
  });

  test('a missing connection prevents a download', () async {
    final policy = policyFor([ConnectivityResult.none]);

    expect(
      await policy.manualDownloadDecision(),
      ManualDownloadDecision.offline,
    );
  });

  test(
    'Wi-Fi takes precedence when multiple transports are reported',
    () async {
      final policy = policyFor([
        ConnectivityResult.mobile,
        ConnectivityResult.wifi,
      ]);

      expect(await policy.currentConnection(), DownloadConnection.wifi);
    },
  );
}
