import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/log_service.dart';

enum _LogFilter { all, warnings, errors }

/// Shows the saved log (this run, earlier runs and background updates) with
/// a level filter, and lets the owner copy, share or clear it.
class DebugLogPage extends ConsumerStatefulWidget {
  const DebugLogPage({super.key});

  @override
  ConsumerState<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends ConsumerState<DebugLogPage> {
  /// Copying a huge log can exceed what the clipboard accepts.
  static const _copyLimit = 1000;

  final _scrollController = ScrollController();
  late final LogService _log;
  StreamSubscription<LogEntry>? _subscription;
  List<LogEntry> _entries = const [];
  bool _loading = true;
  _LogFilter _filter = _LogFilter.all;

  @override
  void initState() {
    super.initState();
    _log = ref.read(logServiceProvider);
    unawaited(_load());
  }

  Future<void> _load() async {
    // Listen first so nothing logged while the file is read is missed.
    final arrivedWhileLoading = <LogEntry>[];
    var loaded = false;
    await _subscription?.cancel();
    _subscription = _log.onEntry.listen((entry) {
      if (!loaded) {
        arrivedWhileLoading.add(entry);
      } else if (mounted) {
        setState(() => _entries = [..._entries, entry]);
      }
    });
    List<LogEntry> history;
    try {
      history = await _log.history();
    } catch (_) {
      history = _log.entries;
    }
    final known = {for (final entry in history.reversed.take(500)) entry.key};
    loaded = true;
    if (!mounted) return;
    setState(() {
      _entries = [
        ...history,
        for (final entry in arrivedWhileLoading)
          if (!known.contains(entry.key)) entry,
      ];
      _loading = false;
    });
    _jumpToEnd();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  List<LogEntry> get _visible => switch (_filter) {
    _LogFilter.all => _entries,
    _LogFilter.warnings => [
      for (final e in _entries)
        if (e.level == 'warn' || e.level == 'error') e,
    ],
    _LogFilter.errors => [
      for (final e in _entries)
        if (e.level == 'error') e,
    ],
  };

  String _text(List<LogEntry> entries) =>
      entries.map((e) => e.formattedWithDate).join('\n');

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _copy() async {
    final visible = _visible;
    final shown =
        visible.length > _copyLimit
            ? visible.sublist(visible.length - _copyLimit)
            : visible;
    await Clipboard.setData(ClipboardData(text: _text(shown)));
    if (!mounted) return;
    _showMessage(
      shown.length < visible.length
          ? 'Copied the last $_copyLimit lines. Use Share for the whole log.'
          : 'Log copied',
    );
  }

  Future<void> _share() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'woolytube-log.txt'));
      await file.writeAsString(_text(_visible));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], title: 'WoolyTube log'),
      );
    } catch (error) {
      if (mounted) _showMessage('Could not share the log: $error');
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Clear the log?'),
            content: const Text(
              'This deletes the saved log, including lines from background '
              'updates.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Clear'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    await _log.clear();
    if (mounted) setState(() => _entries = const []);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy',
            onPressed: visible.isEmpty ? null : _copy,
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: visible.isEmpty ? null : _share,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: _entries.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (filter, label) in const [
                  (_LogFilter.all, 'All'),
                  (_LogFilter.warnings, 'Warnings'),
                  (_LogFilter.errors, 'Errors'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _filter == filter,
                    onSelected: (_) {
                      setState(() => _filter = filter);
                      _jumpToEnd();
                    },
                  ),
              ],
            ),
          ),
          Expanded(child: _body(visible)),
        ],
      ),
    );
  }

  Widget _body(List<LogEntry> visible) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _entries.isEmpty ? 'The log is empty' : 'Nothing at this level',
          style: const TextStyle(color: Color(0xFF888888)),
        ),
      );
    }

    // Follow new entries only while the owner is already reading the tail;
    // never yank the list away from an older entry.
    final following =
        !_scrollController.hasClients ||
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 48;
    if (following) _jumpToEnd();

    return ValueListenableBuilder<double>(
      valueListenable: audioPlayerOverlayHeightNotifier,
      builder:
          (context, overlay, _) => ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(12, 4, 12, 12 + overlay),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final entry = visible[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  entry.formattedWithDate,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: _colorForLevel(entry.level),
                  ),
                ),
              );
            },
          ),
    );
  }

  Color _colorForLevel(String level) {
    switch (level) {
      case 'error':
        return Colors.red;
      case 'warn':
        return Colors.orange;
      default:
        return const Color(0xFFCCCCCC);
    }
  }
}
