// Plain landing screen for the core app. A game-system module can replace it
// with a richer aggregate via GameSystemModule.dashboardHome (see
// router.dart); the private Fuzion build does exactly that.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../ui/chrome.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider).value;
    final name = me?.displayName?.trim().isNotEmpty == true
        ? me!.displayName!
        : (me?.username ?? '');

    const tiles = [
      (label: 'Library', desc: 'Browse your rulebooks and game systems', path: '/library', icon: Icons.menu_book_outlined),
      (label: 'Campaigns', desc: 'Your games, wikis, session notes and files', path: '/campaigns', icon: Icons.groups_outlined),
      (label: 'Maps', desc: 'Battle maps and scene art', path: '/maps', icon: Icons.map_outlined),
      (label: 'Tokens', desc: 'Character and monster tokens', path: '/tokens', icon: Icons.circle_outlined),
    ];

    return PageChrome(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SanctumBanner(),
          const SizedBox(height: 28),
          Text(name.isEmpty ? 'Welcome' : 'Welcome, $name', style: serif(22, color: kT100)),
          const SizedBox(height: 6),
          const Text('Your TTRPG library and campaign hub.',
              style: TextStyle(fontSize: 12, color: kT55)),
          const SizedBox(height: 24),
          TileGrid(
            count: tiles.length,
            minTileWidth: 260,
            itemBuilder: (i, w) {
              final t = tiles[i];
              return InkWell(
                onTap: () => context.go(t.path),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: w,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: kCard,
                    border: Border.all(color: kBorder),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(t.icon, size: 26, color: kBrass),
                    const SizedBox(height: 12),
                    Text(t.label, style: serif(15, color: kT100)),
                    const SizedBox(height: 4),
                    Text(t.desc, style: const TextStyle(fontSize: 11, color: kT55)),
                  ]),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }
}
