/// Frontend mirror of the backend `config.yaml`.
///
/// Fetched once on app startup from `GET /api/settings`; cached for the
/// session. The Settings screen reads + writes this same object. When the
/// user changes anything, we POST to `/api/settings` and refresh.
///
/// The shape is intentionally permissive (Map<String, dynamic>) — new
/// sections added in `config.yaml` show up here without a Dart change.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class AppConfig {
  final Map<String, dynamic> raw;
  AppConfig(this.raw);

  /// Convenience accessor — returns the named section as a Map, or {} when missing.
  Map<String, dynamic> section(String name) {
    final v = raw[name];
    if (v is Map) return v.cast<String, dynamic>();
    return const {};
  }

  String get llmProvider =>
      (section('llm')['provider'] as String?) ?? 'ollama';
  String get llmModel =>
      (section('llm')['model'] as String?) ?? '';
  String get themeDefault =>
      (section('app')['theme_default'] as String?) ?? 'dark';
  String get wsPath =>
      (section('server')['ws_path'] as String?) ?? '/ws/live';

  AppConfig merge(Map<String, dynamic> updates) {
    final merged = Map<String, dynamic>.from(raw);
    updates.forEach((k, v) {
      if (v is Map && merged[k] is Map) {
        merged[k] = {...(merged[k] as Map), ...v};
      } else {
        merged[k] = v;
      }
    });
    return AppConfig(merged);
  }
}

/// Loads the live config from the backend. Used by the Provider scope in
/// `main.dart` to seed [AppState] on startup.
Future<AppConfig> fetchAppConfig(String baseUrl) async {
  final resp = await http.get(Uri.parse('$baseUrl/api/settings'));
  if (resp.statusCode != 200) {
    throw Exception('Could not load /api/settings (${resp.statusCode})');
  }
  final body = jsonDecode(resp.body);
  if (body is! Map<String, dynamic>) {
    throw Exception('Unexpected /api/settings response shape');
  }
  return AppConfig(body);
}

/// POSTs a partial deep-merge update and returns the new full config.
Future<AppConfig> updateAppConfig(
  String baseUrl,
  Map<String, dynamic> updates,
) async {
  final resp = await http.post(
    Uri.parse('$baseUrl/api/settings'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(updates),
  );
  if (resp.statusCode != 200) {
    throw Exception('Settings update failed: ${resp.body}');
  }
  return AppConfig(jsonDecode(resp.body) as Map<String, dynamic>);
}

/// Fetches the settings schema (drives the Settings screen's dropdowns).
Future<Map<String, dynamic>> fetchSettingsSchema(String baseUrl) async {
  final resp = await http.get(Uri.parse('$baseUrl/api/settings/schema'));
  if (resp.statusCode != 200) {
    throw Exception('Could not load /api/settings/schema');
  }
  return jsonDecode(resp.body) as Map<String, dynamic>;
}
