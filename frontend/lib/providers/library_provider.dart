import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

final gameSystemsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final data = await apiGet('/library/systems') as List;
  return data.cast<Map<String, dynamic>>();
});

class BookQuery {
  final String q;
  final String? system;
  final String? category;
  final String? tag;
  final int page;

  const BookQuery({this.q = '', this.system, this.category, this.tag, this.page = 1});

  @override
  bool operator ==(Object other) =>
      other is BookQuery && q == other.q && system == other.system &&
      category == other.category && tag == other.tag && page == other.page;

  @override
  int get hashCode => Object.hash(q, system, category, tag, page);
}

final booksProvider = FutureProvider.family<Map<String, dynamic>, BookQuery>((ref, query) async {
  final params = <String, String>{
    'page': query.page.toString(),
    'page_size': '40',
  };
  if (query.q.isNotEmpty) params['q'] = query.q;
  if (query.system != null) params['system'] = query.system!;
  if (query.category != null) params['category'] = query.category!;
  if (query.tag != null) params['tag'] = query.tag!;

  final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  final data = await apiGet('/library/books?$qs') as Map<String, dynamic>;
  return data;
});

final bookTagsProvider = FutureProvider<List<String>>((ref) async {
  final data = await apiGet('/library/tags') as List;
  return data.cast<String>();
});

final bookmarkProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final data = await apiGet('/library/bookmarks') as List;
  return data.cast<Map<String, dynamic>>();
});

final singleBookProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final data = await apiGet('/library/books/$id') as Map<String, dynamic>;
  return data;
});

// Word bounding boxes for one PDF page — powers the reader's text-selection
// overlay. Empty `words` means no embedded text layer on that page.
typedef PageWordsQuery = ({String bookId, int page});

final pageWordsProvider =
    FutureProvider.family<Map<String, dynamic>, PageWordsQuery>((ref, query) async {
  final data = await apiGet('/library/books/${query.bookId}/page/${query.page}/words')
      as Map<String, dynamic>;
  return data;
});

// Fetches all books for a single system (up to 500) so we can group by category client-side.
typedef SystemBooksQuery = ({String systemId, String? tag});

final systemBooksProvider = FutureProvider.family<Map<String, dynamic>, SystemBooksQuery>((ref, query) async {
  final params = <String, String>{'system': query.systemId, 'page_size': '500'};
  if (query.tag != null) params['tag'] = query.tag!;
  final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  final data = await apiGet('/library/books?$qs') as Map<String, dynamic>;
  return data;
});

// Searches one book's own extracted page text (real full-document search, not
// just title/metadata) — powers the in-reader search panel.
final bookPageSearchProvider =
    FutureProvider.family<List<Map<String, dynamic>>, ({String bookId, String q})>((ref, args) async {
  if (args.q.trim().isEmpty) return [];
  final data = await apiGet(
    '/library/books/${args.bookId}/search?q=${Uri.encodeComponent(args.q)}',
  ) as List;
  return data.cast<Map<String, dynamic>>();
});
