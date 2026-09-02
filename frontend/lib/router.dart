import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'providers/auth_provider.dart';
import 'game_systems.dart';
import 'providers/campaigns_provider.dart';
import 'session/session_dispatch.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/join_invite_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/core/dashboard_screen.dart';
import 'screens/core/library_screen.dart';
import 'screens/core/campaigns_screen.dart';
import 'screens/core/campaign_detail_screen.dart';
import 'screens/core/account_screen.dart';
import 'screens/core/admin_users_screen.dart';
import 'screens/core/admin_tags_screen.dart';
import 'screens/library/book_reader_screen.dart';
import 'screens/assets/maps_screen.dart';
import 'screens/assets/tokens_screen.dart';

// Bridges Riverpod auth state into go_router's `refreshListenable`. The
// router itself must stay a single stable instance — rebuilding a whole new
// GoRouter (e.g. by `ref.watch`ing authProvider directly in routerProvider)
// doesn't re-run `redirect` against the current URL when there's no
// navigation event to trigger it, so a state-only change like signing out
// (an API call + local state update, no page navigation) was silently
// ignored. `refreshListenable` is go_router's documented mechanism for
// exactly this: it re-evaluates `redirect` for the current location whenever
// the listenable fires, without touching the router instance itself.
class _AuthRefreshListenable extends ChangeNotifier {
  _AuthRefreshListenable(Ref ref) {
    ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

/// go_router page with no enter/exit animation. The default MaterialPage
/// cross-fade keeps both the old and new screen composited for a frame, which
/// the canvaskit web renderer can leave ghosted when navigating between
/// content-sparse screens. Instant swaps avoid that entirely.
Page<void> _noAnim(Widget child) => NoTransitionPage<void>(child: child);

/// The plain dashboard, unless a game-system module supplies a richer one.
Widget _dashboardHome() {
  for (final m in gameSystemModules) {
    final home = m.dashboardHome;
    if (home != null) return home();
  }
  return const DashboardScreen();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefreshListenable(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authState = ref.read(authProvider);
      // authProvider's build() is async, so on a cold load its value is
      // transiently null while the /auth/me check is in flight — identical
      // to "logged out". Redirecting to /login during that window discards
      // whatever deep link was actually requested (e.g. #/my-games), because
      // by the time auth resolves a moment later, matchedLocation is already
      // '/login' and the isLoginPage branch below sends everyone to
      // '/dashboard' instead. Waiting for the load to finish (refreshListenable
      // re-runs this once it does) keeps the originally requested route intact.
      if (authState.isLoading) return null;
      final isLoggedIn = authState.value != null;
      final loc = state.matchedLocation;
      final isLoginPage = loc == '/login';
      // /join/:token is a public landing page — it renders its own sign-in.
      final isPublic = isLoginPage || loc.startsWith('/join/');
      if (!isLoggedIn && !isPublic) return '/login';
      if (isLoggedIn && isLoginPage) return '/dashboard';
      // Resume an invite that was interrupted by an SSO round-trip.
      if (isLoggedIn && !loc.startsWith('/join/')) {
        final pending = readPendingInvite();
        if (pending != null && pending.isNotEmpty) return '/join/$pending';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/join/:token',
        builder: (_, state) => JoinInviteScreen(token: state.pathParameters['token']!),
      ),
      ShellRoute(
        builder: (context, state, child) => ShellScreen(child: child),
        routes: [
          // Dashboard is the site landing page; Library / Maps / Tokens are
          // peer sidebar destinations. Game-system modules append their own
          // routes below.
          GoRoute(
            path: '/dashboard',
            pageBuilder: (_, __) => _noAnim(_dashboardHome()),
          ),
          // Library is the real system grid + real per-system book browsing.
          GoRoute(
            path: '/library',
            pageBuilder: (_, __) => _noAnim(const LibraryScreen()),
            routes: [
              GoRoute(
                path: 'system/:systemId',
                pageBuilder: (_, state) => _noAnim(SystemLandingScreen(
                  systemId: state.pathParameters['systemId']!,
                )),
              ),
              // Book reader stays nested under /library so the sidebar stays
              // visible while reading.
              GoRoute(
                path: ':bookId',
                pageBuilder: (_, state) => _noAnim(
                    BookReaderScreen(bookId: state.pathParameters['bookId']!)),
              ),
            ],
          ),
          GoRoute(
            path: '/campaigns',
            pageBuilder: (_, __) => _noAnim(const CampaignsScreen()),
            routes: [
              GoRoute(
                path: ':id',
                pageBuilder: (_, state) => _noAnim(CampaignDetailScreen(
                  campaignId: state.pathParameters['id']!,
                  tab: state.uri.queryParameters['tab'] ?? 'overview',
                )),
                routes: [
                  // System-agnostic Session Room. Dispatches to the game
                  // system's focused room if its module provides one
                  // (session_dispatch.dart), else the generic SessionRoomScreen.
                  GoRoute(
                    path: 'session',
                    pageBuilder: (_, state) => _noAnim(_SessionRoomRoute(
                      campaignId: state.pathParameters['id']!,
                      params: state.uri.queryParameters,
                    )),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/maps',
            pageBuilder: (_, __) => _noAnim(const MapsScreen(standalone: true)),
          ),
          GoRoute(
            path: '/tokens',
            pageBuilder: (_, __) => _noAnim(const TokensScreen(standalone: true)),
          ),
          GoRoute(
            path: '/account',
            pageBuilder: (_, __) => _noAnim(const AccountScreen()),
          ),
          GoRoute(
            path: '/admin/users',
            pageBuilder: (_, __) => _noAnim(const AdminUsersScreen()),
          ),
          GoRoute(
            path: '/admin/tags',
            pageBuilder: (_, __) => _noAnim(const AdminTagsScreen()),
          ),
          // Game-system module routes (Fuzion in the private build; none in
          // the public open-core build).
          for (final m in gameSystemModules) ...m.routes,
        ],
      ),
    ],
  );
});

class _SessionRoomRoute extends ConsumerWidget {
  final String campaignId;
  final Map<String, String> params;
  const _SessionRoomRoute({required this.campaignId, this.params = const {}});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignDetailProvider(campaignId));
    return async.when(
      loading: () => const Scaffold(
          backgroundColor: Color(0xFF19130E),
          body: Center(child: CircularProgressIndicator(color: Color(0xFF8C2F2F)))),
      error: (e, _) => Scaffold(
          backgroundColor: const Color(0xFF19130E),
          body: Center(child: Text('$e', style: const TextStyle(color: Colors.white)))),
      data: (campaign) => sessionRoomFor(campaign, params),
    );
  }
}
