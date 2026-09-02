// Persistent app-level sidebar — pixel-exact port of the design system
// handoff's new sidebar nav (Sanctum TTRPG App.dc.html ~L28-63, 2026-07-17
// update). Replaces the earlier custom NavigationRail sidebar, which existed
// only because the *original* handoff had a top app bar the user explicitly
// rejected in favor of a sidebar — the design system has since converged on its
// own sidebar design, so this now ports that spec directly instead of
// improvising the layout.
//
// Two deliberate deviations from the raw markup, both carried over from
// already-established, user-confirmed constraints:
// - The PLAYER/GM preview toggle stays admin-gated (moved into the user
//   avatar menu below, not shown as a plain sidebar item) — the design
//   tool has no real accounts behind that toggle, and an earlier session
//   found a real read-side security leak from rendering it un-gated
//   (see fuzion_chrome.dart's resolveIsGm doc comment).
// - Fuzion's own Resources/Games/Characters/etc. sub-tabs are NOT migrated
//   into the sidebar here — they're deeply threaded through
//   FuzionWorkspaceState as local widget state across half a dozen files,
//   and moving them to a shared provider is a large, separate refactor.
//   They still work exactly as before, as an in-page tab row.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../game_systems.dart';
import '../ui/chrome.dart';

class ShellScreen extends ConsumerWidget {
  final Widget child;
  const ShellScreen({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value;
    final routerState = GoRouterState.of(context);
    final location = routerState.matchedLocation;
    // Full location incl. query — game-system nav items match on `?tab=`.
    final fullLocation = routerState.uri.toString();

    final isDashboard = location.startsWith('/dashboard');
    final isLibrary = location.startsWith('/library');
    final isCampaigns = location.startsWith('/campaigns');
    final isMaps = location.startsWith('/maps');
    final isTokens = location.startsWith('/tokens');

    final moduleNav = [for (final m in gameSystemModules) ...m.navItems];
    final adminNav = [for (final m in gameSystemModules) ...m.adminNavItems];

    return Scaffold(
      backgroundColor: kBg,
      body: Row(children: [
        Container(
          width: 210,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: const BoxDecoration(color: kNav, border: Border(right: BorderSide(color: kBorderDim))),
          child: Column(children: [
            Expanded(child: SingleChildScrollView(child: Column(children: [
              Center(
                child: Container(
                  width: 190, height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kRodDark, width: 4),
                    boxShadow: const [
                      BoxShadow(color: kRodLight, spreadRadius: 3, blurRadius: 0),
                      BoxShadow(color: Color(0xFF241708), spreadRadius: 5, blurRadius: 0),
                      BoxShadow(color: Color(0x73000000), blurRadius: 12, spreadRadius: -2),
                    ],
                  ),
                  // Same emblem asset as the login screen (clean, transparent,
                  // isolated) — contained so the whole medallion + "Sanctum"
                  // banner reads, not a tight crop.
                  child: ClipOval(child: Padding(
                    padding: const EdgeInsets.all(6),
                    // The source is 512px; rendered here at ~175px. Flutter's
                    // default FilterQuality.low box-samples that ~3x downscale
                    // and it reads grainy next to the browser-resampled copy on
                    // the (Authentik-hosted) login screen. high = cubic
                    // resampling; the icon is static so the extra cost is
                    // irrelevant. cacheWidth decodes closer to display size so
                    // the GPU texture is well-formed.
                    child: Image.asset(
                      'assets/sanctum_logo.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      cacheWidth: 400,
                    ),
                  )),
                ),
              ),
              const SizedBox(height: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _SidebarNavItem('Dashboard', isDashboard, () => context.go('/dashboard')),
                _SidebarNavItem('Library', isLibrary, () => context.go('/library')),
                _SidebarNavItem('Campaigns', isCampaigns, () => context.go('/campaigns')),
                for (final item in moduleNav)
                  _SidebarNavItem(item.label, item.isActive(fullLocation), () => context.go(item.path)),
                const SizedBox(height: 6),
                Container(height: 1, color: kBorderDim, margin: const EdgeInsets.symmetric(horizontal: 2)),
                const SizedBox(height: 6),
                _SidebarNavItem('Maps', isMaps, () => context.go('/maps')),
                _SidebarNavItem('Tokens', isTokens, () => context.go('/tokens')),
                if (user?.isAdmin == true) ...[
                  const SizedBox(height: 6),
                  Container(height: 1, color: kBorderDim, margin: const EdgeInsets.symmetric(horizontal: 2)),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.only(left: 10, bottom: 2),
                    child: Text('ADMIN', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0x59E6D7BE), letterSpacing: 0.5)),
                  ),
                  _SidebarNavItem('Users', location.startsWith('/admin/users'), () => context.go('/admin/users')),
                  _SidebarNavItem('Tags', location.startsWith('/admin/tags'), () => context.go('/admin/tags')),
                  for (final item in adminNav)
                    _SidebarNavItem(item.label, item.isActive(fullLocation), () => context.go(item.path)),
                ],
                const SizedBox(height: 10),
                Container(height: 1, color: kBorderDim, margin: const EdgeInsets.symmetric(horizontal: 2)),
                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.only(left: 10, bottom: 2),
                  child: Text('COMING SOON', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0x59E6D7BE), letterSpacing: 0.5)),
                ),
                const _ComingSoonItem('Community'),
                const _ComingSoonItem('Discord Bot'),
              ]),
            ]))),
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (user?.isAdmin == true) _AdminRolePreview(ref: ref),
              const SizedBox(height: 8),
              _UserTrailing(user: user, ref: ref),
              const SizedBox(height: 8),
              const _SourceFooter(),
              const _SupportFooter(),
            ]),
          ]),
        ),
        const VerticalDivider(width: 1, color: kBorderDim),
        // Per-route key + opaque backdrop. (Client-side nav between sparse
        // screens can still briefly ghost the previous one under the canvaskit
        // renderer — a known Flutter-web issue; a reload always clears it.)
        Expanded(
          child: Container(
            key: ValueKey(location),
            color: kBg,
            child: child,
          ),
        ),
      ]),
    );
  }
}

/// sidebarNavStyle(active): 9/10 padding, radius 6, 12px 700/600.
class _SidebarNavItem extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _SidebarNavItem(this.label, this.active, this.onTap);
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : Colors.transparent,
            border: Border.all(color: active ? kAccent : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: TextStyle(fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: active ? Colors.white : kT68)),
        ),
      );
}

/// AGPL-3.0 asks that network users be able to get the source. The URL is a
/// compile-time define so a fork can point it at its own repo:
///   flutter build web --dart-define=SANCTUM_SOURCE_URL=https://…
class _SourceFooter extends StatelessWidget {
  const _SourceFooter();
  static const _url = String.fromEnvironment('SANCTUM_SOURCE_URL',
      defaultValue: 'https://github.com/dracov314/sanctum');
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => openExternal(_url),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text('Sanctum · AGPL-3.0 · source',
              style: TextStyle(fontSize: 9, color: Color(0x59E6D7BE))),
        ),
      );
}

/// Same compile-time-define pattern as [_SourceFooter], so a fork can point
/// this at its own support page instead.
class _SupportFooter extends StatelessWidget {
  const _SupportFooter();
  static const _url = String.fromEnvironment('SANCTUM_SUPPORT_URL',
      defaultValue: 'https://ko-fi.com/untrustedhub');
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => openExternal(_url),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text('☕ Support untrustedhub',
              style: TextStyle(fontSize: 9, color: Color(0x59E6D7BE))),
        ),
      );
}

class _ComingSoonItem extends StatelessWidget {
  final String label;
  const _ComingSoonItem(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0x59E6D7BE))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(3)),
            child: const Text('soon', style: TextStyle(fontSize: 8, color: Color(0x59E6D7BE))),
          ),
        ]),
      );
}

/// Admin-only preview toggle — see the file-level doc comment on why this
/// stays gated behind isAdmin instead of the raw markup's un-gated sidebar chip.
class _AdminRolePreview extends StatelessWidget {
  final WidgetRef ref;
  const _AdminRolePreview({required this.ref});
  @override
  Widget build(BuildContext context) {
    final current = ref.watch(fuzionAdminPreviewProvider);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      RoleChip('PLAYER', current == 'player', () => ref.read(fuzionAdminPreviewProvider.notifier).state = current == 'player' ? null : 'player'),
      const SizedBox(width: 6),
      RoleChip('GM', current == 'gm', () => ref.read(fuzionAdminPreviewProvider.notifier).state = current == 'gm' ? null : 'gm'),
    ]);
  }
}

class _UserTrailing extends StatelessWidget {
  final AuthUser? user;
  final WidgetRef ref;
  const _UserTrailing({this.user, required this.ref});

  @override
  Widget build(BuildContext context) {
    if (user == null) return const SizedBox.shrink();
    return PopupMenuButton<void>(
      position: PopupMenuPosition.over,
      child: Row(children: [
        CircleAvatar(
          backgroundColor: kBorder,
          radius: 16,
          child: Text(user!.initials, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(user!.displayName ?? user!.username, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: kT82))),
      ]),
      itemBuilder: (_) => <PopupMenuEntry<void>>[
        PopupMenuItem<void>(
          enabled: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user!.displayName ?? user!.username, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (user!.email != null) Text(user!.email!, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          onTap: () => context.go('/account'),
          child: const Row(children: [Icon(Icons.settings_outlined, size: 18), SizedBox(width: 8), Text('Account settings')]),
        ),
        PopupMenuItem<void>(
          onTap: () => ref.read(authProvider.notifier).logout(),
          child: const Row(children: [Icon(Icons.logout, size: 18), SizedBox(width: 8), Text('Sign out')]),
        ),
      ],
    );
  }
}
