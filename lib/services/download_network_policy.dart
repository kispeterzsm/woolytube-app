import 'package:connectivity_plus/connectivity_plus.dart';

import 'app_settings_service.dart';

enum DownloadConnection { wifi, mobile, offline, other }

enum ManualDownloadDecision { allow, confirmMobileData, offline }

typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();

class DownloadNetworkPolicy {
  DownloadNetworkPolicy(this._settings, {ConnectivityCheck? checkConnectivity})
    : _checkConnectivity =
          checkConnectivity ?? Connectivity().checkConnectivity;

  final AppSettingsService _settings;
  final ConnectivityCheck _checkConnectivity;

  Future<DownloadConnection> currentConnection() async {
    final results = await _checkConnectivity();
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return DownloadConnection.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return DownloadConnection.mobile;
    }
    if (results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none)) {
      return DownloadConnection.offline;
    }
    return DownloadConnection.other;
  }

  Future<ManualDownloadDecision> manualDownloadDecision() async {
    final connection = await currentConnection();
    if (connection == DownloadConnection.offline) {
      return ManualDownloadDecision.offline;
    }
    if (connection == DownloadConnection.mobile &&
        !await _settings.getAutoDownloadWithMobileData()) {
      return ManualDownloadDecision.confirmMobileData;
    }
    return ManualDownloadDecision.allow;
  }
}
