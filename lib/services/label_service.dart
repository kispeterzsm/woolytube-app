import 'package:drift/drift.dart';

import '../database/database.dart';
import 'chapters.dart';
import 'labels.dart';

/// Refused label change, with a message for the owner.
class LabelException implements Exception {
  const LabelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How many files and chapters carry one label.
class LabelUsage {
  const LabelUsage({this.files = 0, this.chapters = 0});

  final int files;
  final int chapters;

  bool get isEmpty => files == 0 && chapters == 0;
}

/// What [importLabels] did.
class LabelImport {
  const LabelImport({this.remap = const {}, this.added = 0, this.updated = 0});

  /// The uid each incoming label has in this library. It differs from the
  /// incoming one when a label of the same name was already here.
  final Map<String, String> remap;

  /// Labels that were new here.
  final int added;

  /// Labels whose name or color came from the newer incoming copy.
  final int updated;

  /// [uids] with each remapped, in order and without repeats.
  List<String> apply(Iterable<String> uids) =>
      labelUidList([for (final uid in uids) remap[uid] ?? uid]);

  /// [chaptersJson] (a `Tracks.chaptersJson` value) with its chapter labels
  /// remapped; unchanged when nothing is remapped.
  String? applyToChapters(String? chaptersJson) {
    if (chaptersJson == null || !remap.entries.any((e) => e.key != e.value)) {
      return chaptersJson;
    }
    final data = ChapterData.decode(chaptersJson);
    if (data.chapterLabels.isEmpty) return chaptersJson;
    return data
        .copyWith(
          chapterLabels: {
            for (final entry in data.chapterLabels.entries)
              entry.key: apply(entry.value),
          },
        )
        .encode();
  }
}

/// Brings [incoming] labels (from a copied library file or metadata file)
/// into the library, and says which uid each has here.
///
/// A label is matched by uid, then by name (case ignored) among the labels
/// in use. A matched label takes the incoming name and color only when the
/// incoming copy changed later; a name another label already has is not
/// taken. A label deleted here stays deleted unless the incoming copy
/// changed after the deletion. New labels go to the end of the owner's
/// order, in the incoming order.
Future<LabelImport> importLabels(
  AppDatabase db,
  Iterable<PortableLabel> incoming, {
  DateTime Function() clock = DateTime.now,
}) async {
  final list = incoming.toList();
  if (list.isEmpty) return const LabelImport();
  return db.transaction(() async {
    final all = await db.getLabels(includeDeleted: true);
    final byUid = {for (final label in all) label.uid: label};
    final aliveByName = {
      for (final label in all)
        if (label.deletedAt == null) labelNameKey(label.name): label,
    };
    var nextOrder = await db.nextLabelSortOrder();
    final remap = <String, String>{};
    var added = 0;
    var updated = 0;

    bool newer(PortableLabel label, DateTime than) {
      final at = label.updatedAt;
      return at != null && at.isAfter(than);
    }

    /// Whether [name] is free for the label with [uid].
    bool nameFree(String name, String uid) {
      final holder = aliveByName[labelNameKey(name)];
      return holder == null || holder.uid == uid;
    }

    Future<void> store(Label label, LabelsCompanion fields) async {
      await db.updateLabelFields(label.uid, fields);
      final stored = (await db.getLabel(label.uid))!;
      aliveByName.removeWhere((_, l) => l.uid == label.uid);
      if (stored.deletedAt == null) {
        aliveByName[labelNameKey(stored.name)] = stored;
      }
      byUid[label.uid] = stored;
    }

    for (final label in list) {
      if (remap.containsKey(label.uid)) continue;
      final here = byUid[label.uid];
      if (here != null && here.deletedAt != null) {
        final deletedAt = here.deletedAt!;
        if (!newer(label, deletedAt)) {
          // Deleted here after the incoming copy last changed: the files
          // keep the uid, which stays ignored.
          remap[label.uid] = label.uid;
          continue;
        }
        final sameName = aliveByName[labelNameKey(label.name)];
        if (sameName != null) {
          remap[label.uid] = sameName.uid;
          continue;
        }
        await store(
          here,
          LabelsCompanion(
            name: Value(label.name),
            color: Value(label.color),
            updatedAt: Value(label.updatedAt!),
            deletedAt: const Value(null),
          ),
        );
        remap[label.uid] = label.uid;
        updated++;
        continue;
      }
      if (here != null) {
        remap[label.uid] = label.uid;
        if (!newer(label, here.updatedAt)) continue;
        final rename =
            label.name != here.name && nameFree(label.name, here.uid);
        if (!rename && label.color == here.color) continue;
        await store(
          here,
          LabelsCompanion(
            name: rename ? Value(label.name) : const Value.absent(),
            color: Value(label.color),
            updatedAt: Value(label.updatedAt!),
          ),
        );
        updated++;
        continue;
      }
      final sameName = aliveByName[labelNameKey(label.name)];
      if (sameName != null) {
        remap[label.uid] = sameName.uid;
        continue;
      }
      final now = clock();
      await db.insertLabel(
        LabelsCompanion.insert(
          uid: label.uid,
          name: label.name,
          color: label.color,
          sortOrder: Value(nextOrder++),
          createdAt: now,
          updatedAt: label.updatedAt ?? now,
        ),
      );
      final stored = (await db.getLabel(label.uid))!;
      byUid[label.uid] = stored;
      aliveByName[labelNameKey(stored.name)] = stored;
      remap[label.uid] = label.uid;
      added++;
    }
    return LabelImport(remap: remap, added: added, updated: updated);
  });
}

/// The owner's labels: making, renaming, recoloring, ordering and deleting
/// them, putting them on files and chapters, and finding what carries them.
///
/// Labels and their assignments live in the database and reach the folder
/// files through the mirrors: each file's labels and its chapters' labels
/// are in its playlist's `woolytube_meta.json` (with the names and colors
/// of the labels that playlist uses), and every label is in
/// `woolytube_library.json`.
///
/// Deleting a label keeps it as deleted (see `Labels.deletedAt`): the files
/// and chapters that carry it keep its uid, which is ignored, so [restore]
/// brings everything back. A uid of a deleted label is dropped from a file
/// or chapter the next time its labels are changed.
class LabelService {
  LabelService(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Longest label name.
  static const maxNameLength = 40;

  Stream<List<Label>> watchLabels() => _db.watchLabels();

  Future<List<Label>> labels() => _db.getLabels();

  /// Makes a label at the end of the owner's order.
  Future<Label> create(String name, int color) async {
    final trimmed = _checkName(name);
    return _db.transaction(() async {
      await _checkNameFree(trimmed);
      final now = _clock();
      final uid = newLabelUid();
      await _db.insertLabel(
        LabelsCompanion.insert(
          uid: uid,
          name: trimmed,
          color: color,
          sortOrder: Value(await _db.nextLabelSortOrder()),
          createdAt: now,
          updatedAt: now,
        ),
      );
      return (await _db.getLabel(uid))!;
    });
  }

  Future<void> rename(String uid, String name) async {
    final trimmed = _checkName(name);
    await _db.transaction(() async {
      final label = await _alive(uid);
      if (label.name == trimmed) return;
      await _checkNameFree(trimmed, except: uid);
      await _db.updateLabelFields(
        uid,
        LabelsCompanion(name: Value(trimmed), updatedAt: Value(_clock())),
      );
    });
  }

  Future<void> recolor(String uid, int color) async {
    await _db.transaction(() async {
      final label = await _alive(uid);
      if (label.color == color) return;
      await _db.updateLabelFields(
        uid,
        LabelsCompanion(color: Value(color), updatedAt: Value(_clock())),
      );
    });
  }

  /// Saves the owner's order of labels.
  Future<void> reorder(List<String> uids) => _db.setLabelOrder(uids);

  /// Deletes a label. Files and chapters stop showing it; [restore] undoes
  /// this.
  Future<void> delete(String uid) async {
    await _db.transaction(() async {
      final label = await _db.getLabel(uid);
      if (label == null || label.deletedAt != null) return;
      await _db.updateLabelFields(
        uid,
        LabelsCompanion(deletedAt: Value(_clock())),
      );
    });
  }

  /// Brings a deleted label back, on every file and chapter that had it.
  Future<void> restore(String uid) async {
    await _db.transaction(() async {
      final label = await _db.getLabel(uid);
      if (label == null || label.deletedAt == null) return;
      await _checkNameFree(label.name, except: uid);
      await _db.updateLabelFields(
        uid,
        LabelsCompanion(
          deletedAt: const Value(null),
          updatedAt: Value(_clock()),
        ),
      );
    });
  }

  /// How many files and chapters carry each label in use, by uid. Only the
  /// chapters each file currently shows count.
  Future<Map<String, LabelUsage>> usage() async {
    final labels = await _db.getLabels();
    final files = <String, int>{};
    final chapters = <String, int>{};
    for (final track in await _db.tracksMentioningLabels(
      labels.map((l) => l.uid),
    )) {
      for (final uid in decodeLabelUids(track.labelUids)) {
        files[uid] = (files[uid] ?? 0) + 1;
      }
      final data = ChapterData.decode(track.chaptersJson);
      for (final chapter in data.active) {
        for (final uid in data.labelsOf(chapter.id)) {
          chapters[uid] = (chapters[uid] ?? 0) + 1;
        }
      }
    }
    return {
      for (final label in labels)
        label.uid: LabelUsage(
          files: files[label.uid] ?? 0,
          chapters: chapters[label.uid] ?? 0,
        ),
    };
  }

  /// The labels in use that [track] (the file itself) carries, in the
  /// owner's order.
  Future<List<Label>> labelsOfTrack(Track track) async =>
      _inUse(decodeLabelUids(track.labelUids));

  /// The labels in use that chapter [chapterId] of [track] carries, in the
  /// owner's order.
  Future<List<Label>> labelsOfChapter(Track track, String chapterId) async =>
      _inUse(ChapterData.decode(track.chaptersJson).labelsOf(chapterId));

  Future<List<Label>> _inUse(List<String> uids) async {
    if (uids.isEmpty) return const [];
    final wanted = uids.toSet();
    return [
      for (final label in await _db.getLabels())
        if (wanted.contains(label.uid)) label,
    ];
  }

  /// Gives the file [trackId] label [uid], or takes it away. Returns
  /// whether anything changed.
  Future<bool> setTrackLabel(int trackId, String uid, bool on) =>
      _changeTrackLabels(trackId, (current) {
        final without = current.where((u) => u != uid);
        return on ? [...without, uid] : without.toList();
      });

  /// Makes [uids] the labels of the file [trackId]. Returns whether
  /// anything changed.
  Future<bool> setTrackLabels(int trackId, Iterable<String> uids) {
    final next = uids.toList();
    return _changeTrackLabels(trackId, (_) => next);
  }

  Future<bool> _changeTrackLabels(
    int trackId,
    List<String> Function(List<String> current) change,
  ) async {
    var changed = false;
    await _db.transaction(() async {
      final fresh = await _db.getTrack(trackId);
      if (fresh == null) return;
      final inUse = await _inUseUids();
      final next = encodeLabelUids(
        // Uids of deleted labels are dropped here, the next time the
        // file's labels change.
        change(decodeLabelUids(fresh.labelUids)).where(inUse.contains),
      );
      if (next == fresh.labelUids) return;
      await _db.setTrackLabelUids(trackId, next);
      changed = true;
    });
    return changed;
  }

  /// Gives chapter [chapterId] of [trackId] label [uid], or takes it away.
  /// Returns whether anything changed.
  Future<bool> setChapterLabel(
    int trackId,
    String chapterId,
    String uid,
    bool on,
  ) => _changeChapterLabels(trackId, chapterId, (current) {
    final without = current.where((u) => u != uid);
    return on ? [...without, uid] : without.toList();
  });

  /// Makes [uids] the labels of chapter [chapterId] of [trackId]. Returns
  /// whether anything changed.
  Future<bool> setChapterLabels(
    int trackId,
    String chapterId,
    Iterable<String> uids,
  ) {
    final next = uids.toList();
    return _changeChapterLabels(trackId, chapterId, (_) => next);
  }

  /// Read and written in one transaction, so a chapter fetch or song
  /// recognition finishing meanwhile is not overwritten. Only a chapter
  /// the file currently shows can be labelled.
  Future<bool> _changeChapterLabels(
    int trackId,
    String chapterId,
    List<String> Function(List<String> current) change,
  ) async {
    var changed = false;
    await _db.transaction(() async {
      final fresh = await _db.getTrack(trackId);
      if (fresh == null) return;
      final old = ChapterData.decode(fresh.chaptersJson);
      if (!old.active.any((c) => c.id == chapterId)) {
        throw const LabelException(
          'This chapter changed. Open the chapters again.',
        );
      }
      final inUse = await _inUseUids();
      final next = old.withChapterLabels(
        chapterId,
        change(old.labelsOf(chapterId)).where(inUse.contains),
      );
      if (identical(next, old)) return;
      await _db.writeTrackChapters(trackId, next);
      changed = true;
    });
    return changed;
  }

  /// The files and chapters of the whole library that carry [uids] under
  /// [match] (see [itemsWithLabels]), by playlist and track order. Labels
  /// not in use match nothing.
  Future<List<LabelledItem>> find(
    Set<String> uids, {
    LabelMatch match = LabelMatch.all,
  }) async {
    final inUse = await _inUseUids();
    final wanted = uids.where(inUse.contains).toSet();
    if (wanted.isEmpty ||
        (match == LabelMatch.all && wanted.length < uids.length)) {
      return const [];
    }
    final tracks = await _db.tracksMentioningLabels(wanted);
    return itemsWithLabels(tracks, wanted, match: match);
  }

  Future<Set<String>> _inUseUids() async => {
    for (final label in await _db.getLabels()) label.uid,
  };

  Future<Label> _alive(String uid) async {
    final label = await _db.getLabel(uid);
    if (label == null || label.deletedAt != null) {
      throw const LabelException('This label was deleted.');
    }
    return label;
  }

  static String _checkName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const LabelException('A label needs a name.');
    }
    if (trimmed.length > maxNameLength) {
      throw const LabelException(
        'A label name can be at most $maxNameLength characters.',
      );
    }
    return trimmed;
  }

  Future<void> _checkNameFree(String name, {String? except}) async {
    final key = labelNameKey(name);
    for (final label in await _db.getLabels()) {
      if (label.uid != except && labelNameKey(label.name) == key) {
        throw LabelException('There is already a label "${label.name}".');
      }
    }
  }
}
