// The shared session activity feed — chat / roll / system / journal entries.
// System-agnostic: renders the generic roll payload written by DiceRoller
// (and any focused room that follows the same {label, dice, total, crit,
// fumble} shape).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ui/chrome.dart';
import 'session_providers.dart';

class SessionLogFeed extends ConsumerStatefulWidget {
  final String campaignId;
  const SessionLogFeed({super.key, required this.campaignId});
  @override
  ConsumerState<SessionLogFeed> createState() => _SessionLogFeedState();
}

class _SessionLogFeedState extends ConsumerState<SessionLogFeed> {
  Timer? _poll;
  final _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5),
        (_) => ref.invalidate(sessionLogProvider(widget.campaignId)));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sessionLogProvider(widget.campaignId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
      error: (e, _) => Text('Could not load the log: $e',
          style: const TextStyle(fontSize: 11, color: kFail)),
      data: (entries) {
        _autoScroll(entries.length);
        if (entries.isEmpty) {
          return const Center(
            child: Text('Nothing yet — say hi or roll some dice.',
                style: TextStyle(fontSize: 12, color: kT55)),
          );
        }
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(4),
          itemCount: entries.length,
          itemBuilder: (_, i) => _entry(entries[i]),
        );
      },
    );
  }

  Widget _entry(Map<String, dynamic> e) {
    final kind = e['kind'] as String? ?? 'chat';
    final p = (e['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    final author = p['who'] as String? ?? p['author'] as String? ?? e['author_name'] as String? ?? '';
    final isDiscord = e['source'] == 'discord';

    if (kind == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('— ${p['text'] ?? ''} —',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: kT45, fontStyle: FontStyle.italic)),
      );
    }

    if (kind == 'journal') {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kWell, borderRadius: BorderRadius.circular(6)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.menu_book_outlined, size: 12, color: kT55),
            const SizedBox(width: 6),
            Text(p['title'] as String? ?? 'Journal', style: serif(12, color: kT100)),
            if (p['visibility'] == 'gm') ...[
              const SizedBox(width: 6),
              const Text('GM', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kGmTag)),
            ],
          ]),
          const SizedBox(height: 4),
          Text(p['body'] as String? ?? '', style: const TextStyle(fontSize: 11, color: kT82, height: 1.4)),
        ]),
      );
    }

    if (kind == 'roll') {
      final chips = (p['dice'] as List?) ?? const [];
      final crit = p['crit'] == true, fumble = p['fumble'] == true;
      final mod = (p['modifier'] as num?)?.toInt() ?? 0;
      final totalColor = crit ? kSuccess : (fumble ? kFail : Colors.white);
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: kChipBox, borderRadius: BorderRadius.circular(6)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('🎲 ', style: TextStyle(fontSize: 11)),
            Flexible(
              child: RichText(text: TextSpan(children: [
                TextSpan(text: author, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kLink)),
                TextSpan(text: '  rolled ${p['label'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: Color(0xE6E6D7BE))),
              ])),
            ),
            if (p['private'] == true) ...[
              const SizedBox(width: 6),
              const Icon(Icons.visibility_off, size: 11, color: kGmTag),
            ],
            const Spacer(),
            if (p['total'] != null)
              Text('${p['total']}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: totalColor)),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 5, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final d in chips)
              DieChip(((d as Map)['v'] as num).toInt(), kind: d['kind'] as String? ?? 'base'),
            if (mod != 0)
              Text(mod > 0 ? '+ $mod' : '− ${mod.abs()}',
                  style: const TextStyle(fontSize: 11, color: kT68)),
            if (crit) const Text('MAX!', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kSuccess)),
            if (fumble) const Text('MIN!', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kFail)),
            if (isDiscord) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: kDiscord), borderRadius: BorderRadius.circular(3)),
                child: const Text('DISCORD', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: kDiscord)),
              ),
            ],
          ]),
        ]),
      );
    }

    // chat
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(text: TextSpan(children: [
        TextSpan(text: '$author: ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kLink)),
        TextSpan(text: p['text'] as String? ?? '', style: const TextStyle(fontSize: 12, color: Color(0xE6E6D7BE))),
      ], style: const TextStyle(height: 1.4))),
    );
  }
}
