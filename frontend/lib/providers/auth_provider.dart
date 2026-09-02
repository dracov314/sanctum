import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

/// What auth methods the backend offers — drives the login screen UI.
/// Falls back to "OIDC only" if the endpoint can't be reached.
final authConfigProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  try {
    final m = await apiGet('/auth/config') as Map;
    return m.cast<String, dynamic>();
  } catch (_) {
    return const {
      'mode': 'oidc',
      'oidc_enabled': true,
      'local_enabled': false,
      'allow_registration': false,
    };
  }
});

class AuthUser {
  final int id;
  final String username;
  final String? displayName;
  final String? email;
  final bool isAdmin;
  final bool hasPassword;
  final bool localAuth;

  const AuthUser({
    required this.id,
    required this.username,
    this.displayName,
    this.email,
    required this.isAdmin,
    this.hasPassword = false,
    this.localAuth = false,
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id'],
        username: j['username'],
        displayName: j['display_name'],
        email: j['email'],
        isAdmin: j['is_admin'] ?? false,
        hasPassword: j['has_password'] ?? false,
        localAuth: j['local_auth'] ?? false,
      );

  String get initials {
    final name = displayName ?? username;
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

class AuthNotifier extends AsyncNotifier<AuthUser?> {
  @override
  Future<AuthUser?> build() async {
    try {
      final data = await apiGet('/auth/me') as Map<String, dynamic>;
      return AuthUser.fromJson(data);
    } on ApiException catch (e) {
      if (e.status == 401) return null;
      rethrow;
    }
  }

  void login() {
    html.window.location.href = '/api/auth/login';
  }

  /// Local username/password sign-in. Returns null on success, or an error
  /// message to show the user.
  Future<String?> loginLocal(String username, String password) =>
      _localAuth('/auth/login-local', {'username': username, 'password': password});

  /// Local account registration. Returns null on success, or an error message.
  /// [inviteToken] lets someone register when open registration is off.
  Future<String?> registerLocal(String username, String email, String password,
          {String? inviteToken}) =>
      _localAuth('/auth/register', {
        'username': username,
        if (email.isNotEmpty) 'email': email,
        'password': password,
        if (inviteToken != null) 'invite_token': inviteToken,
      });

  Future<String?> _localAuth(String path, Map<String, dynamic> body) async {
    try {
      await apiPost(path, body);
    } on ApiException catch (e) {
      return _detail(e.message);
    }
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
    return null;
  }

  /// Self-service profile edit (display name + email). Returns null on
  /// success or an error message.
  Future<String?> updateProfile({String? displayName, String? email}) async {
    try {
      await apiPatch('/auth/me', {
        if (displayName != null) 'display_name': displayName,
        if (email != null) 'email': email,
      });
    } on ApiException catch (e) {
      return _detail(e.message);
    }
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
    return null;
  }

  /// Change (or, for an OIDC account, set) the local password. Returns null
  /// on success or an error message.
  Future<String?> changePassword(String currentPassword, String newPassword) async {
    try {
      await apiPost('/auth/change-password', {
        'current_password': currentPassword,
        'new_password': newPassword,
      });
    } on ApiException catch (e) {
      return _detail(e.message);
    }
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
    return null;
  }

  static String _detail(String body) {
    try {
      final m = jsonDecode(body);
      if (m is Map && m['detail'] is String) return m['detail'] as String;
    } catch (_) {}
    return 'Something went wrong. Try again.';
  }

  Future<void> logout() async {
    final result = await apiPost('/auth/logout') as Map<String, dynamic>?;
    state = const AsyncData(null);

    // Real top-level navigation to Authentik's end-session endpoint is the
    // only reliable way to actually terminate Authentik's own session
    // cookie (a hidden-iframe approach doesn't reliably work). Backend
    // includes id_token_hint + post_logout_redirect_uri so Authentik
    // bounces the browser straight back here once its session is cleared.
    final logoutUrl = result?['idp_logout_url'] as String?;
    if (logoutUrl != null) {
      html.window.location.href = logoutUrl;
    }
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthUser?>(() => AuthNotifier());

/// An invite token stashed before an SSO round-trip (which lands the user back
/// on `/` and would otherwise lose the invite context). The router picks this
/// up post-login and sends the user to `/join/<token>`.
const _pendingInviteKey = 'sanctum_pending_invite';

void setPendingInvite(String token) {
  try {
    html.window.localStorage[_pendingInviteKey] = token;
  } catch (_) {}
}

String? readPendingInvite() {
  try {
    return html.window.localStorage[_pendingInviteKey];
  } catch (_) {
    return null;
  }
}

void clearPendingInvite() {
  try {
    html.window.localStorage.remove(_pendingInviteKey);
  } catch (_) {}
}
