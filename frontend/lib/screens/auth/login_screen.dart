// Login is app infrastructure (no design mockup — that assumed an
// already-authenticated session). Styled from the Sanctum design system's
// tokens.css + foundations/brand.html (emblem at 160px, serif brass wordmark).
//
// The form shown depends on GET /api/auth/config: SSO, local
// username/password, or both. The public open-core build ships local-only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../ui/chrome.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(authConfigProvider);
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/sanctum_logo.png', width: 160, height: 160),
            const SizedBox(height: 24),
            Text('Sanctum', style: serif(28, color: kBrass)),
            const SizedBox(height: 8),
            const Text('Your TTRPG library and campaign hub',
                style: TextStyle(fontSize: 14, color: kT68)),
            const SizedBox(height: 40),
            cfg.when(
              loading: () => const SizedBox(
                  height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
              error: (_, __) => _SsoButton(
                  label: 'Sign in with SSO',
                  onTap: () => ref.read(authProvider.notifier).login()),
              data: (c) {
                final oidc = c['oidc_enabled'] == true;
                final local = c['local_enabled'] == true;
                final providerName = (c['oidc_provider_name'] as String?)?.trim();
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  if (local)
                    _LocalAuthForm(allowRegister: c['allow_registration'] == true),
                  if (local && oidc) ...[
                    const SizedBox(height: 20),
                    const Text('or', style: TextStyle(fontSize: 12, color: kT45)),
                    const SizedBox(height: 12),
                  ],
                  if (oidc)
                    _SsoButton(
                      label: 'Sign in with ${providerName?.isNotEmpty == true ? providerName : 'SSO'}',
                      onTap: () => ref.read(authProvider.notifier).login(),
                    ),
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _SsoButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  const _SsoButton({required this.onTap, required this.label});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(18)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_open_outlined, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
          ]),
        ),
      );
}

class _LocalAuthForm extends ConsumerStatefulWidget {
  final bool allowRegister;
  const _LocalAuthForm({required this.allowRegister});
  @override
  ConsumerState<_LocalAuthForm> createState() => _LocalAuthFormState();
}

class _LocalAuthFormState extends ConsumerState<_LocalAuthForm> {
  final _user = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final notifier = ref.read(authProvider.notifier);
    final err = _register
        ? await notifier.registerLocal(_user.text.trim(), _email.text.trim(), _pass.text)
        : await notifier.loginLocal(_user.text.trim(), _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _field(_user, 'Username', autofill: true),
        if (_register) ...[
          const SizedBox(height: 10),
          _field(_email, 'Email (optional)'),
        ],
        const SizedBox(height: 10),
        _field(_pass, 'Password', obscure: true, onSubmit: _submit),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(fontSize: 12, color: kFail)),
        ],
        const SizedBox(height: 16),
        InkWell(
          onTap: _busy ? null : _submit,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(18)),
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_register ? 'Create account' : 'Sign in',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ),
        if (widget.allowRegister) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : () => setState(() {
              _register = !_register;
              _error = null;
            }),
            child: Text(
              _register ? 'Have an account? Sign in' : 'Create an account',
              style: const TextStyle(fontSize: 12, color: kLink),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool obscure = false, bool autofill = false, VoidCallback? onSubmit}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      autofocus: autofill,
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
}
