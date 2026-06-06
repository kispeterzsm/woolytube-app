import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../services/log_service.dart';

class DebugLogPage extends ConsumerStatefulWidget {
  const DebugLogPage({super.key});

  @override
  ConsumerState<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends ConsumerState<DebugLogPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(logServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: 'Copy all',
            onPressed: () {
              final text = log.entries.map((e) => e.formatted).join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Clear',
            onPressed: () {
              log.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: StreamBuilder<List<LogEntry>>(
        stream: log.stream,
        initialData: log.entries,
        builder: (context, snapshot) {
          final entries = snapshot.data ?? [];
          if (entries.isEmpty) {
            return const Center(
              child: Text(
                'No log entries yet',
                style: TextStyle(color: Color(0xFF888888)),
              ),
            );
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            }
          });

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  entry.formatted,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: _colorForLevel(entry.level),
                  ),
                ),
              );
            },
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
