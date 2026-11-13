import '../database/database.dart';
import 'app_settings_service.dart';

/// Subtitle languages a playlist without its own list downloads.
const defaultSubtitleLanguages = 'en';

/// Checks and tidies a comma-separated list of subtitle language codes for
/// yt-dlp. Spaces and empty items (a trailing comma) are dropped. A code
/// may end in `.*` to also match its regional variants (`en.*` for en-US
/// and en-GB captions). 'all' is refused: it would download hundreds of
/// automatic translations.
String normalizeSubtitleLanguages(String value) {
  final languages =
      value
          .split(',')
          .map((code) => code.trim())
          .where((code) => code.isNotEmpty)
          .toSet();
  if (languages.isEmpty ||
      languages.any(
        (code) =>
            code.toLowerCase() == 'all' ||
            !RegExp(
              r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]+)*(?:\.\*)?$',
            ).hasMatch(code),
      )) {
    throw const FormatException(
      'Enter language codes separated by commas, such as en, hu, de.',
    );
  }
  return languages.join(',');
}

/// A stored or hand-edited language list (a metadata file, an old
/// setting): the tidied list, or null (English) when it is missing, empty
/// or something yt-dlp must not be given.
String? subtitleLanguagesOrNull(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  try {
    return normalizeSubtitleLanguages(value);
  } on FormatException {
    return null;
  }
}

/// The languages a download of [playlist] asks for.
String subtitleLanguagesFor(Playlist playlist) =>
    subtitleLanguagesOrNull(playlist.subtitleLanguages) ??
    defaultSubtitleLanguages;

/// Moves the app-wide "Download subtitles" setting of earlier versions to
/// the playlists. If it was on, every video playlist gets subtitles with
/// its languages; then the old setting is removed. Playlists are changed
/// before the setting is removed, so an interrupted run just repeats, and
/// a finished one does nothing again.
///
/// Runs when the app starts and before a scheduled update, which may come
/// first after an update of the app.
Future<void> migrateLegacySubtitleSetting(
  AppDatabase db,
  AppSettingsService settings,
) async {
  final legacy = await settings.readLegacySubtitleSetting();
  if (legacy == null) return;
  if (legacy.enabled) {
    await db.enableSubtitlesForVideoPlaylists(
      subtitleLanguagesOrNull(legacy.languages),
    );
  }
  await settings.clearLegacySubtitleSetting();
}
