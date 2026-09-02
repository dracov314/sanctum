import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

const _base = '/api';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

Future<dynamic> apiGet(String path) async {
  final res = await http.get(Uri.parse('$_base$path'));
  if (res.statusCode == 401) throw ApiException(401, 'Not authenticated');
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  return jsonDecode(res.body);
}

Future<dynamic> apiPost(String path, [Map<String, dynamic>? body]) async {
  final res = await http.post(
    Uri.parse('$_base$path'),
    headers: {'Content-Type': 'application/json'},
    body: body != null ? jsonEncode(body) : null,
  );
  if (res.statusCode == 401) throw ApiException(401, 'Not authenticated');
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  if (res.body.isEmpty) return null;
  return jsonDecode(res.body);
}

Future<dynamic> apiPatch(String path, Map<String, dynamic> body) async {
  final res = await http.patch(
    Uri.parse('$_base$path'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  if (res.body.isEmpty) return null;
  return jsonDecode(res.body);
}

Future<dynamic> apiPut(String path, Map<String, dynamic> body) async {
  final res = await http.put(
    Uri.parse('$_base$path'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  if (res.body.isEmpty) return null;
  return jsonDecode(res.body);
}

Future<void> apiDelete(String path) async {
  final res = await http.delete(Uri.parse('$_base$path'));
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
}

Future<dynamic> apiUploadFile(String path, List<int> bytes, String filename,
    {String? mimeType, Map<String, String>? fields}) async {
  final request = http.MultipartRequest('POST', Uri.parse('$_base$path'))
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename,
        contentType: (mimeType != null && mimeType.isNotEmpty) ? MediaType.parse(mimeType) : null));
  if (fields != null) request.fields.addAll(fields);
  final res = await http.Response.fromStream(await request.send());
  if (res.statusCode == 401) throw ApiException(401, 'Not authenticated');
  if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  if (res.body.isEmpty) return null;
  return jsonDecode(res.body);
}
