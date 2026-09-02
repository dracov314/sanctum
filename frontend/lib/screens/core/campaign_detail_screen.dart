// Campaign detail — Overview / Members / Wiki / Resources / Notes / Files.
// System-agnostic: every tab talks to the generic /api/campaigns backend.
// The active tab is a ?tab= query param so tabs are deep-linkable.

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../api/client.dart';
import '../../providers/campaigns_provider.dart';
import '../../ui/chrome.dart';
import 'campaign_wiki.dart';
import 'campaign_system_extras.dart';

const _tabs = ['overview', 'schedule', 'members', 'wiki', 'resources', 'notes', 'files'];

class CampaignDetailScreen extends ConsumerWidget {
  final String campaignId;
  final String tab;
  const CampaignDetailScreen({super.key, required this.campaignId, required this.tab});

  bool _isGm(String? role) => role == 'owner' || role == 'gm';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignDetailProvider(campaignId));
    final params = GoRouterState.of(context).uri.queryParameters;

    return PageChrome(
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _BackLink(),
          const SizedBox(height: 12),
          Text('Could not load this campaign: $e',
              style: const TextStyle(fontSize: 12, color: kFail)),
        ]),
        data: (c) {
          final isGm = _isGm(c['role'] as String?);
          final moduleTabs = campaignSystemTabs(c, isGm: isGm);
          final allIds = [..._tabs, ...moduleTabs.map((t) => t.id)];
          final active = allIds.contains(tab) ? tab : 'overview';
          final moduleTab = moduleTabs.where((t) => t.id == active).firstOrNull;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _BackLink(),
            const SizedBox(height: 10),
            Row(children: [
              Flexible(child: Text(c['name'] as String? ?? '',
                  style: serif(22, color: kT100), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 12),
              PillButton('Session Room', () => context.go('/campaigns/$campaignId/session')),
            ]),
            if ((c['description'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(c['description'] as String,
                  style: const TextStyle(fontSize: 12, color: kT68)),
            ],
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final t in _tabs) ...[
                  RefTab(_label(t), t == active,
                      () => context.go('/campaigns/$campaignId?tab=$t')),
                  const SizedBox(width: 18),
                ],
                for (final t in moduleTabs) ...[
                  RefTab(t.label, t.id == active,
                      () => context.go('/campaigns/$campaignId?tab=${t.id}')),
                  const SizedBox(width: 18),
                ],
              ]),
            ),
            Container(height: 1, color: kBorderDim),
            const SizedBox(height: 20),
            Expanded(
              child: moduleTab != null
                  ? moduleTab.builder(campaignId, isGm: isGm, params: params)
                  : SingleChildScrollView(
                      child: switch (active) {
                        'schedule' => _ScheduleTab(campaignId: campaignId, isGm: isGm),
                        'members' => _MembersTab(campaignId: campaignId, isGm: isGm),
                        'wiki' => CampaignWikiPanel(gameId: campaignId, isGm: isGm),
                        'resources' => _ResourcesTab(campaignId: campaignId, isGm: isGm),
                        'notes' => _NotesTab(campaignId: campaignId, isGm: isGm),
                        'files' => _FilesTab(campaignId: campaignId, isGm: isGm),
                        _ => _OverviewTab(campaign: c, isGm: isGm),
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }

  static String _label(String t) => switch (t) {
        'overview' => 'Overview',
        'schedule' => 'Schedule',
        'members' => 'Members',
        'wiki' => 'Wiki',
        'resources' => 'Resources',
        'notes' => 'Notes',
        'files' => 'Files',
        _ => t,
      };
}

class _BackLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => context.go('/campaigns'),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chevron_left, size: 16, color: kLink),
          Text('All campaigns', style: TextStyle(fontSize: 12, color: kLink)),
        ]),
      );
}

// ── Overview ────────────────────────────────────────────────────────────────

class _OverviewTab extends ConsumerWidget {
  final Map<String, dynamic> campaign;
  final bool isGm;
  const _OverviewTab({required this.campaign, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = campaign['id'] as String;
    final systemCard = campaignOverviewCardFor(campaign, isGm: isGm);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (systemCard != null) ...[systemCard, const SizedBox(height: 16)],
      Text('Your role: ${(campaign['role'] as String? ?? 'player').toUpperCase()}',
          style: const TextStyle(fontSize: 12, color: kT68)),
      const SizedBox(height: 10),
      _NextSessionLine(campaignId: id),
      const SizedBox(height: 16),
      if (isGm) ...[
        PillButtonOutlined('Edit name & description', () => _edit(context, ref)),
        const SizedBox(height: 10),
      ],
      if (campaign['role'] == 'owner')
        PillButtonOutlined('Delete campaign', () => _confirmDelete(context, ref, id)),
    ]);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final id = campaign['id'] as String;
    final nameCtrl = TextEditingController(text: campaign['name'] as String? ?? '');
    final descCtrl = TextEditingController(text: campaign['description'] as String? ?? '');
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Edit campaign', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              const FieldLabel('NAME'),
              const SizedBox(height: 4),
              RefInput(nameCtrl, hint: 'Campaign name'),
              const SizedBox(height: 10),
              const FieldLabel('DESCRIPTION'),
              const SizedBox(height: 4),
              RefInput(descCtrl, hint: 'Optional', maxLines: 3),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Save', () async {
                  await apiPatch('/campaigns/$id', {
                    'name': nameCtrl.text.trim(),
                    'description': descCtrl.text.trim(),
                  });
                  ref.invalidate(campaignDetailProvider(id));
                  ref.invalidate(campaignsProvider);
                  if (ctx.mounted) Navigator.pop(ctx);
                }),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Delete this campaign?', style: serif(15, color: kT100)),
        content: const Text('This removes the campaign and everything in it. This cannot be undone.',
            style: TextStyle(fontSize: 12, color: kT68)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: kFail))),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(campaignsProvider.notifier).delete(id);
      if (context.mounted) context.go('/campaigns');
    }
  }
}

// ── Session scheduling ─────────────────────────────────────────────────────

String _fmtDateTime(String iso) {
  final dt = DateTime.parse(iso).toLocal();
  return DateFormat('EEE, MMM d · h:mm a').format(dt);
}

Map<String, dynamic>? _confirmedUpcoming(List<Map<String, dynamic>> polls) {
  final now = DateTime.now();
  final confirmed = polls.where((p) =>
      p['status'] == 'confirmed' && p['confirmed_starts_at'] != null);
  Map<String, dynamic>? best;
  for (final p in confirmed) {
    final when = DateTime.tryParse(p['confirmed_starts_at'] as String)?.toLocal();
    if (when == null || when.isBefore(now.subtract(const Duration(hours: 6)))) continue;
    if (best == null ||
        when.isBefore(DateTime.parse(best['confirmed_starts_at'] as String).toLocal())) {
      best = p;
    }
  }
  return best;
}

class _NextSessionLine extends ConsumerWidget {
  final String campaignId;
  const _NextSessionLine({required this.campaignId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionPollsProvider(campaignId));
    final poll = async.maybeWhen(
        data: (polls) => _confirmedUpcoming(polls), orElse: () => null);
    return InkWell(
      onTap: () => context.go('/campaigns/$campaignId?tab=schedule'),
      child: Row(children: [
        const Icon(Icons.event_outlined, size: 14, color: kT55),
        const SizedBox(width: 6),
        Text(
          poll != null
              ? 'Next session: ${_fmtDateTime(poll['confirmed_starts_at'] as String)}'
              : 'No session scheduled — open the Schedule tab',
          style: const TextStyle(fontSize: 12, color: kT68),
        ),
      ]),
    );
  }
}

class _ScheduleTab extends ConsumerWidget {
  final String campaignId;
  final bool isGm;
  const _ScheduleTab({required this.campaignId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionPollsProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isGm) ...[
        PillButtonOutlined('+ Propose session times', () => _propose(context, ref)),
        const SizedBox(height: 4),
        const Text('Players mark which slots work; confirm one when it’s settled.',
            style: TextStyle(fontSize: 10, color: kT45)),
        const SizedBox(height: 14),
      ],
      async.when(
        loading: () => const Padding(
            padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (polls) {
          if (polls.isEmpty) {
            return const Text('No sessions proposed yet.',
                style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(
            children: [for (final p in polls) _PollCard(campaignId: campaignId, poll: p, isGm: isGm)],
          );
        },
      ),
    ]);
  }

  Future<void> _propose(BuildContext context, WidgetRef ref) async {
    final titleCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final slots = <DateTime>[];
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: kCard,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Propose session times', style: serif(15, color: kT100)),
                const SizedBox(height: 12),
                const FieldLabel('TITLE'),
                const SizedBox(height: 4),
                RefInput(titleCtrl, hint: 'e.g. Session 12'),
                const SizedBox(height: 10),
                const FieldLabel('NOTE (OPTIONAL)'),
                const SizedBox(height: 4),
                RefInput(noteCtrl, hint: 'Anything players should know', maxLines: 2),
                const SizedBox(height: 12),
                const FieldLabel('CANDIDATE TIMES'),
                const SizedBox(height: 4),
                for (int i = 0; i < slots.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Expanded(child: Text(_fmtDateTime(slots[i].toIso8601String()),
                          style: const TextStyle(fontSize: 12, color: kT100))),
                      InkWell(
                        onTap: () => setS(() => slots.removeAt(i)),
                        child: const Icon(Icons.close, size: 14, color: kT45),
                      ),
                    ]),
                  ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await _pickDateTime(ctx);
                    if (picked != null) setS(() => slots.add(picked));
                  },
                  icon: const Icon(Icons.add, size: 16, color: kLink),
                  label: const Text('Add a time', style: TextStyle(fontSize: 12, color: kLink)),
                ),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                  const SizedBox(width: 8),
                  PillButton('Create', () async {
                    if (titleCtrl.text.trim().isEmpty || slots.isEmpty) return;
                    try {
                      await createSessionPoll(campaignId,
                          title: titleCtrl.text.trim(),
                          note: noteCtrl.text.trim(),
                          slots: slots);
                      ref.invalidate(sessionPollsProvider(campaignId));
                      if (ctx.mounted) Navigator.pop(ctx);
                    } on ApiException catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(_detail(e.message))));
                      }
                    }
                  }),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Future<DateTime?> _pickDateTime(BuildContext ctx) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: ctx,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: now.add(const Duration(days: 1)),
    );
    if (date == null || !ctx.mounted) return null;
    final time = await showTimePicker(
      context: ctx,
      initialTime: const TimeOfDay(hour: 19, minute: 0),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}

class _PollCard extends ConsumerWidget {
  final String campaignId;
  final Map<String, dynamic> poll;
  final bool isGm;
  const _PollCard({required this.campaignId, required this.poll, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = poll['status'] as String? ?? 'open';
    final options = (poll['options'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final mine = (poll['my_responses'] as Map?)?.cast<String, String>() ?? {};
    final confirmedId = poll['confirmed_option_id'] as String?;
    final pollId = poll['id'] as String;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: status == 'confirmed' ? kSuccess : kBorderDim),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(poll['title'] as String? ?? 'Session',
              style: serif(14, color: kT100))),
          _StatusPill(status),
          if (isGm) ...[
            const SizedBox(width: 6),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 16, color: kT68),
              color: kCard,
              onSelected: (v) async {
                if (v == 'reopen') {
                  await updateSessionPoll(campaignId, pollId, status: 'open');
                } else if (v == 'close') {
                  await updateSessionPoll(campaignId, pollId, status: 'closed');
                } else if (v == 'delete') {
                  await deleteSessionPoll(campaignId, pollId);
                }
                ref.invalidate(sessionPollsProvider(campaignId));
              },
              itemBuilder: (_) => [
                if (status != 'open')
                  const PopupMenuItem(value: 'reopen',
                      child: Text('Reopen', style: TextStyle(fontSize: 12, color: kT100))),
                if (status != 'closed')
                  const PopupMenuItem(value: 'close',
                      child: Text('Close', style: TextStyle(fontSize: 12, color: kT100))),
                const PopupMenuItem(value: 'delete',
                    child: Text('Delete', style: TextStyle(fontSize: 12, color: kFail))),
              ],
            ),
          ],
        ]),
        if ((poll['note'] as String?)?.isNotEmpty == true) ...[
          const SizedBox(height: 4),
          Text(poll['note'] as String, style: const TextStyle(fontSize: 11, color: kT55)),
        ],
        const SizedBox(height: 10),
        for (final o in options)
          _OptionRow(
            campaignId: campaignId,
            pollId: pollId,
            option: o,
            myVote: mine[o['id']],
            isConfirmed: o['id'] == confirmedId,
            canRespond: status == 'open',
            isGm: isGm,
          ),
      ]),
    );
  }
}

class _OptionRow extends ConsumerWidget {
  final String campaignId;
  final String pollId;
  final Map<String, dynamic> option;
  final String? myVote;
  final bool isConfirmed;
  final bool canRespond;
  final bool isGm;
  const _OptionRow({
    required this.campaignId,
    required this.pollId,
    required this.option,
    required this.myVote,
    required this.isConfirmed,
    required this.canRespond,
    required this.isGm,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tally = (option['tally'] as Map?)?.cast<String, dynamic>() ?? {};
    final yes = (tally['yes'] as List?)?.length ?? 0;
    final maybe = (tally['maybe'] as List?)?.length ?? 0;
    final no = (tally['no'] as List?)?.length ?? 0;
    final id = option['id'] as String;

    Future<void> vote(String v) async {
      await respondSessionPoll(campaignId, pollId, {id: myVote == v ? 'no' : v});
      ref.invalidate(sessionPollsProvider(campaignId));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isConfirmed ? const Color(0x1A7FA65C) : kWell,
        border: Border.all(color: isConfirmed ? kSuccess : kBorderDim),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_fmtDateTime(option['starts_at'] as String),
                style: TextStyle(fontSize: 12,
                    color: isConfirmed ? kSuccess : kT100,
                    fontWeight: isConfirmed ? FontWeight.w600 : FontWeight.w400)),
            const SizedBox(height: 2),
            Text('✓ $yes  ? $maybe  ✗ $no', style: const TextStyle(fontSize: 10, color: kT45)),
          ]),
        ),
        if (canRespond) ...[
          _voteChip('Yes', myVote == 'yes', kSuccess, () => vote('yes')),
          const SizedBox(width: 4),
          _voteChip('Maybe', myVote == 'maybe', kWarn, () => vote('maybe')),
          const SizedBox(width: 4),
          _voteChip('No', myVote == 'no', kFail, () => vote('no')),
        ],
        if (isGm) ...[
          const SizedBox(width: 6),
          InkWell(
            onTap: () async {
              await updateSessionPoll(campaignId, pollId,
                  confirmedOptionId: isConfirmed ? null : id, clearConfirmed: isConfirmed);
              ref.invalidate(sessionPollsProvider(campaignId));
            },
            child: Text(isConfirmed ? 'Unconfirm' : 'Confirm',
                style: const TextStyle(fontSize: 10, color: kLink)),
          ),
        ],
      ]),
    );
  }

  Widget _voteChip(String label, bool active, Color color, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.22) : Colors.transparent,
            border: Border.all(color: active ? color : kBorderDim),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 10, color: active ? color : kT55)),
        ),
      );
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill(this.status);
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'confirmed' => ('CONFIRMED', kSuccess),
      'closed' => ('CLOSED', kT45),
      _ => ('OPEN', kInfo),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(3)),
      child: Text(label, style: TextStyle(fontSize: 8, letterSpacing: 0.5, color: color)),
    );
  }
}

// ── Members ─────────────────────────────────────────────────────────────────

class _MembersTab extends ConsumerWidget {
  final String campaignId;
  final bool isGm;
  const _MembersTab({required this.campaignId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignMembersProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isGm) ...[
        PillButtonOutlined('+ Add member', () => _addMember(context, ref)),
        const SizedBox(height: 4),
        const Text('Members must have signed in to Sanctum at least once.',
            style: TextStyle(fontSize: 10, color: kT45)),
        const SizedBox(height: 14),
      ],
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (members) {
          if (members.isEmpty) {
            return const Text('No members yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          final onlyOwner = members.every((m) => m['is_owner'] == true);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (onlyOwner)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text('No players added yet.', style: TextStyle(fontSize: 12, color: kT55)),
              ),
            for (final m in members)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  Expanded(child: Text(
                      (m['display_name'] as String?)?.isNotEmpty == true
                          ? m['display_name'] as String
                          : m['username'] as String? ?? '',
                      style: const TextStyle(fontSize: 12, color: kT100))),
                  Text((m['role'] as String? ?? 'player').toUpperCase(),
                      style: const TextStyle(fontSize: 10, color: kT55)),
                  if (isGm && m['is_owner'] != true) ...[
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: () async {
                        await apiDelete('/campaigns/$campaignId/members/${m['user_id']}');
                        ref.invalidate(campaignMembersProvider(campaignId));
                      },
                      child: const Icon(Icons.close, size: 14, color: kT45),
                    ),
                  ],
                ]),
              ),
          ]);
        },
      ),
      if (isGm) ...[
        const SizedBox(height: 28),
        _InviteLinksSection(campaignId: campaignId),
      ],
    ]);
  }

  Future<void> _addMember(BuildContext context, WidgetRef ref) async {
    final userCtrl = TextEditingController();
    String role = 'player';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Add member', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              const FieldLabel('USERNAME'),
              const SizedBox(height: 4),
              RefInput(userCtrl, hint: 'Their Sanctum username'),
              const SizedBox(height: 10),
              const FieldLabel('ROLE'),
              const SizedBox(height: 4),
              Row(children: [
                ChoiceChipX('Player', role == 'player', () => setS(() => role = 'player')),
                const SizedBox(width: 6),
                ChoiceChipX('GM', role == 'gm', () => setS(() => role = 'gm')),
              ]),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Add', () async {
                  if (userCtrl.text.trim().isEmpty) return;
                  try {
                    await apiPost('/campaigns/$campaignId/members',
                        {'username': userCtrl.text.trim(), 'role': role});
                    ref.invalidate(campaignMembersProvider(campaignId));
                    if (ctx.mounted) Navigator.pop(ctx);
                  } on ApiException catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text(_detail(e.message))));
                    }
                  }
                }),
              ]),
            ]),
          ),
        ),
      )),
    );
  }
}

// ── Invite links ────────────────────────────────────────────────────────────

class _InviteLinksSection extends ConsumerWidget {
  final String campaignId;
  const _InviteLinksSection({required this.campaignId});

  String _url(String token) => '${html.window.location.origin}/#/join/$token';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignInvitesProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeading('INVITE LINKS'),
      const SizedBox(height: 4),
      const Text('Share a link so someone can join without you knowing their account.',
          style: TextStyle(fontSize: 10, color: kT45)),
      const SizedBox(height: 10),
      PillButtonOutlined('+ New invite link', () => _create(context, ref)),
      const SizedBox(height: 12),
      async.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (invites) {
          if (invites.isEmpty) {
            return const Text('No invite links yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(children: [
            for (final inv in invites) _row(context, ref, inv),
          ]);
        },
      ),
    ]);
  }

  Widget _row(BuildContext context, WidgetRef ref, Map<String, dynamic> inv) {
    final active = inv['active'] == true;
    final token = inv['token'] as String;
    final maxUses = inv['max_uses'] as int?;
    final uses = inv['uses'] ?? 0;
    final expiresAt = inv['expires_at'] as String?;
    final parts = <String>[
      (inv['role'] as String? ?? 'player').toUpperCase(),
      maxUses == null ? '$uses used' : '$uses / $maxUses used',
      if (expiresAt != null) 'expires ${expiresAt.split('T').first}',
      if (inv['is_revoked'] == true) 'revoked',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: active ? kBorderDim : const Color(0x33C1443B)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_url(token),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: active ? kLink : kT45)),
            const SizedBox(height: 2),
            Text(parts.join(' · '), style: const TextStyle(fontSize: 10, color: kT45)),
          ]),
        ),
        if (active) ...[
          IconButton(
            tooltip: 'Copy link',
            icon: const Icon(Icons.copy, size: 15, color: kT68),
            onPressed: () {
              html.window.navigator.clipboard?.writeText(_url(token));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite link copied')));
            },
          ),
          IconButton(
            tooltip: 'Revoke',
            icon: const Icon(Icons.link_off, size: 15, color: kFail),
            onPressed: () async {
              await revokeCampaignInvite(campaignId, inv['id'] as String);
              ref.invalidate(campaignInvitesProvider(campaignId));
            },
          ),
        ],
      ]),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    String role = 'player';
    String expiry = '7';
    String uses = '';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: kCard,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('New invite link', style: serif(15, color: kT100)),
                const SizedBox(height: 12),
                const FieldLabel('JOINS AS'),
                const SizedBox(height: 4),
                Row(children: [
                  ChoiceChipX('Player', role == 'player', () => setS(() => role = 'player')),
                  const SizedBox(width: 6),
                  ChoiceChipX('GM', role == 'gm', () => setS(() => role = 'gm')),
                ]),
                const SizedBox(height: 12),
                const FieldLabel('EXPIRES AFTER'),
                const SizedBox(height: 4),
                Wrap(spacing: 6, children: [
                  for (final d in const ['1', '7', '30', ''])
                    ChoiceChipX(d.isEmpty ? 'Never' : '$d days', expiry == d, () => setS(() => expiry = d)),
                ]),
                const SizedBox(height: 12),
                const FieldLabel('MAX USES (BLANK = UNLIMITED)'),
                const SizedBox(height: 4),
                SizedBox(
                  width: 120,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    onChanged: (v) => uses = v,
                    style: const TextStyle(fontSize: 13, color: kT100),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: kInput,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: kBorderDim),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                  const SizedBox(width: 8),
                  PillButton('Create', () async {
                    try {
                      await createCampaignInvite(
                        campaignId,
                        role: role,
                        maxUses: int.tryParse(uses.trim()),
                        expiresInDays: expiry.isEmpty ? null : int.parse(expiry),
                      );
                      ref.invalidate(campaignInvitesProvider(campaignId));
                      if (ctx.mounted) Navigator.pop(ctx);
                    } on ApiException catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(_detail(e.message))));
                      }
                    }
                  }),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Resources ───────────────────────────────────────────────────────────────

class _ResourcesTab extends ConsumerWidget {
  final String campaignId;
  final bool isGm;
  const _ResourcesTab({required this.campaignId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignResourcesProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isGm) ...[
        PillButtonOutlined('+ Add link', () => _add(context, ref)),
        const SizedBox(height: 14),
      ],
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (resources) {
          if (resources.isEmpty) {
            return const Text('No resources yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(children: [
            for (final r in resources)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  const Icon(Icons.link, size: 14, color: kT55),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        final u = r['url'] as String?;
                        if (u != null && u.isNotEmpty) html.window.open(u, '_blank');
                      },
                      child: Text(r['name'] as String? ?? r['url'] as String? ?? '',
                          style: const TextStyle(fontSize: 12, color: kLink)),
                    ),
                  ),
                  if (isGm)
                    InkWell(
                      onTap: () async {
                        await apiDelete('/campaigns/$campaignId/resources/${r['id']}');
                        ref.invalidate(campaignResourcesProvider(campaignId));
                      },
                      child: const Icon(Icons.close, size: 14, color: kT45),
                    ),
                ]),
              ),
          ]);
        },
      ),
    ]);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Add a link', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              const FieldLabel('LABEL'),
              const SizedBox(height: 4),
              RefInput(nameCtrl, hint: 'e.g. Session prep doc'),
              const SizedBox(height: 10),
              const FieldLabel('URL'),
              const SizedBox(height: 4),
              RefInput(urlCtrl, hint: 'https://…'),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Add', () async {
                  if (urlCtrl.text.trim().isEmpty) return;
                  await apiPost('/campaigns/$campaignId/resources', {
                    'name': nameCtrl.text.trim().isEmpty ? urlCtrl.text.trim() : nameCtrl.text.trim(),
                    'resource_type': 'link',
                    'url': urlCtrl.text.trim(),
                  });
                  ref.invalidate(campaignResourcesProvider(campaignId));
                  if (ctx.mounted) Navigator.pop(ctx);
                }),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Notes ───────────────────────────────────────────────────────────────────

class _NotesTab extends ConsumerWidget {
  final String campaignId;
  final bool isGm;
  const _NotesTab({required this.campaignId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignNotesProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isGm) ...[
        PillButtonOutlined('+ New session note', () => _add(context, ref)),
        const SizedBox(height: 14),
      ],
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (notes) {
          if (notes.isEmpty) {
            return const Text('No session notes yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(children: [
            for (final n in notes)
              InkWell(
                onTap: () => _view(context, ref, n),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    Text('#${n['session_number']}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kBrass)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(n['title'] as String? ?? '',
                        style: const TextStyle(fontSize: 12, color: kT100), overflow: TextOverflow.ellipsis)),
                    if (n['is_gm_only'] == true)
                      const Text('GM ONLY', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kGmTag)),
                  ]),
                ),
              ),
          ]);
        },
      ),
    ]);
  }

  void _view(BuildContext context, WidgetRef ref, Map<String, dynamic> n) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Session #${n['session_number']} · ${n['title'] ?? ''}', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(
                child: Text((n['content'] as String? ?? '').isEmpty ? '(no content)' : n['content'] as String,
                    style: const TextStyle(fontSize: 12, color: kT82, height: 1.5)),
              )),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (isGm)
                  PillButtonOutlined('Delete', () async {
                    await apiDelete('/campaigns/$campaignId/notes/${n['id']}');
                    ref.invalidate(campaignNotesProvider(campaignId));
                    if (ctx.mounted) Navigator.pop(ctx);
                  }),
                const SizedBox(width: 8),
                PillButton('Close', () => Navigator.pop(ctx)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final numCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    bool gmOnly = false;
    // Prefill the next session number.
    final existing = ref.read(campaignNotesProvider(campaignId)).value ?? [];
    final maxNum = existing.fold<int>(0, (a, n) => (n['session_number'] as int? ?? 0) > a ? n['session_number'] as int : a);
    numCtrl.text = '${maxNum + 1}';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('New session note', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              Row(children: [
                SizedBox(width: 70, child: RefInput(numCtrl, hint: '#')),
                const SizedBox(width: 10),
                Expanded(child: RefInput(titleCtrl, hint: 'Session title')),
              ]),
              const SizedBox(height: 10),
              const FieldLabel('RECAP'),
              const SizedBox(height: 4),
              RefInput(bodyCtrl, hint: 'What happened this session…', maxLines: 8),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setS(() => gmOnly = !gmOnly),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(gmOnly ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: kT68),
                  const SizedBox(width: 6),
                  const Text('GM only', style: TextStyle(fontSize: 11, color: kT68)),
                ]),
              ),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Save', () async {
                  if (titleCtrl.text.trim().isEmpty) return;
                  await apiPost('/campaigns/$campaignId/notes', {
                    'session_number': int.tryParse(numCtrl.text.trim()) ?? (maxNum + 1),
                    'title': titleCtrl.text.trim(),
                    'content': bodyCtrl.text,
                    'is_gm_only': gmOnly,
                  });
                  ref.invalidate(campaignNotesProvider(campaignId));
                  if (ctx.mounted) Navigator.pop(ctx);
                }),
              ]),
            ]),
          ),
        ),
      )),
    );
  }
}

// ── Files ───────────────────────────────────────────────────────────────────

class _FilesTab extends ConsumerWidget {
  final String campaignId;
  final bool isGm;
  const _FilesTab({required this.campaignId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignFilesProvider(campaignId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PillButtonOutlined('+ Upload file', () => pickAndUpload(
            context,
            url: '/campaigns/$campaignId/files',
            onDone: () => ref.invalidate(campaignFilesProvider(campaignId)),
          )),
      const SizedBox(height: 14),
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
        data: (files) {
          if (files.isEmpty) {
            return const Text('No files yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(children: [
            for (final f in files)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  Icon(f['is_image'] == true ? Icons.image_outlined : Icons.insert_drive_file_outlined,
                      size: 14, color: kT55),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => html.window.open(
                          '/api/campaigns/$campaignId/files/${f['id']}/download', '_blank'),
                      child: Text(f['filename'] as String? ?? '',
                          style: const TextStyle(fontSize: 12, color: kLink), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  Text(_size(f['size_bytes'] as int? ?? 0),
                      style: const TextStyle(fontSize: 10, color: kT45)),
                  if (isGm) ...[
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: () async {
                        await apiDelete('/campaigns/$campaignId/files/${f['id']}');
                        ref.invalidate(campaignFilesProvider(campaignId));
                      },
                      child: const Icon(Icons.close, size: 14, color: kT45),
                    ),
                  ],
                ]),
              ),
          ]);
        },
      ),
    ]);
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

String _detail(String body) {
  try {
    final m = jsonDecode(body);
    if (m is Map && m['detail'] is String) return m['detail'] as String;
  } catch (_) {}
  return 'Something went wrong.';
}
