import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/app_settings_service.dart';
import 'package:woolytube/services/subtitles.dart';

import '../helpers/test_database.dart';

void main() {
  group('subtitle languages', () {
    test('forgive spaces and a trailing comma and accept en.*', () {
      expect(normalizeSubtitleLanguages('en, hu,'), 'en,hu');
      expect(normalizeSubtitleLanguages(' hu, en,hu, pt-BR'), 'hu,en,pt-BR');
      expect(normalizeSubtitleLanguages('en.*, pt-BR'), 'en.*,pt-BR');
    });

    test('refuse what yt-dlp must not be given', () {
      for (final invalid in ['', ' , ', 'all', 'en.+', 'live_chat', '--help']) {
        expect(
          () => normalizeSubtitleLanguages(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    });

    test('stored values read as English when missing or invalid', () {
      expect(subtitleLanguagesOrNull(null), isNull);
      expect(subtitleLanguagesOrNull(''), isNull);
      expect(subtitleLanguagesOrNull('all'), isNull);
      expect(subtitleLanguagesOrNull(7), isNull);
      expect(subtitleLanguagesOrNull('de , en'), 'de,en');
    });
  });

  group('moving the old app-wide setting to the playlists', () {
    late AppDatabase db;
    late AppSettingsService settings;
    late Playlist video;
    late Playlist temporary;
    late Playlist audio;

    setUp(() async {
      db = openTestDatabase();
      settings = AppSettingsService();
      video = await insertTestPlaylist(db, name: 'Talks');
      temporary = await insertTestPlaylist(
        db,
        url: 'woolytube://temporary',
        name: 'Temporary',
        isTemporary: true,
      );
      audio = await insertTestPlaylist(
        db,
        url: 'https://www.youtube.com/playlist?list=songs',
        name: 'Songs',
        audioOnly: true,
      );
    });

    tearDown(() => db.close());

    Future<List<(bool, String?)>> subtitles() async => [
      for (final playlist in [video, temporary, audio])
        await db
            .getPlaylist(playlist.id)
            .then((p) => (p.downloadSubtitles, p.subtitleLanguages)),
    ];

    test('on: every video playlist gets subtitles in its languages', () async {
      SharedPreferences.setMockInitialValues({
        AppSettingsService.legacyDownloadSubtitlesKey: true,
        AppSettingsService.legacySubtitleLanguagesKey: 'en,hu',
        AppSettingsService.evenOutVolumeKey: true,
      });

      await migrateLegacySubtitleSetting(db, settings);

      expect(await subtitles(), [
        (true, 'en,hu'),
        (true, 'en,hu'),
        (false, null),
      ]);
      expect(await settings.readLegacySubtitleSetting(), isNull);
      expect(await settings.getEvenOutVolume(), isTrue);

      // A second run finds nothing to move and changes nothing.
      await db.updatePlaylistFields(
        video.id,
        const PlaylistsCompanion(downloadSubtitles: Value(false)),
      );
      await migrateLegacySubtitleSetting(db, settings);
      expect((await subtitles()).first, (false, 'en,hu'));
    });

    test('on without languages, or with invalid ones: English', () async {
      SharedPreferences.setMockInitialValues({
        AppSettingsService.legacyDownloadSubtitlesKey: true,
        AppSettingsService.legacySubtitleLanguagesKey: 'all',
      });

      await migrateLegacySubtitleSetting(db, settings);

      expect(await subtitles(), [(true, null), (true, null), (false, null)]);
      expect(await settings.readLegacySubtitleSetting(), isNull);
    });

    test('off: no playlist changes and the old setting goes', () async {
      SharedPreferences.setMockInitialValues({
        AppSettingsService.legacyDownloadSubtitlesKey: false,
        AppSettingsService.legacySubtitleLanguagesKey: 'en,hu',
      });

      await migrateLegacySubtitleSetting(db, settings);

      expect(await subtitles(), [(false, null), (false, null), (false, null)]);
      expect(await settings.readLegacySubtitleSetting(), isNull);
    });

    test(
      'the old setting stays when the playlists cannot be changed',
      () async {
        SharedPreferences.setMockInitialValues({
          AppSettingsService.legacyDownloadSubtitlesKey: true,
        });
        await db.close();

        await expectLater(
          migrateLegacySubtitleSetting(db, settings),
          throwsA(anything),
        );
        expect(await settings.readLegacySubtitleSetting(), (
          enabled: true,
          languages: null,
        ));
      },
    );
  });
}
