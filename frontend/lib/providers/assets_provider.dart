import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

// Use records (structural equality) so Riverpod doesn't re-fetch on every rebuild.
typedef AssetFilter = ({String? folder, String? q, String? tag, bool favoritesOnly, int page});

final mapsProvider = FutureProvider.family<Map<String, dynamic>, AssetFilter>(
  (ref, params) async {
    final qp = <String, String>{'page': params.page.toString(), 'page_size': '40'};
    if (params.folder != null) qp['folder'] = params.folder!;
    if (params.q != null && params.q!.isNotEmpty) qp['q'] = params.q!;
    if (params.tag != null) qp['tag'] = params.tag!;
    if (params.favoritesOnly) qp['favorites_only'] = 'true';
    final query = qp.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    return await apiGet('/assets/maps?$query');
  },
);

final mapFoldersProvider = FutureProvider<List<String>>((ref) async {
  final result = await apiGet('/assets/maps/folders');
  return List<String>.from(result as List);
});

final mapTagsProvider = FutureProvider<List<String>>((ref) async {
  final result = await apiGet('/assets/maps/tags');
  return List<String>.from(result as List);
});

final tokensProvider = FutureProvider.family<Map<String, dynamic>, AssetFilter>(
  (ref, params) async {
    final qp = <String, String>{'page': params.page.toString(), 'page_size': '40'};
    if (params.folder != null) qp['folder'] = params.folder!;
    if (params.q != null && params.q!.isNotEmpty) qp['q'] = params.q!;
    if (params.tag != null) qp['tag'] = params.tag!;
    if (params.favoritesOnly) qp['favorites_only'] = 'true';
    final query = qp.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    return await apiGet('/assets/tokens?$query');
  },
);

final tokenFoldersProvider = FutureProvider<List<String>>((ref) async {
  final result = await apiGet('/assets/tokens/folders');
  return List<String>.from(result as List);
});

final tokenTagsProvider = FutureProvider<List<String>>((ref) async {
  final result = await apiGet('/assets/tokens/tags');
  return List<String>.from(result as List);
});
