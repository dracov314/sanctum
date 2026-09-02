import 'package:flutter/material.dart';
import '../../../ui/chrome.dart';
import '../../../api/client.dart';

/// Right-side panel listing a PDF's own embedded outline (from
/// `GET /library/books/{id}/toc`), nested by level. Tapping an entry jumps
/// the reader to that page and closes the drawer.
class TocDrawer extends StatefulWidget {
  final String bookId;
  final int currentPage;
  final ValueChanged<int> onGoToPage;
  final VoidCallback onClose;
  const TocDrawer({
    super.key,
    required this.bookId,
    required this.currentPage,
    required this.onGoToPage,
    required this.onClose,
  });

  @override
  State<TocDrawer> createState() => _TocDrawerState();
}

class _TocDrawerState extends State<TocDrawer> {
  List<dynamic>? _toc;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await apiGet('/library/books/${widget.bookId}/toc');
      if (mounted) setState(() { _toc = (data['toc'] as List?) ?? []; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _toc = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      decoration: const BoxDecoration(
        color: kNav,
        border: Border(left: BorderSide(color: kBorderDim)),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kBorderDim))),
          child: Row(children: [
            const Icon(Icons.toc, size: 16, color: kT55),
            const SizedBox(width: 8),
            Expanded(child: Text('Contents', style: serif(13, color: kT82))),
            InkWell(onTap: widget.onClose, child: const Icon(Icons.close, size: 16, color: kT55)),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: kAccent))
              : (_toc == null || _toc!.isEmpty)
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('This book has no embedded table of contents.',
                          style: TextStyle(fontSize: 12, color: kT45)),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        for (final node in _toc!)
                          _TocNode(
                            node: node as Map<String, dynamic>,
                            depth: 0,
                            currentPage: widget.currentPage,
                            onGoToPage: widget.onGoToPage,
                          ),
                      ],
                    ),
        ),
      ]),
    );
  }
}

/// A single (recursive) TOC node with collapsible children — ported directly
/// top two levels open by default (`depth <
/// 2`), deeper levels start collapsed so a book with hundreds of leaf entries
/// (e.g. one row per power/spell) doesn't dump its entire tree into view at
/// once. A chevron only appears when there are children to toggle.
class _TocNode extends StatefulWidget {
  final Map<String, dynamic> node;
  final int depth;
  final int currentPage;
  final ValueChanged<int> onGoToPage;
  const _TocNode({
    required this.node,
    required this.depth,
    required this.currentPage,
    required this.onGoToPage,
  });

  @override
  State<_TocNode> createState() => _TocNodeState();
}

class _TocNodeState extends State<_TocNode> {
  late bool _open = widget.depth < 2;

  @override
  Widget build(BuildContext context) {
    final page = (widget.node['page'] as num?)?.toInt() ?? 1;
    final title = widget.node['title'] as String? ?? '';
    final children = (widget.node['children'] as List?) ?? const [];
    final hasChildren = children.isNotEmpty;
    final isActive = page == widget.currentPage;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        padding: EdgeInsets.only(left: 8 + widget.depth * 14, right: 8),
        decoration: BoxDecoration(
          color: isActive ? kCard : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          if (hasChildren)
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: AnimatedRotation(
                  turns: _open ? 0 : -0.25,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.keyboard_arrow_down, size: 15, color: kT55),
                ),
              ),
            )
          else
            const SizedBox(width: 23),
          Expanded(
            child: InkWell(
              onTap: () => widget.onGoToPage(page),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.depth == 0 ? 13 : 12,
                    fontWeight: widget.depth == 0 ? FontWeight.w600 : FontWeight.w400,
                    color: isActive ? kBrass : kT82,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text('$page', style: const TextStyle(fontSize: 11, color: kT45)),
        ]),
      ),
      if (hasChildren && _open)
        for (final child in children)
          _TocNode(
            node: child as Map<String, dynamic>,
            depth: widget.depth + 1,
            currentPage: widget.currentPage,
            onGoToPage: widget.onGoToPage,
          ),
    ]);
  }
}
