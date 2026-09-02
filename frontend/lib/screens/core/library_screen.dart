// Library home — the site's real landing page. Systems grid is pixel-exact
// per the design handoff (isLibrary/isLibraryGrid, Sanctum TTRPG App.dc.html
// L46-78). Per-system landing page (book browsing) has no equivalent in the
// mockup at all — the design handoff only ever covered Fuzion's tooling — so
// that part is real functionality styled to match, not a ported design.

import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../api/client.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../ui/chrome.dart';
import '../../ui/icons.dart';
import '../../ui/view_prefs.dart';
import '../../game_systems.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _filter = '';
  String _bookQuery = '';
  Timer? _debounce;
  late LibraryView _view = readLibraryView();
  late SystemSort _sort = readSystemSort();
  String? _genre;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _uploadBook(BuildContext context) async {
    final systemCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Add a book', style: serif(15, color: kT100)),
              const SizedBox(height: 4),
              const Text('The PDF is filed under this game system and indexed for search.',
                  style: TextStyle(fontSize: 11, color: kT55)),
              const SizedBox(height: 12),
              const FieldLabel('GAME SYSTEM'),
              const SizedBox(height: 4),
              RefInput(systemCtrl, hint: 'e.g. Pathfinder 2e (new or existing)'),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Choose PDF…', () {
                  final sys = systemCtrl.text.trim();
                  if (sys.isEmpty) return;
                  Navigator.pop(ctx);
                  pickAndUpload(
                    context,
                    url: '/library/books',
                    accept: '.pdf,application/pdf',
                    fields: {'system': sys},
                    onDone: () {
                      ref.invalidate(gameSystemsProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Book uploaded — indexing in the background.')),
                        );
                      }
                    },
                  );
                }),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _presets() {
    final raw = ref.watch(userPreferencesProvider).value?['library.presets'];
    return (raw is List) ? raw.cast<Map<String, dynamic>>() : const [];
  }

  Future<void> _writePresets(List<Map<String, dynamic>> presets) async {
    await saveUserPreference('library.presets', presets);
    ref.invalidate(userPreferencesProvider);
  }

  void _applyPreset(Map<String, dynamic> p, List<String> genres) {
    final g = p['genre'] as String?;
    setState(() {
      _view = p['view'] == 'list' ? LibraryView.list : LibraryView.grid;
      _sort = p['sort'] == 'books' ? SystemSort.books : SystemSort.name;
      _genre = (g != null && genres.contains(g)) ? g : null;
    });
    writeLibraryView(_view);
    writeSystemSort(_sort);
  }

  Future<void> _saveCurrentPreset() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Save this view', style: serif(15, color: kT100)),
              const SizedBox(height: 4),
              Text(
                '${_view == LibraryView.list ? 'List' : 'Grid'} · sort by '
                '${_sort == SystemSort.books ? 'books' : 'name'}'
                '${_genre != null ? ' · $_genre' : ''}',
                style: const TextStyle(fontSize: 11, color: kT55),
              ),
              const SizedBox(height: 12),
              RefInput(nameCtrl, hint: 'Preset name'),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Save', () => Navigator.pop(ctx, nameCtrl.text.trim())),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    final next = [
      for (final p in _presets()) if (p['name'] != name) p,
      {
        'name': name,
        'view': _view == LibraryView.list ? 'list' : 'grid',
        'sort': _sort == SystemSort.books ? 'books' : 'name',
        if (_genre != null) 'genre': _genre,
      },
    ];
    await _writePresets(next);
  }

  Widget _presetBar(List<String> genres) {
    final presets = _presets();
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      const Text('Presets', style: TextStyle(fontSize: 10, color: kT45)),
      for (final p in presets)
        _PresetChip(
          label: p['name'] as String? ?? '?',
          onApply: () => _applyPreset(p, genres),
          onDelete: () => _writePresets([for (final q in presets) if (q['name'] != p['name']) q]),
        ),
      InkWell(
        onTap: _saveCurrentPreset,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: kBorderDim),
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text('+ Save view', style: TextStyle(fontSize: 10, color: kLink)),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final systemsAsync = ref.watch(gameSystemsProvider);
    // Cross-system book search (no `system` param) — the box also does
    // double duty filtering the systems grid below by name, but a real
    // library search should find content by title/author/full-text
    // regardless of which system it's filed under, not just system names.
    final bookSearchAsync = _bookQuery.isEmpty ? null : ref.watch(booksProvider(BookQuery(q: _bookQuery)));

    return PageChrome(
      child: systemsAsync.when(
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())),
        error: (e, _) => Text('$e', style: const TextStyle(color: kFail)),
        data: (systems) {
          final genres = systems
              .map((s) => s['genre'])
              .whereType<String>()
              .where((g) => g.trim().isNotEmpty)
              .toSet()
              .toList()
            ..sort();
          var filtered = systems.where((s) =>
              (s['name'] as String).toLowerCase().contains(_filter.toLowerCase()) &&
              (_genre == null || s['genre'] == _genre)).toList();
          filtered.sort((a, b) => _sort == SystemSort.books
              ? (b['book_count'] as int? ?? 0).compareTo(a['book_count'] as int? ?? 0)
              : (a['name'] as String).compareTo(b['name'] as String));

          return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SanctumBanner(),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Game Systems', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                  fontFamily: 'Georgia', color: kT100)),
              if (ref.watch(authProvider).value?.isAdmin == true)
                Row(children: [
                  PillButtonOutlined('Scan', () async {
                    try {
                      await apiPost('/library/scan');
                      ref.invalidate(gameSystemsProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Scanned — new files indexing in the background.')));
                      }
                    } on ApiException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  }),
                  const SizedBox(width: 8),
                  PillButtonOutlined('+ Add book', () => _uploadBook(context)),
                ]),
            ]),
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.only(bottom: 10),
              margin: const EdgeInsets.only(bottom: 18),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kBorderDim))),
              child: Row(children: [
                const Text('🔍', style: TextStyle(fontSize: 13, color: kT55)),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  onChanged: (v) {
                    setState(() => _filter = v);
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () {
                      if (mounted) setState(() => _bookQuery = v);
                    });
                  },
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: const InputDecoration(hintText: 'Search your library…',
                      hintStyle: TextStyle(fontSize: 13, color: kT55), border: InputBorder.none, isDense: true),
                )),
              ]),
            ),
            if (bookSearchAsync != null) ...[
              _BookSearchResults(
                query: _bookQuery,
                async: bookSearchAsync,
                systems: systems,
                onFavoriteChanged: () => ref.invalidate(booksProvider(BookQuery(q: _bookQuery))),
              ),
              const SizedBox(height: 20),
            ],
            // Only needed to separate from the search results block above it —
            // redundant with the page's own "Game Systems" heading otherwise.
            if (bookSearchAsync != null) ...[
              const Text('Browse by System', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kAccent, letterSpacing: 0.5)),
              const SizedBox(height: 10),
            ],
            _ViewControls(
              view: _view,
              sort: _sort,
              genres: genres,
              activeGenre: _genre,
              onView: (v) => setState(() { _view = v; writeLibraryView(v); }),
              onSort: (s) => setState(() { _sort = s; writeSystemSort(s); }),
              onGenre: (g) => setState(() => _genre = _genre == g ? null : g),
            ),
            const SizedBox(height: 10),
            _presetBar(genres),
            const SizedBox(height: 14),
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No systems match those filters.',
                    style: TextStyle(fontSize: 12, color: kT45)),
              )
            else if (_view == LibraryView.list)
              Column(children: [for (final s in filtered) _SystemListRow(system: s)])
            else
              LayoutBuilder(builder: (context, constraints) {
                // grid-template-columns: repeat(auto-fill, minmax(230px,1fr)) —
                // as many 230px+ columns as fit, each stretched to fill the row.
                const spacing = 10.0, minTileWidth = 230.0;
                final cols = ((constraints.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(1, 999);
                final tileWidth = (constraints.maxWidth - spacing * (cols - 1)) / cols;
                return Wrap(spacing: spacing, runSpacing: spacing, children: [
                  for (final s in filtered) _SystemCard(system: s, width: tileWidth),
                  DashedRRectBorder(
                    radius: 8,
                    child: Container(
                      width: tileWidth,
                      constraints: const BoxConstraints(minHeight: 76),
                      padding: const EdgeInsets.all(14),
                      alignment: Alignment.center,
                      child: const Text('+ Add System', style: TextStyle(fontSize: 12, color: kT55)),
                    ),
                  ),
                ]);
              }),
          ]));
        },
      ),
    );
  }
}

class _BookSearchResults extends StatelessWidget {
  final String query;
  final AsyncValue<Map<String, dynamic>> async;
  final List<Map<String, dynamic>> systems;
  final VoidCallback onFavoriteChanged;
  const _BookSearchResults({required this.query, required this.async, required this.systems, required this.onFavoriteChanged});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Books matching "$query"', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kAccent, letterSpacing: 0.5)),
        const SizedBox(height: 10),
        async.when(
          loading: () => const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('$e', style: const TextStyle(color: kFail)),
          data: (data) {
            final books = (data['books'] as List).cast<Map<String, dynamic>>();
            if (books.isEmpty) {
              return Text('No books match "$query".', style: const TextStyle(fontSize: 12, color: kT45));
            }
            return Column(children: [
              for (final b in books)
                _BookRow(
                  book: b,
                  onFavoriteChanged: onFavoriteChanged,
                  systemName: systems.where((s) => s['id'] == b['game_system_id']).firstOrNull?['name'] as String?,
                ),
            ]);
          },
        ),
      ]);
}

class _SystemCard extends StatelessWidget {
  final Map<String, dynamic> system;
  final double width;
  const _SystemCard({required this.system, required this.width});

  @override
  Widget build(BuildContext context) {
    final name = system['name'] as String;
    final books = system['book_count'] as int? ?? 0;

    return InkWell(
      // Every system card leads to the Library's own per-system book
      // browsing page — no exceptions. Fuzion's game-management tooling
      // (Games/Characters/Sessions) is reached via the "My Games"/"My
      // Characters" sidebar destinations instead, same as every other
      // cross-system aggregate on this site — clicking through the Library
      // should never be a shortcut into that.
      onTap: () => context.go('/library/system/${system['id']}'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0x661E1530),
          border: Border.all(color: kBorderDim),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Container(
            width: 56, height: 76,
            decoration: BoxDecoration(color: kWell, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(4)),
            alignment: Alignment.center,
            child: SystemIcon(iconKeyForSystem(name), size: 28),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kT100)),
            const SizedBox(height: 2),
            Text('$books books', style: const TextStyle(fontSize: 11, color: kT68)),
          ])),
          // Every card is identical now, Fuzion included — no accent
          // border, no badge, same plain chevron (2026-08-10 correction:
          // the Library grid is books-only for every system, uniformly).
          const Text('›', style: TextStyle(fontSize: 13, color: kT55)),
        ]),
      ),
    );
  }
}

class _ViewControls extends StatelessWidget {
  final LibraryView view;
  final SystemSort sort;
  final List<String> genres;
  final String? activeGenre;
  final ValueChanged<LibraryView> onView;
  final ValueChanged<SystemSort> onSort;
  final ValueChanged<String> onGenre;
  const _ViewControls({
    required this.view,
    required this.sort,
    required this.genres,
    required this.activeGenre,
    required this.onView,
    required this.onSort,
    required this.onGenre,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _seg('Grid', view == LibraryView.grid, () => onView(LibraryView.grid)),
        _seg('List', view == LibraryView.list, () => onView(LibraryView.list)),
        const SizedBox(width: 4),
        const Text('Sort', style: TextStyle(fontSize: 10, color: kT45)),
        _seg('Name', sort == SystemSort.name, () => onSort(SystemSort.name)),
        _seg('Books', sort == SystemSort.books, () => onSort(SystemSort.books)),
      ]),
      if (genres.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final g in genres) ChoiceChipX(g, activeGenre == g, () => onGenre(g)),
        ]),
      ],
    ]);
  }

  Widget _seg(String label, bool active, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : Colors.transparent,
            border: Border.all(color: active ? kAccent : kBorderDim),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: active ? Colors.white : kT68)),
        ),
      );
}

class _PresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onApply;
  final VoidCallback onDelete;
  const _PresetChip({required this.label, required this.onApply, required this.onDelete});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: kChipBox,
          border: Border.all(color: kBorderDim),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: onApply,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Text(label, style: const TextStyle(fontSize: 10, color: kT82)),
            ),
          ),
          InkWell(
            onTap: onDelete,
            child: const Padding(
              padding: EdgeInsets.fromLTRB(2, 4, 6, 4),
              child: Icon(Icons.close, size: 11, color: kT45),
            ),
          ),
        ]),
      );
}

class _SystemListRow extends StatelessWidget {
  final Map<String, dynamic> system;
  const _SystemListRow({required this.system});

  @override
  Widget build(BuildContext context) {
    final name = system['name'] as String;
    final books = system['book_count'] as int? ?? 0;
    final genre = system['genre'] as String?;
    return InkWell(
      onTap: () => context.go('/library/system/${system['id']}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: kCard,
          border: Border.all(color: kBorderDim),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          SystemIcon(iconKeyForSystem(name), size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kT100))),
          if (genre != null && genre.isNotEmpty) ...[
            Text(genre, style: const TextStyle(fontSize: 10, color: kT45)),
            const SizedBox(width: 12),
          ],
          Text('$books ${books == 1 ? 'book' : 'books'}',
              style: const TextStyle(fontSize: 11, color: kT68)),
          const SizedBox(width: 8),
          const Text('›', style: TextStyle(fontSize: 13, color: kT55)),
        ]),
      ),
    );
  }
}

// ── Per-system landing page (real book browsing, no mockup equivalent) ─────

const _categoryOrder = [
  'core', 'supplement', 'adventure', 'character-sheet', 'setting', 'reference',
  'homebrew', 'unofficial', 'the-rifter', 'world-books', 'dimension-books', 'coalition-war', 'cenotaphium',
];

String _categoryLabel(String? cat) => switch (cat) {
      'core' => 'Core Rulebooks', 'supplement' => 'Supplements', 'adventure' => 'Adventures',
      'character-sheet' => 'Character Sheets', 'setting' => 'Setting Books', 'reference' => 'Reference',
      'homebrew' => 'Homebrew', 'unofficial' => 'Unofficial', 'the-rifter' => 'The Rifter',
      'world-books' => 'World Books', 'dimension-books' => 'Dimension Books',
      'coalition-war' => 'Coalition Wars', 'cenotaphium' => 'Cenotaphium',
      _ => cat ?? 'Uncategorized',
    };

int _categoryRank(String? cat) {
  final i = _categoryOrder.indexOf(cat ?? '');
  return i < 0 ? 99 : i;
}

class SystemLandingScreen extends ConsumerStatefulWidget {
  final String systemId;
  const SystemLandingScreen({super.key, required this.systemId});
  @override
  ConsumerState<SystemLandingScreen> createState() => _SystemLandingScreenState();
}

class _SystemLandingScreenState extends ConsumerState<SystemLandingScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _favoritesOnly = false;
  String? _tagFilter;
  Timer? _debounce;
  late LibraryView _view = readBookView();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final systemsAsync = ref.watch(gameSystemsProvider);
    // Empty query: full unfiltered list for category-grouped folder browsing.
    // Non-empty query: hit the backend search instead of filtering client-side
    // — it matches each book's own extracted page text (including OCR'd scans),
    // not just title/author, so a rules term finds the book that mentions it.
    final booksAsync = _query.isEmpty
        ? ref.watch(systemBooksProvider((systemId: widget.systemId, tag: _tagFilter)))
        : ref.watch(booksProvider(BookQuery(q: _query, system: widget.systemId, tag: _tagFilter)));
    final tagsAsync = ref.watch(bookTagsProvider);

    return PageChrome(
      child: systemsAsync.when(
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())),
        error: (e, _) => Text('$e', style: const TextStyle(color: kFail)),
        data: (systems) {
          final system = systems.where((s) => s['id'] == widget.systemId).firstOrNull;
          final name = system?['name'] as String? ?? 'System';
          final count = system?['book_count'] as int? ?? 0;
          final isAdmin = ref.watch(authProvider).value?.isAdmin ?? false;

          return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => context.go('/library'),
              child: const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('← Library', style: TextStyle(fontSize: 11, color: kLink))),
            ),
            Container(
              padding: const EdgeInsets.only(bottom: 10),
              margin: const EdgeInsets.only(bottom: 24),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kBorderDim))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(name, style: serif(20, color: kT100)),
                    if (isAdmin && system != null) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _editSystem(context, ref, system),
                        child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.edit_outlined, size: 14, color: kT55)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text('$count ${count == 1 ? 'book' : 'books'} in library', style: const TextStyle(fontSize: 11, color: kT68)),
                ])),
                Padding(padding: const EdgeInsets.only(bottom: 10), child: TagButton('⬇ Download ZIP', () => _downloadZip(widget.systemId))),
              ]),
            ),
            if (gameSystemModules.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.construction, size: 14, color: kT55),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    "This page is real book browsing. Game-management tools (Games, Characters, Sessions) live in the sidebar, not here.",
                    style: const TextStyle(fontSize: 11, color: kT55),
                  )),
                ]),
              ),
            Row(children: [
              RefInput(_searchCtrl, hint: 'Search in $name…', width: 320, onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () { if (mounted) setState(() => _query = v); });
              }),
              const SizedBox(width: 10),
              ChoiceChipX('Favorites only', _favoritesOnly, () => setState(() => _favoritesOnly = !_favoritesOnly)),
              const Spacer(),
              _ViewToggle(
                view: _view,
                onChanged: (v) => setState(() { _view = v; writeBookView(v); }),
              ),
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
            const SizedBox(height: 16),
            booksAsync.when(
              loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Text('$e', style: const TextStyle(color: kFail)),
              data: (data) {
                var books = (data['books'] as List).cast<Map<String, dynamic>>();
                if (_favoritesOnly) books = books.where((b) => b['is_favorited'] == true).toList();
                if (books.isEmpty) {
                  return Text(
                    _favoritesOnly
                        ? 'No favorited books in $name yet.'
                        : _tagFilter != null
                            ? 'No books tagged "$_tagFilter" in $name.'
                            : (_query.isNotEmpty ? 'No books match "$_query"' : 'No books in this system yet.'),
                    style: const TextStyle(fontSize: 12, color: kT45),
                  );
                }
                final groups = <String?, List<Map<String, dynamic>>>{};
                for (final b in books) {
                  groups.putIfAbsent(b['category'] as String?, () => []).add(b);
                }
                final sortedGroups = groups.entries.toList()..sort((a, b) => _categoryRank(a.key).compareTo(_categoryRank(b.key)));
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final g in sortedGroups)
                    _CategorySection(category: g.key, books: g.value,
                        grid: _view == LibraryView.grid, onFavoriteChanged: _refreshBooks),
                ]);
              },
            ),
          ]));
        },
      ),
    );
  }

  void _downloadZip(String systemId) {
    html.AnchorElement(href: '/api/library/systems/$systemId/download')..click();
  }

  Future<void> _editSystem(BuildContext context, WidgetRef ref, Map<String, dynamic> system) async {
    final nameCtrl = TextEditingController(text: system['name'] as String? ?? '');
    final genreCtrl = TextEditingController(text: system['genre'] as String? ?? '');
    final builderCtrl = TextEditingController(text: system['character_builder_url'] as String? ?? '');
    String? selectedParentId = system['parent_id'] as String?;
    // One-time snapshot for the picker — the list doesn't need to react to
    // changes while this dialog is open.
    final allSystems = (ref.read(gameSystemsProvider).valueOrNull ?? [])
        .where((s) => s['id'] != system['id'])
        .toList();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Dialog(
        backgroundColor: kCard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Edit System', style: serif(15)),
              const SizedBox(height: 12),
              const FieldLabel('NAME'),
              const SizedBox(height: 4),
              RefInput(nameCtrl, hint: 'System name'),
              const SizedBox(height: 10),
              const FieldLabel('GENRE'),
              const SizedBox(height: 4),
              RefInput(genreCtrl, hint: 'e.g. Sci-fi, Fantasy, Horror'),
              const SizedBox(height: 10),
              const FieldLabel('CHARACTER BUILDER URL'),
              const SizedBox(height: 4),
              RefInput(builderCtrl, hint: 'https://…'),
              const SizedBox(height: 10),
              const FieldLabel('PARENT SYSTEM (OPTIONAL)'),
              const SizedBox(height: 4),
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(color: kInput, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(3)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: selectedParentId,
                    isDense: true,
                    isExpanded: true,
                    dropdownColor: kCard,
                    style: const TextStyle(fontSize: 12, color: kT100),
                    hint: const Text('None', style: TextStyle(fontSize: 12, color: kT55)),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final s in allSystems)
                        DropdownMenuItem<String?>(value: s['id'] as String, child: Text(s['name'] as String? ?? '')),
                    ],
                    onChanged: (v) => setS(() => selectedParentId = v),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                PillButton('Save', () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  await apiPatch('/library/systems/${system['id']}', {
                    'name': name,
                    'genre': genreCtrl.text.trim().isEmpty ? null : genreCtrl.text.trim(),
                    'character_builder_url': builderCtrl.text.trim().isEmpty ? null : builderCtrl.text.trim(),
                    'parent_id': selectedParentId,
                  });
                  ref.invalidate(gameSystemsProvider);
                  if (ctx.mounted) Navigator.pop(ctx);
                }),
              ]),
            ]),
          ),
        ),
      )),
    );
  }

  // Re-fetch after a favorite toggle so the "Favorites only" filter (which
  // reads is_favorited off the already-fetched list) doesn't judge new stars
  // against a stale snapshot.
  void _refreshBooks() {
    ref.invalidate(systemBooksProvider((systemId: widget.systemId, tag: _tagFilter)));
    if (_query.isNotEmpty) ref.invalidate(booksProvider(BookQuery(q: _query, system: widget.systemId, tag: _tagFilter)));
    ref.invalidate(bookTagsProvider);
  }
}

class _ViewToggle extends StatelessWidget {
  final LibraryView view;
  final ValueChanged<LibraryView> onChanged;
  const _ViewToggle({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        _btn(Icons.view_list, view == LibraryView.list, () => onChanged(LibraryView.list)),
        const SizedBox(width: 4),
        _btn(Icons.grid_view, view == LibraryView.grid, () => onChanged(LibraryView.grid)),
      ]);

  Widget _btn(IconData icon, bool active, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: active ? const Color(0x668C2F2F) : Colors.transparent,
            border: Border.all(color: active ? kAccent : kBorderDim),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(icon, size: 14, color: active ? Colors.white : kT55),
        ),
      );
}

class _CategorySection extends StatefulWidget {
  final String? category;
  final List<Map<String, dynamic>> books;
  final bool grid;
  final VoidCallback onFavoriteChanged;
  const _CategorySection({required this.category, required this.books, this.grid = false, required this.onFavoriteChanged});
  @override
  State<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends State<_CategorySection> {
  late bool _expanded = _categoryRank(widget.category) < 4;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(_expanded ? Icons.folder_open : Icons.folder, size: 14, color: kAccent),
              const SizedBox(width: 8),
              Text(_categoryLabel(widget.category), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kAccent, letterSpacing: 0.5)),
              const SizedBox(width: 8),
              Text('(${widget.books.length})', style: const TextStyle(fontSize: 11, color: kT45)),
              const Spacer(),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: kT45),
            ]),
          ),
        ),
        if (_expanded)
          widget.grid
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final b in widget.books) _BookCoverTile(book: b, onFavoriteChanged: widget.onFavoriteChanged),
                  ]),
                )
              : Column(children: [
                  for (final b in widget.books) _BookRow(book: b, onFavoriteChanged: widget.onFavoriteChanged),
                ]),
        const SizedBox(height: 6),
      ]);
}

class _BookCoverTile extends ConsumerWidget {
  final Map<String, dynamic> book;
  final VoidCallback onFavoriteChanged;
  const _BookCoverTile({required this.book, required this.onFavoriteChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = book['id'] as String;
    return SizedBox(
      width: 116,
      child: InkWell(
        onTap: () => context.push('/library/$id'),
        borderRadius: BorderRadius.circular(4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: book['has_thumbnail'] == true
                    ? Image.network('/api/library/books/$id/thumbnail', fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const ColoredBox(color: kInput, child: Icon(Icons.menu_book, size: 20, color: kT45)))
                    : const ColoredBox(color: kInput, child: Icon(Icons.menu_book, size: 20, color: kT45)),
              ),
            ),
            Positioned(
              top: 0, right: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
                child: FavoriteButton(itemType: 'book', itemId: id, initialValue: book['is_favorited'] == true, onChanged: onFavoriteChanged),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(book['title'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: kT82, height: 1.25)),
        ]),
      ),
    );
  }
}

class _BookRow extends ConsumerWidget {
  final Map<String, dynamic> book;
  final VoidCallback onFavoriteChanged;
  final String? systemName;
  const _BookRow({required this.book, required this.onFavoriteChanged, this.systemName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(authProvider).value?.isAdmin ?? false;
    final pages = book['page_count'];
    final year = book['year'];
    final authors = (book['authors'] as List?)?.cast<String>() ?? [];
    final isBookmarked = book['is_bookmarked'] == true;

    return InkWell(
      onTap: () => context.push('/library/${book['id']}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              width: 32, height: 44,
              child: book['has_thumbnail'] == true
                  ? Image.network('/api/library/books/${book['id']}/thumbnail', fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: kInput, child: Icon(Icons.menu_book, size: 14, color: kT45)))
                  : const ColoredBox(color: kInput, child: Icon(Icons.menu_book, size: 14, color: kT45)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(book['title'] as String? ?? '', style: const TextStyle(fontSize: 12, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (authors.isNotEmpty) Text(authors.join(', '), style: const TextStyle(fontSize: 10, color: kT55), maxLines: 1, overflow: TextOverflow.ellipsis),
            Row(children: [
              if (systemName != null) Text(systemName!, style: const TextStyle(fontSize: 10, color: kAccent)),
              if (systemName != null && (pages != null || year != null)) const Text('  ·  ', style: TextStyle(fontSize: 10, color: kT45)),
              if (pages != null) Text('$pages pp', style: const TextStyle(fontSize: 10, color: kT45)),
              if (pages != null && year != null) const Text('  ·  ', style: TextStyle(fontSize: 10, color: kT45)),
              if (year != null) Text('$year', style: const TextStyle(fontSize: 10, color: kT45)),
            ]),
            const SizedBox(height: 4),
            TagEditor(
              itemType: 'book',
              itemId: book['id'] as String,
              initialTags: ((book['tags'] as List?) ?? []).cast<String>(),
              onChanged: onFavoriteChanged,
              compact: true,
            ),
          ])),
          _IndexStatusIcon(book: book),
          if (isBookmarked) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.bookmark, size: 14, color: kAccent)),
          if (isAdmin)
            InkWell(
              onTap: () => _editBookMetadata(context, ref, book, onFavoriteChanged),
              child: const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.edit_outlined, size: 14, color: kT55)),
            ),
          FavoriteButton(itemType: 'book', itemId: book['id'] as String, initialValue: book['is_favorited'] == true, onChanged: onFavoriteChanged),
        ]),
      ),
    );
  }
}

Future<void> _editBookMetadata(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> book,
  VoidCallback onSaved,
) async {
  final titleCtrl = TextEditingController(text: book['title'] as String? ?? '');
  final categoryCtrl = TextEditingController(text: book['category'] as String? ?? '');
  final authorsCtrl = TextEditingController(text: ((book['authors'] as List?) ?? []).cast<String>().join(', '));
  final publisherCtrl = TextEditingController(text: book['publisher'] as String? ?? '');
  final publisherUrlCtrl = TextEditingController(text: book['publisher_url'] as String? ?? '');
  final isbnCtrl = TextEditingController(text: book['isbn'] as String? ?? '');
  final licenseCtrl = TextEditingController(text: book['license'] as String? ?? '');
  final yearCtrl = TextEditingController(text: book['year']?.toString() ?? '');
  final descriptionCtrl = TextEditingController(text: book['description'] as String? ?? '');
  bool isExplicit = book['is_explicit'] == true;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Dialog(
      backgroundColor: kCard,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Edit Book Metadata', style: serif(15)),
            const SizedBox(height: 12),
            Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const FieldLabel('TITLE'),
              const SizedBox(height: 4),
              RefInput(titleCtrl, hint: 'Book title'),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('CATEGORY'),
                  const SizedBox(height: 4),
                  RefInput(categoryCtrl, hint: 'core, supplement…'),
                ])),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('YEAR'),
                  const SizedBox(height: 4),
                  RefInput(yearCtrl, hint: 'e.g. 1998'),
                ])),
              ]),
              const SizedBox(height: 10),
              const FieldLabel('AUTHORS (comma-separated)'),
              const SizedBox(height: 4),
              RefInput(authorsCtrl, hint: 'Jane Doe, John Smith'),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('PUBLISHER'),
                  const SizedBox(height: 4),
                  RefInput(publisherCtrl, hint: 'Publisher name'),
                ])),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('PUBLISHER URL'),
                  const SizedBox(height: 4),
                  RefInput(publisherUrlCtrl, hint: 'https://…'),
                ])),
              ]),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('ISBN (OPTIONAL)'),
                  const SizedBox(height: 4),
                  RefInput(isbnCtrl, hint: 'e.g. 978-0-7869-6560-1'),
                ])),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const FieldLabel('LICENSE (OPTIONAL)'),
                  const SizedBox(height: 4),
                  RefInput(licenseCtrl, hint: 'e.g. OGL, Commercial, Homebrew'),
                ])),
              ]),
              const SizedBox(height: 10),
              const FieldLabel('DESCRIPTION'),
              const SizedBox(height: 4),
              RefInput(descriptionCtrl, hint: 'Back-cover blurb / summary…', maxLines: 4),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setS(() => isExplicit = !isExplicit),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(isExplicit ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: kT68),
                  const SizedBox(width: 6),
                  const Text('Explicit content', style: TextStyle(fontSize: 11, color: kT68)),
                ]),
              ),
            ]))),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              PillButtonOutlined('Cancel', () => Navigator.pop(ctx)),
              const SizedBox(width: 8),
              PillButton('Save', () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                final authors = authorsCtrl.text.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
                final yearText = yearCtrl.text.trim();
                await apiPatch('/library/books/${book['id']}', {
                  'title': title,
                  'category': categoryCtrl.text.trim().isEmpty ? null : categoryCtrl.text.trim(),
                  'authors': authors,
                  'publisher': publisherCtrl.text.trim().isEmpty ? null : publisherCtrl.text.trim(),
                  'publisher_url': publisherUrlCtrl.text.trim().isEmpty ? null : publisherUrlCtrl.text.trim(),
                  'isbn': isbnCtrl.text.trim().isEmpty ? null : isbnCtrl.text.trim(),
                  'license': licenseCtrl.text.trim().isEmpty ? null : licenseCtrl.text.trim(),
                  'year': yearText.isEmpty ? null : int.tryParse(yearText),
                  'description': descriptionCtrl.text.trim().isEmpty ? null : descriptionCtrl.text.trim(),
                  'is_explicit': isExplicit,
                });
                ref.invalidate(singleBookProvider(book['id'] as String));
                onSaved();
                if (ctx.mounted) Navigator.pop(ctx);
              }),
            ]),
          ]),
        ),
      ),
    )),
  );
}

/// Small, quiet indicator of whether a book's own page text has been indexed
/// yet — nothing shown once searchable (the common case), so it only draws
/// attention to books still mid-pipeline.
class _IndexStatusIcon extends StatelessWidget {
  final Map<String, dynamic> book;
  const _IndexStatusIcon({required this.book});

  @override
  Widget build(BuildContext context) {
    if (book['ocr_pending'] == true) {
      return const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Tooltip(message: "Reading this book's text…", child: Icon(Icons.hourglass_empty, size: 12, color: kWarn)),
      );
    }
    return const SizedBox.shrink();
  }
}
