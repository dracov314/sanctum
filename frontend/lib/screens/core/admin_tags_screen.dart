// Admin → Tags. Every tag across books / maps / tokens with usage counts;
// rename (or merge into an existing tag) and delete library-wide.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/client.dart';
import '../../ui/chrome.dart';

final _tagUsageProvider =
    AsyncNotifierProvider<_TagUsageNotifier, List<Map<String, dynamic>>>(
        _TagUsageNotifier.new);

class _TagUsageNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    final data = await apiGet('/library/tags/usage') as List;
    return data.cast<Map<String, dynamic>>();
  }

  Future<String?> rename(String from, String to) => _post('/library/tags/rename',
      {'from_tag': from, 'to_tag': to});

  Future<String?> remove(String tag) => _post('/library/tags/delete', {'tag': tag});

  Future<String?> _post(String path, Map<String, dynamic> body) async {
    try {
      await apiPost(path, body);
    } on ApiException catch (e) {
      final m = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(e.message);
      return m?.group(1) ?? 'Something went wrong.';
    }
    ref.invalidateSelf();
    return null;
  }
}

class AdminTagsScreen extends ConsumerWidget {
  const AdminTagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(_tagUsageProvider);
    return PageChrome(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SanctumPageHeader('Tags',
              subtitle: 'Every tag across books, maps and tokens.'),
          tags.when(
            loading: () => const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator(color: kAccent))),
            error: (e, _) => Text('Failed to load: $e',
                style: const TextStyle(color: kFail, fontSize: 12)),
            data: (rows) => rows.isEmpty
                ? const Text('No tags yet.', style: TextStyle(fontSize: 12, color: kT55))
                : Column(children: [for (final t in rows) _TagRow(row: t)]),
          ),
        ]),
      ),
    );
  }
}

class _TagRow extends ConsumerWidget {
  final Map<String, dynamic> row;
  const _TagRow({required this.row});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<String?> action) async {
    final err = await action;
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(_tagUsageProvider.notifier);
    final tag = row['tag'] as String;
    final parts = <String>[
      if ((row['books'] ?? 0) > 0) '${row['books']} books',
      if ((row['maps'] ?? 0) > 0) '${row['maps']} maps',
      if ((row['tokens'] ?? 0) > 0) '${row['tokens']} tokens',
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorderDim),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tag, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kT100)),
            const SizedBox(height: 2),
            Text(parts.isEmpty ? 'unused' : parts.join('  ·  '),
                style: const TextStyle(fontSize: 10, color: kT45)),
          ]),
        ),
        TextButton(
          onPressed: () async {
            final to = await _promptRename(context, tag);
            if (to != null && to.isNotEmpty && to != tag) {
              await _run(context, ref, n.rename(tag, to));
            }
          },
          child: const Text('Rename / merge', style: TextStyle(fontSize: 11, color: kLink)),
        ),
        IconButton(
          tooltip: 'Delete tag everywhere',
          icon: const Icon(Icons.delete_outline, size: 17),
          color: kFail,
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: kCard,
                title: const Text('Delete tag', style: TextStyle(color: kT100, fontSize: 15)),
                content: Text('Remove "$tag" from every book, map and token that has it?',
                    style: const TextStyle(color: kT82, fontSize: 12, height: 1.4)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel', style: TextStyle(color: kT68))),
                  TextButton(onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete', style: TextStyle(color: kFail))),
                ],
              ),
            );
            if (ok == true) await _run(context, ref, n.remove(tag));
          },
        ),
      ]),
    );
  }

  Future<String?> _promptRename(BuildContext context, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Rename "$current"', style: serif(15, color: kT100)),
              const SizedBox(height: 4),
              const Text('Renaming to a tag that already exists merges the two.',
                  style: TextStyle(fontSize: 11, color: kT55)),
              const SizedBox(height: 12),
              RefInput(ctrl, hint: 'New tag name'),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Apply', () => Navigator.pop(ctx, ctrl.text.trim())),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
