/// API service: all communication with the thin-slice backend.
///
/// The interesting method is [streamChat], which consumes the backend's
/// Server-Sent Events stream and yields [StreamEvent]s as they arrive.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiService {
  /// Base URL of the backend. Defaults to the local dev server.
  ///
  /// If you run the backend on a different host/port, change this. When
  /// running the Flutter *web* app, localhost works because the browser and
  /// backend are on the same machine.
  final String baseUrl;

  ApiService({this.baseUrl = 'http://localhost:8000'});

  /// GET /api/health — returns the parsed health JSON, or throws on failure.
  Future<Map<String, dynamic>> health() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/health'));
    if (resp.statusCode != 200) {
      throw ApiException('Health check failed (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// GET /api/chat/attachment-image — fetch the bytes of a persisted chat
  /// image (so a retry after reload can re-attach the original picture).
  /// Returns null if the image is gone or the request fails.
  Future<List<int>?> fetchAttachmentImage(String path) async {
    try {
      final uri = Uri.parse('$baseUrl/api/chat/attachment-image')
          .replace(queryParameters: {'path': path});
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/conversations — list all conversations, newest first.
  Future<List<ConversationSummary>> listConversations({String? type}) async {
    final uri = Uri.parse('$baseUrl/api/conversations').replace(
      queryParameters: type == null ? null : {'type': type},
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw ApiException('Could not load conversations (${resp.statusCode})');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => ConversationSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/live/sessions — create a live-interview session for [orgName].
  /// Returns the session id to pass to the WebSocket as session_id.
  Future<LiveSessionSummary> createLiveSession(String orgName) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/live/sessions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'org_name': orgName}),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Could not create live session (${resp.statusCode})');
    }
    return LiveSessionSummary.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// GET /api/live/sessions — past live interviews (org + created date).
  Future<List<LiveSessionSummary>> listLiveSessions() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/live/sessions'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load live sessions (${resp.statusCode})');
    }
    return (jsonDecode(resp.body) as List<dynamic>)
        .map((e) => LiveSessionSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/conversations/{id} — full conversation with messages.
  /// Load a conversation's messages, newest-window paginated.
  ///
  /// - [limit]: return at most this many of the most-recent messages; the
  ///   result's `hasMore` is true when older messages exist beyond the window.
  /// - [before]: only messages strictly older than this `created_at` ISO
  ///   cursor (page backwards as the user scrolls up).
  /// Omit both to load the full history (back-compat).
  Future<({List<Message> messages, bool hasMore})> getConversationMessages(
    String conversationId, {
    int? limit,
    String? before,
  }) async {
    final qp = <String, String>{};
    if (limit != null) qp['limit'] = '$limit';
    if (before != null) qp['before'] = before;
    final uri = Uri.parse('$baseUrl/api/conversations/$conversationId')
        .replace(queryParameters: qp.isEmpty ? null : qp);
    final resp = await http.get(uri);
    if (resp.statusCode == 404) {
      throw ApiException('Conversation not found');
    }
    if (resp.statusCode != 200) {
      throw ApiException('Could not load conversation (${resp.statusCode})');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final messages = (json['messages'] as List<dynamic>)
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
    return (messages: messages, hasMore: json['has_more'] == true);
  }

  /// POST /api/agents/stream — drive the multi-agent mesh.
  ///
  /// Same SSE shape as [streamChat], with extra event kinds:
  ///   - "tool"     each blackboard write becomes a tool-chip event
  ///                with {name, key, status, ts_ms}
  ///   - "clarify"  the Clarifier asked a question; quick-reply
  ///                chips are in `data.chips`
  Stream<StreamEvent> streamAgents({
    required String message,
    String? conversationId,
    String? resumeId,
    String? sessionId,
    String? depth,
  }) {
    return _postSse(
      path: '/api/agents/stream',
      body: {
        'message': message,
        if (conversationId != null) 'conversation_id': conversationId,
        if (resumeId != null) 'resume_id': resumeId,
        if (sessionId != null) 'session_id': sessionId,
        if (depth != null) 'depth': depth,
      },
    );
  }

  /// POST /api/chat/upload-stream — chat with attached documents/images.
  ///
  /// Multipart (mirrors [streamSolveImage]): the message + each file. Backend
  /// RAGs the documents and routes images to a vision model. Same SSE events
  /// as [streamChat] (meta / token / done / error).
  Stream<StreamEvent> streamChatUpload({
    required String message,
    String? conversationId,
    String? sessionId,
    String? depth,
    required List<ComposerAttachment> attachments,
  }) async* {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/chat/upload-stream'),
    );
    request.fields['message'] = message;
    if (conversationId != null) request.fields['conversation_id'] = conversationId;
    if (sessionId != null) request.fields['session_id'] = sessionId;
    if (depth != null) request.fields['depth'] = depth;
    for (final a in attachments) {
      if (a.path != null) {
        request.files.add(
          await http.MultipartFile.fromPath('files', a.path!, filename: a.name),
        );
      } else if (a.bytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes('files', a.bytes!, filename: a.name),
        );
      }
    }

    final http.StreamedResponse response;
    try {
      response = await request.send();
    } catch (e) {
      throw ApiException(
        'Could not reach the backend at $baseUrl. Is it running? ($e)',
      );
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ApiException('Upload failed (${response.statusCode}): ${_errorDetail(body)}');
    }
    yield* _parseSseFromStream(response.stream);
  }

  /// POST /api/documents/export — convert Markdown/text content to a file and
  /// return its raw bytes. `format` is one of md|txt|csv|xlsx|docx|pdf (the
  /// backend also accepts aliases like word/excel). Used by the Download menu
  /// on assistant messages and artifacts.
  Future<List<int>> exportDocument({
    required String content,
    required String format,
    String? filename,
    String? title,
  }) async {
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$baseUrl/api/documents/export'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': content,
          'format': format,
          if (filename != null) 'filename': filename,
          if (title != null) 'title': title,
        }),
      );
    } catch (e) {
      throw ApiException('Could not reach the backend at $baseUrl. ($e)');
    }
    if (resp.statusCode != 200) {
      throw ApiException(
          'Export failed (${resp.statusCode}): ${_errorDetail(resp.body)}');
    }
    return resp.bodyBytes;
  }

  /// POST /api/documents/preview — render the content to a PDF and return its
  /// pages as base64 PNGs for the Claude-style document panel.
  /// Returns (title, List of base64 png strings, one per page).
  Future<({String title, List<String> pages})> previewDocument({
    required String content,
    String? title,
  }) async {
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$baseUrl/api/documents/preview'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': content,
          if (title != null) 'title': title,
        }),
      );
    } catch (e) {
      throw ApiException('Could not reach the backend at $baseUrl. ($e)');
    }
    if (resp.statusCode != 200) {
      throw ApiException(
          'Preview failed (${resp.statusCode}): ${_errorDetail(resp.body)}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final pages = (json['pages'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList();
    return (title: (json['title'] as String?) ?? 'Document', pages: pages);
  }

  /// POST /api/agents/episodes/{id}/feedback — attach 👍/👎/edit to an episode.
  ///
  /// Drives the self-learning loop: the Reflector reads these signals
  /// when extracting skill patterns from recent turns.
  Future<void> sendEpisodeFeedback({
    required String episodeId,
    required String kind,
    Map<String, dynamic>? payload,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/agents/episodes/$episodeId/feedback'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'kind': kind,
        if (payload != null) 'payload': payload,
      }),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Feedback failed (${resp.statusCode}): ${resp.body}');
    }
  }

  /// POST /api/chat/stream — send a message, stream the reply.
  ///
  /// Yields [StreamEvent]s in this order:
  ///   - one "meta"  event   (conversation_id, intent)
  ///   - many "token" events (incremental text)
  ///   - one "done"  event   (message_id)   OR   one "error" event
  ///
  /// The caller is responsible for updating the UI from these events.
  Stream<StreamEvent> streamChat({
    required String message,
    String? conversationId,
  }) {
    return _postSse(
      path: '/api/chat/stream',
      body: {
        'message': message,
        if (conversationId != null) 'conversation_id': conversationId,
      },
    );
  }

  // ---- Resume Q&A ------------------------------------------------------

  /// POST /api/resume/upload — multipart upload, returns the parsed profile.
  Future<ResumeDetail> uploadResume({
    required List<int> bytes,
    required String filename,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/resume/upload'),
    )..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );

    final http.StreamedResponse response;
    try {
      response = await request.send();
    } catch (e) {
      throw ApiException(
        'Could not reach the backend at $baseUrl. Is it running? ($e)',
      );
    }
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        'Upload failed (${response.statusCode}): $body',
      );
    }
    return ResumeDetail.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// GET /api/resumes — list uploaded resumes, most recent first.
  Future<List<ResumeSummary>> listResumes() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/resumes'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load resumes (${resp.statusCode})');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => ResumeSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/resume/{id} — one resume with its parsed profile.
  Future<ResumeDetail> getResume(String resumeId) async {
    final resp = await http.get(Uri.parse('$baseUrl/api/resume/$resumeId'));
    if (resp.statusCode == 404) {
      throw ApiException('Resume not found');
    }
    if (resp.statusCode != 200) {
      throw ApiException('Could not load resume (${resp.statusCode})');
    }
    return ResumeDetail.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// POST /api/resume/ask/stream — stream an answer as the candidate.
  ///
  /// Goes through the orchestrator now: emits "start", "meta" (classifier
  /// output), optional "tool" events (e.g. resume_lookup hits), then
  /// many "token" events, then "done" or "error".
  Stream<StreamEvent> streamResumeAsk({
    required String resumeId,
    required String question,
    String? sessionId,
  }) {
    return _postSse(
      path: '/api/resume/ask/stream',
      body: {
        'resume_id': resumeId,
        'question': question,
        if (sessionId != null) 'session_id': sessionId,
      },
    );
  }

  // ---- Code solver -----------------------------------------------------

  /// POST /api/solve/text — stream a structured solution to a typed problem.
  Stream<StreamEvent> streamSolveText({
    required String problem,
    String? language,
  }) {
    return _postSse(
      path: '/api/solve/text',
      body: {'problem': problem, if (language != null) 'language': language},
    );
  }

  /// POST /api/solve/image — upload a screenshot, stream the solution.
  ///
  /// `visionModel` / `codeModel` are per-call overrides. Pass null to fall
  /// through to the values in config.yaml (`llm.vision_model` / `llm.code_model`).
  Stream<StreamEvent> streamSolveImage({
    required List<int> bytes,
    required String filename,
    String? language,
    String? extraContext,
    String? visionModel,
    String? codeModel,
  }) async* {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/solve/image'),
    )..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    if (language != null) request.fields['language'] = language;
    if (extraContext != null) request.fields['extra_context'] = extraContext;
    if (visionModel != null && visionModel.isNotEmpty) {
      request.fields['vision_model'] = visionModel;
    }
    if (codeModel != null && codeModel.isNotEmpty) {
      request.fields['code_model'] = codeModel;
    }

    final http.StreamedResponse response;
    try {
      response = await request.send();
    } catch (e) {
      throw ApiException(
        'Could not reach the backend at $baseUrl. Is it running? ($e)',
      );
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ApiException('Solve failed (${response.statusCode}): $body');
    }

    // Reuse the SSE-frame parser by streaming the response body through it.
    yield* _parseSseFromStream(response.stream);
  }

  // ---- Solve history ---------------------------------------------------

  /// GET /api/solve/sessions — list past solves, newest first.
  Future<List<SolveSummary>> listSolveSessions() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/solve/sessions'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load solve history (${resp.statusCode})');
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => SolveSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/solve/sessions/{id} — load one past solve with full
  /// problem statement + response.
  Future<SolveDetail> getSolveSession(String solveId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/solve/sessions/$solveId'),
    );
    if (resp.statusCode == 404) {
      throw ApiException('Solve not found');
    }
    if (resp.statusCode != 200) {
      throw ApiException('Could not load solve (${resp.statusCode})');
    }
    return SolveDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// DELETE /api/solve/sessions/{id} — remove from history.
  Future<void> deleteSolveSession(String solveId) async {
    final resp = await http.delete(
      Uri.parse('$baseUrl/api/solve/sessions/$solveId'),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Could not delete solve (${resp.statusCode})');
    }
  }

  /// URL the `Image.network` widget can hit directly to render a saved
  /// screenshot. Returns a plain string — http isn't involved here.
  String solveImageUrl(String solveId) =>
      '$baseUrl/api/solve/sessions/$solveId/image';

  // ---- Resume reindex --------------------------------------------------

  /// POST /api/resume/{id}/reindex — rebuild Qdrant vectors from the
  /// Postgres chunks. Surfaces in the Resume screen as a "Re-index"
  /// button when vector search comes up empty despite the resume row
  /// being present (Qdrant volume wiped, snapshot rollback, etc.).
  Future<int> reindexResume(String resumeId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/resume/$resumeId/reindex'),
    );
    if (resp.statusCode != 200) {
      throw ApiException(
        'Could not reindex resume (${resp.statusCode}): ${resp.body}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['reindexed'] as num?)?.toInt() ?? 0;
  }

  // ---- Database settings ----------------------------------------------

  /// GET /api/settings/database — current connection status snapshot.
  Future<Map<String, dynamic>> getDatabaseStatus() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/settings/database'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load database status (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// POST /api/settings/database/test — dry-run a Postgres connection.
  ///
  /// Accepts any subset of {host, port, db, schema_name, user, password}
  /// as overrides; missing fields fall through to the current config.
  /// Returns `{ok, host, port, version?, schema?, schema_exists?, error?}`.
  Future<Map<String, dynamic>> testDatabaseConnection({
    String? host,
    int? port,
    String? db,
    String? schemaName,
    String? user,
    String? password,
  }) async {
    final body = <String, dynamic>{
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (db != null) 'db': db,
      if (schemaName != null) 'schema_name': schemaName,
      if (user != null) 'user': user,
      if (password != null) 'password': password,
    };
    final resp = await http.post(
      Uri.parse('$baseUrl/api/settings/database/test'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Database test failed: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// POST /api/settings/database/apply — re-run schema-create + migrate
  /// against the *current* config. Used by the UI's Retry button after
  /// a failed startup probe.
  Future<Map<String, dynamic>> applyDatabaseSettings() async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/settings/database/apply'),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Database apply failed: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ---- Settings --------------------------------------------------------

  /// GET /api/settings — full config.
  Future<Map<String, dynamic>> getSettings() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/settings'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load settings (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// POST /api/settings — partial deep-merge update.
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> updates,
  ) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/settings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(updates),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Settings update failed: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// GET /api/settings/schema — describes user-tunable knobs for the UI.
  Future<Map<String, dynamic>> getSettingsSchema() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/settings/schema'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load schema (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// GET /api/settings/llm/models — list models the provider has installed.
  ///
  /// Used by the Solve screen's per-tool model picker. Returns an empty
  /// list if the provider is unreachable so the UI degrades gracefully.
  Future<List<String>> listLlmModels() async {
    final resp =
        await http.get(Uri.parse('$baseUrl/api/settings/llm/models'));
    if (resp.statusCode != 200) {
      return const <String>[];
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final models = (body['models'] as List<dynamic>?) ?? const [];
    return models
        .map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // ---- Per-message actions (chat) -------------------------------------

  /// POST /api/messages/{id}/feedback — store/toggle 👍/👎. Pass null to clear.
  Future<void> sendMessageFeedback(String messageId, String? signal) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/feedback'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'signal': signal}),
    );
    if (resp.statusCode != 200) {
      throw ApiException(_errorDetail(resp.body));
    }
  }

  /// POST /api/messages/{id}/resolve — clear the `incomplete` flag (the user
  /// resumed/accepted an interrupted turn), so the bar doesn't reappear.
  Future<void> resolveMessage(String messageId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/resolve'),
    );
    if (resp.statusCode != 200) {
      throw ApiException(_errorDetail(resp.body));
    }
  }

  /// DELETE /api/messages/{id} — delete one message, or (cascade='after') the
  /// message and every later one in its conversation. Powers retry/edit.
  Future<void> deleteMessage(String messageId, {String? cascade}) async {
    final q = cascade != null ? '?cascade=$cascade' : '';
    final resp =
        await http.delete(Uri.parse('$baseUrl/api/messages/$messageId$q'));
    if (resp.statusCode != 200) {
      throw ApiException(_errorDetail(resp.body));
    }
  }

  // ---- Multi-provider routing (Providers screen) ----------------------

  /// GET /api/providers — full catalog: each provider + its models + key
  /// counts. Drives the Providers management screen.
  Future<List<Map<String, dynamic>>> listProviders() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/providers'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load providers (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return ((body['providers'] as List<dynamic>?) ?? const [])
        .map((e) => (e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/providers/keys — stored keys (masked), optionally filtered.
  Future<List<Map<String, dynamic>>> listProviderKeys({String? platform}) async {
    final q = platform != null ? '?platform=$platform' : '';
    final resp = await http.get(Uri.parse('$baseUrl/api/providers/keys$q'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load keys (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return ((body['keys'] as List<dynamic>?) ?? const [])
        .map((e) => (e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/providers/{platform}/keys — add a key (encrypted server-side).
  Future<Map<String, dynamic>> addProviderKey(
    String platform,
    String key, {
    String label = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/providers/$platform/keys'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'key': key, 'label': label}),
    );
    if (resp.statusCode != 200) {
      throw ApiException(_errorDetail(resp.body));
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// PATCH /api/providers/keys/{id} — enable/disable a key.
  Future<void> setProviderKeyEnabled(int keyId, bool enabled) async {
    final resp = await http.patch(
      Uri.parse('$baseUrl/api/providers/keys/$keyId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'enabled': enabled}),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Update key failed: ${resp.body}');
    }
  }

  /// POST /api/providers/keys/{id}/validate — re-check a key now. Returns the
  /// new status ('healthy' | 'invalid' | 'error').
  Future<String> validateProviderKey(int keyId) async {
    final resp = await http
        .post(Uri.parse('$baseUrl/api/providers/keys/$keyId/validate'));
    if (resp.statusCode != 200) {
      throw ApiException('Validate failed: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return (json['status'] ?? 'unknown').toString();
  }

  /// DELETE /api/providers/keys/{id} — remove a key.
  Future<void> deleteProviderKey(int keyId) async {
    final resp = await http.delete(Uri.parse('$baseUrl/api/providers/keys/$keyId'));
    if (resp.statusCode != 200) {
      throw ApiException('Delete key failed: ${resp.body}');
    }
  }

  /// GET /api/providers/fallback — the priority chain + live penalties.
  Future<List<Map<String, dynamic>>> getFallback() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/providers/fallback'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load fallback (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return ((body['fallback'] as List<dynamic>?) ?? const [])
        .map((e) => (e as Map<String, dynamic>))
        .toList();
  }

  /// PUT /api/providers/fallback — reorder priorities and/or toggle models.
  Future<void> setFallback({
    List<int>? order,
    Map<int, bool>? enabled,
  }) async {
    final body = <String, dynamic>{};
    if (order != null) body['order'] = order;
    if (enabled != null) {
      body['enabled'] = enabled.map((k, v) => MapEntry(k.toString(), v));
    }
    final resp = await http.put(
      Uri.parse('$baseUrl/api/providers/fallback'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Update fallback failed: ${resp.body}');
    }
  }

  /// POST /api/providers/{platform}/refresh-models — live /models discovery.
  Future<Map<String, dynamic>> refreshProviderModels(String platform) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/providers/$platform/refresh-models'),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Refresh failed: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Pull FastAPI's `{"detail": "..."}` out of an error body, falling back
  /// to the raw body (e.g. a plain "Internal Server Error" string).
  String _errorDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {/* not JSON — use the raw body */}
    return body;
  }

  // ---- Shared SSE helper ----------------------------------------------

  /// POST a JSON body and yield Server-Sent Events from the response.
  ///
  /// SSE frames are separated by blank lines. Each frame has an `event:` line
  /// and a `data:` line (the data is JSON). We accumulate lines, then emit a
  /// [StreamEvent] when we hit a blank line.
  Stream<StreamEvent> _postSse({
    required String path,
    required Map<String, dynamic> body,
  }) async* {
    final request = http.Request('POST', Uri.parse('$baseUrl$path'));
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await http.Client().send(request);
    } catch (e) {
      throw ApiException(
        'Could not reach the backend at $baseUrl. Is it running? ($e)',
      );
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw ApiException(
        'Backend returned ${response.statusCode}: $errBody',
      );
    }

    yield* _parseSseFromStream(response.stream);
  }

  /// SSE frame parser. Pulled out of `_postSse` so the multipart solve
  /// endpoint can reuse it on its own response stream.
  Stream<StreamEvent> _parseSseFromStream(
    http.ByteStream stream,
  ) async* {
    final lines =
        stream.transform(utf8.decoder).transform(const LineSplitter());

    String? currentEvent;
    final dataBuffer = StringBuffer();

    await for (final line in lines) {
      if (line.isEmpty) {
        if (currentEvent != null && dataBuffer.isNotEmpty) {
          final data =
              jsonDecode(dataBuffer.toString()) as Map<String, dynamic>;
          yield StreamEvent(currentEvent, data);
        }
        currentEvent = null;
        dataBuffer.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataBuffer.write(line.substring(5).trim());
      }
    }

    if (currentEvent != null && dataBuffer.isNotEmpty) {
      final data = jsonDecode(dataBuffer.toString()) as Map<String, dynamic>;
      yield StreamEvent(currentEvent, data);
    }
  }

  /// PATCH /api/conversations/{id} — rename / pin / archive / retag.
  Future<void> patchConversation(
    String conversationId, {
    String? title,
    bool? pinned,
    bool? archived,
    List<String>? tags,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (pinned != null) body['pinned'] = pinned;
    if (archived != null) body['archived'] = archived;
    if (tags != null) body['tags'] = tags;
    final resp = await http.patch(
      Uri.parse('$baseUrl/api/conversations/$conversationId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw ApiException('patchConversation failed (${resp.statusCode})');
    }
  }

  /// DELETE /api/conversations/{id} — drop a conversation + its messages.
  Future<void> deleteConversation(String conversationId) async {
    final resp = await http.delete(
      Uri.parse('$baseUrl/api/conversations/$conversationId'),
    );
    if (resp.statusCode != 200) {
      throw ApiException('deleteConversation failed (${resp.statusCode})');
    }
  }

  /// PATCH /api/solve/sessions/{id} — rename a solve session.
  Future<void> renameSolveSession(String solveId, String title) async {
    final resp = await http.patch(
      Uri.parse('$baseUrl/api/solve/sessions/$solveId'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'title': title}),
    );
    if (resp.statusCode != 200) {
      throw ApiException('renameSolveSession failed (${resp.statusCode})');
    }
  }

  // ---- Workspaces (Architecture.md §Workspace) -------------------------
  Future<Map<String, dynamic>> listWorkspaces() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/workspaces'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load workspaces (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getWorkspaceDriverCatalog() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/workspaces/drivers'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load drivers (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> probeWorkspace(String name) async {
    final resp = await http.post(Uri.parse('$baseUrl/api/workspaces/$name/probe'));
    if (resp.statusCode != 200) {
      throw ApiException('Probe failed (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> upsertWorkspace(Map<String, dynamic> body) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/workspaces'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Save workspace failed (${resp.statusCode})');
    }
  }

  Future<void> activateWorkspace(String name) async {
    final resp = await http.post(Uri.parse('$baseUrl/api/workspaces/$name/activate'));
    if (resp.statusCode != 200) {
      throw ApiException('Activate workspace failed (${resp.statusCode})');
    }
  }

  // ---- MCP tools (Architecture.md §MCP) --------------------------------
  Future<List<Map<String, dynamic>>> listMcpTools() async {
    final resp = await http.get(Uri.parse('$baseUrl/api/mcp/tools'));
    if (resp.statusCode != 200) {
      throw ApiException('Could not load tools (${resp.statusCode})');
    }
    return (jsonDecode(resp.body) as List)
        .cast<Map<String, dynamic>>();
  }

  Future<void> grantMcpTool(String name, {String rationale = ''}) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/mcp/tools/$name/grant'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'rationale': rationale}),
    );
    if (resp.statusCode != 200) {
      throw ApiException('Grant failed (${resp.statusCode})');
    }
  }

  Future<void> revokeMcpTool(String name) async {
    final resp = await http.post(Uri.parse('$baseUrl/api/mcp/tools/$name/revoke'));
    if (resp.statusCode != 200) {
      throw ApiException('Revoke failed (${resp.statusCode})');
    }
  }
}

/// Thrown for any API-level failure. The UI catches this and shows a banner.
class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
