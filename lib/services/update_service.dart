import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.currentVersion,
    required this.downloadUri,
    required this.releaseUri,
  });

  final String version;
  final String currentVersion;
  final Uri downloadUri;
  final Uri releaseUri;
}

class UpdateService {
  UpdateService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  static final Uri _latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/kispeterzsm/woolytube-app/releases/latest',
  );

  final HttpClient _httpClient;

  Future<AppUpdate?> checkForUpdate({String? currentVersion}) async {
    final installedVersion =
        currentVersion ?? (await PackageInfo.fromPlatform()).version;
    final release = await _fetchLatestRelease();
    if (release == null || !isVersionNewer(release.version, installedVersion)) {
      return null;
    }

    return AppUpdate(
      version: release.version,
      currentVersion: installedVersion,
      downloadUri: release.downloadUri,
      releaseUri: release.releaseUri,
    );
  }

  Future<_GitHubRelease?> _fetchLatestRelease() async {
    final request = await _httpClient.getUrl(_latestReleaseUri);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'WoolyTube update checker',
    );

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == HttpStatus.notFound) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GitHub releases API returned ${response.statusCode}',
        uri: _latestReleaseUri,
      );
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected GitHub release response');
    }

    final tagName = decoded['tag_name'];
    final releaseUrl = decoded['html_url'];
    final assets = decoded['assets'];
    if (tagName is! String || releaseUrl is! String || assets is! List) {
      throw const FormatException('Missing GitHub release fields');
    }

    final apkUri = _findApkUri(assets);
    if (apkUri == null) {
      return null;
    }

    return _GitHubRelease(
      version: normalizeVersion(tagName),
      releaseUri: Uri.parse(releaseUrl),
      downloadUri: apkUri,
    );
  }

  Uri? _findApkUri(List<dynamic> assets) {
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;

      final name = asset['name'];
      final downloadUrl = asset['browser_download_url'];
      if (name is! String || downloadUrl is! String) continue;

      if (name.toLowerCase().endsWith('.apk')) {
        return Uri.parse(downloadUrl);
      }
    }

    return null;
  }
}

class _GitHubRelease {
  const _GitHubRelease({
    required this.version,
    required this.releaseUri,
    required this.downloadUri,
  });

  final String version;
  final Uri releaseUri;
  final Uri downloadUri;
}

String normalizeVersion(String version) {
  var normalized = version.trim();
  if (normalized.startsWith('v') || normalized.startsWith('V')) {
    normalized = normalized.substring(1);
  }
  return normalized.split('+').first.split('-').first;
}

bool isVersionNewer(String candidateVersion, String currentVersion) {
  final candidate = _parseVersion(candidateVersion);
  final current = _parseVersion(currentVersion);
  if (candidate == null || current == null) {
    return false;
  }

  for (var i = 0; i < 3; i++) {
    if (candidate[i] > current[i]) return true;
    if (candidate[i] < current[i]) return false;
  }
  return false;
}

List<int>? _parseVersion(String version) {
  final normalized = normalizeVersion(version);
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(normalized);
  if (match == null) return null;

  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}
