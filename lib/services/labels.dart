import 'dart:convert';
import 'dart:math';

import '../database/database.dart';
import 'chapters.dart';

/// Whether [uid] looks like a label uid: what this app makes (a UUID) or
/// close to it. Anything else in a folder file is not a label reference.
bool isLabelUid(Object? uid) => uid is String && _labelUidPattern.hasMatch(uid);

final _labelUidPattern = RegExp(r'^[A-Za-z0-9-]{8,64}$');

/// A new label uid: a random (version 4) UUID.
String newLabelUid([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10).join()}';
}

/// The uids in a `Tracks.labelUids` value, without repeats; empty for null
/// or anything unreadable.
List<String> decodeLabelUids(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    return labelUidList(jsonDecode(json));
  } catch (_) {
    return const [];
  }
}

/// The `Tracks.labelUids` value for [uids]: null when there are none.
String? encodeLabelUids(Iterable<String> uids) {
  final list = labelUidList(uids.toList());
  return list.isEmpty ? null : jsonEncode(list);
}

/// The label uids in [value] (a JSON list), in order and without repeats.
List<String> labelUidList(Object? value) {
  if (value is! List) return const [];
  final seen = <String>{};
  return List.unmodifiable([
    for (final uid in value)
      if (isLabelUid(uid) && seen.add(uid as String)) uid,
  ]);
}

/// A label's color as written in the folder files: `#RRGGBB`, or
/// `#AARRGGBB` when it is not opaque.
String labelColorHex(int argb) {
  final value = argb & 0xffffffff;
  if (value >> 24 == 0xff) {
    return '#${(value & 0xffffff).toRadixString(16).padLeft(6, '0')}';
  }
  return '#${value.toRadixString(16).padLeft(8, '0')}';
}

/// A label color from a folder file (`#RRGGBB`, `#AARRGGBB` or an ARGB
/// number), or null.
int? parseLabelColor(Object? value) {
  if (value is int) return value & 0xffffffff;
  if (value is! String) return null;
  final hex = value.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(hex)) {
    return null;
  }
  final number = int.parse(hex, radix: 16);
  return hex.length == 6 ? 0xff000000 | number : number;
}

/// How a name is compared with other label names: case and surrounding
/// spaces do not matter.
String labelNameKey(String name) => name.trim().toLowerCase();

/// A label as the folder files carry it: in `woolytube_library.json`
/// (every label, in the owner's order) and at the top of each playlist's
/// `woolytube_meta.json` (the labels its files and chapters carry), so a
/// single copied playlist folder still knows its labels' names and colors.
class PortableLabel {
  const PortableLabel({
    required this.uid,
    required this.name,
    required this.color,
    this.updatedAt,
  });

  factory PortableLabel.of(Label label) => PortableLabel(
    uid: label.uid,
    name: label.name,
    color: label.color,
    updatedAt: label.updatedAt,
  );

  final String uid;
  final String name;

  /// ARGB.
  final int color;

  /// When its name or color last changed; the newer copy wins on import.
  final DateTime? updatedAt;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'name': name,
    'color': labelColorHex(color),
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  static PortableLabel? fromJson(Object? value) {
    if (value is! Map) return null;
    final uid = value['uid'];
    final name = value['name'];
    final color = parseLabelColor(value['color']);
    if (!isLabelUid(uid) || name is! String || name.trim().isEmpty) {
      return null;
    }
    final updatedAt = value['updatedAt'];
    return PortableLabel(
      uid: uid as String,
      name: name.trim(),
      // A label is never lost over a color it cannot read.
      color: color ?? defaultLabelColor,
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    );
  }

  /// The labels in [value] (a JSON list), each uid once.
  static List<PortableLabel> listFromJson(Object? value) {
    if (value is! List) return const [];
    final seen = <String>{};
    return [
      for (final entry in value)
        if (fromJson(entry) case final label? when seen.add(label.uid)) label,
    ];
  }
}

/// The color of a label whose color could not be read (Material grey).
const defaultLabelColor = 0xff9e9e9e;

/// How several chosen labels select items.
enum LabelMatch {
  /// Items that carry every chosen label.
  all,

  /// Items that carry at least one of them.
  any,
}

/// Whether [carried] (an item's labels) satisfies [wanted] under [match].
/// Nothing wanted matches nothing.
bool labelsMatch(
  Iterable<String> carried,
  Set<String> wanted,
  LabelMatch match,
) {
  if (wanted.isEmpty) return false;
  final have = carried.toSet();
  return switch (match) {
    LabelMatch.all => wanted.every(have.contains),
    LabelMatch.any => wanted.any(have.contains),
  };
}

/// A file, or one chapter of it, that carries the chosen labels.
class LabelledItem {
  const LabelledItem(this.track, [this.chapter]);

  final Track track;

  /// The labelled chapter; null when the file itself carries the labels.
  final MediaChapter? chapter;

  @override
  bool operator ==(Object other) =>
      other is LabelledItem &&
      other.track.id == track.id &&
      other.chapter?.id == chapter?.id;

  @override
  int get hashCode => Object.hash(track.id, chapter?.id);

  @override
  String toString() =>
      'LabelledItem(${track.id}${chapter == null ? '' : ', ${chapter!.id}'})';
}

/// The files and chapters of [tracks] that carry [wanted] under [match], in
/// the order of [tracks], each file before its chapters.
///
/// A file's labels and its chapters' labels are separate: a file row comes
/// from the file's own labels and plays the whole file, a chapter row from
/// that chapter's labels and plays only that chapter. Only the chapters the
/// file currently shows count.
List<LabelledItem> itemsWithLabels(
  Iterable<Track> tracks,
  Set<String> wanted, {
  LabelMatch match = LabelMatch.all,
}) {
  if (wanted.isEmpty) return const [];
  final result = <LabelledItem>[];
  for (final track in tracks) {
    if (labelsMatch(decodeLabelUids(track.labelUids), wanted, match)) {
      result.add(LabelledItem(track));
    }
    final chapters = ChapterData.decode(track.chaptersJson);
    if (chapters.chapterLabels.isEmpty) continue;
    for (final chapter in chapters.active) {
      if (labelsMatch(chapters.labelsOf(chapter.id), wanted, match)) {
        result.add(LabelledItem(track, chapter));
      }
    }
  }
  return result;
}

/// Whether every one of [items] carries label [uid] (true), none does
/// (false), or some do (null), as their rows say: a file item by the
/// file's own labels, a chapter item by that chapter's.
bool? labelStateOf(Iterable<LabelledItem> items, String uid) {
  var some = false;
  var all = true;
  for (final carries in _carrying(items, uid)) {
    if (carries) {
      some = true;
    } else {
      all = false;
    }
    if (some && !all) return null;
  }
  return some && all;
}

/// Those of [items] that carry label [uid], judged as in [labelStateOf].
List<LabelledItem> itemsWithLabel(List<LabelledItem> items, String uid) {
  final carrying = _carrying(items, uid).toList();
  return [
    for (var i = 0; i < items.length; i++)
      if (carrying[i]) items[i],
  ];
}

/// For each of [items], whether it carries label [uid]: a file item by
/// the file's own labels, a chapter item by that chapter's.
Iterable<bool> _carrying(Iterable<LabelledItem> items, String uid) sync* {
  final chapterData = <int, ChapterData>{};
  for (final item in items) {
    final chapter = item.chapter;
    final carried =
        chapter == null
            ? decodeLabelUids(item.track.labelUids)
            : chapterData
                .putIfAbsent(
                  item.track.id,
                  () => ChapterData.decode(item.track.chaptersJson),
                )
                .labelsOf(chapter.id);
    yield carried.contains(uid);
  }
}
