import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/database/database.dart';
import 'package:woolytube/services/audio_processing.dart';
import 'package:woolytube/services/loudness_service.dart';
import 'package:woolytube/services/playback_service.dart';
import 'package:woolytube/services/playback_settings_store.dart';

import '../helpers/test_database.dart';
import 'playback_fakes.dart';

/// One mpv option the player set, with how many files had been opened.
typedef _PropertySet = ({String name, String value, int openedBefore});

/// Hands out fixed measurements and records the player's requests.
class _FakeLoudness implements TrackLoudnessSource {
  final values = <int, MeasuredLoudness>{};
  final requests = <List<LoudnessJob>>[];

  @override
  Future<MeasuredLoudness?> loudnessFor(int trackId, String path) async =>
      values[trackId];

  @override
  void prioritize(List<LoudnessJob> files) => requests.add(files);
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late Playlist playlist;
  late FakePlayer player;
  late FakeAudioSession session;
  late PlaybackService playback;
  late List<_PropertySet> sets;
  var nextIndex = 1;

  Future<Track> addTrack(String name) async {
    final path = '${dir.path}/$name.m4a';
    await File(path).writeAsString(name);
    final track = await insertTestTrack(
      db,
      playlistId: playlist.id,
      index: nextIndex++,
      videoId: name,
      title: name,
      status: 'complete',
      filePath: path,
      durationSeconds: 60,
    );
    return (await db.getTrack(track.id))!;
  }

  Future<void> settle([int ms = 30]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<PlaybackService> createPlayback({PlaybackSettingsStore? store}) async {
    player = FakePlayer();
    final service = PlaybackService(
      db,
      player: player,
      settingsStore: store,
      setMpvProperty: (name, value) async {
        sets.add((
          name: name,
          value: value,
          openedBefore: player.opened.length,
        ));
      },
    );
    await service.initializeAudioFocus(
      pauseOnAudioInterruption: true,
      audioSession: session,
    );
    return service;
  }

  List<String> valuesOf(String name) => [
    for (final set in sets)
      if (set.name == name) set.value,
  ];

  setUp(() async {
    db = openTestDatabase();
    dir = await Directory.systemTemp.createTemp('woolytube-plane-');
    playlist = await insertTestPlaylist(db);
    nextIndex = 1;
    session = FakeAudioSession();
    sets = [];
    playback = await createPlayback();
  });

  tearDown(() async {
    await playback.dispose();
    await session.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  test('without plane mode or levelling mpv gets no filters', () async {
    final tracks = [await addTrack('a'), await addTrack('b')];
    await playback.playTrack(tracks[0], tracks);
    await playback.next();
    expect(sets, isEmpty);
  });

  test('plane mode filters are in place before the song opens', () async {
    final loudness = _FakeLoudness();
    final track = await addTrack('a');
    loudness.values[track.id] = const MeasuredLoudness(
      integratedLufs: -8,
      cabinLufs: -11,
      peakDb: 0,
    );
    playback.attachLoudness(loudness);
    await playback.setPlaneMode(true);
    expect(sets, isEmpty, reason: 'nothing is playing yet');

    await playback.playTrack(track, [track]);
    final af = sets.singleWhere((s) => s.name == 'af');
    expect(af.openedBefore, 0);
    expect(
      af.value,
      planeModeFilters(PlaneModeStrength.standard, loudness.values[track.id]),
    );
    expect(af.value, contains('volume=-12.00dB'));
    expect(valuesOf('replaygain-fallback'), isEmpty);
  });

  test(
    'each song gets its own levelling, unchanged settings are not resent',
    () async {
      final loudness = _FakeLoudness();
      final tracks = [
        await addTrack('loud'),
        await addTrack('quiet'),
        await addTrack('loud again'),
      ];
      loudness.values[tracks[0].id] = const MeasuredLoudness(
        integratedLufs: -8,
        cabinLufs: -11,
      );
      loudness.values[tracks[1].id] = const MeasuredLoudness(
        integratedLufs: -22,
        cabinLufs: -23,
      );
      loudness.values[tracks[2].id] = loudness.values[tracks[0].id]!;
      playback.attachLoudness(loudness);
      await playback.setPlaneMode(true);
      await playback.playTrack(tracks[0], tracks);
      await playback.next();
      await playback.next();
      final filters = valuesOf('af');
      expect(filters, hasLength(3));
      expect(filters[0], contains('volume=-12.00dB'));
      expect(filters[1], contains('volume=2.00dB'));
      expect(filters[2], filters[0]);
      expect([for (final s in sets) s.openedBefore], [0, 1, 2]);
    },
  );

  test('switching plane mode changes the playing song at once', () async {
    final track = await addTrack('a');
    await playback.playTrack(track, [track]);
    expect(sets, isEmpty);

    await playback.togglePlaneMode();
    expect(playback.planeMode, isTrue);
    expect(valuesOf('af').single, startsWith('@plane:lavfi=['));
    expect(player.opened, hasLength(1), reason: 'no reopen');

    await playback.setPlaneModeStrength(PlaneModeStrength.strong);
    expect(valuesOf('af').last, contains('threshold=-32dB'));

    await playback.togglePlaneMode();
    expect(valuesOf('af').last, isEmpty);
  });

  test('"Even out volume" sets a plain gain and no filters', () async {
    final loudness = _FakeLoudness();
    final tracks = [await addTrack('loud'), await addTrack('unmeasured')];
    loudness.values[tracks[0].id] = const MeasuredLoudness(
      integratedLufs: -9,
      peakDb: 0,
    );
    playback.attachLoudness(loudness);
    await playback.setEvenOutVolume(true);
    await playback.playTrack(tracks[0], tracks);
    expect(valuesOf('replaygain-fallback'), ['-5.00']);
    expect(valuesOf('af'), isEmpty);

    await playback.next();
    expect(valuesOf('replaygain-fallback'), ['-5.00', '0.00']);

    // Plane mode takes over: the plain gain goes back to 0.
    await playback.previous();
    await playback.setPlaneMode(true);
    expect(valuesOf('af').last, startsWith('@plane:'));
    expect(valuesOf('replaygain-fallback').last, '0.00');
  });

  test('the playing song and the next ones are measured first', () async {
    final loudness = _FakeLoudness();
    final tracks = [for (var i = 0; i < 6; i++) await addTrack('t$i')];
    playback.attachLoudness(loudness);
    await playback.playTrack(tracks[1], tracks);
    expect(loudness.requests, isEmpty, reason: 'measuring is off');

    await playback.setPlaneMode(true);
    final request = loudness.requests.last;
    expect(
      [for (final job in request) job.trackId],
      [tracks[1].id, tracks[2].id, tracks[3].id, tracks[4].id],
    );
    expect(request.first.path, tracks[1].filePath);

    loudness.requests.clear();
    await playback.next();
    expect(loudness.requests.last.first.trackId, tracks[2].id);
  });

  test('a failing mpv option does not stop the song from playing', () async {
    await playback.dispose();
    player = FakePlayer();
    playback = PlaybackService(
      db,
      player: player,
      setMpvProperty: (name, value) async => throw StateError('no mpv'),
    );
    await playback.initializeAudioFocus(
      pauseOnAudioInterruption: true,
      audioSession: session,
    );
    final track = await addTrack('a');
    await playback.setPlaneMode(true);
    await playback.playTrack(track, [track]);
    expect(player.opened, hasLength(1));
    expect(playback.hasLoadedMedia, isTrue);
  });

  test(
    'plane mode is remembered, and restored before the first song',
    () async {
      final store = MemoryPlaybackSettingsStore();
      await playback.dispose();
      playback = await createPlayback(store: store);
      await settle();
      await playback.togglePlaneMode();
      await settle();
      expect(store.preferences.planeMode, isTrue);

      await playback.dispose();
      sets.clear();
      playback = await createPlayback(store: store);
      await settle();
      expect(playback.planeMode, isTrue);
      final track = await addTrack('a');
      await playback.playTrack(track, [track]);
      expect(valuesOf('af').single, startsWith('@plane:'));

      // Strength and levelling are app settings, not remembered here.
      await playback.setPlaneModeStrength(PlaneModeStrength.strong);
      await playback.setEvenOutVolume(true);
      await settle();
      expect(store.preferences.planeMode, isTrue);
    },
  );

  test('settings streams report changes once', () async {
    final seen = <bool>[];
    final sub = playback.planeModeStream.listen(seen.add);
    await playback.setPlaneMode(true);
    await playback.setPlaneMode(true);
    await playback.setEvenOutVolume(true);
    await playback.setPlaneMode(false);
    await settle();
    await sub.cancel();
    expect(seen, [false, true, false]);
    expect(
      playback.audioProcessingSettings,
      const AudioProcessingSettings(evenOutVolume: true),
    );
  });
}
