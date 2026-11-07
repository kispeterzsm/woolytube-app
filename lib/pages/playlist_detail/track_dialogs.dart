part of '../playlist_detail_page.dart';

typedef _TrackRenameResult = ({String title, String fileName});

/// Edits a track's shown title and its file name. Owns its text
/// controllers, so they are disposed only after the dialog is gone.
class _TrackRenameDialog extends StatefulWidget {
  const _TrackRenameDialog({
    required this.title,
    required this.fileName,
    required this.hasFile,
  });

  final String title;

  /// The editable part of the file name (no number prefix or extension).
  final String fileName;
  final bool hasFile;

  @override
  State<_TrackRenameDialog> createState() => _TrackRenameDialogState();
}

class _TrackRenameDialogState extends State<_TrackRenameDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.title,
  );
  late final TextEditingController _fileName = TextEditingController(
    text: widget.hasFile ? widget.fileName : '',
  );

  @override
  void dispose() {
    _title.dispose();
    _fileName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text(
        'Edit title & file name',
        style: TextStyle(color: Colors.white),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TapToPlaceCursorTextField(
            key: const ValueKey('track-rename-title'),
            controller: _title,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Title',
              labelStyle: const TextStyle(color: _muted),
              hintText: widget.title,
              hintStyle: const TextStyle(color: Color(0xFF555555)),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TapToPlaceCursorTextField(
            key: const ValueKey('track-rename-file'),
            controller: _fileName,
            enabled: widget.hasFile,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'File name',
              labelStyle: const TextStyle(color: _muted),
              hintText: widget.hasFile ? widget.fileName : 'No file on disk',
              hintStyle: const TextStyle(color: Color(0xFF555555)),
              helperText:
                  widget.hasFile
                      ? 'The number in front and the extension stay the same'
                      : null,
              helperStyle: const TextStyle(color: Color(0xFF666666)),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: _muted)),
        ),
        TextButton(
          onPressed:
              () => Navigator.pop<_TrackRenameResult>(context, (
                title: _title.text,
                fileName: _fileName.text,
              )),
          child: const Text('Save', style: TextStyle(color: Color(0xFF4A9EFF))),
        ),
      ],
    );
  }
}

/// Lists a track's skip segments with edit, hide/delete and restore.
class _SkipSegmentsSheet extends StatefulWidget {
  const _SkipSegmentsSheet({
    required this.track,
    required this.db,
    required this.initialSegments,
    required this.onChanged,
    required this.onError,
  });

  final Track track;
  final AppDatabase db;
  final List<SponsorBlockSegment> initialSegments;

  /// Lets the player pick up the edited segments.
  final Future<void> Function() onChanged;
  final void Function(String message) onError;

  @override
  State<_SkipSegmentsSheet> createState() => _SkipSegmentsSheetState();
}

class _SkipSegmentsSheetState extends State<_SkipSegmentsSheet> {
  late List<SponsorBlockSegment> _segments = widget.initialSegments;
  bool _busy = false;

  Future<void> _reload() async {
    final updated = await widget.db.getSegmentsForTrack(widget.track.id);
    if (mounted) setState(() => _segments = updated);
    await widget.onChanged();
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      await _reload();
    } catch (e) {
      widget.onError('Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(SponsorBlockSegment segment) async {
    final changed = await showDialog<bool>(
      context: context,
      builder:
          (_) => _SegmentEditDialog(
            track: widget.track,
            segment: segment,
            db: widget.db,
          ),
    );
    if (changed == true && mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Skip segments',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_segments.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Text(
                'This track has no skip segments yet.',
                style: TextStyle(color: _muted),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.65,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final segment in _segments)
                    ListTile(
                      leading: _segmentColorSwatch(segment),
                      title: Text(
                        sponsorBlockCategoryLabels[segment.category] ??
                            segment.category,
                        style: TextStyle(
                          color:
                              segment.source == 'hidden'
                                  ? _muted
                                  : Colors.white,
                        ),
                      ),
                      subtitle: Text(
                        '${_sourceLabel(segment.source)} · '
                        '${_formatMs(segment.startMs)} – '
                        '${_formatMs(segment.endMs)}',
                        style: const TextStyle(color: _muted),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.white70),
                            tooltip: 'Edit segment',
                            onPressed: _busy ? null : () => _edit(segment),
                          ),
                          if (segment.source == 'hidden')
                            IconButton(
                              icon: const Icon(Icons.restore, color: _accent),
                              tooltip: 'Restore segment',
                              onPressed:
                                  _busy
                                      ? null
                                      : () => _runBusy(
                                        () => db.updateSegment(
                                          segment.id,
                                          source: 'sponsorblock',
                                        ),
                                      ),
                            )
                          else
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.redAccent,
                              ),
                              tooltip:
                                  segment.source == 'local'
                                      ? 'Delete segment'
                                      : 'Hide segment',
                              onPressed:
                                  _busy
                                      ? null
                                      : () => _runBusy(() async {
                                        if (segment.source == 'local' ||
                                            segment.uuid == null) {
                                          await db.deleteSegment(segment.id);
                                        } else {
                                          await db.updateSegment(
                                            segment.id,
                                            source: 'hidden',
                                          );
                                        }
                                      }),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Widget _segmentColorSwatch(SponsorBlockSegment segment) {
  final colorValue = sponsorBlockCategoryColors[segment.category] ?? 0xFF888888;
  return Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: Color(
        colorValue,
      ).withValues(alpha: segment.source == 'hidden' ? 0.35 : 1),
      borderRadius: BorderRadius.circular(2),
      border: Border.all(color: const Color(0xFF555555)),
    ),
  );
}

String _sourceLabel(String source) => switch (source) {
  'sponsorblock' => 'SponsorBlock',
  'override' => 'Edited',
  'hidden' => 'Hidden',
  'local' => 'Marked by you',
  _ => source,
};

/// Edits one skip segment's category and times. Owns its text controllers.
class _SegmentEditDialog extends StatefulWidget {
  const _SegmentEditDialog({
    required this.track,
    required this.segment,
    required this.db,
  });

  final Track track;
  final SponsorBlockSegment segment;
  final AppDatabase db;

  @override
  State<_SegmentEditDialog> createState() => _SegmentEditDialogState();
}

class _SegmentEditDialogState extends State<_SegmentEditDialog> {
  late String _category =
      isSponsorBlockCategory(widget.segment.category)
          ? widget.segment.category
          : 'sponsor';
  late final TextEditingController _start = TextEditingController(
    text: _formatMs(widget.segment.startMs),
  );
  late final TextEditingController _end = TextEditingController(
    text: _formatMs(widget.segment.endMs),
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final startMs = _parseTimestampMs(_start.text);
    final endMs = _parseTimestampMs(_end.text);
    if (startMs == null || endMs == null) {
      setState(() => _error = 'Use mm:ss or seconds');
      return;
    }
    if (endMs <= startMs) {
      setState(() => _error = 'End must be after start');
      return;
    }
    setState(() => _saving = true);
    final segment = widget.segment;
    final track = widget.track;
    final db = widget.db;
    try {
      if (segment.source == 'sponsorblock' || segment.source == 'hidden') {
        await db.deleteSegment(segment.id);
        await db.insertSegment(
          SponsorBlockSegmentsCompanion.insert(
            trackId: track.id,
            videoId: track.videoId,
            source: 'override',
            uuid: Value(segment.uuid),
            category: _category,
            actionType: Value(segment.actionType),
            startMs: startMs,
            endMs: endMs,
            votes: Value(segment.votes),
            locked: Value(segment.locked),
            description: Value(segment.description),
            createdAt: DateTime.now(),
          ),
        );
      } else {
        await db.updateSegment(
          segment.id,
          category: _category,
          startMs: startMs,
          endMs: endMs,
          source: segment.source == 'local' ? 'local' : 'override',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save: $e';
        });
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text(
        'Edit skip segment',
        style: TextStyle(color: Colors.white),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            value: _category,
            dropdownColor: const Color(0xFF2A2A2A),
            decoration: const InputDecoration(
              labelText: 'Category',
              labelStyle: TextStyle(color: _muted),
            ),
            style: const TextStyle(color: Colors.white),
            items:
                sponsorBlockCategoryDefinitions
                    .map(
                      (definition) => DropdownMenuItem(
                        value: definition.id,
                        child: Text(definition.label),
                      ),
                    )
                    .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _category = value);
            },
          ),
          TextField(
            controller: _start,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Start',
              labelStyle: TextStyle(color: _muted),
            ),
          ),
          TextField(
            controller: _end,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'End',
              labelStyle: TextStyle(color: _muted),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

int? _parseTimestampMs(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final seconds = double.tryParse(value);
  if (seconds != null) return (seconds * 1000).round();

  final parts = value.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  var totalSeconds = 0;
  for (final part in parts) {
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < 0) return null;
    totalSeconds = totalSeconds * 60 + parsed;
  }
  return totalSeconds * 1000;
}
