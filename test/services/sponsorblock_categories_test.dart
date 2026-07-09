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
