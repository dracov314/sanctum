// Invite-link landing page — reached at /join/:token, works logged-out.
//
// Valid + signed in  → "Accept invite" joins the campaign.
// Valid + signed out → sign in / create an account inline (the invite is its
//                      own authorization to register), then the page flips to
//                      the accept state. SSO stashes the token first so the
//                      round-trip back to "/" can resume the join.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../api/client.dart';
import '../../providers/auth_provider.dart';
import '../../ui/chrome.dart';

final _invitePreviewProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, token) async {
  final m = await apiGet('/invites/$token') as Map;
  return m.cast<String, dynamic>();
});

class JoinInviteScreen extends ConsumerWidget {
  final String token;
  const JoinInviteScreen({super.key, required this.token});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(_invitePreviewProvider(token));
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/sanctum_logo.png', width: 120, height: 120),
              const SizedBox(height: 20),
              preview.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(color: kAccent),
                ),
                error: (_, __) => const _Dead(),
                data: (p) => (p['valid'] == true)
                    ? _ValidInvite(token: token, preview: p)
                    : _Dead(reason: p['reason'] as String?),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Dead extends StatelessWidget {
  final String? reason;
  const _Dead({this.reason});
  @override
  Widget build(BuildContext context) {
    final msg = switch (reason) {
      'expired' => 'This invite link has expired.',
      'revoked' => 'This invite link was revoked by the GM.',
      'used_up' => 'This invite link has been used up.',
      _ => "This invite link isn't valid.",
    };
    return Column(children: [
      Text('Invite unavailable', style: serif(20, color: kBrass)),
      const SizedBox(height: 10),
      Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: kT68)),
      const SizedBox(height: 20),
      PillButtonOutlined('Go to Sanctum', () => context.go('/dashboard')),
    ]);
  }
}

class _ValidInvite extends ConsumerWidget {
  final String token;
  final Map<String, dynamic> preview;
  const _ValidInvite({required this.token, required this.preview});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final name = preview['campaign_name'] as String? ?? 'a campaign';
    final inviter = preview['inviter_name'] as String?;
    final role = preview['role'] as String? ?? 'player';

    return Column(children: [
      const Text("You've been invited to join",
          style: TextStyle(fontSize: 13, color: kT55)),
      const SizedBox(height: 6),
      Text(name, textAlign: TextAlign.center, style: serif(22, color: kBrass)),
      const SizedBox(height: 6),
      Text(
        '${inviter != null ? '$inviter · ' : ''}as ${role.toUpperCase()}',
        style: const TextStyle(fontSize: 11, color: kT45),
      ),
      const SizedBox(height: 24),
      auth.when(
        loading: () => const CircularProgressIndicator(color: kAccent),
        error: (_, __) => _AuthGate(token: token),
        data: (user) => user != null
            ? _AcceptButton(token: token)
            : _AuthGate(token: token),
      ),
    ]);
  }
}

class _AcceptButton extends ConsumerStatefulWidget {
  final String token;
  const _AcceptButton({required this.token});
  @override
  ConsumerState<_AcceptButton> createState() => _AcceptButtonState();
}

class _AcceptButtonState extends ConsumerState<_AcceptButton> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // We're here and authenticated — the SSO-resume stash has done its job.
    clearPendingInvite();
  }

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await apiPost('/invites/${widget.token}/accept') as Map;
      clearPendingInvite();
      if (mounted) context.go('/campaigns/${res['campaign_id']}');
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = _detail(e.message);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final who = ref.watch(authProvider).value;
    return Column(children: [
      if (who != null)
        Text('Signed in as ${who.displayName ?? who.username}',
            style: const TextStyle(fontSize: 11, color: kT45)),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: PillButton(_busy ? 'Joining…' : 'Accept invite', _busy ? () {} : _accept),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: const TextStyle(fontSize: 12, color: kFail)),
      ],
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => context.go('/dashboard'),
        child: const Text('Not now', style: TextStyle(fontSize: 12, color: kLink)),
      ),
    ]);
  }
}

/// Signed-out state: SSO button and/or an inline local sign-in / register form.
class _AuthGate extends ConsumerStatefulWidget {
  final String token;
  const _AuthGate({required this.token});
  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _register = true; // an invited person most often needs a new account
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final n = ref.read(authProvider.notifier);
    final err = _register
        ? await n.registerLocal(_user.text.trim(), '', _pass.text, inviteToken: widget.token)
        : await n.loginLocal(_user.text.trim(), _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    // On success authProvider flips to a user and the parent swaps in the
    // accept button automatically.
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(authConfigProvider).value ?? const {};
    final oidc = cfg['oidc_enabled'] == true;
    final local = cfg['local_enabled'] == true;
    final providerName = (cfg['oidc_provider_name'] as String?)?.trim();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (local) ...[
        _field(_user, 'Username'),
        const SizedBox(height: 8),
        _field(_pass, 'Password', obscure: true, onSubmit: _submit),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(fontSize: 12, color: kFail)),
        ],
        const SizedBox(height: 12),
        PillButton(
          _busy ? 'Please wait…' : (_register ? 'Create account & join' : 'Sign in & join'),
          _busy ? () {} : _submit,
        ),
        TextButton(
          onPressed: () => setState(() {
            _register = !_register;
            _error = null;
          }),
          child: Text(_register ? 'I already have an account' : 'I need an account',
              style: const TextStyle(fontSize: 12, color: kLink)),
        ),
      ],
      if (local && oidc) ...[
        const SizedBox(height: 4),
        const Text('or', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: kT45)),
        const SizedBox(height: 8),
      ],
      if (oidc)
        PillButtonOutlined(
          'Sign in with ${providerName?.isNotEmpty == true ? providerName : 'SSO'}',
          () {
            setPendingInvite(widget.token);
            ref.read(authProvider.notifier).login();
          },
        ),
    ]);
  }

  Widget _field(TextEditingController c, String label,
      {bool obscure = false, VoidCallback? onSubmit}) => TextField(
        controller: c,
        obscureText: obscure,
        onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
        style: const TextStyle(fontSize: 14, color: kT100),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 13, color: kT55),
          filled: true,
          fillColor: kInput,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBorderDim),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kAccent),
          ),
        ),
      );
}

String _detail(String body) {
  final m = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(body);
  return m?.group(1) ?? 'Something went wrong.';
}
