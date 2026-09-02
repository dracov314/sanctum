// Admin → Users. List every account; toggle admin / disabled; delete.
// Backed by /auth/users (admin-only).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/client.dart';
import '../../providers/auth_provider.dart';
import '../../ui/chrome.dart';

final adminUsersProvider =
    AsyncNotifierProvider<AdminUsersNotifier, List<Map<String, dynamic>>>(
        AdminUsersNotifier.new);

class AdminUsersNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    final data = await apiGet('/auth/users') as List;
    return data.cast<Map<String, dynamic>>();
  }

  Future<String?> patch(int id, {bool? isAdmin, bool? isDisabled}) async {
    try {
      await apiPatch('/auth/users/$id', {
        if (isAdmin != null) 'is_admin': isAdmin,
        if (isDisabled != null) 'is_disabled': isDisabled,
      });
    } on ApiException catch (e) {
      return _detail(e.message);
    }
    ref.invalidateSelf();
    return null;
  }

  Future<String?> remove(int id) async {
    try {
      await apiDelete('/auth/users/$id');
    } on ApiException catch (e) {
      return _detail(e.message);
    }
    ref.invalidateSelf();
    return null;
  }

  static String _detail(String body) {
    final m = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(body);
    return m?.group(1) ?? 'Something went wrong.';
  }
}

class AdminUsersScreen extends ConsumerWidget {
  const AdminUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider).value;
    final users = ref.watch(adminUsersProvider);
    return PageChrome(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SanctumPageHeader('Users',
              subtitle: 'Every account on this instance.'),
          users.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator(color: kAccent)),
            ),
            error: (e, _) => Text('Failed to load: $e',
                style: const TextStyle(color: kFail, fontSize: 12)),
            data: (rows) => Column(
              children: [
                for (final u in rows)
                  _UserRow(user: u, isSelf: u['id'] == me?.id),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _UserRow extends ConsumerWidget {
  final Map<String, dynamic> user;
  final bool isSelf;
  const _UserRow({required this.user, required this.isSelf});

  Future<void> _act(BuildContext context, WidgetRef ref, Future<String?> action) async {
    final err = await action;
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(adminUsersProvider.notifier);
    final id = user['id'] as int;
    final disabled = user['is_disabled'] == true;
    final isAdmin = user['is_admin'] == true;
    final owned = (user['campaigns_owned'] ?? 0) as int;
    final joined = user['campaigns_joined'] ?? 0;
    final name = (user['display_name'] as String?)?.isNotEmpty == true
        ? user['display_name'] as String
        : user['username'] as String;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: disabled ? kBorderDim : kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: disabled ? kT45 : kT100)),
              ),
              const SizedBox(width: 8),
              if (isAdmin) _tag('admin', gold: true),
              if (disabled) ...[const SizedBox(width: 6), _tag('disabled', fail: true)],
              if (isSelf) ...[const SizedBox(width: 6), _tag('you', accent: true)],
            ]),
            const SizedBox(height: 3),
            Text(
              '@${user['username']}'
              '${(user['email'] as String?)?.isNotEmpty == true ? '  ·  ${user['email']}' : ''}'
              '  ·  ${user['auth_kind'] ?? 'sso'}'
              '  ·  $owned owned / $joined joined',
              style: const TextStyle(fontSize: 11, color: kT55),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        if (isSelf)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text('—', style: TextStyle(color: kT45)),
          )
        else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18, color: kT68),
            color: kCard,
            onSelected: (v) async {
              switch (v) {
                case 'admin':
                  await _act(context, ref, n.patch(id, isAdmin: !isAdmin));
                case 'disable':
                  await _act(context, ref, n.patch(id, isDisabled: !disabled));
                case 'delete':
                  final ok = await _confirmDelete(context, name, owned);
                  if (ok == true) await _act(context, ref, n.remove(id));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'admin',
                child: Text(isAdmin ? 'Remove admin' : 'Make admin',
                    style: const TextStyle(fontSize: 12, color: kT100)),
              ),
              PopupMenuItem(
                value: 'disable',
                child: Text(disabled ? 'Re-enable account' : 'Disable account',
                    style: const TextStyle(fontSize: 12, color: kT100)),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete account…',
                    style: const TextStyle(fontSize: 12, color: kFail)),
              ),
            ],
          ),
      ]),
    );
  }

  Widget _tag(String text, {bool accent = false, bool fail = false, bool gold = false}) {
    final c = fail ? kFail : (gold ? kBrass : (accent ? kAccentHover : kT55));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: fail ? kFail : (gold ? kBrass : (accent ? kAccent : kBorderDim))),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text.toUpperCase(),
          style: TextStyle(fontSize: 8, letterSpacing: 0.5, color: c)),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name, int owned) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('Delete account', style: TextStyle(color: kT100, fontSize: 15)),
          content: Text(
            'Permanently delete $name?'
            '${owned > 0 ? '\n\nThis also deletes the $owned campaign${owned == 1 ? '' : 's'} they own, '
                'along with all sessions, wiki pages and files in them.' : ''}',
            style: const TextStyle(color: kT82, fontSize: 12, height: 1.4),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel', style: TextStyle(color: kT68))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete', style: TextStyle(color: kFail))),
          ],
        ),
      );
}
