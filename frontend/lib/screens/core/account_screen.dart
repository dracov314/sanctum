// Account settings — profile summary + (for local accounts) change password.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../ui/chrome.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value;
    if (user == null) {
      return const PageChrome(child: Center(child: CircularProgressIndicator(color: kAccent)));
    }
    return PageChrome(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SanctumPageHeader('Account', subtitle: 'Your profile and sign-in.'),
          _row('Username', user.username),
          _row('Role', user.isAdmin ? 'Admin' : 'Member'),
          _row('Sign-in', user.hasPassword ? 'Password' : 'Single sign-on'),
          const SizedBox(height: 28),
          _ProfileCard(
            key: ValueKey('${user.displayName}|${user.email}'),
            initialName: user.displayName ?? '',
            initialEmail: user.email ?? '',
          ),
          const SizedBox(height: 20),
          if (user.localAuth) const _PasswordCard(),
        ]),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: const TextStyle(fontSize: 12, color: kT55))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12, color: kT100))),
        ]),
      );
}

class _ProfileCard extends ConsumerStatefulWidget {
  final String initialName;
  final String initialEmail;
  const _ProfileCard({super.key, required this.initialName, required this.initialEmail});
  @override
  ConsumerState<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<_ProfileCard> {
  late final _name = TextEditingController(text: widget.initialName);
  late final _email = TextEditingController(text: widget.initialEmail);
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final err = await ref.read(authProvider.notifier).updateProfile(
          displayName: _name.text.trim(),
          email: _email.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _msg = err ?? 'Profile updated.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final sso = !(ref.watch(authProvider).value?.hasPassword ?? true);
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionHeading('PROFILE'),
        const SizedBox(height: 12),
        const FieldLabel('DISPLAY NAME'),
        const SizedBox(height: 4),
        _field(_name),
        const SizedBox(height: 10),
        const FieldLabel('EMAIL'),
        const SizedBox(height: 4),
        _field(_email, onSubmit: _submit),
        if (sso) ...[
          const SizedBox(height: 10),
          const Text(
            'You sign in with single sign-on — your identity provider will '
            'overwrite these on your next sign-in.',
            style: TextStyle(fontSize: 11, color: kT55, height: 1.4),
          ),
        ],
        if (_msg != null) ...[
          const SizedBox(height: 10),
          Text(_msg!, style: TextStyle(fontSize: 12, color: _ok ? kSuccess : kFail)),
        ],
        const SizedBox(height: 14),
        PillButton(_busy ? 'Saving…' : 'Save', _busy ? () {} : _submit),
      ]),
    );
  }

  Widget _field(TextEditingController c, {VoidCallback? onSubmit}) => TextField(
        controller: c,
        onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
        style: const TextStyle(fontSize: 13, color: kT100),
        decoration: InputDecoration(
          filled: true,
          fillColor: kInput,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: kBorderDim),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: kAccent),
          ),
        ),
      );
}

class _PasswordCard extends ConsumerStatefulWidget {
  const _PasswordCard();
  @override
  ConsumerState<_PasswordCard> createState() => _PasswordCardState();
}

class _PasswordCardState extends ConsumerState<_PasswordCard> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_next.text.length < 8) {
      setState(() {
        _ok = false;
        _msg = 'New password must be at least 8 characters.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    final err = await ref.read(authProvider.notifier).changePassword(_current.text, _next.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _msg = err ?? 'Password updated.';
      if (err == null) {
        _current.clear();
        _next.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasPw = ref.watch(authProvider).value?.hasPassword ?? true;
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SectionHeading('PASSWORD'),
        const SizedBox(height: 12),
        if (!hasPw) ...[
          const Text(
            'You sign in with single sign-on. Set a password to also be able '
            'to sign in locally.',
            style: TextStyle(fontSize: 11, color: kT55, height: 1.4),
          ),
          const SizedBox(height: 12),
        ],
        if (hasPw) ...[
          const FieldLabel('CURRENT PASSWORD'),
          const SizedBox(height: 4),
          _field(_current),
          const SizedBox(height: 10),
        ],
        const FieldLabel('NEW PASSWORD'),
        const SizedBox(height: 4),
        _field(_next, onSubmit: _submit),
        if (_msg != null) ...[
          const SizedBox(height: 10),
          Text(_msg!, style: TextStyle(fontSize: 12, color: _ok ? kSuccess : kFail)),
        ],
        const SizedBox(height: 14),
        PillButton(_busy ? 'Saving…' : (hasPw ? 'Change password' : 'Set password'),
            _busy ? () {} : _submit),
      ]),
    );
  }

  Widget _field(TextEditingController c, {VoidCallback? onSubmit}) => TextField(
        controller: c,
        obscureText: true,
        onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
        style: const TextStyle(fontSize: 13, color: kT100),
        decoration: InputDecoration(
          filled: true,
          fillColor: kInput,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: kBorderDim),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: kAccent),
          ),
        ),
      );
}
