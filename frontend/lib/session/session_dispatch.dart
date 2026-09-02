// Session Room dispatch: render a game system's focused room if one applies to
// the campaign's system, else the generic SessionRoomScreen.
//
// A module opts in by setting GameSystemModule.sessionRoom (+ optionally
// sessionRoomSystemIds for scanned systems whose id is a UUID). In the public
// build no module ships one, so every campaign gets the generic room.

import 'package:flutter/widgets.dart';
import '../game_systems.dart';
import 'session_room_screen.dart';

Widget sessionRoomFor(Map<String, dynamic> campaign, Map<String, String> params) {
  final id = campaign['id'] as String;
  final sys = ((campaign['system_slug'] ?? campaign['game_system_id'] ?? '') as String? ?? '')
      .toLowerCase();
  for (final m in gameSystemModules) {
    if (m.sessionRoom == null) continue;
    final matches = m.id.toLowerCase() == sys ||
        m.sessionRoomSystemIds.map((s) => s.toLowerCase()).contains(sys);
    if (matches) return m.sessionRoom!(id, params);
  }
  return SessionRoomScreen(campaignId: id);
}
