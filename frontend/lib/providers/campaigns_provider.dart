import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

class CampaignsNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    final data = await apiGet('/campaigns') as List;
    return data.cast<Map<String, dynamic>>();
  }

  Future<void> create(String name, {String? gameSystemId, String? description}) async {
    final body = <String, dynamic>{'name': name};
    if (gameSystemId != null) body['game_system_id'] = gameSystemId;
    if (description != null && description.isNotEmpty) body['description'] = description;
    await apiPost('/campaigns', body);
    ref.invalidateSelf();
  }

  Future<void> delete(String id) async {
    await apiDelete('/campaigns/$id');
    ref.invalidateSelf();
  }
}

final campaignsProvider =
    AsyncNotifierProvider<CampaignsNotifier, List<Map<String, dynamic>>>(CampaignsNotifier.new);

final campaignDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id') as Map<String, dynamic>;
  return data;
});

final campaignNotesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/notes') as List;
  return data.cast<Map<String, dynamic>>();
});

final activeSessionProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/notes/active');
  if (data == null) return null;
  return data as Map<String, dynamic>;
});

final campaignWikiProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/wiki') as List;
  return data.cast<Map<String, dynamic>>();
});

final wikiTemplatesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/wiki-templates') as List;
  return data.cast<Map<String, dynamic>>();
});

final campaignMembersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/members') as List;
  return data.cast<Map<String, dynamic>>();
});

final campaignInvitesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/invites') as List;
  return data.cast<Map<String, dynamic>>();
});

Future<Map<String, dynamic>> createCampaignInvite(
  String campaignId, {
  String role = 'player',
  int? maxUses,
  int? expiresInDays,
}) async {
  final res = await apiPost('/campaigns/$campaignId/invites', {
    'role': role,
    if (maxUses != null) 'max_uses': maxUses,
    if (expiresInDays != null) 'expires_in_days': expiresInDays,
  });
  return (res as Map).cast<String, dynamic>();
}

Future<void> revokeCampaignInvite(String campaignId, String inviteId) =>
    apiDelete('/campaigns/$campaignId/invites/$inviteId');

final sessionPollsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/session-polls') as List;
  return data.cast<Map<String, dynamic>>();
});

Future<void> createSessionPoll(String campaignId,
    {required String title, String? note, required List<DateTime> slots}) async {
  await apiPost('/campaigns/$campaignId/session-polls', {
    'title': title,
    if (note != null && note.isNotEmpty) 'note': note,
    'option_datetimes': slots.map((d) => d.toUtc().toIso8601String()).toList(),
  });
}

Future<Map<String, dynamic>> respondSessionPoll(
    String campaignId, String pollId, Map<String, String> responses) async {
  final res = await apiPost(
      '/campaigns/$campaignId/session-polls/$pollId/respond', {'responses': responses});
  return (res as Map).cast<String, dynamic>();
}

Future<void> updateSessionPoll(String campaignId, String pollId,
    {String? status, String? confirmedOptionId, bool clearConfirmed = false}) async {
  await apiPatch('/campaigns/$campaignId/session-polls/$pollId', {
    if (status != null) 'status': status,
    if (confirmedOptionId != null) 'confirmed_option_id': confirmedOptionId,
    if (clearConfirmed) 'confirmed_option_id': '',
  });
}

Future<void> deleteSessionPoll(String campaignId, String pollId) =>
    apiDelete('/campaigns/$campaignId/session-polls/$pollId');

final campaignResourcesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/resources') as List;
  return data.cast<Map<String, dynamic>>();
});

final campaignFilesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/files') as List;
  return data.cast<Map<String, dynamic>>();
});
