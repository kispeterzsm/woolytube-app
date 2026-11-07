import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/playback_providers.dart';
import '../providers/providers.dart';
import '../services/sponsorblock_categories.dart';

/// '6 skipped · 1 shown' for a playlist's SponsorBlock choices.
String sponsorBlockSummary(Map<String, SponsorBlockCategoryAction> actions) {
  var skipped = 0, shown = 0;
  for (final definition in sponsorBlockCategoryDefinitions) {
    final action = allowedSponsorBlockAction(
      definition.id,
      actions[definition.id] ?? definition.defaultAction,
    );
    if (action == SponsorBlockCategoryAction.autoSkip) skipped++;
    if (action == SponsorBlockCategoryAction.showInSeekbar) shown++;
  }
  if (skipped == 0 && shown == 0) return 'Nothing is skipped or shown';
  return [
    if (skipped > 0) '$skipped skipped',
    if (shown > 0) '$shown shown',
  ].join(' · ');
}

/// Lets the owner choose, per kind of SponsorBlock segment, whether a
/// playlist skips it, only marks it on the progress bar, or ignores it.
/// Every choice is saved at once and applies to the song that is playing.
class SponsorBlockSettingsPage extends ConsumerStatefulWidget {
  final int playlistId;

  const SponsorBlockSettingsPage({super.key, required this.playlistId});

  @override
  ConsumerState<SponsorBlockSettingsPage> createState() =>
      _SponsorBlockSettingsPageState();
}

class _SponsorBlockSettingsPageState
    extends ConsumerState<SponsorBlockSettingsPage> {
  Map<String, SponsorBlockCategoryAction>? _actions;
  bool _audioOnly = false;
  Future<void> _saves = Future<void>.value();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final playlist = await ref
          .read(databaseProvider)
          .getPlaylist(widget.playlistId);
      if (!mounted) return;
      setState(() {
        _audioOnly = playlist.audioOnly;
        _actions = decodeSponsorBlockCategoryActions(
          playlist.sponsorBlockCategoryActions,
          legacyCategories: playlist.sponsorBlockCategories,
        );
      });
    } catch (error) {
      if (!mounted) return;
      _showMessage('Could not load the playlist: $error');
      Navigator.of(context).pop();
    }
  }

  /// Shows [next] at once and saves it; on failure the screen goes back to
  /// what is stored.
  void _apply(Map<String, SponsorBlockCategoryAction> next) {
    final previous = _actions;
    setState(() => _actions = next);
    final playlists = ref.read(playlistServiceProvider);
    // Saves run one after another so a quick second tap cannot be
    // overtaken by the first.
    _saves = _saves.then((_) async {
      try {
        await playlists.updatePlaylistSettings(
          id: widget.playlistId,
          sponsorBlockCategoryActions: next,
        );
        await _tellPlayer();
      } catch (error) {
        if (!mounted) return;
        setState(() => _actions = previous);
        _showMessage('Could not save: $error');
      }
    });
  }

  Future<void> _tellPlayer() async {
    try {
      await ref
          .read(playbackServiceProvider)
          .playlistSettingsChanged(widget.playlistId);
    } catch (_) {
      // Nothing from this playlist is playing, or no player (tests).
    }
  }

  void _set(String category, SponsorBlockCategoryAction action) {
    final actions = _actions;
    if (actions == null || actions[category] == action) return;
    _apply({...actions, category: action});
  }

  void _resetToDefaults() {
    final previous = _actions;
    if (previous == null) return;
    _apply(defaultSponsorBlockCategoryActions());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Back to the default choices'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (mounted) _apply(previous);
            },
          ),
        ),
      );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// SponsorBlock's own order, except that music playlists see the
  /// non-music category first: it is the one that matters there.
  List<SponsorBlockCategoryDefinition> get _orderedDefinitions {
    if (!_audioOnly) return sponsorBlockCategoryDefinitions;
    return [
      for (final d in sponsorBlockCategoryDefinitions)
        if (d.id == 'music_offtopic') d,
      for (final d in sponsorBlockCategoryDefinitions)
        if (d.id != 'music_offtopic') d,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Skip segments'),
        actions: [
          TextButton(
            key: const ValueKey('sponsorblock-reset'),
            onPressed: actions == null ? null : _resetToDefaults,
            child: const Text('Reset'),
          ),
        ],
      ),
      body:
          actions == null
              ? const Center(child: CircularProgressIndicator())
              : ValueListenableBuilder<double>(
                valueListenable: audioPlayerOverlayHeightNotifier,
                builder:
                    (context, overlay, _) => ListView(
                      padding: EdgeInsets.only(bottom: 16 + overlay),
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'SponsorBlock users mark parts of YouTube videos. '
                            'Choose what happens to each kind of part.',
                            style: TextStyle(color: Color(0xFFBBBBBB)),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Text(
                            'Skip: jumped over automatically.\n'
                            'Show: only marked on the progress bar.\n'
                            'Ignore: not used.',
                            style: TextStyle(
                              color: Color(0xFF888888),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        for (final definition in _orderedDefinitions)
                          _CategoryRow(
                            definition: definition,
                            action: allowedSponsorBlockAction(
                              definition.id,
                              actions[definition.id] ??
                                  definition.defaultAction,
                            ),
                            onChanged: (action) => _set(definition.id, action),
                          ),
                      ],
                    ),
              ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.definition,
    required this.action,
    required this.onChanged,
  });

  final SponsorBlockCategoryDefinition definition;
  final SponsorBlockCategoryAction action;
  final ValueChanged<SponsorBlockCategoryAction> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('sponsorblock-category-${definition.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Color(definition.colorValue),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  definition.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (definition.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                definition.description,
                style: const TextStyle(color: Color(0xFF999999), fontSize: 13),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<SponsorBlockCategoryAction>(
              showSelectedIcon: false,
              segments: [
                for (final allowed in definition.allowedActions)
                  ButtonSegment(
                    value: allowed,
                    label: Text(allowed.shortLabel),
                    tooltip: allowed.label,
                  ),
              ],
              selected: {action},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onChanged(selection.first);
              },
            ),
          ),
        ],
      ),
    );
  }
}
