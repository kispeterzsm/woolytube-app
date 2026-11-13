import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../pages/labels_page.dart';
import '../providers/providers.dart';
import '../services/chapters.dart';
import '../services/label_service.dart';
import '../services/labels.dart';
import '../services/track_title.dart';

const _muted = Color(0xFF888888);
const _sheetColor = Color(0xFF2A2A2A);

/// The colors a label can have: Material's lighter shades, which read well
/// on the dark background, each with a name for screen readers.
const labelPalette = <(String, int)>[
  ('Red', 0xFFE57373),
  ('Pink', 0xFFF06292),
  ('Purple', 0xFFBA68C8),
  ('Deep purple', 0xFF9575CD),
  ('Indigo', 0xFF7986CB),
  ('Blue', 0xFF64B5F6),
  ('Cyan', 0xFF4DD0E1),
  ('Teal', 0xFF4DB6AC),
  ('Green', 0xFF81C784),
  ('Light green', 0xFFAED581),
  ('Yellow', 0xFFFFF176),
  ('Amber', 0xFFFFD54F),
  ('Orange', 0xFFFFB74D),
  ('Deep orange', 0xFFFF8A65),
  ('Brown', 0xFFA1887F),
  ('Blue grey', 0xFF90A4AE),
];

/// The first palette color no label in [labels] has yet, so new labels
/// look different from the old ones for as long as colors last.
int nextLabelColor(Iterable<Label> labels) {
  final used = {for (final label in labels) label.color};
  for (final (_, color) in labelPalette) {
    if (!used.contains(color)) return color;
  }
  return labelPalette[labels.length % labelPalette.length].$2;
}

/// The labels in use among [uids], in the owner's order ([ordered] is the
/// list of labels in use, as [labelsProvider] gives it).
List<Label> carriedLabels(List<Label> ordered, Iterable<String> uids) {
  final wanted = uids is Set<String> ? uids : uids.toSet();
  if (wanted.isEmpty) return const [];
  return [
    for (final label in ordered)
      if (wanted.contains(label.uid)) label,
  ];
}

/// "1 file · 2 chapters", or "Not used yet".
String labelUsageText(LabelUsage usage) {
  if (usage.isEmpty) return 'Not used yet';
  return [
    if (usage.files > 0) usage.files == 1 ? '1 file' : '${usage.files} files',
    if (usage.chapters > 0)
      usage.chapters == 1 ? '1 chapter' : '${usage.chapters} chapters',
  ].join(' · ');
}

/// A round swatch of a label's color, with an optional mark inside.
class LabelSwatch extends StatelessWidget {
  const LabelSwatch({
    super.key,
    required this.color,
    this.size = 18,
    this.icon,
  });

  final int color;
  final double size;

  /// Drawn in the middle, dark so it reads on every palette color.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Color(color), shape: BoxShape.circle),
      child:
          icon == null
              ? null
              : Icon(icon, size: size * 0.75, color: const Color(0xDD000000)),
    );
  }
}

/// Small dots in the colors of [labels], for rows that have no room for
/// names. At most [max] dots; more labels show as a last grey "+" dot.
class LabelDots extends StatelessWidget {
  const LabelDots({
    super.key,
    required this.labels,
    this.size = 8,
    this.max = 4,
  });

  final List<Label> labels;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final overflow = labels.length > max;
    final shown = overflow ? labels.take(max - 1) : labels;
    Widget dot(Color color, {Widget? child}) => Container(
      width: size,
      height: size,
      margin: const EdgeInsets.only(right: 2),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        // A dark ring, so a light dot still shows on a light thumbnail.
        border: Border.all(color: const Color(0xCC000000), width: 1),
      ),
      child: child,
    );
    return Semantics(
      label: 'Labels: ${labels.map((l) => l.name).join(', ')}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final label in shown) dot(Color(label.color)),
          if (overflow) dot(const Color(0xFFBBBBBB)),
        ],
      ),
    );
  }
}

/// [labels] as full chips (color and name), for sheet headers.
class LabelChips extends StatelessWidget {
  const LabelChips({super.key, required this.labels});

  final List<Label> labels;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in labels)
          Chip(
            key: ValueKey('label-chip-${label.uid}'),
            avatar: LabelSwatch(color: label.color, size: 12),
            label: Text(label.name),
            labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
            backgroundColor: const Color(0xFF333333),
            side: BorderSide(color: Color(label.color).withAlpha(0x99)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 2),
          ),
      ],
    );
  }
}

/// Makes a new label, or edits [label]: a name and a color. Returns the
/// label as saved, or null when cancelled.
Future<Label?> showLabelEditor(
  BuildContext context,
  WidgetRef ref, {
  Label? label,
}) {
  final service = ref.read(labelServiceProvider);
  final existing = ref.read(labelsProvider).valueOrNull ?? const <Label>[];
  return showDialog<Label>(
    context: context,
    builder:
        (_) => _LabelEditorDialog(
          service: service,
          label: label,
          initialColor: label?.color ?? nextLabelColor(existing),
        ),
  );
}

class _LabelEditorDialog extends StatefulWidget {
  const _LabelEditorDialog({
    required this.service,
    required this.label,
    required this.initialColor,
  });

  final LabelService service;
  final Label? label;
  final int initialColor;

  @override
  State<_LabelEditorDialog> createState() => _LabelEditorDialogState();
}

class _LabelEditorDialogState extends State<_LabelEditorDialog> {
  late final _name = TextEditingController(text: widget.label?.name ?? '');
  late int _color = widget.initialColor;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      final label = widget.label;
      final Label saved;
      if (label == null) {
        saved = await widget.service.create(_name.text, _color);
      } else {
        await widget.service.rename(label.uid, _name.text);
        await widget.service.recolor(label.uid, _color);
        saved = label.copyWith(name: _name.text.trim(), color: _color);
      }
      navigator.pop(saved);
    } on LabelException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = [
      // A color from another phone or an older palette stays choosable.
      if (!labelPalette.any((p) => p.$2 == widget.initialColor))
        ('Current color', widget.initialColor),
      ...labelPalette,
    ];
    return AlertDialog(
      title: Text(widget.label == null ? 'New label' : 'Edit label'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('label-editor-name'),
              controller: _name,
              autofocus: true,
              maxLength: LabelService.maxNameLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'A genre, a band, a mood…',
                errorText: _error,
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: LabelSwatch(color: _color, size: 16),
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            const Text('Color', style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, (name, color)) in colors.indexed)
                  Semantics(
                    label: name,
                    selected: color == _color,
                    button: true,
                    child: InkWell(
                      key: ValueKey('label-color-$i'),
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = color),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Color(color),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color:
                                color == _color
                                    ? Colors.white
                                    : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child:
                            color == _color
                                ? const Icon(
                                  Icons.check,
                                  size: 20,
                                  color: Color(0xDD000000),
                                )
                                : null,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder:
              (context, value, _) => FilledButton(
                key: const ValueKey('label-editor-save'),
                onPressed: _saving || value.text.trim().isEmpty ? null : _save,
                child: Text(widget.label == null ? 'Create' : 'Save'),
              ),
        ),
      ],
    );
  }
}

/// A sheet of every label as a chip to turn on or off for something:
/// one file, one chapter or many search results. Each tap saves at once.
/// It also makes new labels (turned on right away) and opens the label
/// list.
class LabelPickerSheet extends ConsumerStatefulWidget {
  const LabelPickerSheet({
    super.key,
    required this.title,
    required this.subject,
    this.note,
    required this.initial,
    required this.onChanged,
    this.onRestore,
  });

  final String title;

  /// What gets the labels: a title, or "23 results".
  final String subject;
  final String? note;

  /// Each label's state by uid: true on, false (or missing) off, null on
  /// some of many items.
  final Map<String, bool?> initial;

  /// Saves label [uid] on or off. A [LabelException] shows in the sheet.
  final Future<void> Function(String uid, bool on) onChanged;

  /// Puts label [uid], which [initial] has on only some items and which
  /// is now off all of them, back on the items that had it. With it, such
  /// a chip goes some → all → none → some again, so a stray tap can be
  /// undone; without it, it goes only between all and none.
  final Future<void> Function(String uid)? onRestore;

  @override
  ConsumerState<LabelPickerSheet> createState() => _LabelPickerSheetState();
}

class _LabelPickerSheetState extends ConsumerState<LabelPickerSheet> {
  late final Map<String, bool?> _state = {...widget.initial};
  final _saving = <String>{};
  String? _error;

  /// Turns label [uid] on or off, or with [on] null back to how it was
  /// on each item (see [LabelPickerSheet.onRestore]).
  Future<void> _set(String uid, bool? on) async {
    if (_saving.contains(uid)) return;
    final before = _state.containsKey(uid) ? _state[uid] : false;
    setState(() {
      _state[uid] = on;
      _saving.add(uid);
      _error = null;
    });
    try {
      if (on == null) {
        await widget.onRestore!(uid);
      } else {
        await widget.onChanged(uid, on);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state[uid] = before;
          _error = e is LabelException ? e.message : 'Could not save: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _saving.remove(uid));
    }
  }

  Future<void> _newLabel() async {
    final label = await showLabelEditor(context, ref);
    if (label == null || !mounted) return;
    await _set(label.uid, true);
  }

  void _manage() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LabelsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelsProvider).valueOrNull ?? const <Label>[];
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: SingleChildScrollView(
        key: const ValueKey('label-picker'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.subject,
              key: const ValueKey('label-picker-subject'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted),
            ),
            if (widget.note case final note?) ...[
              const SizedBox(height: 8),
              Text(note, style: const TextStyle(color: _muted, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            if (labels.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'No labels yet. Make one for a genre, a band or anything '
                  'else, then search for it.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final label in labels) _chip(label),
                ActionChip(
                  key: const ValueKey('label-picker-new'),
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('New label'),
                  onPressed: _newLabel,
                ),
              ],
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                key: const ValueKey('label-picker-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('label-picker-manage'),
                onPressed: _manage,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Manage labels'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether label [uid] started on only some items and can be put back
  /// that way.
  bool _restorable(String uid) =>
      widget.onRestore != null &&
      widget.initial.containsKey(uid) &&
      widget.initial[uid] == null;

  Widget _chip(Label label) {
    final state = _state.containsKey(label.uid) ? _state[label.uid] : false;
    final restorable = _restorable(label.uid);
    // Some → all → none (→ some again when it started that way).
    final bool? next =
        state == null
            ? true
            : state
            ? false
            : restorable
            ? null
            : true;
    return FilterChip(
      key: ValueKey('label-picker-${label.uid}'),
      avatar: LabelSwatch(
        color: label.color,
        icon:
            state == true
                ? Icons.check
                : state == null
                ? Icons.remove
                : null,
      ),
      label: Text(label.name),
      tooltip:
          state == null
              ? 'On some of them. Tap to put it on all'
              : state
              ? 'Tap to take it off'
              : next == null
              ? 'Tap to put it back on the ones that had it'
              : 'Tap to put it on',
      selected: state != false,
      showCheckmark: false,
      onSelected: (_) => unawaited(_set(label.uid, next)),
    );
  }
}

Future<void> _showPicker(BuildContext context, LabelPickerSheet sheet) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _sheetColor,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => sheet,
  );
}

/// Labels for one file: [track]'s own, apart from its chapters' and from
/// other copies of the same video.
Future<void> showTrackLabelPicker(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final service = ref.read(labelServiceProvider);
  final fresh = await ref.read(databaseProvider).getTrack(track.id) ?? track;
  if (!context.mounted) return;
  final hasChapters =
      fresh.chaptersJson != null &&
      ChapterData.decode(fresh.chaptersJson).active.isNotEmpty;
  await _showPicker(
    context,
    LabelPickerSheet(
      title: 'Labels',
      subject: fresh.displayTitle,
      note:
          hasChapters
              ? 'For the whole file. Its chapters have labels of their own, '
                  'in Chapters.'
              : null,
      initial: {for (final uid in decodeLabelUids(fresh.labelUids)) uid: true},
      onChanged: (uid, on) => service.setTrackLabel(track.id, uid, on),
    ),
  );
}

/// Labels for chapter [chapterId] of [track].
Future<void> showChapterLabelPicker(
  BuildContext context,
  WidgetRef ref,
  Track track,
  MediaChapter chapter,
) async {
  final service = ref.read(labelServiceProvider);
  final fresh = await ref.read(databaseProvider).getTrack(track.id) ?? track;
  if (!context.mounted) return;
  final carried = ChapterData.decode(fresh.chaptersJson).labelsOf(chapter.id);
  await _showPicker(
    context,
    LabelPickerSheet(
      title: 'Chapter labels',
      subject: chapter.title,
      initial: {for (final uid in carried) uid: true},
      onChanged:
          (uid, on) => service.setChapterLabel(track.id, chapter.id, uid, on),
    ),
  );
}

/// Labels for many search results at once ([items], see
/// `searchLabelTargets`): a tap puts a label on all of them, or takes it
/// off all when all have it. A label only some of them had goes on all,
/// then off all, then back on just the ones that had it.
Future<void> showLabelAllPicker(
  BuildContext context,
  WidgetRef ref,
  List<LabelledItem> items,
) async {
  final service = ref.read(labelServiceProvider);
  final labels = ref.read(labelsProvider).valueOrNull ?? const <Label>[];
  final files = items.where((i) => i.chapter == null).length;
  final chapters = items.length - files;
  final subject = [
    if (files > 0) files == 1 ? '1 file' : '$files files',
    if (chapters > 0) chapters == 1 ? '1 chapter' : '$chapters chapters',
  ].join(' and ');
  await _showPicker(
    context,
    LabelPickerSheet(
      title: 'Label all results',
      subject: subject,
      note:
          chapters > 0
              ? 'Files found by their title get the label on the file; '
                  'files found by their chapters on those chapters.'
              : null,
      initial: {
        for (final label in labels) label.uid: labelStateOf(items, label.uid),
      },
      onChanged: (uid, on) => service.setLabelOnItems(items, uid, on),
      onRestore:
          (uid) =>
              service.setLabelOnItems(itemsWithLabel(items, uid), uid, true),
    ),
  );
}
