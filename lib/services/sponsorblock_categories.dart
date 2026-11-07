import 'dart:convert';

enum SponsorBlockCategoryAction { autoSkip, showInSeekbar, disabled }

extension SponsorBlockCategoryActionX on SponsorBlockCategoryAction {
  String get storageValue => switch (this) {
    SponsorBlockCategoryAction.autoSkip => 'autoSkip',
    SponsorBlockCategoryAction.showInSeekbar => 'showInSeekbar',
    SponsorBlockCategoryAction.disabled => 'disabled',
  };

  String get label => switch (this) {
    SponsorBlockCategoryAction.autoSkip => 'Skip automatically',
    SponsorBlockCategoryAction.showInSeekbar => 'Show on progress bar',
    SponsorBlockCategoryAction.disabled => 'Ignore',
  };

  /// One word, for compact controls such as a segmented button.
  String get shortLabel => switch (this) {
    SponsorBlockCategoryAction.autoSkip => 'Skip',
    SponsorBlockCategoryAction.showInSeekbar => 'Show',
    SponsorBlockCategoryAction.disabled => 'Ignore',
  };
}

class SponsorBlockCategoryDefinition {
  final String id;
  final String label;

  /// One plain sentence saying what the category marks.
  final String description;
  final int colorValue;
  final SponsorBlockCategoryAction defaultAction;

  /// What a user can pick for this category. A highlight is a single point
  /// to jump to, so it can be shown but not skipped.
  final List<SponsorBlockCategoryAction> allowedActions;

  const SponsorBlockCategoryDefinition({
    required this.id,
    required this.label,
    this.description = '',
    required this.colorValue,
    required this.defaultAction,
    this.allowedActions = SponsorBlockCategoryAction.values,
  });
}

const sponsorBlockCategoryDefinitions = [
  SponsorBlockCategoryDefinition(
    id: 'sponsor',
    label: 'Sponsor',
    description: 'Paid promotions and ads read in the video.',
    colorValue: 0xFF00D400,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'selfpromo',
    label: 'Self-promotion',
    description: 'Plugs for the creator\'s own merch, channels or donations.',
    colorValue: 0xFFFFFF00,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'interaction',
    label: 'Subscribe reminder',
    description: 'Asking you to like, subscribe or comment.',
    colorValue: 0xFFCC00FF,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'intro',
    label: 'Intro',
    description: 'Intro animations and pauses with no real content.',
    colorValue: 0xFF00FFFF,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'outro',
    label: 'Outro and credits',
    description: 'End cards and credits after the content ends.',
    colorValue: 0xFF0202ED,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'preview',
    label: 'Preview or recap',
    description: 'Clips of what is coming up or what happened before.',
    colorValue: 0xFF008FD6,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'hook',
    label: 'Greeting',
    description: 'Teasers and greetings at the start.',
    colorValue: 0xFF395699,
    defaultAction: SponsorBlockCategoryAction.disabled,
  ),
  SponsorBlockCategoryDefinition(
    id: 'music_offtopic',
    label: 'Non-music part',
    description: 'Talking or other non-music parts of a music video.',
    colorValue: 0xFFFF9900,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'filler',
    label: 'Tangent or joke',
    description: 'Off-topic jokes and tangents.',
    colorValue: 0xFF7300FF,
    defaultAction: SponsorBlockCategoryAction.disabled,
  ),
  SponsorBlockCategoryDefinition(
    id: 'poi_highlight',
    label: 'Highlight',
    description: 'The main moment of the video, to jump to.',
    colorValue: 0xFFFF1684,
    defaultAction: SponsorBlockCategoryAction.disabled,
    allowedActions: [
      SponsorBlockCategoryAction.showInSeekbar,
      SponsorBlockCategoryAction.disabled,
    ],
  ),
];

const sponsorBlockCategories = [
  'sponsor',
  'selfpromo',
  'interaction',
  'intro',
  'outro',
  'preview',
  'hook',
  'music_offtopic',
  'filler',
  'poi_highlight',
];

const legacyDefaultSponsorBlockCategories = [
  'sponsor',
  'selfpromo',
  'music_offtopic',
];

const defaultSponsorBlockCategories = [
  'sponsor',
  'selfpromo',
  'interaction',
  'intro',
  'outro',
  'preview',
  'music_offtopic',
];

const defaultSponsorBlockCategoryActionsJson =
    '{"sponsor":"autoSkip","selfpromo":"autoSkip","interaction":"autoSkip",'
    '"intro":"autoSkip","outro":"autoSkip","preview":"autoSkip",'
    '"hook":"disabled","music_offtopic":"autoSkip","filler":"disabled",'
    '"poi_highlight":"disabled"}';

final sponsorBlockCategoryLabels = {
  for (final definition in sponsorBlockCategoryDefinitions)
    definition.id: definition.label,
};

final sponsorBlockCategoryColors = {
  for (final definition in sponsorBlockCategoryDefinitions)
    definition.id: definition.colorValue,
};

bool isSponsorBlockCategory(String category) =>
    sponsorBlockCategories.contains(category);

SponsorBlockCategoryDefinition sponsorBlockCategoryDefinition(
  String category,
) => sponsorBlockCategoryDefinitions.firstWhere(
  (definition) => definition.id == category,
  orElse:
      () => SponsorBlockCategoryDefinition(
        id: category,
        label: category,
        colorValue: 0xFF888888,
        defaultAction: SponsorBlockCategoryAction.disabled,
      ),
);

Map<String, SponsorBlockCategoryAction> defaultSponsorBlockCategoryActions() =>
    {
      for (final definition in sponsorBlockCategoryDefinitions)
        definition.id: definition.defaultAction,
    };

/// [action] if [category] allows it; otherwise the closest allowed one (a
/// highlight set to skip has always only been shown).
SponsorBlockCategoryAction allowedSponsorBlockAction(
  String category,
  SponsorBlockCategoryAction action,
) {
  final allowed = sponsorBlockCategoryDefinition(category).allowedActions;
  if (allowed.contains(action)) return action;
  return action == SponsorBlockCategoryAction.autoSkip &&
          allowed.contains(SponsorBlockCategoryAction.showInSeekbar)
      ? SponsorBlockCategoryAction.showInSeekbar
      : allowed.last;
}

String encodeSponsorBlockCategoryActions(
  Map<String, SponsorBlockCategoryAction> actions,
) {
  final sanitized = <String, String>{};
  for (final definition in sponsorBlockCategoryDefinitions) {
    sanitized[definition.id] =
        allowedSponsorBlockAction(
          definition.id,
          actions[definition.id] ?? definition.defaultAction,
        ).storageValue;
  }
  return jsonEncode(sanitized);
}

Map<String, SponsorBlockCategoryAction> decodeSponsorBlockCategoryActions(
  String raw, {
  String? legacyCategories,
}) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final actions = defaultSponsorBlockCategoryActions();
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) continue;
        if (!isSponsorBlockCategory(key)) continue;
        final action = _parseAction(value);
        if (action != null) {
          actions[key] = allowedSponsorBlockAction(key, action);
        }
      }
      return actions;
    }
    if (decoded is List) {
      return sponsorBlockCategoryActionsFromLegacyJson(raw);
    }
  } catch (_) {}

  if (legacyCategories != null) {
    return sponsorBlockCategoryActionsFromLegacyJson(legacyCategories);
  }
  return defaultSponsorBlockCategoryActions();
}

Map<String, SponsorBlockCategoryAction>
sponsorBlockCategoryActionsFromLegacyJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final categories =
          decoded.whereType<String>().where(isSponsorBlockCategory).toSet();
      if (_sameCategorySet(categories, legacyDefaultSponsorBlockCategories)) {
        return defaultSponsorBlockCategoryActions();
      }
      return {
        for (final definition in sponsorBlockCategoryDefinitions)
          definition.id:
              categories.contains(definition.id)
                  ? SponsorBlockCategoryAction.autoSkip
                  : SponsorBlockCategoryAction.disabled,
      };
    }
  } catch (_) {}
  return defaultSponsorBlockCategoryActions();
}

String sponsorBlockCategoryActionsJsonFromLegacyJson(String raw) =>
    encodeSponsorBlockCategoryActions(
      sponsorBlockCategoryActionsFromLegacyJson(raw),
    );

List<String> autoSkipCategoriesFromActions(
  Map<String, SponsorBlockCategoryAction> actions,
) => [
  for (final definition in sponsorBlockCategoryDefinitions)
    if (actions[definition.id] == SponsorBlockCategoryAction.autoSkip)
      definition.id,
];

SponsorBlockCategoryAction? _parseAction(String raw) {
  for (final action in SponsorBlockCategoryAction.values) {
    if (action.storageValue == raw) return action;
  }
  return null;
}

bool _sameCategorySet(Set<String> categories, List<String> expected) {
  if (categories.length != expected.length) return false;
  return expected.every(categories.contains);
}
