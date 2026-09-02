// Game-system module seam. The open-core build ships with no modules
// (game_systems_public.dart); the private build ships Fuzion
// (game_systems.dart -> fuzion/module.dart). router.dart and shell_screen.dart
// only ever see this interface, so removing lib/fuzion/ + lib/screens/fuzion/
// leaves the core app intact.
//
// This file is ALWAYS present and never swapped by the publish script — only
// game_systems.dart (the concrete module list) is.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

class GameSystemNavItem {
  final String label;
  final String path; // go_router location this item navigates to

  /// Custom active-state test against the current location. Defaults to a
  /// `location == path || location.startsWith('$path/')` prefix match.
  final bool Function(String location)? isActiveFor;

  const GameSystemNavItem(this.label, this.path, {this.isActiveFor});

  bool isActive(String location) =>
      isActiveFor?.call(location) ??
      (location == path || location.startsWith('$path/'));
}

/// A tab a game-system module adds to the campaign detail screen, after the
/// core tabs (Overview / Members / Wiki / ...). `params` is the route query
/// string so the tab can hold sub-state (e.g. `?tab=characters&char=<id>`).
class GameSystemCampaignTab {
  final String id;
  final String label;
  final bool gmOnly;
  final Widget Function(String campaignId,
      {required bool isGm, required Map<String, String> params}) builder;
  const GameSystemCampaignTab({
    required this.id,
    required this.label,
    required this.builder,
    this.gmOnly = false,
  });
}

class GameSystemModule {
  final String id;

  /// Routes mounted inside the app ShellRoute, after the core routes.
  final List<RouteBase> routes;

  /// Sidebar destinations shown under the core ones (Dashboard/Library/...).
  final List<GameSystemNavItem> navItems;

  /// Sidebar destinations shown only to admins, in the ADMIN section.
  final List<GameSystemNavItem> adminNavItems;

  /// Optional replacement for the plain `/dashboard` landing screen. The first
  /// module that provides one wins.
  final Widget Function()? dashboardHome;

  /// Optional card rendered at the top of a campaign's Overview tab, for
  /// campaigns of this system. Fuzion uses it to surface a combat that a
  /// session ended without resolving. `isGm` reflects the viewer's role.
  final Widget Function(String campaignId, {required bool isGm})? campaignOverviewCard;

  /// Extra tabs on the campaign detail screen for campaigns of this system,
  /// shown after the core tabs. Fuzion adds "Characters".
  final List<GameSystemCampaignTab> campaignTabs;

  /// Optional focused Session Room. When a campaign's `game_system_id` (or
  /// slug) matches [id] or [sessionRoomSystemIds], `/campaigns/:id/session`
  /// renders this instead of the generic SessionRoomScreen. `params` is the
  /// route's query string (`?ct=` / `?pc=`) so the room can restore its nav
  /// state after a refresh.
  final Widget Function(String campaignId, Map<String, String> params)? sessionRoom;

  /// Extra game_system_id / slug values this module's session room applies to
  /// (beyond [id]) — e.g. a scanned system whose id is a UUID.
  final List<String> sessionRoomSystemIds;

  const GameSystemModule({
    required this.id,
    this.routes = const [],
    this.navItems = const [],
    this.adminNavItems = const [],
    this.dashboardHome,
    this.campaignOverviewCard,
    this.campaignTabs = const [],
    this.sessionRoom,
    this.sessionRoomSystemIds = const [],
  });
}
