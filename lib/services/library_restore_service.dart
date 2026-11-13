import '../database/database.dart';
import 'app_settings_service.dart';
import 'library_export_service.dart';
import 'library_file.dart';
import 'log_service.dart';
import 'loudness_service.dart';
import 'metadata_service.dart';
import 'playback_service.dart';

/// What [LibraryRestoreService.importAll] brought back.
class LibraryRestoreResult {
  const LibraryRestoreResult({
    required this.imported,
    required this.failed,
    this.settingsRestored,
    this.orderRestored = false,
    this.resumeRestored = false,
  });

  /// Playlists added to the library.
  final int imported;

  /// Names of playlists that could not be imported.
  final List<String> failed;

  /// How many settings came back, or null when none were restored (not a
  /// fresh install, or no settings file).
  final int? settingsRestored;

  /// Whether the home page order came back for the imported playlists.
  final bool orderRestored;

  /// Whether the player's "where I was" point came back.
  final bool resumeRestored;

  /// One line for the owner.
  String get message {
    final restored = [
      if (settingsRestored case final count? when count > 0)
        _count(count, 'setting'),
      if (orderRestored) 'the home order',
      if (resumeRestored) 'where you were listening',
    ];
    final String head;
    if (failed.isEmpty) {
      head = 'Imported ${_count(imported, 'playlist')}';
    } else if (imported == 0) {
      head =
          'Could not import ${_count(failed.length, 'playlist')}: '
          '${failed.join(', ')}';
    } else {
      head =
          'Imported $imported, failed ${failed.length}: ${failed.join(', ')}';
    }
    if (restored.isEmpty) return '$head.';
    return '$head. Restored ${_join(restored)}.';
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  static String _join(List<String> parts) {
    if (parts.length == 1) return parts.single;
    return '${parts.sublist(0, parts.length - 1).join(', ')} and '
        '${parts.last}';
  }
}

/// Brings a copied library back: the playlist folders, and from the
/// library files the home page order, the settings and where the player
/// was.
///
/// Settings and "where I was" come back by themselves only on a fresh
/// install (no playlist in the database yet): they never replace what the
/// owner already has. The order of imported playlists comes back always;
/// playlists already in the library keep their places.
class LibraryRestoreService {
  LibraryRestoreService(
    this._db,
    this._metadata,
    this._exporter,
    this._libraryFile, {
    LogService? log,
  }) : _log = log;

  final AppDatabase _db;
  final MetadataService _metadata;
  final LibraryExportService _exporter;
  final LibraryFileService _libraryFile;
  final LogService? _log;

  /// Imports [imports] (the playlists the startup search found). On a
  /// fresh install the settings are restored first and the "where I was"
  /// point last. [onSettled] is called for each playlist that is now in
  /// the library, imported or already there.
  Future<LibraryRestoreResult> importAll(
    List<DiscoveredPlaylist> imports, {
    void Function(DiscoveredPlaylist discovered)? onSettled,
  }) => _libraryFile.holdWrites(() async {
    final fresh = (await _db.getAllPlaylists()).isEmpty;
    // Read before importing: the file is the order being restored.
    LibraryFileData? file;
    try {
      file = await _libraryFile.read();
    } catch (e) {
      _log?.warn('Could not read the library file: $e');
    }

    int? settings;
    if (fresh) {
      try {
        settings = await _exporter.restoreSettings();
      } catch (e) {
        _log?.warn('Could not restore the settings: $e');
      }
    }

    final failed = <String>[];
    final placed = <int>{};
    for (final discovered in imports) {
      try {
        placed.add(await _metadata.importPlaylist(discovered));
        onSettled?.call(discovered);
      } on PlaylistExistsException {
        // Already in the library (for example added again by URL since
        // the banner appeared): nothing to import.
        onSettled?.call(discovered);
      } catch (e) {
        failed.add(discovered.name);
        _log?.warn('import of ${discovered.name} failed: $e');
      }
    }

    var order = false;
    var resume = false;
    if (file != null && placed.isNotEmpty) {
      try {
        order = await _libraryFile.applyOrder(file, placed) > 0;
      } catch (e) {
        _log?.warn('Could not restore the home order: $e');
      }
      if (fresh) {
        try {
          resume = await _libraryFile.restoreResumePoint(file);
        } catch (e) {
          _log?.warn('Could not restore where the player was: $e');
        }
      }
    }
    _log?.info(
      'restore: ${placed.length} playlists, ${failed.length} failed, '
      'settings ${settings ?? 'not restored'}, order $order, resume $resume',
    );
    return LibraryRestoreResult(
      imported: placed.length,
      failed: failed,
      settingsRestored: settings,
      orderRestored: order,
      resumeRestored: resume,
    );
  });

  /// Imports one playlist (the Restore playlists page) and puts it where the
  /// library file of [folder] (a copied backup the owner picked) or of the
  /// library folders had it. Returns its id.
  Future<int> importOne(DiscoveredPlaylist discovered, {String? folder}) =>
      _libraryFile.holdWrites(() async {
        LibraryFileData? file;
        try {
          file = await _libraryFile.read(folder: folder);
        } catch (e) {
          _log?.warn('Could not read the library file: $e');
        }
        final id = await _metadata.importPlaylist(discovered);
        if (file != null) {
          try {
            await _libraryFile.applyOrder(file, {id});
          } catch (e) {
            _log?.warn('Could not place "${discovered.name}": $e');
          }
        }
        return id;
      });
}

/// Gives the player and the loudness measuring the settings a restore just
/// stored. Runs also when the page that started the restore is already
/// closed.
Future<void> applyRestoredSettings(
  AppSettingsService settings,
  PlaybackService? player,
  LoudnessService? loudness,
) async {
  try {
    loudness?.setOnlyWhileCharging(
      await settings.getLoudnessOnlyWhileCharging(),
    );
  } catch (_) {
    // Applies at the next start.
  }
  if (player == null) return;
  try {
    await player.setPauseOnAudioInterruption(
      await settings.getPauseOnAudioInterruption(),
    );
    await player.setEvenOutVolume(await settings.getEvenOutVolume());
    await player.setEvenOutMode(await settings.getEvenOutMode());
    await player.setPlaneModeStrength(await settings.getPlaneModeStrength());
  } catch (_) {
    // Applies at the next start.
  }
  try {
    // Shuffle, autoplay, audio-only and the plane mode switch.
    await player.applyRememberedOptions();
  } catch (_) {
    // Applies at the next start.
  }
}
