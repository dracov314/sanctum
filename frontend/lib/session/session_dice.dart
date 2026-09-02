// Generic dice roller for the Session Room — NdM+K notation, quick buttons,
// and a private (you + GM only) toggle. Posts a `roll` log entry that
// SessionLogFeed renders.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../ui/chrome.dart';
import 'session_providers.dart';

final _rng = math.Random();
final _diceExpr = RegExp(r'^\s*(\d*)\s*[dD]\s*(\d+)\s*(?:([+-])\s*(\d+))?\s*$');

class RollResult {
  final String label;      // normalized, e.g. "3d6+2"
  final List<int> rolls;
  final int sides;
  final int modifier;
  final int total;
  final bool crit;         // every die showed its max face
  final bool fumble;       // every die showed 1
  RollResult(this.label, this.rolls, this.sides, this.modifier, this.total, this.crit, this.fumble);
}

/// Returns null if `expr` isn't a valid dice expression.
RollResult? parseAndRoll(String expr) {
  final m = _diceExpr.firstMatch(expr);
  if (m == null) return null;
  final count = int.tryParse(m.group(1)!.isEmpty ? '1' : m.group(1)!) ?? 1;
  final sides = int.tryParse(m.group(2)!) ?? 0;
  if (count < 1 || count > 100 || sides < 2 || sides > 1000) return null;
  final sign = m.group(3);
  final modAbs = int.tryParse(m.group(4) ?? '0') ?? 0;
  final modifier = sign == '-' ? -modAbs : modAbs;

  final rolls = [for (var i = 0; i < count; i++) _rng.nextInt(sides) + 1];
  final sum = rolls.fold<int>(0, (a, b) => a + b);
  final label = '${count}d$sides'
      '${modifier == 0 ? '' : (modifier > 0 ? '+$modifier' : '$modifier')}';
  return RollResult(
    label, rolls, sides, modifier, sum + modifier,
    rolls.every((r) => r == sides),
    rolls.every((r) => r == 1),
  );
}

class DiceRoller extends ConsumerStatefulWidget {
  final String campaignId;
  const DiceRoller({super.key, required this.campaignId});
  @override
  ConsumerState<DiceRoller> createState() => _DiceRollerState();
}

class _DiceRollerState extends ConsumerState<DiceRoller> {
  final _ctrl = TextEditingController();
  bool _private = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _roll(String expr) async {
    final r = parseAndRoll(expr);
    if (r == null) {
      setState(() => _error = 'Try e.g. 2d6+3, d20, 4d8-1');
      return;
    }
    setState(() => _error = null);
    final me = ref.read(authProvider).value;
    await postSessionLog(ref, widget.campaignId, 'roll', {
      'who': me?.displayName ?? me?.username ?? 'You',
      'label': r.label,
      'dice': [for (final v in r.rolls) {'v': v, 'kind': 'base'}],
      'modifier': r.modifier,
      'total': r.total,
      'crit': r.crit,
      'fumble': r.fumble,
      'private': _private,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            textInputAction: TextInputAction.send,
            onSubmitted: (v) => _roll(v),
            inputFormatters: [LengthLimitingTextInputFormatter(24)],
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Roll… (2d6+3)',
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
        PillButton('Roll', () => _roll(_ctrl.text), compact: true),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 4),
        Text(_error!, style: const TextStyle(fontSize: 10, color: kFail)),
      ],
      const SizedBox(height: 6),
      Wrap(spacing: 4, runSpacing: 4, children: [
        for (final s in [4, 6, 8, 10, 12, 20, 100])
          InkWell(
            onTap: () => _roll('d$s'),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: kChipBox,
                border: Border.all(color: kBorderDim),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('d$s', style: const TextStyle(fontSize: 11, color: kT82)),
            ),
          ),
        InkWell(
          onTap: () => setState(() => _private = !_private),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _private ? const Color(0x33D9A441) : kChipBox,
              border: Border.all(color: _private ? kGmTag : kBorderDim),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_private ? Icons.visibility_off : Icons.visibility_outlined,
                  size: 11, color: _private ? kGmTag : kT55),
              const SizedBox(width: 4),
              Text('Private', style: TextStyle(fontSize: 11, color: _private ? kGmTag : kT55)),
            ]),
          ),
        ),
      ]),
    ]);
  }
}
