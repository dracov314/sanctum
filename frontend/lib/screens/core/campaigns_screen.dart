// "My Campaigns" — every campaign you own or are a member of. System-agnostic:
// talks only to the generic /api/campaigns backend. A game-system module can
// layer richer game management on top (Fuzion does), but this list and the
// campaign detail screen work on their own.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/campaigns_provider.dart';
import '../../ui/chrome.dart';

class CampaignsScreen extends ConsumerWidget {
  const CampaignsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(campaignsProvider);
    return PageChrome(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SanctumBanner(),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Campaigns', style: serif(20, color: kT100)),
            PillButton('+ New campaign', () => _newCampaign(context, ref)),
          ]),
          const SizedBox(height: 4),
          const Text('Every campaign you run or play in.',
              style: TextStyle(fontSize: 11, color: kT55)),
          const SizedBox(height: 20),
          async.when(
            loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: kAccent))),
            error: (e, _) => Text('Could not load campaigns: $e',
                style: const TextStyle(fontSize: 12, color: kFail)),
            data: (campaigns) {
              if (campaigns.isEmpty) {
                return const Text(
                  "No campaigns yet. Create one — you'll be its GM.",
                  style: TextStyle(fontSize: 12, color: kT55),
                );
              }
              return TileGrid(
                count: campaigns.length,
                minTileWidth: 320,
                itemBuilder: (i, w) => _CampaignCard(campaign: campaigns[i], width: w),
              );
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _newCampaign(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('New campaign', style: serif(15, color: kT100)),
              const SizedBox(height: 12),
              const FieldLabel('NAME'),
              const SizedBox(height: 4),
              RefInput(nameCtrl, hint: 'Campaign name'),
              const SizedBox(height: 10),
              const FieldLabel('DESCRIPTION'),
              const SizedBox(height: 4),
              RefInput(descCtrl, hint: 'Optional', maxLines: 3),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx, false)),
                const SizedBox(width: 8),
                PillButton('Create', () async {
                  if (nameCtrl.text.trim().isEmpty) return;
                  await ref.read(campaignsProvider.notifier)
                      .create(nameCtrl.text.trim(), description: descCtrl.text.trim());
                  if (ctx.mounted) Navigator.pop(ctx, true);
                }),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (created == true && context.mounted) {
      // Land on the new campaign.
      final list = ref.read(campaignsProvider).value ?? [];
      final match = list.where((c) => c['name'] == nameCtrl.text.trim()).toList();
      if (match.isNotEmpty) context.go('/campaigns/${match.last['id']}');
    }
  }
}

class _CampaignCard extends ConsumerWidget {
  final Map<String, dynamic> campaign;
  final double width;
  const _CampaignCard({required this.campaign, required this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = campaign['role'] as String? ?? 'player';
    final latest = campaign['latest_session'] as Map?;
    return InkWell(
      onTap: () => context.go('/campaigns/${campaign['id']}'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: kCard,
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(campaign['name'] as String? ?? '',
                style: serif(15, color: kT100), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            _RoleBadge(role),
          ]),
          if ((campaign['description'] as String?)?.isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(campaign['description'] as String,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: kT68)),
          ],
          const SizedBox(height: 8),
          Text(
            latest != null
                ? 'Last session: #${latest['session_number']} · ${latest['title'] ?? ''}'
                : 'No sessions logged yet',
            style: const TextStyle(fontSize: 10.5, color: kT45),
            overflow: TextOverflow.ellipsis,
          ),
        ]),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;
  const _RoleBadge(this.role);
  @override
  Widget build(BuildContext context) {
    final isGm = role == 'owner' || role == 'gm';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: isGm ? kGmTag : kBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(role.toUpperCase(),
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
              color: isGm ? kGmTag : kT55)),
    );
  }
}
