import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/library_provider.dart';
import '../../../api/client.dart';
import '../../../ui/chrome.dart';

/// Toolbar bookmark icon — filled when the current book has at least one
/// bookmark, opens the same sheet [showBookmarkSheet] uses for the
/// text-selection path.
class BookmarkButton extends ConsumerWidget {
  final String bookId;
  final Map<String, dynamic> book;
  const BookmarkButton({super.key, required this.bookId, required this.book});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBookmarked = book['is_bookmarked'] == true;
    return InkWell(
      onTap: () => showBookmarkSheet(context, ref, bookId: bookId),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(isBookmarked ? Icons.bookmark : Icons.bookmark_border, size: 18,
            color: isBookmarked ? kAccent : kT55),
      ),
    );
  }
}

/// Lists/creates/deletes bookmarks for [bookId]. When [selectedText] is
/// given (the text-selection overlay's "bookmark this" path), the sheet
/// opens straight to the create form with that passage shown read-only above
/// the label/notes fields and pre-fills the page number from [prefillPage].
Future<void> showBookmarkSheet(
  BuildContext context,
  WidgetRef ref, {
  required String bookId,
  String? selectedText,
  int? prefillPage,
}) async {
  final pageCtrl = TextEditingController(text: prefillPage != null ? '$prefillPage' : '');
  final labelCtrl = TextEditingController();
  final notesCtrl = TextEditingController();

  List<dynamic> existing = [];
  try {
    existing = await apiGet('/library/books/$bookId/bookmarks') as List;
  } catch (_) {}

  if (!context.mounted) return;

  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(color: kCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: ListView(
          controller: ctrl,
          children: [
            Text('Bookmarks', style: serif(16, color: kT100)),
            const SizedBox(height: 12),
            if (existing.isNotEmpty) ...[
              for (final bm in existing)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: kWell, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    const Icon(Icons.bookmark, size: 16, color: kAccent),
                    const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(bm['label'] as String? ?? 'Bookmark', style: const TextStyle(fontSize: 12, color: kT100)),
                      if (bm['page_number'] != null)
                        Text('Page ${bm['page_number']}', style: const TextStyle(fontSize: 10, color: kT55)),
                      if (bm['selected_text'] != null && (bm['selected_text'] as String).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('"${bm['selected_text']}"',
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: kT55)),
                        ),
                    ])),
                    InkWell(
                      onTap: () async {
                        await apiDelete('/library/bookmarks/${bm['id']}');
                        ref.invalidate(singleBookProvider(bookId));
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Icon(Icons.close, size: 15, color: kT55),
                    ),
                  ]),
                ),
              const SizedBox(height: 10),
            ],
            const SectionHeading('ADD A NEW BOOKMARK'),
            const SizedBox(height: 8),
            if (selectedText != null) ...[
              const FieldLabel('SELECTED TEXT'),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: kWell, borderRadius: BorderRadius.circular(6)),
                child: Text('"$selectedText"',
                    style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: kT100)),
              ),
              const SizedBox(height: 12),
            ],
            const FieldLabel('PAGE NUMBER (OPTIONAL)'),
            const SizedBox(height: 2),
            RefInput(pageCtrl, hint: 'e.g. 42'),
            const SizedBox(height: 8),
            const FieldLabel('LABEL (OPTIONAL)'),
            const SizedBox(height: 2),
            RefInput(labelCtrl, hint: 'e.g. Chargen rules'),
            const SizedBox(height: 8),
            const FieldLabel('NOTES (OPTIONAL)'),
            const SizedBox(height: 2),
            RefInput(notesCtrl, hint: '…', maxLines: 2),
            const SizedBox(height: 16),
            PillButton('Save Bookmark', () async {
              final payload = <String, dynamic>{};
              if (pageCtrl.text.isNotEmpty) payload['page_number'] = int.tryParse(pageCtrl.text);
              if (labelCtrl.text.isNotEmpty) payload['label'] = labelCtrl.text;
              if (notesCtrl.text.isNotEmpty) payload['notes'] = notesCtrl.text;
              if (selectedText != null && selectedText.isNotEmpty) payload['selected_text'] = selectedText;
              await apiPost('/library/books/$bookId/bookmarks', payload);
              ref.invalidate(singleBookProvider(bookId));
              if (ctx.mounted) Navigator.pop(ctx);
            }),
          ],
        ),
      ),
    ),
  );
}
