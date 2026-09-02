// Session Room data — system-agnostic. Backed by the generic
// /api/campaigns/{id}/log + /session-state endpoints (routers/campaigns.py).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

// current_only: the Session Room only ever shows *this* session's activity —
// the server cuts the log at the last "Session started". Starting a new
// session resets the cutoff, so the room comes up fresh.
final sessionLogProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, campaignId) async {
  final data = await apiGet('/campaigns/$campaignId/log?current_only=true') as List;
  return data.cast<Map<String, dynamic>>();
});

// Cheap poll target — {session_active, session_started_at, sessions_completed}
// — so a player on a game page sees a session start/end within a few seconds
// without refreshing.
final sessionStateProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, campaignId) async {
  return (await apiGet('/campaigns/$campaignId/session-state')) as Map<String, dynamic>;
});

/// POST a log entry then refresh the feed. `payload` gets `author_id` stamped
/// server-side (used for private-roll filtering + attribution).
Future<void> postSessionLog(
  WidgetRef ref,
  String campaignId,
  String kind,
  Map<String, dynamic> payload,
) async {
  await apiPost('/campaigns/$campaignId/log', {'kind': kind, 'payload': payload});
  ref.invalidate(sessionLogProvider(campaignId));
}
