import 'package:flutter_test/flutter_test.dart';
import 'package:woolytube/services/sponsorblock_categories.dart';

void main() {
  test('legacy default category list migrates to new preferred defaults', () {
    final actions = sponsorBlockCategoryActionsFromLegacyJson(
      '["sponsor","selfpromo","music_offtopic"]',
    );

    expect(actions['sponsor'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['selfpromo'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['interaction'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['intro'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['outro'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['preview'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['music_offtopic'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['hook'], SponsorBlockCategoryAction.disabled);
    expect(actions['filler'], SponsorBlockCategoryAction.disabled);
    expect(actions['poi_highlight'], SponsorBlockCategoryAction.disabled);
  });

  test('custom legacy category list preserves only selected auto-skips', () {
    final actions = sponsorBlockCategoryActionsFromLegacyJson(
      '["sponsor","intro"]',
    );

    expect(actions['sponsor'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['intro'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['selfpromo'], SponsorBlockCategoryAction.disabled);
    expect(actions['music_offtopic'], SponsorBlockCategoryAction.disabled);
  });

  test('a highlight can be shown but never set to skip', () {
    final highlight = sponsorBlockCategoryDefinition('poi_highlight');
    expect(
      highlight.allowedActions,
      isNot(contains(SponsorBlockCategoryAction.autoSkip)),
    );
    final actions = decodeSponsorBlockCategoryActions(
      '{"poi_highlight":"autoSkip"}',
    );
    expect(actions['poi_highlight'], SponsorBlockCategoryAction.showInSeekbar);
    expect(
      encodeSponsorBlockCategoryActions({
        'poi_highlight': SponsorBlockCategoryAction.autoSkip,
      }),
      contains('"poi_highlight":"showInSeekbar"'),
    );
  });

  test('every category explains itself in plain words', () {
    for (final definition in sponsorBlockCategoryDefinitions) {
      expect(definition.description, isNotEmpty, reason: definition.id);
      expect(definition.label, isNot(contains('/')), reason: definition.id);
    }
  });

  test('action map decoder fills missing categories with defaults', () {
    final actions = decodeSponsorBlockCategoryActions(
      '{"sponsor":"disabled","hook":"showInSeekbar"}',
    );

    expect(actions['sponsor'], SponsorBlockCategoryAction.disabled);
    expect(actions['hook'], SponsorBlockCategoryAction.showInSeekbar);
    expect(actions['interaction'], SponsorBlockCategoryAction.autoSkip);
    expect(actions['poi_highlight'], SponsorBlockCategoryAction.disabled);
  });
}
