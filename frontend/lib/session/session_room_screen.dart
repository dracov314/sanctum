// Generic Session Room — the default live-play screen for any campaign.
// Left: shared log feed + chat + dice. Center: Wiki / Notes / Maps / Resources.
// A game system can register a focused room instead (see session_dispatch.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api/client.dart';
import '../providers/campaigns_provider.dart';
import '../ui/chrome.dart';
import '../screens/core/campaign_wiki.dart' show CampaignWikiPanel;
import '../screens/assets/maps_screen.dart' show MapsScreen;
import 'session_dice.dart';
import 'session_log_feed.dart';
import 'session_providers.dart';

final _resourcesProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final data = await apiGet('/campaigns/$id/resources') as List;
  return data.cast<Map<String, dynamic>>();
});

const _centerTabs = ['wiki', 'notes', 'maps', 'resources'];

class SessionRoomScreen extends ConsumerStatefulWidget {
  final String campaignId;
  const SessionRoomScreen({super.key, required this.campaignId});
  @override
  ConsumerState<SessionRoomScreen> createState() => _SessionRoomScreenState();
}

class _SessionRoomScreenState extends ConsumerState<SessionRoomScreen> {
  final _chatCtrl = TextEditingController();
  String _tab = 'wiki';

  @override
  void dispose() {
    _chatCtrl.dispose();
    super.dispose();
  }

  bool _isGm(Map<String, dynamic>? c) {
    final r = c?['role'] as String?;
    return r == 'owner' || r == 'gm';
  }

  Future<void> _sendChat() async {
    final t = _chatCtrl.text.trim();
    if (t.isEmpty) return;
    _chatCtrl.clear();
    await postSessionLog(ref, widget.campaignId, 'chat', {'text': t});
  }

  Future<void> _startSession() async {
    await apiPost('/campaigns/${widget.campaignId}/session/start');
    ref.invalidate(sessionStateProvider(widget.campaignId));
    ref.invalidate(sessionLogProvider(widget.campaignId));
  }

  Future<void> _endSession() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('End the session?', style: serif(15, color: kT100)),
        content: const Text('The log stays; the room resets for the next session.',
            style: TextStyle(fontSize: 12, color: kT68)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End session')),
        ],
      ),
    );
    if (ok != true) return;
    await apiPost('/campaigns/${widget.campaignId}/session/end');
    ref.invalidate(sessionStateProvider(widget.campaignId));
  }

  @override
  Widget build(BuildContext context) {
    final campaign = ref.watch(campaignDetailProvider(widget.campaignId)).value;
    final state = ref.watch(sessionStateProvider(widget.campaignId)).value;
    final isGm = _isGm(campaign);
    final live = state?['session_active'] == true;
    final narrow = MediaQuery.of(context).size.width < 940;

    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: kWell, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.all(8),
          child: SessionLogFeed(campaignId: widget.campaignId),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _chatCtrl,
            onSubmitted: (_) => _sendChat(),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: InputDecoration(
              isDense: true, hintText: 'Message…',
              hintStyle: const TextStyle(fontSize: 12, color: kT45),
              filled: true, fillColor: kInput,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: kBorderDim)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: kBorderDim)),
            ),
          ),
        ),
        const SizedBox(width: 6),
        PillButton('Send', _sendChat, compact: true),
      ]),
      const SizedBox(height: 8),
      DiceRoller(campaignId: widget.campaignId),
    ]);

    final center = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final t in _centerTabs) ...[
            RefTab(_label(t), t == _tab, () => setState(() => _tab = t)),
            const SizedBox(width: 16),
          ],
        ]),
      ),
      Container(height: 1, color: kBorderDim),
      const SizedBox(height: 14),
      Expanded(child: _centerPanel(isGm)),
    ]);

    return PageChrome(
      contentMaxWidth: 1500,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          InkWell(
            onTap: () => context.canPop() ? context.pop() : context.go('/dashboard'),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.chevron_left, size: 16, color: kLink),
              Text('Back', style: TextStyle(fontSize: 12, color: kLink)),
            ]),
          ),
          const SizedBox(width: 14),
          Flexible(child: Text(campaign?['name'] as String? ?? 'Session Room',
              style: serif(18, color: kT100), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 10),
          _StatusPill(live: live),
          const Spacer(),
          if (isGm)
            live
                ? PillButtonOutlined('End session', _endSession)
                : PillButton('Start session', _startSession, compact: true),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: narrow
              ? DefaultTabController(
                  length: 2,
                  child: Column(children: [
                    const TabBar(tabs: [Tab(text: 'Room'), Tab(text: 'Play')], labelColor: Colors.white),
                    Expanded(child: TabBarView(children: [
                      Padding(padding: const EdgeInsets.only(top: 12), child: left),
                      Padding(padding: const EdgeInsets.only(top: 12), child: center),
                    ])),
                  ]),
                )
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 340, child: left),
                  const SizedBox(width: 20),
                  Expanded(child: center),
                ]),
        ),
      ]),
    );
  }

  static String _label(String t) => switch (t) {
        'wiki' => 'Wiki',
        'notes' => 'Notes & Journal',
        'maps' => 'Maps & Tokens',
        'resources' => 'Resources',
        _ => t,
      };

  Widget _centerPanel(bool isGm) => switch (_tab) {
        'wiki' => CampaignWikiPanel(gameId: widget.campaignId, isGm: isGm),
        'maps' => const MapsScreen(),
        'notes' => _JournalPanel(campaignId: widget.campaignId, isGm: isGm),
        'resources' => _ResourcesPanel(campaignId: widget.campaignId),
        _ => const SizedBox.shrink(),
      };
}

class _StatusPill extends StatelessWidget {
  final bool live;
  const _StatusPill({required this.live});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: live ? const Color(0x1F7FA65C) : kChipBox,
          border: Border.all(color: live ? kSuccess : kBorderDim),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(live ? '● Live' : 'Not in session',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: live ? kSuccess : kT55)),
      );
}

// ── Journal panel — session-log entries of kind 'journal' ───────────────────

class _JournalPanel extends ConsumerStatefulWidget {
  final String campaignId;
  final bool isGm;
  const _JournalPanel({required this.campaignId, required this.isGm});
  @override
  ConsumerState<_JournalPanel> createState() => _JournalPanelState();
}

class _JournalPanelState extends ConsumerState<_JournalPanel> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _gmOnly = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final b = _body.text.trim();
    if (b.isEmpty) return;
    await postSessionLog(ref, widget.campaignId, 'journal', {
      'title': _title.text.trim().isEmpty ? 'Journal' : _title.text.trim(),
      'body': b,
      'visibility': _gmOnly ? 'gm' : 'everyone',
    });
    _title.clear();
    _body.clear();
  }

  @override
  Widget build(BuildContext context) {
    final entries = (ref.watch(sessionLogProvider(widget.campaignId)).value ?? [])
        .where((e) => e['kind'] == 'journal')
        .toList()
        .reversed
        .toList();
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RefInput(_title, hint: 'Entry title (optional)'),
        const SizedBox(height: 8),
        RefInput(_body, hint: 'What happened…', maxLines: 4),
        const SizedBox(height: 8),
        Row(children: [
          if (widget.isGm)
            InkWell(
              onTap: () => setState(() => _gmOnly = !_gmOnly),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_gmOnly ? Icons.check_box : Icons.check_box_outline_blank, size: 15, color: kT68),
                const SizedBox(width: 5),
                const Text('GM only', style: TextStyle(fontSize: 11, color: kT68)),
              ]),
            ),
          const Spacer(),
          PillButton('Add entry', _add, compact: true),
        ]),
        const SizedBox(height: 16),
        if (entries.isEmpty)
          const Text('No journal entries this session.', style: TextStyle(fontSize: 12, color: kT55))
        else
          for (final e in entries)
            Builder(builder: (_) {
              final p = (e['payload'] as Map?)?.cast<String, dynamic>() ?? {};
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(p['title'] as String? ?? 'Journal', style: serif(12, color: kT100)),
                    if (p['visibility'] == 'gm') ...[
                      const SizedBox(width: 6),
                      const Text('GM ONLY', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kGmTag)),
                    ],
                  ]),
                  const SizedBox(height: 4),
                  Text(p['body'] as String? ?? '', style: const TextStyle(fontSize: 11, color: kT82, height: 1.4)),
                ]),
              );
            }),
      ]),
    );
  }
}

// ── Resources panel ────────────────────────────────────────────────────────

class _ResourcesPanel extends ConsumerWidget {
  final String campaignId;
  const _ResourcesPanel({required this.campaignId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_resourcesProvider(campaignId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
      error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
      data: (rs) => rs.isEmpty
          ? const Text('No resources linked to this campaign.',
              style: TextStyle(fontSize: 12, color: kT55))
          : ListView(children: [
              for (final r in rs)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    const Icon(Icons.link, size: 13, color: kT55),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r['name'] as String? ?? r['url'] as String? ?? '',
                        style: const TextStyle(fontSize: 12, color: kLink))),
                  ]),
                ),
            ]),
    );
  }
}
