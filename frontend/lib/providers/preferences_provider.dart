import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/client.dart';

/// Server-synced per-user UI preferences (see api /auth/me/preferences).
/// Follows the user across devices, unlike the localStorage view defaults.
final userPreferencesProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final m = await apiGet('/auth/me/preferences') as Map;
  return m.cast<String, dynamic>();
});

Future<void> saveUserPreference(String key, Object value) =>
    apiPut('/auth/me/preferences/$key', {'value': value});
