// VM-platform fallback (selected when dart.library.html is unavailable, e.g.
// under `flutter test`'s default runner) for the web-only helpers real code
// uses via fuzion_chrome.dart's conditional import/export of this file vs.
// fuzion_web_impl.dart. Keeps fuzion_chrome.dart — and the plain-Dart dice
// RNG living in it — loadable and testable without a browser.
import 'package:flutter/material.dart';

String? readLocalStorage(String key) => null;
void writeLocalStorage(String key, String value) {}
void openExternal(String url) {}

Future<void> pickAndUpload(BuildContext context,
    {required String url,
    required VoidCallback onDone,
    String accept = '*/*',
    Map<String, String>? fields}) async {
  throw UnsupportedError('File picking is only available on web');
}
