import 'dart:math' show min, max;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/client.dart';
import '../../providers/assets_provider.dart';
import '../../ui/chrome.dart';

class TokensScreen extends ConsumerStatefulWidget {
  /// True when shown as its own `/tokens` route (adds the page banner + title);
  /// false when embedded elsewhere.
  final bool standalone;
  const TokensScreen({super.key, this.standalone = false});

  @override
  ConsumerState<TokensScreen> createState() => _TokensScreenState();
}

class _TokensScreenState extends ConsumerState<TokensScreen> {
  String? _selectedFolder;
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _favoritesOnly = false;
  String? _tagFilter;
  Set<String> _selectedIds = {};
  int? _anchorIndex;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  AssetFilter get _filter => (
        folder: _selectedFolder,
        q: _query.isEmpty ? null : _query,
        tag: _tagFilter,
        favoritesOnly: _favoritesOnly,
        page: 1,
      );

  void _onTileTap(BuildContext context, List<Map<String, dynamic>> items, int index) {
    final hk = HardwareKeyboard.instance;
    final id = items[index]['id'] as String;
    if (hk.isShiftPressed && _anchorIndex != null) {
      final lo = min(_anchorIndex!, index), hi = max(_anchorIndex!, index);
      setState(() => _selectedIds = {for (var i = lo; i <= hi; i++) items[i]['id'] as String});
      return;
    }
    if (hk.isControlPressed || hk.isMetaPressed) {
      setState(() {
        _anchorIndex = index;
        _selectedIds.contains(id) ? _selectedIds.remove(id) : _selectedIds.add(id);
      });
      return;
    }
    if (_selectedIds.isNotEmpty) {
      setState(() => _selectedIds = {});
      return;
    }
    _anchorIndex = index;
    _showTokenDialog(context, items[index], () {
      ref.invalidate(tokensProvider(_filter));
      ref.invalidate(tokenTagsProvider);
    });
  }

  List<Map<String, dynamic>> get _currentItems =>
      List<Map<String, dynamic>>.from((ref.read(tokensProvider(_filter)).value?['items'] as List?) ?? const []);

  Future<void> _bulkAddTag(String tag) async {
    final selected = _currentItems.where((m) => _selectedIds.contains(m['id']));
    await Future.wait([
      for (final m in selected)
        if (!((m['tags'] as List?) ?? const []).cast<String>().contains(tag))
          apiPatch('/assets/tokens/${m['id']}/tags', {'tags': [...((m['tags'] as List?) ?? const []).cast<String>(), tag]}),
    ]);
    ref.invalidate(tokensProvider(_filter));
    ref.invalidate(tokenTagsProvider);
    setState(() => _selectedIds = {});
  }

  Future<void> _bulkRemoveTag(String tag) async {
    final selected = _currentItems.where((m) => _selectedIds.contains(m['id']));
    await Future.wait([
      for (final m in selected)
        if (((m['tags'] as List?) ?? const []).cast<String>().contains(tag))
          apiPatch('/assets/tokens/${m['id']}/tags',
              {'tags': ((m['tags'] as List?) ?? const []).cast<String>().where((t) => t != tag).toList()}),
    ]);
    ref.invalidate(tokensProvider(_filter));
    ref.invalidate(tokenTagsProvider);
    setState(() => _selectedIds = {});
  }

  Future<void> _bulkFavorite(bool value) async {
    final ids = List<String>.from(_selectedIds);
    await Future.wait([
      for (final id in ids)
        value
            ? apiPost('/favorites', {'item_type': 'token', 'item_id': id})
            : apiDelete('/favorites/token/$id'),
    ]);
    ref.invalidate(tokensProvider(_filter));
    setState(() => _selectedIds = {});
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(tokenFoldersProvider);
    final tokensAsync = ref.watch(tokensProvider(_filter));
    final tagsAsync = ref.watch(tokenTagsProvider);

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: kBg,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, widget.standalone ? 16 : 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.standalone)
              const SanctumPageHeader('Tokens', subtitle: 'Character and monster tokens.'),
            Row(children: [
              Expanded(child: RefInput(_searchCtrl, hint: 'Search tokens…',
                  onChanged: (v) => setState(() => _query = v))),
              const SizedBox(width: 10),
              ChoiceChipX('Favorites only', _favoritesOnly, () => setState(() => _favoritesOnly = !_favoritesOnly)),
            ]),
            tagsAsync.maybeWhen(
              data: (tags) => tags.isEmpty ? const SizedBox.shrink() : Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final t in tags)
                    ChoiceChipX(t, _tagFilter == t, () => setState(() => _tagFilter = _tagFilter == t ? null : t)),
                ]),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
          ]),
        ),
        if (_selectedIds.isNotEmpty)
          _BulkActionBar(
            count: _selectedIds.length,
            allTags: tagsAsync.value ?? const [],
            onClear: () => setState(() => _selectedIds = {}),
            onAddTag: (tag) => _bulkAddTag(tag),
            onRemoveTag: (tag) => _bulkRemoveTag(tag),
            onFavorite: () => _bulkFavorite(true),
            onUnfavorite: () => _bulkFavorite(false),
          ),
        Expanded(
          child: Row(children: [
            foldersAsync.when(
              data: (folders) => folders.isEmpty
                  ? const SizedBox.shrink()
                  : _FolderRail(folders: folders, selected: _selectedFolder,
                      onSelect: (f) => setState(() => _selectedFolder = f)),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            Expanded(
              child: tokensAsync.when(
                loading: () => const Center(child: CircularProgressIndicator(color: kAccent)),
                error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: kT55))),
                data: (data) {
                  final items = List<Map<String, dynamic>>.from(data['items'] as List);
                  if (items.isEmpty) {
                    return _favoritesOnly
                        ? const _EmptyState(glyph: '⭐', title: 'No favorited tokens yet.',
                            subtitle: 'Star a token to see it here.')
                        : _tagFilter != null
                            ? _EmptyState(glyph: '🏷', title: 'No tokens tagged "$_tagFilter".',
                                subtitle: 'Try a different tag.')
                            : const _EmptyState(glyph: '🧍', title: 'No tokens yet.',
                                subtitle: 'Add image files to /library/tokens/ and run a scan.');
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(0, 0, 24, 24),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 140, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 1,
                    ),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _TokenTile(
                      token: items[i],
                      selected: _selectedIds.contains(items[i]['id']),
                      onTap: () => _onTileTap(context, items, i),
                      onFavoriteChanged: () {
                        ref.invalidate(tokensProvider(_filter));
                        ref.invalidate(tokenTagsProvider);
                      },
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _FolderRail extends StatelessWidget {
  final List<String> folders;
  final String? selected;
  final ValueChanged<String?> onSelect;
  const _FolderRail({required this.folders, this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) => Container(
        width: 200,
        padding: const EdgeInsets.only(right: 12),
        child: ListView(children: [
          _FolderRow(label: 'All Tokens', selected: selected == null, onTap: () => onSelect(null)),
          const SizedBox(height: 8),
          for (final f in folders) _FolderRow(label: f, selected: selected == f, onTap: () => onSelect(f)),
        ]),
      );
}

class _FolderRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FolderRow({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? const Color(0x668C2F2F) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: selected ? Colors.white : kT68)),
        ),
      );
}

class _TokenTile extends StatelessWidget {
  final Map<String, dynamic> token;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFavoriteChanged;
  const _TokenTile({required this.token, required this.selected, required this.onTap, required this.onFavoriteChanged});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(8),
            border: selected ? Border.all(color: kAccent, width: 3) : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ClipOval(
                    child: Image.network('/api/assets/tokens/${token['id']}/file', fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(child: Text('🧍', style: TextStyle(fontSize: 28, color: kT40)))),
                  ),
                ),
                Positioned(
                  top: 2, right: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(20)),
                    child: FavoriteButton(itemType: 'token', itemId: token['id'] as String, initialValue: token['is_favorited'] == true, size: 16, onChanged: onFavoriteChanged),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 2, left: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(20)),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.check, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Column(children: [
                Text(token['filename'] as String? ?? '', overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10, color: kT68)),
                _TileTags(token['tags']),
              ]),
            ),
          ]),
        ),
      );
}

void _showTokenDialog(BuildContext context, Map<String, dynamic> token, VoidCallback onChanged) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: kNav,
            child: Row(children: [
              Expanded(child: Text(token['filename'] as String? ?? '', overflow: TextOverflow.ellipsis,
                  style: serif(14, color: kT100))),
              InkWell(onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, size: 18, color: kT55)),
            ]),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: TagEditor(
              itemType: 'token',
              itemId: token['id'] as String,
              initialTags: ((token['tags'] as List?) ?? []).cast<String>(),
              onChanged: onChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Image.network('/api/assets/tokens/${token['id']}/file', fit: BoxFit.contain),
          ),
        ]),
      ),
    ),
  );
}

// Compact tag chips shown on an asset tile (read-only; edit via the dialog).
class _TileTags extends StatelessWidget {
  final Object? raw;
  const _TileTags(this.raw);
  @override
  Widget build(BuildContext context) {
    final tags = ((raw as List?) ?? const []).cast<String>();
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: [
        for (final t in tags.take(3))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: kChipBox, borderRadius: BorderRadius.circular(3)),
            child: Text(t, style: const TextStyle(fontSize: 9, color: kT68)),
          ),
        if (tags.length > 3)
          Text('+${tags.length - 3}', style: const TextStyle(fontSize: 9, color: kT45)),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String glyph, title, subtitle;
  const _EmptyState({required this.glyph, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(glyph, style: const TextStyle(fontSize: 40, color: kT40)),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(fontSize: 13, color: kT55)),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: kT45)),
        ]),
      );
}

/// Appears when one or more tiles are selected (ctrl/cmd-click to toggle,
/// shift-click to range-select). Bulk ops reuse the same per-item tag/favorite
/// endpoints the single-item TagEditor/FavoriteButton already call — no new
/// backend endpoints, just N calls fired together.
class _BulkActionBar extends StatelessWidget {
  final int count;
  final List<String> allTags;
  final VoidCallback onClear;
  final ValueChanged<String> onAddTag;
  final ValueChanged<String> onRemoveTag;
  final VoidCallback onFavorite;
  final VoidCallback onUnfavorite;
  const _BulkActionBar({
    required this.count,
    required this.allTags,
    required this.onClear,
    required this.onAddTag,
    required this.onRemoveTag,
    required this.onFavorite,
    required this.onUnfavorite,
  });

  Future<void> _promptTag(BuildContext context, ValueChanged<String> onSubmit) async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(8)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FieldLabel('TAG NAME'),
            const SizedBox(height: 6),
            RefInput(ctrl, hint: 'e.g. goblin'),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
              const SizedBox(width: 8),
              PillButton('Add', () => Navigator.pop(ctx, ctrl.text)),
            ]),
          ]),
        ),
      ),
    );
    ctrl.dispose();
    final v = value?.trim() ?? '';
    if (v.isNotEmpty) onSubmit(v);
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: kWell, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('$count selected', style: const TextStyle(fontSize: 12, color: kT82)),
          PillButtonOutlined('Clear', onClear, compact: true),
          PillButtonOutlined('Add tag', () => _promptTag(context, onAddTag), compact: true),
          if (allTags.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Remove tag',
              onSelected: onRemoveTag,
              itemBuilder: (_) => [for (final t in allTags) PopupMenuItem(value: t, child: Text(t))],
              child: const PillButtonOutlined('Remove tag', null, compact: true),
            ),
          PillButtonOutlined('☆ Favorite', onFavorite, compact: true),
          PillButtonOutlined('☆ Unfavorite', onUnfavorite, compact: true),
        ]),
      );
}
