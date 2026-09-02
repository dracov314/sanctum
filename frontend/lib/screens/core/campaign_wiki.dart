// Campaign wiki — page tree with [[wiki links]], Markdown rendering, and a
// GM/author create-edit-delete flow. Fully system-agnostic: it talks only to
// the generic /api/campaigns/{id}/wiki endpoints via campaignWikiProvider.
//
// Extracted from the Fuzion workspace (was FuzionWikiPanel) so the core app —
// and the public open-core build — can mount it directly.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import '../../api/client.dart';
import '../../providers/auth_provider.dart';
import '../../providers/campaigns_provider.dart';
import '../../ui/chrome.dart';

class CampaignWikiPanel extends ConsumerWidget {
  final String gameId;
  final bool isGm;
  const CampaignWikiPanel({super.key, required this.gameId, required this.isGm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wikiAsync = ref.watch(campaignWikiProvider(gameId));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        TagButton('+ New Page', () => _editWikiPage(context, ref, gameId: gameId, isGm: isGm, pages: wikiAsync.value ?? const [])),
        TagButton('Templates', () => _manageTemplates(context, ref, gameId: gameId)),
        TagButton('Export Wiki (JSON)', () => openExternal('/api/campaigns/$gameId/wiki/export')),
        TagButton('Import Page (.md)', () => pickAndUpload(context,
            url: '/campaigns/$gameId/wiki/import-markdown',
            accept: '.md,.markdown,text/markdown',
            onDone: () => ref.invalidate(campaignWikiProvider(gameId)))),
        if (isGm)
          TagButton('Import Wiki (JSON)', () => pickAndUpload(context,
              url: '/campaigns/$gameId/wiki/import',
              accept: '.json,application/json',
              onDone: () => ref.invalidate(campaignWikiProvider(gameId)))),
      ]),
      const SizedBox(height: 10),
      wikiAsync.when(
        loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
        error: (e, _) => Text('$e', style: const TextStyle(color: kFail, fontSize: 11)),
        data: (pages) {
          if (pages.isEmpty) {
            return const Text('No wiki pages yet.', style: TextStyle(fontSize: 12, color: kT55));
          }
          return Column(children: _wikiTreeRows(context, ref, gameId, isGm, pages, null, 0, <String>{}));
        },
      ),
    ]);
  }
}

List<Widget> _wikiTreeRows(
  BuildContext context,
  WidgetRef ref,
  String gameId,
  bool isGm,
  List<Map<String, dynamic>> pages,
  String? parentId,
  int depth,
  Set<String> ancestors,
) {
  final children = pages.where((p) => (p['parent_id'] as String?) == parentId).toList();
  final rows = <Widget>[];
  for (final p in children) {
    final id = p['id'] as String;
    if (ancestors.contains(id)) continue; // guards against a corrupt cyclic parent chain
    rows.add(Padding(
      padding: EdgeInsets.only(left: depth * 16.0, bottom: 4),
      child: InkWell(
        onTap: () => _showWikiPage(context, ref, gameId: gameId, isGm: isGm, page: p, pages: pages),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            const Icon(Icons.article_outlined, size: 14, color: kT55),
            const SizedBox(width: 8),
            Expanded(child: Text(p['title'] as String? ?? '', style: const TextStyle(fontSize: 12, color: Colors.white))),
            if (p['is_gm_only'] == true) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: const Color(0x2ED9A441), border: Border.all(color: const Color(0x99D9A441)), borderRadius: BorderRadius.circular(4)),
                child: const Text('GM ONLY', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kGmTag)),
              ),
              const SizedBox(width: 6),
            ],
            InkWell(
              onTap: () => _editWikiPage(context, ref, gameId: gameId, isGm: isGm, pages: pages, initialParentId: id),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.add, size: 14, color: kT55),
              ),
            ),
          ]),
        ),
      ),
    ));
    rows.addAll(_wikiTreeRows(context, ref, gameId, isGm, pages, id, depth + 1, {...ancestors, id}));
  }
  return rows;
}

// -- [[Page Title]] link syntax + parsing -------------------------------------

class _WikiTarget {
  final String title;
  final String? pageId;
  final String? heading;
  _WikiTarget(this.title, this.pageId, this.heading);
}

_WikiTarget _parseWikiTarget(String raw) {
  var s = raw.trim();
  String? heading;
  final hashAt = s.indexOf(':#');
  if (hashAt != -1) {
    final h = s.substring(hashAt + 2).trim();
    heading = h.isEmpty ? null : h;
    s = s.substring(0, hashAt);
  }
  String? pageId;
  final idMatch = RegExp(r':id-([0-9A-Za-z_-]+)$').firstMatch(s);
  if (idMatch != null) {
    pageId = idMatch.group(1);
    s = s.substring(0, idMatch.start);
  }
  return _WikiTarget(s.trim(), pageId, heading);
}

Map<String, dynamic>? _resolveWikiLink(String target, List<Map<String, dynamic>> pages) {
  final parsed = _parseWikiTarget(target);
  if (parsed.pageId != null) {
    for (final p in pages) {
      if (p['id'] == parsed.pageId) return p;
    }
    return null;
  }
  final norm = parsed.title.toLowerCase();
  for (final p in pages) {
    if ((p['title'] as String? ?? '').trim().toLowerCase() == norm) return p;
  }
  return null;
}

class _WikiLinkSyntax extends md.InlineSyntax {
  _WikiLinkSyntax() : super(r'\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = match[1]!.trim();
    final label = (match[2] ?? match[1]!).trim();
    final anchor = md.Element.text('a', label);
    anchor.attributes['href'] = 'wikilink://${Uri.encodeComponent(target)}';
    parser.addNode(anchor);
    return true;
  }
}

// -- View/edit dialog ----------------------------------------------------------

Future<void> _showWikiPage(
  BuildContext context,
  WidgetRef ref, {
  required String gameId,
  required bool isGm,
  required Map<String, dynamic> page,
  required List<Map<String, dynamic>> pages,
}) {
  return showDialog(
    context: context,
    builder: (_) => _WikiPageDialog(gameId: gameId, isGm: isGm, page: page, pages: pages),
  );
}

class _WikiPageDialog extends ConsumerStatefulWidget {
  final String gameId;
  final bool isGm;
  final Map<String, dynamic> page;
  final List<Map<String, dynamic>> pages;
  const _WikiPageDialog({required this.gameId, required this.isGm, required this.page, required this.pages});

  @override
  ConsumerState<_WikiPageDialog> createState() => _WikiPageDialogState();
}

class _WikiPageDialogState extends ConsumerState<_WikiPageDialog> {
  late Map<String, dynamic> current;

  @override
  void initState() {
    super.initState();
    current = widget.page;
  }

  void _navigateTo(Map<String, dynamic> page) => setState(() => current = page);

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final canDelete = widget.isGm || auth?.isAdmin == true || auth?.id == current['author_id'];
    return Dialog(
      backgroundColor: kCard,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(current['title'] as String? ?? '', style: serif(16)),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: (current['content'] as String? ?? '').isEmpty ? '_Empty page._' : current['content'] as String,
                  selectable: true,
                  inlineSyntaxes: [_WikiLinkSyntax()],
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 12, color: kT82, height: 1.5),
                    h1: serif(18), h2: serif(16), h3: serif(14),
                    a: const TextStyle(color: kGmTag, decoration: TextDecoration.underline),
                    code: const TextStyle(fontSize: 11, color: kT82, backgroundColor: kInput),
                    listBullet: const TextStyle(fontSize: 12, color: kT82),
                  ),
                  onTapLink: (text, href, title) {
                    if (href == null || !href.startsWith('wikilink://')) return;
                    final target = Uri.decodeComponent(href.substring('wikilink://'.length));
                    final resolved = _resolveWikiLink(target, widget.pages);
                    if (resolved != null) {
                      _navigateTo(resolved);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Page not found: ${_parseWikiTarget(target).title}')),
                      );
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Row(children: [
                PillButtonOutlined('Export .md',
                    () => openExternal('/api/campaigns/${widget.gameId}/wiki/${current['id']}/export')),
                const SizedBox(width: 8),
                PillButtonOutlined('Save as Template',
                    () => _saveAsTemplate(context, ref, gameId: widget.gameId, content: current['content'] as String? ?? '')),
                if (canDelete) ...[
                  const SizedBox(width: 8),
                  PillButtonOutlined('Delete', () async {
                    await apiDelete('/campaigns/${widget.gameId}/wiki/${current['id']}');
                    ref.invalidate(campaignWikiProvider(widget.gameId));
                    if (context.mounted) Navigator.pop(context);
                  }),
                ],
              ]),
              Row(children: [
                PillButtonOutlined('Edit', () {
                  Navigator.pop(context);
                  _editWikiPage(context, ref, gameId: widget.gameId, isGm: widget.isGm, pages: widget.pages, existing: current);
                }),
                const SizedBox(width: 8),
                PillButton('Close', () => Navigator.pop(context)),
              ]),
            ]),
          ]),
        ),
      ),
    );
  }
}

// -- Templates -------------------------------------------------------------

Future<void> _saveAsTemplate(
  BuildContext context,
  WidgetRef ref, {
  required String gameId,
  required String content,
}) async {
  final nameCtrl = TextEditingController();
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: kCard,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Save as Template', style: serif(15)),
            const SizedBox(height: 12),
            const FieldLabel('TEMPLATE NAME'),
            const SizedBox(height: 4),
            RefInput(nameCtrl, hint: 'e.g. NPC, Location'),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
              const SizedBox(width: 8),
              PillButton('Save', () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                await apiPost('/campaigns/$gameId/wiki-templates', {'name': name, 'content': content});
                ref.invalidate(wikiTemplatesProvider(gameId));
                if (ctx.mounted) Navigator.pop(ctx);
              }),
            ]),
          ]),
        ),
      ),
    ),
  );
}

Future<void> _manageTemplates(BuildContext context, WidgetRef ref, {required String gameId}) async {
  await showDialog(
    context: context,
    builder: (ctx) => Consumer(builder: (ctx, ref, _) {
      final templatesAsync = ref.watch(wikiTemplatesProvider(gameId));
      return Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 480),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Templates', style: serif(15)),
              const SizedBox(height: 12),
              Flexible(
                child: templatesAsync.when(
                  loading: () => const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
                  error: (e, _) => Text('$e', style: const TextStyle(color: kFail, fontSize: 11)),
                  data: (templates) {
                    if (templates.isEmpty) {
                      return const Text('No templates yet — save a page as one from its view dialog.',
                          style: TextStyle(fontSize: 12, color: kT55));
                    }
                    return SingleChildScrollView(
                      child: Column(children: [
                        for (final t in templates)
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(color: kWell, borderRadius: BorderRadius.circular(6)),
                            child: Row(children: [
                              Expanded(child: Text(t['name'] as String? ?? '', style: const TextStyle(fontSize: 12, color: kT100))),
                              InkWell(
                                onTap: () async {
                                  await apiDelete('/campaigns/$gameId/wiki-templates/${t['id']}');
                                  ref.invalidate(wikiTemplatesProvider(gameId));
                                },
                                child: const Icon(Icons.close, size: 15, color: kT55),
                              ),
                            ]),
                          ),
                      ]),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Align(alignment: Alignment.centerRight, child: PillButton('Close', () => Navigator.pop(ctx))),
            ]),
          ),
        ),
      );
    }),
  );
}

// -- Create/edit dialog ---------------------------------------------------------

Future<void> _editWikiPage(
  BuildContext context,
  WidgetRef ref, {
  required String gameId,
  required bool isGm,
  required List<Map<String, dynamic>> pages,
  Map<String, dynamic>? existing,
  String? initialParentId,
}) async {
  final titleCtrl = TextEditingController(text: existing?['title'] as String? ?? '');
  final contentCtrl = TextEditingController(text: existing?['content'] as String? ?? '');
  bool gmOnly = existing?['is_gm_only'] == true;
  String? parentId = existing != null ? existing['parent_id'] as String? : initialParentId;

  // A page can't be parented to itself or to any of its own descendants.
  final excluded = <String>{};
  if (existing != null) {
    excluded.add(existing['id'] as String);
    void collectDescendants(String id) {
      for (final p in pages) {
        if (p['parent_id'] == id && !excluded.contains(p['id'])) {
          excluded.add(p['id'] as String);
          collectDescendants(p['id'] as String);
        }
      }
    }
    collectDescendants(existing['id'] as String);
  }
  final parentOptions = pages.where((p) => !excluded.contains(p['id'])).toList();
  if (parentId != null && !parentOptions.any((p) => p['id'] == parentId)) parentId = null;

  // Templates only make sense as a starting point for a brand-new page — a
  // one-time snapshot is enough, this list won't change while the dialog is open.
  final templates = existing == null ? (ref.read(wikiTemplatesProvider(gameId)).valueOrNull ?? []) : const <Map<String, dynamic>>[];
  String? selectedTemplateId;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Dialog(
      backgroundColor: kCard,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(existing == null ? 'New Wiki Page' : 'Edit Wiki Page', style: serif(15)),
            const SizedBox(height: 12),
            const FieldLabel('TITLE'),
            const SizedBox(height: 4),
            RefInput(titleCtrl, hint: 'Page title'),
            const SizedBox(height: 10),
            const FieldLabel('PARENT PAGE'),
            const SizedBox(height: 4),
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(color: kInput, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(3)),
              child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
                value: parentId,
                isDense: true, isExpanded: true,
                hint: const Text('None (top level)', style: TextStyle(fontSize: 11, color: kT40)),
                dropdownColor: kCard,
                style: const TextStyle(fontSize: 11, color: Colors.white),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('None (top level)')),
                  for (final p in parentOptions)
                    DropdownMenuItem<String?>(value: p['id'] as String, child: Text(p['title'] as String? ?? '')),
                ],
                onChanged: (v) => setS(() => parentId = v),
              )),
            ),
            if (templates.isNotEmpty) ...[
              const SizedBox(height: 10),
              const FieldLabel('TEMPLATE (OPTIONAL)'),
              const SizedBox(height: 4),
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(color: kInput, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(3)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
                  value: selectedTemplateId,
                  isDense: true, isExpanded: true,
                  hint: const Text('Start from a template…', style: TextStyle(fontSize: 11, color: kT40)),
                  dropdownColor: kCard,
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                  items: [
                    for (final t in templates)
                      DropdownMenuItem<String?>(value: t['id'] as String, child: Text(t['name'] as String? ?? '')),
                  ],
                  onChanged: (v) {
                    final t = templates.firstWhere((t) => t['id'] == v, orElse: () => const {});
                    setS(() {
                      selectedTemplateId = v;
                      contentCtrl.text = t['content'] as String? ?? '';
                    });
                  },
                )),
              ),
            ],
            const SizedBox(height: 10),
            const FieldLabel('CONTENT'),
            const SizedBox(height: 4),
            RefInput(contentCtrl, hint: 'Markdown content... use [[Page Title]] to link another page', maxLines: 8),
            if (isGm) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setS(() => gmOnly = !gmOnly),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(gmOnly ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: kT68),
                  const SizedBox(width: 6),
                  const Text('GM only', style: TextStyle(fontSize: 11, color: kT68)),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
              const SizedBox(width: 8),
              PillButton('Save', () async {
                final body = {
                  'title': titleCtrl.text.trim(),
                  'content': contentCtrl.text,
                  'is_gm_only': gmOnly,
                  'parent_id': parentId,
                };
                if (existing == null) {
                  await apiPost('/campaigns/$gameId/wiki', body);
                } else {
                  await apiPatch('/campaigns/$gameId/wiki/${existing['id']}', body);
                }
                ref.invalidate(campaignWikiProvider(gameId));
                if (ctx.mounted) Navigator.pop(ctx);
              }),
            ]),
          ]),
        ),
      ),
    )),
  );
}
