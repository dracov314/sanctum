// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/library_provider.dart';
import '../../ui/chrome.dart';
import 'reader/toc_drawer.dart';
import 'reader/bookmark_sheet.dart';
import 'reader/text_selection_overlay.dart';

/// The three ways a PDF can be read, the three reader modes:
/// one page at a time, two pages as a spread, or the raw file in the
/// browser's native PDF plugin.
enum _ReaderMode { page, spread, pdf }

class BookReaderScreen extends ConsumerStatefulWidget {
  final String bookId;
  const BookReaderScreen({super.key, required this.bookId});

  @override
  ConsumerState<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends ConsumerState<BookReaderScreen> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  bool _searchOpen = false;
  bool _tocOpen = false;

  _ReaderMode _mode = _ReaderMode.page;
  int _spreadOffset = 0;
  int _currentPage = 1;
  int _totalPages = 0;
  late final TextEditingController _pageCtrl;
  final FocusNode _pageFieldFocus = FocusNode();
  final FocusNode _keyFocus = FocusNode();
  final Set<int> _preloaded = {};

  // Zoom — shared across Page/Spread's InteractiveViewers so the toolbar's
  // -/+/% control and pinch-zoom drive the same transform. Reset to 100% on
  // every page turn/mode switch rather than persisted, matching how the page
  // image itself always starts fresh.
  static const _minScale = 1.0;
  static const _maxScale = 4.0;
  static const _zoomStep = 1.25;
  final TransformationController _transformController = TransformationController();
  final GlobalKey _viewerKey = GlobalKey();
  late final TextEditingController _zoomCtrl;
  final FocusNode _zoomFieldFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _pageCtrl = TextEditingController(text: '$_currentPage');
    _zoomCtrl = TextEditingController(text: '100');
    _transformController.addListener(_syncZoomField);
    _viewType = 'pdf-${widget.bookId}';
    ui.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final el = html.IFrameElement()
        ..src = '/api/library/books/${widget.bookId}/file#page=$_currentPage'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'block';
      _iframe = el;
      return el;
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _pageFieldFocus.dispose();
    _keyFocus.dispose();
    _transformController.removeListener(_syncZoomField);
    _transformController.dispose();
    _zoomCtrl.dispose();
    _zoomFieldFocus.dispose();
    super.dispose();
  }

  /// Keeps the zoom text field showing the live scale (including pinch/scroll
  /// zoom, not just button clicks) — skipped while the field has focus so it
  /// doesn't clobber the user mid-type.
  void _syncZoomField() {
    if (_zoomFieldFocus.hasFocus) return;
    final text = '${(_transformController.value.getMaxScaleOnAxis() * 100).round()}';
    if (_zoomCtrl.text != text) _zoomCtrl.text = text;
  }

  /// Zooms around the viewport's center to [newScale], scaling relative to
  /// the current transform rather than setting it absolutely, so this
  /// composes correctly with whatever pinch/scroll zooming already did
  /// instead of snapping the pan position back to a fixed point.
  void _zoomTo(double newScale) {
    final box = _viewerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final currentScale = _transformController.value.getMaxScaleOnAxis();
    final clamped = newScale.clamp(_minScale, _maxScale);
    if (clamped == currentScale) return;
    final effectiveFactor = clamped / currentScale;
    final focal = Offset(box.size.width / 2, box.size.height / 2);
    final scenePoint = _transformController.toScene(focal);
    _transformController.value = Matrix4.copy(_transformController.value)
      ..translate(scenePoint.dx, scenePoint.dy)
      ..scale(effectiveFactor)
      ..translate(-scenePoint.dx, -scenePoint.dy);
  }

  void _zoomBy(double factor) =>
      _zoomTo(_transformController.value.getMaxScaleOnAxis() * factor);

  void _commitZoomText(String raw) {
    final parsed = int.tryParse(raw.replaceAll('%', '').trim());
    if (parsed != null) {
      _zoomTo(parsed / 100);
    }
    _syncZoomField();
  }

  void _resetZoom() => _transformController.value = Matrix4.identity();

  String get _prefsKey => 'sanctum_reader_${widget.bookId}';

  void _loadPrefs() {
    final raw = html.window.localStorage[_prefsKey];
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _currentPage = (data['page'] as num?)?.toInt() ?? 1;
      final modeName = data['mode'] as String?;
      _mode = _ReaderMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => _ReaderMode.page,
      );
      _spreadOffset = (data['spreadOffset'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Corrupt/old prefs blob — fall back to defaults rather than crash the reader.
    }
  }

  void _savePrefs() {
    html.window.localStorage[_prefsKey] = jsonEncode({
      'page': _currentPage,
      'mode': _mode.name,
      'spreadOffset': _spreadOffset,
    });
  }

  // Fixed PAGE_WIDTH/SPREAD_WIDTH render sizes — the
  // preloader and the visible image must request the same width so the
  // browser's own image cache actually gets a hit, not just a wasted fetch.
  static const _pageWidth = 1600;
  static const _spreadWidth = 1000;

  int get _renderWidth => _mode == _ReaderMode.spread ? _spreadWidth : _pageWidth;

  String _pageUrl(int page, {int? width}) =>
      '/api/library/books/${widget.bookId}/page/$page?width=${width ?? _renderWidth}';

  bool get _hasRight =>
      _mode == _ReaderMode.spread &&
      (_spreadOffset == 1 || _currentPage != 1) &&
      _currentPage + 1 <= _totalPages;

  int get _step => _mode == _ReaderMode.spread ? 2 : 1;

  void _goToPage(int target) {
    if (_totalPages == 0) return;
    var page = target.clamp(1, _totalPages);
    if (_mode == _ReaderMode.spread) {
      // Snap to the left page of the pair the target page belongs to.
      final leftForTarget = _spreadOffset == 1 ? page % 2 != 0 : (page % 2 == 0 || page == 1);
      if (!leftForTarget) page -= 1;
    }
    setState(() {
      _currentPage = page;
      _pageCtrl.text = '$page';
    });
    _resetZoom();
    _savePrefs();
    _preloadAdjacent();
    if (_mode == _ReaderMode.pdf) _jumpToPage(page);
  }

  void _jumpToPage(int page) {
    _iframe?.src = '/api/library/books/${widget.bookId}/file#page=$page';
  }

  void _preloadAdjacent() {
    final candidates = _mode == _ReaderMode.spread
        ? [_currentPage - 2, _currentPage + 2, _currentPage + 3]
        : [_currentPage - 1, _currentPage + 1, _currentPage + 2];
    for (final p in candidates) {
      if (p < 1 || p > _totalPages || !_preloaded.add(p)) continue;
      precacheImage(NetworkImage(_pageUrl(p)), context);
    }
  }

  void _setMode(_ReaderMode mode) {
    setState(() => _mode = mode);
    _resetZoom();
    if (mode == _ReaderMode.spread) _goToPage(_currentPage);
    if (mode == _ReaderMode.pdf) _jumpToPage(_currentPage);
    _savePrefs();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_pageFieldFocus.hasFocus || _mode == _ReaderMode.pdf) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _goToPage(_currentPage - _step);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _goToPage(_currentPage + _step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onSwipe(DragEndDetails details) {
    if (_mode == _ReaderMode.pdf) return;
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    if (v < 0) {
      _goToPage(_currentPage + _step);
    } else {
      _goToPage(_currentPage - _step);
    }
  }

  void _openBookmarkForSelection(String text) {
    showBookmarkSheet(context, ref,
            bookId: widget.bookId, selectedText: text, prefillPage: _currentPage)
        .then((_) => ref.invalidate(singleBookProvider(widget.bookId)));
  }

  @override
  Widget build(BuildContext context) {
    final bookAsync = ref.watch(singleBookProvider(widget.bookId));
    // Watched here too (same family instance the overlay itself watches, so
    // this doesn't double-fetch) purely to decide whether the current page
    // has selectable text — if it does, the outer swipe-to-turn-page
    // GestureDetector and InteractiveViewer's free-pan need to step aside so
    // they don't contend with the overlay's own drag-to-select gesture.
    final currentWords =
        ref.watch(pageWordsProvider((bookId: widget.bookId, page: _currentPage)));
    final hasWords = currentWords.maybeWhen(
      data: (d) => (d['words'] as List).isNotEmpty,
      orElse: () => false,
    );

    return Container(
      color: kBg,
      child: bookAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: kAccent)),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: kT55))),
        data: (book) {
          if (_totalPages == 0) {
            _totalPages = (book['page_count'] as num?)?.toInt() ?? 0;
            if (_currentPage > _totalPages && _totalPages > 0) _currentPage = _totalPages;
            WidgetsBinding.instance.addPostFrameCallback((_) => _preloadAdjacent());
          }
          final isPdf = book['mime_type'] == 'application/pdf';
          // Non-PDF library items (e.g. a bare image) have no page-image
          // endpoint to render from — always fall back to the raw-file view
          // for those, regardless of a stale page/spread mode saved in prefs.
          final effectiveMode = isPdf ? _mode : _ReaderMode.pdf;

          return Focus(
            focusNode: _keyFocus,
            autofocus: true,
            onKeyEvent: _handleKey,
            child: Column(children: [
              _Toolbar(
                book: book,
                isPdf: isPdf,
                mode: effectiveMode,
                onModeChange: _setMode,
                spreadOffset: _spreadOffset,
                onSpreadOffsetChange: (v) {
                  setState(() => _spreadOffset = v);
                  _goToPage(_currentPage);
                },
                currentPage: _currentPage,
                totalPages: _totalPages,
                step: _step,
                hasRight: _hasRight,
                rightPage: _currentPage + 1,
                pageCtrl: _pageCtrl,
                pageFieldFocus: _pageFieldFocus,
                onPageCommit: (v) => _goToPage(int.tryParse(v) ?? _currentPage),
                tocOpen: _tocOpen,
                onToggleToc: () => setState(() {
                  _tocOpen = !_tocOpen;
                  if (_tocOpen) _searchOpen = false;
                }),
                searchOpen: _searchOpen,
                onToggleSearch: () => setState(() {
                  _searchOpen = !_searchOpen;
                  if (_searchOpen) _tocOpen = false;
                }),
                bookId: widget.bookId,
                onBack: () => context.pop(),
                transformController: _transformController,
                minScale: _minScale,
                maxScale: _maxScale,
                onZoomIn: () => _zoomBy(_zoomStep),
                onZoomOut: () => _zoomBy(1 / _zoomStep),
                zoomCtrl: _zoomCtrl,
                zoomFieldFocus: _zoomFieldFocus,
                onZoomCommit: _commitZoomText,
              ),
              if (_searchOpen)
                _BookSearchPanel(bookId: widget.bookId, book: book, onJumpToPage: _goToPage),
              Expanded(
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      // Selectable text on the current page means a drag is
                      // the overlay's to interpret, not a page-turn swipe —
                      // null disables this recognizer outright rather than
                      // racing it against the overlay's own pan detector.
                      onHorizontalDragEnd: hasWords ? null : _onSwipe,
                      child: Container(
                        key: _viewerKey,
                        color: kWell,
                        child: switch (effectiveMode) {
                          _ReaderMode.pdf => HtmlElementView(viewType: _viewType),
                          _ReaderMode.spread => _SpreadView(
                              controller: _transformController,
                              minScale: _minScale,
                              maxScale: _maxScale,
                              leftUrl: _pageUrl(_currentPage),
                              rightUrl: _hasRight ? _pageUrl(_currentPage + 1) : null,
                            ),
                          _ReaderMode.page => _PageView(
                              bookId: widget.bookId,
                              pageNumber: _currentPage,
                              controller: _transformController,
                              minScale: _minScale,
                              maxScale: _maxScale,
                              panEnabled: !hasWords,
                              url: _pageUrl(_currentPage),
                              onTextSelected: _openBookmarkForSelection,
                            ),
                        },
                      ),
                    ),
                  ),
                  if (_tocOpen && isPdf && effectiveMode != _ReaderMode.pdf)
                    TocDrawer(
                      bookId: widget.bookId,
                      currentPage: _currentPage,
                      onGoToPage: (p) {
                        _goToPage(p);
                        setState(() => _tocOpen = false);
                      },
                      onClose: () => setState(() => _tocOpen = false),
                    ),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final Map<String, dynamic> book;
  final bool isPdf;
  final _ReaderMode mode;
  final ValueChanged<_ReaderMode> onModeChange;
  final int spreadOffset;
  final ValueChanged<int> onSpreadOffsetChange;
  final int currentPage;
  final int totalPages;
  final int step;
  final bool hasRight;
  final int rightPage;
  final TextEditingController pageCtrl;
  final FocusNode pageFieldFocus;
  final ValueChanged<String> onPageCommit;
  final bool tocOpen;
  final VoidCallback onToggleToc;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final String bookId;
  final VoidCallback onBack;
  final TransformationController transformController;
  final double minScale;
  final double maxScale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final TextEditingController zoomCtrl;
  final FocusNode zoomFieldFocus;
  final ValueChanged<String> onZoomCommit;

  const _Toolbar({
    required this.book,
    required this.isPdf,
    required this.mode,
    required this.onModeChange,
    required this.spreadOffset,
    required this.onSpreadOffsetChange,
    required this.currentPage,
    required this.totalPages,
    required this.step,
    required this.hasRight,
    required this.rightPage,
    required this.pageCtrl,
    required this.pageFieldFocus,
    required this.onPageCommit,
    required this.tocOpen,
    required this.onToggleToc,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.bookId,
    required this.onBack,
    required this.transformController,
    required this.minScale,
    required this.maxScale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.zoomCtrl,
    required this.zoomFieldFocus,
    required this.onZoomCommit,
  });

  @override
  Widget build(BuildContext context) {
    // Layout: back/title pinned left; page-nav/mode/cover/zoom cluster fills
    // the middle and hugs the right edge of its own space (scrolls
    // internally if the window is too narrow to fit it); contents/bookmark/
    // search/download stay pinned at the far right.
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: kNav,
      child: Row(children: [
        InkWell(onTap: onBack,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('←', style: TextStyle(fontSize: 18, color: kLink)))),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(book['title'] as String? ?? '', overflow: TextOverflow.ellipsis,
              style: serif(14, color: kT100)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (mode != _ReaderMode.pdf && totalPages > 0) ...[
                _IconBtn(icon: Icons.chevron_left, onTap: currentPage > 1 ? () => onPageCommit('${currentPage - step}') : null),
                SizedBox(
                  width: 44,
                  child: TextField(
                    controller: pageCtrl,
                    focusNode: pageFieldFocus,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: kT100),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                      filled: true,
                      fillColor: kInput,
                      border: OutlineInputBorder(borderSide: BorderSide(color: kBorderDim)),
                    ),
                    onSubmitted: onPageCommit,
                  ),
                ),
                if (mode == _ReaderMode.spread && hasRight)
                  Padding(padding: const EdgeInsets.only(left: 4),
                      child: Text('–$rightPage', style: const TextStyle(fontSize: 12, color: kT55))),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text('/ $totalPages', style: const TextStyle(fontSize: 12, color: kT55))),
                _IconBtn(icon: Icons.chevron_right, onTap: currentPage < totalPages ? () => onPageCommit('${currentPage + step}') : null),
                const SizedBox(width: 14),
              ],

              if (isPdf) ...[
                _ModeToggle(mode: mode, onModeChange: onModeChange),
                const SizedBox(width: 10),
              ],

              if (mode == _ReaderMode.spread) ...[
                _LabeledToggle(
                  label: 'Cover',
                  icon: Icons.flip,
                  active: spreadOffset == 1,
                  tooltip: spreadOffset == 0 ? 'Pair cover with page 2' : 'Let cover stand alone',
                  onTap: () => onSpreadOffsetChange(spreadOffset == 0 ? 1 : 0),
                ),
                const SizedBox(width: 10),
              ],

              if (mode != _ReaderMode.pdf)
                _ZoomControl(
                  controller: transformController,
                  minScale: minScale,
                  maxScale: maxScale,
                  onZoomIn: onZoomIn,
                  onZoomOut: onZoomOut,
                  zoomCtrl: zoomCtrl,
                  zoomFieldFocus: zoomFieldFocus,
                  onZoomCommit: onZoomCommit,
                ),
            ]),
          ),
        ),
        const SizedBox(width: 14),

        if (isPdf && mode != _ReaderMode.pdf)
          _IconBtn(icon: Icons.toc, active: tocOpen, tooltip: 'Contents', onTap: onToggleToc),
        BookmarkButton(bookId: bookId, book: book),
        if (book['ocr_pending'] != true)
          _IconBtn(
            icon: Icons.search,
            active: searchOpen,
            enabled: book['indexed'] == true,
            tooltip: 'Search this book',
            onTap: onToggleSearch,
          )
        else
          const Padding(
            padding: EdgeInsets.all(6),
            child: SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: kWarn)),
          ),
        _IconBtn(
          icon: Icons.download,
          tooltip: 'Download',
          onTap: () => html.window.open('/api/library/books/$bookId/file', '_blank'),
        ),
      ]),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final _ReaderMode mode;
  final ValueChanged<_ReaderMode> onModeChange;
  const _ModeToggle({required this.mode, required this.onModeChange});

  static const _entries = [
    (_ReaderMode.page, Icons.description, 'Page'),
    (_ReaderMode.spread, Icons.menu_book, 'Spread'),
    (_ReaderMode.pdf, Icons.picture_as_pdf, 'PDF'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: kBorderDim), borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (m, icon, label) in _entries)
          InkWell(
            onTap: () => onModeChange(m),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: mode == m ? kCard : Colors.transparent,
              child: Row(children: [
                Icon(icon, size: 13, color: mode == m ? kBrass : kT55),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(fontSize: 11, color: mode == m ? kBrass : kT55)),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Same visual weight as `_ModeToggle`'s segments, but a single standalone
/// on/off button with a visible label instead of an icon-only `_IconBtn` —
/// used for "Cover" since a tooltip alone made the affordance too easy to miss.
class _LabeledToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  const _LabeledToggle({required this.label, required this.icon, required this.active, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? kCard : Colors.transparent,
            border: Border.all(color: active ? kAccent : kBorderDim),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: active ? kBrass : kT55),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: active ? kBrass : kT55)),
          ]),
        ),
      ),
    );
  }
}

/// −/+ buttons around a typeable percentage field showing [controller]'s
/// current scale — drives the same `InteractiveViewer` transform pinch-zoom
/// does, via [onZoomIn]/[onZoomOut]/[onZoomCommit], rather than a separate
/// independent zoom state. Bold text glyphs instead of Material's
/// remove/add icons — those rendered too thin/faint to notice at this size,
/// same reasoning as the back button's literal "←" character.
class _ZoomControl extends StatelessWidget {
  final TransformationController controller;
  final double minScale;
  final double maxScale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final TextEditingController zoomCtrl;
  final FocusNode zoomFieldFocus;
  final ValueChanged<String> onZoomCommit;
  const _ZoomControl({
    required this.controller,
    required this.minScale,
    required this.maxScale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.zoomCtrl,
    required this.zoomFieldFocus,
    required this.onZoomCommit,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Matrix4>(
      valueListenable: controller,
      builder: (context, matrix, _) {
        final pct = (matrix.getMaxScaleOnAxis() * 100).round();
        return Row(mainAxisSize: MainAxisSize.min, children: [
          _ZoomGlyphBtn(label: '-', tooltip: 'Zoom out',
              onTap: pct > (minScale * 100).round() ? onZoomOut : null),
          SizedBox(
            width: 46,
            child: TextField(
              controller: zoomCtrl,
              focusNode: zoomFieldFocus,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: kT100),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 6),
                filled: true,
                fillColor: kInput,
                suffixText: '%',
                suffixStyle: TextStyle(fontSize: 11, color: kT55),
                border: OutlineInputBorder(borderSide: BorderSide(color: kBorderDim)),
              ),
              onSubmitted: onZoomCommit,
            ),
          ),
          _ZoomGlyphBtn(label: '+', tooltip: 'Zoom in',
              onTap: pct < (maxScale * 100).round() ? onZoomIn : null),
        ]);
      },
    );
  }
}

class _ZoomGlyphBtn extends StatelessWidget {
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  const _ZoomGlyphBtn({required this.label, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? kT45 : kT100;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(label, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color, height: 1)),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;
  final String? tooltip;
  const _IconBtn({required this.icon, this.onTap, this.active = false, this.enabled = true, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final color = !enabled ? kT45 : (active ? kAccent : kT100);
    final btn = InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18, color: color)),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}

/// One page's content: the rendered image, plus — when the page has an
/// embedded text layer — a text-selection overlay sized to match it exactly
/// via [AspectRatio] (sidesteps [BoxFit.contain] letterboxing math; both the
/// image and the overlay share one linear PDF-point-to-pixel scale).
class _ReaderPage extends ConsumerWidget {
  final String bookId;
  final int pageNumber;
  final String url;
  final ValueChanged<String>? onTextSelected;
  const _ReaderPage({
    required this.bookId,
    required this.pageNumber,
    required this.url,
    this.onTextSelected,
  });

  Widget _plainImage() => Image.network(url, fit: BoxFit.contain, gaplessPlayback: true,
      loadingBuilder: (ctx, child, progress) => progress == null
          ? child
          : const Center(child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wordsAsync = ref.watch(pageWordsProvider((bookId: bookId, page: pageNumber)));
    return wordsAsync.maybeWhen(
      data: (data) {
        final words = (data['words'] as List).cast<Map<String, dynamic>>();
        if (words.isEmpty || onTextSelected == null) return Center(child: _plainImage());
        final pageW = (data['page_width'] as num).toDouble();
        final pageH = (data['page_height'] as num).toDouble();
        return Center(
          child: AspectRatio(
            aspectRatio: pageW / pageH,
            child: Stack(children: [
              Image.network(url, fit: BoxFit.fill, gaplessPlayback: true),
              Positioned.fill(
                child: PdfTextSelectionOverlay(
                  words: words,
                  pageWidth: pageW,
                  pageHeight: pageH,
                  onSelectionComplete: onTextSelected!,
                ),
              ),
            ]),
          ),
        );
      },
      orElse: () => Center(child: _plainImage()),
    );
  }
}

class _PageView extends StatelessWidget {
  final String bookId;
  final int pageNumber;
  final String url;
  final TransformationController controller;
  final double minScale;
  final double maxScale;
  final bool panEnabled;
  final ValueChanged<String>? onTextSelected;
  const _PageView({
    required this.bookId,
    required this.pageNumber,
    required this.url,
    required this.controller,
    required this.minScale,
    required this.maxScale,
    this.panEnabled = true,
    this.onTextSelected,
  });

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: controller,
      minScale: minScale,
      maxScale: maxScale,
      panEnabled: panEnabled,
      child: _ReaderPage(
        bookId: bookId,
        pageNumber: pageNumber,
        url: url,
        onTextSelected: onTextSelected,
      ),
    );
  }
}

class _SpreadView extends StatelessWidget {
  final String leftUrl;
  final String? rightUrl;
  final TransformationController controller;
  final double minScale;
  final double maxScale;
  const _SpreadView({required this.leftUrl, this.rightUrl, required this.controller, required this.minScale, required this.maxScale});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: controller,
      minScale: minScale,
      maxScale: maxScale,
      child: Center(
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(child: Image.network(leftUrl, fit: BoxFit.contain, gaplessPlayback: true)),
          if (rightUrl != null) ...[
            const SizedBox(width: 2),
            Flexible(child: Image.network(rightUrl!, fit: BoxFit.contain, gaplessPlayback: true)),
          ],
        ]),
      ),
    );
  }
}

class _BookSearchPanel extends ConsumerStatefulWidget {
  final String bookId;
  final Map<String, dynamic> book;
  final ValueChanged<int> onJumpToPage;
  const _BookSearchPanel({required this.bookId, required this.book, required this.onJumpToPage});

  @override
  ConsumerState<_BookSearchPanel> createState() => _BookSearchPanelState();
}

class _BookSearchPanelState extends ConsumerState<_BookSearchPanel> {
  final _ctrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexed = widget.book['indexed'] == true;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      color: kNav,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (!indexed)
          _NotSearchableNotice(book: widget.book)
        else ...[
          RefInput(_ctrl, hint: 'Search this book…', onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () {
              if (mounted) setState(() => _query = v);
            });
          }),
          const SizedBox(height: 8),
          Flexible(child: _SearchResults(bookId: widget.bookId, query: _query, onJumpToPage: widget.onJumpToPage)),
        ],
      ]),
    );
  }
}

class _NotSearchableNotice extends StatelessWidget {
  final Map<String, dynamic> book;
  const _NotSearchableNotice({required this.book});

  @override
  Widget build(BuildContext context) {
    final ocrPending = book['ocr_pending'] == true;
    final imageOnly = book['index_error'] == 'image-only';
    final message = ocrPending
        ? "Still reading this book's text (it's a scan) — search will be available once that finishes."
        : imageOnly
            ? "This book has no readable text layer and text recognition is off, so it can't be searched."
            : "This book hasn't been indexed for search yet.";
    return Row(children: [
      const Icon(Icons.hourglass_empty, size: 14, color: kT55),
      const SizedBox(width: 8),
      Expanded(child: Text(message, style: const TextStyle(fontSize: 11, color: kT55))),
    ]);
  }
}

class _SearchResults extends ConsumerWidget {
  final String bookId;
  final String query;
  final ValueChanged<int> onJumpToPage;
  const _SearchResults({required this.bookId, required this.query, required this.onJumpToPage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().isEmpty) {
      return const Text('Type to search this book\'s pages.', style: TextStyle(fontSize: 11, color: kT45));
    }
    final resultsAsync = ref.watch(bookPageSearchProvider((bookId: bookId, q: query)));
    return resultsAsync.when(
      loading: () => const Padding(padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kAccent))),
      error: (e, _) => Text('$e', style: const TextStyle(fontSize: 11, color: kFail)),
      data: (results) {
        if (results.isEmpty) {
          return Text('No matches for "$query".', style: const TextStyle(fontSize: 11, color: kT45));
        }
        return ListView.separated(
          shrinkWrap: true,
          itemCount: results.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (_, i) {
            final r = results[i];
            final page = r['page_number'] as int;
            return InkWell(
              onTap: () => onJumpToPage(page),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: kCard, border: Border.all(color: kBorderDim),
                    borderRadius: BorderRadius.circular(6)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: kWell, borderRadius: BorderRadius.circular(4)),
                    child: Text('p.$page', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: kBrass)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _SnippetText(r['snippet'] as String? ?? '')),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

/// Renders a ts_headline snippet, bolding the <b>…</b>-wrapped matched terms
/// Postgres inserts around each hit.
class _SnippetText extends StatelessWidget {
  final String raw;
  const _SnippetText(this.raw);

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'<b>(.*?)</b>', dotAll: true);
    var last = 0;
    for (final m in pattern.allMatches(raw)) {
      if (m.start > last) spans.add(TextSpan(text: raw.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700, color: kBrass)));
      last = m.end;
    }
    if (last < raw.length) spans.add(TextSpan(text: raw.substring(last)));
    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: const TextStyle(fontSize: 11, color: kT82), children: spans),
    );
  }
}

// _BookmarkButton / bookmark sheet moved to reader/bookmark_sheet.dart
// (BookmarkButton / showBookmarkSheet) so the text-selection overlay can
// reuse the same sheet for its "bookmark this selection" path.
