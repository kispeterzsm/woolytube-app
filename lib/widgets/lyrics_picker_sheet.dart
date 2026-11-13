import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/lyrics/lyrics_models.dart';

const _accent = Color(0xFF2196F3);
const _muted = Color(0xFF888888);

/// Opens the picker for a track's (or chapter's) lyrics. In [mode]
/// transcript only the "From YouTube" tab is offered. True when a choice
/// was saved.
Future<bool> showLyricsPicker(
  BuildContext context, {
  required int trackId,
  String? chapterId,
  required LyricsMode mode,
  String? fallbackQuery,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: const Color(0xFF2A2A2A),
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder:
        (_) => LyricsPickerSheet(
          trackId: trackId,
          chapterId: chapterId,
          mode: mode,
          fallbackQuery: fallbackQuery,
        ),
  );
  return saved == true;
}

/// The video id in a link to one YouTube video, or null.
String? youTubeVideoIdFromLink(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  String? id;
  if (host == 'youtu.be') {
    id = segments.isEmpty ? null : segments.first;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    if (segments.length == 1 && segments.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segments.length >= 2 &&
        const {'shorts', 'live', 'embed'}.contains(segments.first)) {
      id = segments[1];
    }
  }
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(id)) return null;
  return id;
}

/// Search LRCLIB for the right song, or take a YouTube video's captions.
class LyricsPickerSheet extends ConsumerStatefulWidget {
  const LyricsPickerSheet({
    super.key,
    required this.trackId,
    this.chapterId,
    required this.mode,
    this.fallbackQuery,
  });

  final int trackId;
  final String? chapterId;
  final LyricsMode mode;

  /// The starting search when the service has none (the track title).
  final String? fallbackQuery;

  @override
  ConsumerState<LyricsPickerSheet> createState() => _LyricsPickerSheetState();
}

class _LyricsPickerSheetState extends ConsumerState<LyricsPickerSheet> {
  final _query = TextEditingController();
  final _link = TextEditingController();
  List<LyricsCandidate>? _results;
  String? _searchError;
  String? _linkError;
  bool _searching = false;
  bool _saving = false;
  int _searchRun = 0;
  final _expanded = <int>{};

  bool get _lyrics => widget.mode == LyricsMode.lyrics;

  @override
  void initState() {
    super.initState();
    if (_lyrics) unawaited(_prefill());
  }

  @override
  void dispose() {
    _query.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    var query = '';
    try {
      query = await ref
          .read(lyricsServiceProvider)
          .pickerQueryFor(widget.trackId, widget.chapterId);
    } catch (_) {
      // No parsed title; the track title is a fine start.
    }
    if (query.trim().isEmpty) query = widget.fallbackQuery ?? '';
    if (!mounted) return;
    // The owner may have typed already.
    if (_query.text.isEmpty) _query.text = query.trim();
    if (_query.text.isNotEmpty) await _search();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final run = ++_searchRun;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = await ref
          .read(lyricsServiceProvider)
          .candidatesFor(
            query,
            trackId: widget.trackId,
            chapterId: widget.chapterId,
          );
      if (!mounted || run != _searchRun) return;
      setState(() {
        _results = results;
        _expanded.clear();
      });
    } catch (e) {
      if (!mounted || run != _searchRun) return;
      setState(() => _searchError = 'Could not search: ${_errorText(e)}');
    } finally {
      if (mounted && run == _searchRun) setState(() => _searching = false);
    }
  }

  Future<void> _apply(LyricsPick pick, {bool fromLink = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _linkError = null;
      if (!fromLink) _searchError = null;
    });
    try {
      await ref
          .read(lyricsServiceProvider)
          .applyPick(widget.trackId, widget.chapterId, pick);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final message = 'Could not use it: ${_errorText(e)}';
        if (fromLink) {
          _linkError = message;
        } else {
          _searchError = message;
        }
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _useLink() {
    final text = _link.text.trim();
    final id = youTubeVideoIdFromLink(text);
    if (id == null) {
      setState(
        () =>
            _linkError =
                text.isEmpty
                    ? 'Paste a link'
                    : 'Paste a link to one YouTube video, not a playlist',
      );
      return;
    }
    unawaited(
      _apply(
        LyricsPick(source: LyricsSource.ytSubs, sourceRef: id),
        fromLink: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final body =
        _lyrics
            ? DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    key: ValueKey('lyrics-picker-tabs'),
                    tabs: [
                      Tab(
                        key: ValueKey('lyrics-picker-tab-search'),
                        text: 'Search',
                      ),
                      Tab(
                        key: ValueKey('lyrics-picker-tab-youtube'),
                        text: 'From YouTube',
                      ),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [_buildSearch(), _buildYouTube()],
                    ),
                  ),
                ],
              ),
            )
            : _buildYouTube();
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _lyrics ? 'Choose the song' : 'Choose captions',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_saving)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _buildSearch() {
    final results = _results;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            key: const ValueKey('lyrics-picker-query'),
            controller: _query,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Artist and title',
              hintStyle: const TextStyle(color: _muted),
              filled: true,
              fillColor: const Color(0xFF1E1E1E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.search, color: _muted),
              suffixIcon: IconButton(
                key: const ValueKey('lyrics-picker-search'),
                tooltip: 'Search',
                icon: const Icon(Icons.arrow_forward),
                onPressed: _searching ? null : _search,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _searchError!,
              key: const ValueKey('lyrics-picker-error'),
              style: const TextStyle(color: Color(0xFFE57373)),
            ),
          ),
        Expanded(
          child:
              results == null
                  ? const SizedBox.shrink()
                  : results.isEmpty
                  ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing found. Try fewer words, or only the title.',
                      key: ValueKey('lyrics-picker-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted),
                    ),
                  )
                  : ListView.builder(
                    key: const ValueKey('lyrics-picker-results'),
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: results.length,
                    itemBuilder: (context, i) {
                      final candidate = results[i];
                      return _CandidateTile(
                        candidate: candidate,
                        chapter: widget.chapterId != null,
                        expanded: _expanded.contains(candidate.id),
                        enabled: !_saving,
                        onToggle:
                            () => setState(() {
                              if (!_expanded.remove(candidate.id)) {
                                _expanded.add(candidate.id);
                              }
                            }),
                        onChoose: () => _apply(LyricsPick.lrclib(candidate)),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Widget _buildYouTube() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text(
          _lyrics
              ? 'Paste a link to a video that shows the words as captions, '
                  'like an official lyric video. Its own captions are used, '
                  'never automatic ones.'
              : 'Paste a link to a video with the same talk. Its captions '
                  'are used for this track.',
          style: const TextStyle(color: Color(0xFFCCCCCC)),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('lyrics-picker-link'),
          controller: _link,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Link to the video',
            hintText: 'https://www.youtube.com/watch?v=…',
            errorText: _linkError,
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              key: const ValueKey('lyrics-picker-paste'),
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste),
              onPressed: () async {
                final text =
                    (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                if (text == null || !mounted) return;
                setState(() {
                  _link.text = text.trim();
                  _linkError = null;
                });
              },
            ),
          ),
          onChanged: (_) {
            if (_linkError != null) setState(() => _linkError = null);
          },
          onSubmitted: (_) => _useLink(),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('lyrics-picker-link-use'),
            onPressed: _saving ? null : _useLink,
            child: const Text('Use its captions'),
          ),
        ),
      ],
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.chapter,
    required this.expanded,
    required this.enabled,
    required this.onToggle,
    required this.onChoose,
  });

  final LyricsCandidate candidate;

  /// The lyrics are for a chapter, not the whole file.
  final bool chapter;
  final bool expanded;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    // "4:07 · your file 4:09 · Album": its length against the user's.
    final details = [
      if (c.durationSeconds != null) _clock(c.durationSeconds!.round()),
      if (c.localSeconds != null)
        'your ${chapter ? 'chapter' : 'file'} '
            '${_clock(c.localSeconds!.round())}',
      if (c.album != null && c.album!.trim().isNotEmpty) c.album!.trim(),
    ].join(' · ');
    final (badge, badgeColor) =
        c.instrumental
            ? ('Instrumental', const Color(0xFFFFB74D))
            : !c.synced
            ? ('Plain', _muted)
            : c.timingFits == true
            ? ('Synced · fits', const Color(0xFF81C784))
            : c.timingFits == false
            ? ('Timing off', const Color(0xFFE57373))
            : ('Synced', const Color(0xFF81C784));
    final preview = c.plainPreview.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          key: ValueKey('lyrics-candidate-${c.id}'),
          enabled: enabled,
          title: Text(
            '${c.artist} – ${c.title}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
          // The details go on the next line when they do not fit beside
          // the badge, so the album is never cut.
          subtitle: Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: badgeColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge,
                  key: ValueKey('lyrics-candidate-${c.id}-badge'),
                  style: TextStyle(color: badgeColor, fontSize: 11),
                ),
              ),
              if (details.isNotEmpty)
                Text(
                  details,
                  key: ValueKey('lyrics-candidate-${c.id}-details'),
                  style: const TextStyle(color: _muted),
                ),
            ],
          ),
          trailing:
              preview.isEmpty
                  ? null
                  : IconButton(
                    key: ValueKey('lyrics-candidate-${c.id}-preview'),
                    tooltip: expanded ? 'Hide the words' : 'Show the words',
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    onPressed: onToggle,
                  ),
          onTap: onChoose,
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              key: ValueKey('lyrics-candidate-${c.id}-text'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _firstLines(preview, 12),
                    style: const TextStyle(color: Color(0xFFCCCCCC)),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: ValueKey('lyrics-candidate-${c.id}-choose'),
                      onPressed: enabled ? onChoose : null,
                      style: TextButton.styleFrom(foregroundColor: _accent),
                      child: const Text('Use these lyrics'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _firstLines(String text, int count) {
  final lines = text.split('\n');
  if (lines.length <= count) return text;
  return '${lines.take(count).join('\n')}\n…';
}

String _clock(int seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _errorText(Object error) =>
    error is StateError
        ? error.message
        : error is FormatException
        ? error.message
        : '$error';
