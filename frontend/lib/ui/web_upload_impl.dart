// Real web (dart:html) implementation — selected by fuzion_chrome.dart's
// conditional import/export whenever dart.library.html is available (i.e.
// actually running in a browser). See fuzion_web_stub.dart for the
// VM-platform fallback used under `flutter test`.
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../api/client.dart';

String? readLocalStorage(String key) {
  try {
    return html.window.localStorage[key];
  } catch (_) {
    return null;
  }
}

void writeLocalStorage(String key, String value) {
  try {
    html.window.localStorage[key] = value;
  } catch (_) {}
}

void openExternal(String url) => html.window.open(url, '_blank');

// Opens the browser's native file picker, uploads the chosen file as
// multipart/form-data to `url`, then calls `onDone`. Any failure (including
// the user cancelling the picker) surfaces as a SnackBar instead of throwing
// into the caller — this is meant to be fire-and-forget from a button onTap.
Future<void> pickAndUpload(BuildContext context,
    {required String url,
    required VoidCallback onDone,
    String accept = '*/*',
    Map<String, String>? fields}) async {
  final input = html.FileUploadInputElement()..accept = accept;
  input.click();
  await input.onChange.first;
  final file = input.files?.first;
  if (file == null) return;
  final reader = html.FileReader()..readAsArrayBuffer(file);
  await reader.onLoad.first;
  try {
    // Pass the browser's detected MIME through — endpoints like the portrait
    // upload validate content-type strictly and would 415 on the multipart
    // default of application/octet-stream.
    await apiUploadFile(url, reader.result as Uint8List, file.name,
        mimeType: file.type, fields: fields);
    onDone();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }
}
