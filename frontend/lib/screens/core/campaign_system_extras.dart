// Resolves a campaign's game-system module and returns any Overview-tab card
// it contributes. Mirrors session/session_dispatch.dart — in the public build
// no module ships one, so this always returns null.

import 'package:flutter/widgets.dart';
import '../../game_systems.dart';

GameSystemModule? _moduleFor(Map<String, dynamic> campaign) {
  final sys = ((campaign['system_slug'] ?? campaign['game_system_id'] ?? '') as String? ?? '')
      .toLowerCase();
  for (final m in gameSystemModules) {
    if (m.id.toLowerCase() == sys ||
        m.sessionRoomSystemIds.map((s) => s.toLowerCase()).contains(sys)) {
      return m;
    }
  }
  return null;
}

Widget? campaignOverviewCardFor(Map<String, dynamic> campaign, {required bool isGm}) {
  final card = _moduleFor(campaign)?.campaignOverviewCard;
  return card == null ? null : card(campaign['id'] as String, isGm: isGm);
}

/// The extra campaign tabs a game-system module contributes, filtered by role.
List<GameSystemCampaignTab> campaignSystemTabs(Map<String, dynamic> campaign, {required bool isGm}) {
  final tabs = _moduleFor(campaign)?.campaignTabs ?? const [];
  return [for (final t in tabs) if (!t.gmOnly || isGm) t];
}
