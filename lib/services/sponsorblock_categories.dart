import 'dart:convert';

enum SponsorBlockCategoryAction { autoSkip, showInSeekbar, disabled }

extension SponsorBlockCategoryActionX on SponsorBlockCategoryAction {
  String get storageValue => switch (this) {
    SponsorBlockCategoryAction.autoSkip => 'autoSkip',
    SponsorBlockCategoryAction.showInSeekbar => 'showInSeekbar',
    SponsorBlockCategoryAction.disabled => 'disabled',
  };

  String get label => switch (this) {
    SponsorBlockCategoryAction.autoSkip => 'Auto skip',
    SponsorBlockCategoryAction.showInSeekbar => 'Show only',
    SponsorBlockCategoryAction.disabled => 'Disabled',
  };
}

class SponsorBlockCategoryDefinition {
  final String id;
  final String label;
  final int colorValue;
  final SponsorBlockCategoryAction defaultAction;

  const SponsorBlockCategoryDefinition({
    required this.id,
    required this.label,
    required this.colorValue,
    required this.defaultAction,
  });
}

const sponsorBlockCategoryDefinitions = [
  SponsorBlockCategoryDefinition(
    id: 'sponsor',
    label: 'Sponsor',
    colorValue: 0xFF00D400,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'selfpromo',
    label: 'Unpaid/Self Promotion',
    colorValue: 0xFFFFFF00,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'interaction',
    label: 'Interaction Reminder',
    colorValue: 0xFFCC00FF,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'intro',
    label: 'Intermission/Intro Animation',
    colorValue: 0xFF00FFFF,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'outro',
    label: 'Endcards/Credits',
    colorValue: 0xFF0202ED,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'preview',
    label: 'Preview/Recap',
    colorValue: 0xFF008FD6,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'hook',
    label: 'Hook/Greetings',
    colorValue: 0xFF395699,
    defaultAction: SponsorBlockCategoryAction.disabled,
  ),
  SponsorBlockCategoryDefinition(
    id: 'music_offtopic',
    label: 'Non-Music',
    colorValue: 0xFFFF9900,
    defaultAction: SponsorBlockCategoryAction.autoSkip,
  ),
  SponsorBlockCategoryDefinition(
    id: 'filler',
    label: 'Tangents/Jokes',
    colorValue: 0xFF7300FF,
    defaultAction: SponsorBlockCategoryAction.disabled,
  ),
  SponsorBlockCategoryDefinition(
    id: 'poi_highlight',
    label: 'Highlight',
    colorValue: 0xFFFF1684,
    defaultAction: SponsorBlockCategoryAction.disabled,
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

String encodeSponsorBlockCategoryActions(
  Map<String, SponsorBlockCategoryAction> actions,
) {
  final sanitized = <String, String>{};
  for (final definition in sponsorBlockCategoryDefinitions) {
    sanitized[definition.id] =
        (actions[definition.id] ?? definition.defaultAction).storageValue;
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
        if (action != null) actions[key] = action;
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
