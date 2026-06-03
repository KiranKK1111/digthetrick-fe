/// Data models mirroring the backend's API schemas.
///
/// Kept deliberately small — these match `backend/app/schemas.py`. If you
/// change a schema on the backend, change it here too.
library;

import 'dart:convert';

/// Maximum number of files that can be attached to a single message.
const int kMaxAttachments = 10;

/// Per-file upload ceiling (100 MiB). Mirrors the backend's MAX_UPLOAD_BYTES
/// in app/documents/parser.py — keep the two in sync.
const int kMaxUploadBytes = 100 * 1024 * 1024;

/// One attachment the user picked in the composer. Backed by a real file on
/// disk (desktop, `path`) or an in-memory blob (web/mobile, `bytes`). Lives in
/// the model layer so a [Message] can retain its files for inline editing.
class ComposerAttachment {
  ComposerAttachment({
    required this.name,
    required this.sizeBytes,
    this.path,
    this.bytes,
    this.persisted = false,
  });

  final String name;
  final int sizeBytes;
  final String? path;
  final List<int>? bytes;

  /// True for an attachment reconstructed from a reloaded conversation: the
  /// backend kept the file's name (and its RAG vectors) but not the original
  /// bytes, so we can show + remove the chip but cannot re-upload it. Such an
  /// attachment is display-only — the conversation's persisted RAG context
  /// still covers it on the next turn.
  final bool persisted;

  /// Whether this attachment can actually be sent over multipart (has bytes
  /// or an on-disk path). Persisted/name-only attachments return false.
  bool get isUploadable => !persisted && (path != null || bytes != null);

  String get displaySize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// One selectable option inside a [ClarifyQuestion] (Claude-style
/// AskUserQuestion). `label` is the choice; `description` is a short hint
/// shown under it.
class ClarifyOption {
  ClarifyOption({required this.label, this.description = ''});

  final String label;
  final String description;

  factory ClarifyOption.fromJson(Map<String, dynamic> j) => ClarifyOption(
        label: (j['label'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'label': label, 'description': description};
}

/// A single clarifying question the assistant asks before answering, with a
/// set of options. `multiSelect` allows picking more than one.
/// How a [ClarifyQuestion] is answered.
enum ClarifyKind { single, multi, rank }

class ClarifyQuestion {
  ClarifyQuestion({
    required this.question,
    this.header = '',
    this.kind = ClarifyKind.single,
    required this.options,
  });

  final String question;
  final String header;
  final ClarifyKind kind;
  final List<ClarifyOption> options;

  bool get multiSelect => kind == ClarifyKind.multi;

  static ClarifyKind _kindFrom(Map<String, dynamic> j) {
    switch ((j['kind'] ?? '').toString().toLowerCase()) {
      case 'multi':
        return ClarifyKind.multi;
      case 'rank':
        return ClarifyKind.rank;
      case 'single':
        return ClarifyKind.single;
      default:
        // Back-compat with the older multiSelect bool.
        return j['multiSelect'] == true ? ClarifyKind.multi : ClarifyKind.single;
    }
  }

  factory ClarifyQuestion.fromJson(Map<String, dynamic> j) => ClarifyQuestion(
        question: (j['question'] ?? '').toString(),
        header: (j['header'] ?? '').toString(),
        kind: _kindFrom(j),
        options: ((j['options'] as List?) ?? const [])
            .whereType<Map>()
            .map((o) => ClarifyOption.fromJson(o.cast<String, dynamic>()))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'question': question,
        'header': header,
        'kind': kind.name,
        'options': options.map((o) => o.toJson()).toList(),
      };

  /// Parse the `questions` array from a `clarify` SSE event (or persisted JSON).
  static List<ClarifyQuestion> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((q) => ClarifyQuestion.fromJson(q.cast<String, dynamic>()))
        .where((q) => q.question.isNotEmpty && q.options.length >= 2)
        .toList();
  }

  /// Encode a list for local persistence; decode with [listFrom] + jsonDecode.
  static String encodeList(List<ClarifyQuestion> qs) =>
      jsonEncode(qs.map((q) => q.toJson()).toList());
}

/// A single chat message. `role` is "user" or "assistant".
class Message {
  // Mutable: starts as a local placeholder id, then gets the backend's real
  // id on the SSE `done` event / on reload (needed for feedback + delete).
  String id;
  final String role;
  String content; // mutable: grows as tokens stream in
  final String? intent;
  final DateTime createdAt;
  // The backend's raw `created_at` ISO string, kept verbatim so it can be used
  // as an exact pagination cursor (`before=`) without timezone round-trip
  // drift. Null for local-only messages (not needed — they're never the
  // oldest loaded row).
  final String? createdAtIso;
  // Architecture.md additions populated from SSE events as they arrive.
  // `artifacts` lands on the assistant message when the backend emits
  // an `event: artifacts`. `stagePhase` is the most recent stage name
  // (drives the progressive loader word).
  List<Map<String, dynamic>> artifacts;
  String? stagePhase;
  // Current 👍/👎 on this message: 'thumb_up' | 'thumb_down' | null.
  String? feedback;
  // True when this assistant turn was cut short (disconnect / Stop / provider
  // drop). The bubble shows an "interrupted" hint + Continue/Retry. Mutable so
  // a local Stop can flag it immediately before the backend reload confirms it.
  bool incomplete;
  // True only when the user explicitly asked to generate a document — drives
  // the inline document card / preview panel. Set live for the streaming turn
  // and restored from the backend's `is_document` on reload. Mutable so the
  // chat screen can flag it the moment the turn finishes.
  bool isDocument;
  // The format this document was generated in (pdf/docx/xlsx/csv/md/txt) so the
  // card's Download button saves THAT format directly — no dropdown.
  String documentFormat;
  // Filenames the user attached to this message (shown as chips on the bubble;
  // survives reload from the backend `sources`).
  List<String> attachments;
  // The actual attached files, retained in-session so the inline editor can
  // show/remove/replace them and re-send. Empty for messages loaded from
  // history (the backend stores names, not the bytes).
  List<ComposerAttachment> files;
  // Persisted image refs [{name, path}] from the backend `sources.images`, so a
  // retry after reload can re-fetch + re-attach the original image.
  List<Map<String, dynamic>> imageRefs;

  Message({
    required this.id,
    required this.role,
    required this.content,
    this.intent,
    required this.createdAt,
    this.createdAtIso,
    List<Map<String, dynamic>>? artifacts,
    this.stagePhase,
    this.feedback,
    this.incomplete = false,
    this.isDocument = false,
    this.documentFormat = 'pdf',
    List<String>? attachments,
    List<ComposerAttachment>? files,
    List<Map<String, dynamic>>? imageRefs,
  })  : artifacts = artifacts ?? [],
        attachments = attachments ?? [],
        files = files ?? [],
        imageRefs = imageRefs ?? [];

  bool get isUser => role == 'user';

  /// True once the message has a backend-assigned id (not a local placeholder),
  /// so per-message actions (feedback / delete-to-regenerate) are usable.
  bool get hasServerId => !id.startsWith('local-');

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      intent: json['intent'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      createdAtIso: json['created_at'] as String?,
      feedback: json['feedback'] as String?,
      incomplete: json['incomplete'] == true,
      isDocument: json['is_document'] == true,
      documentFormat: (json['document_format'] as String?) ?? 'pdf',
      attachments:
          (json['attachments'] as List<dynamic>?)?.cast<String>() ?? const [],
      imageRefs: (json['image_refs'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
    );
  }

  /// A local-only placeholder message (e.g. the assistant bubble that is
  /// being streamed into before the backend assigns it a real id).
  factory Message.placeholder({required String role}) {
    return Message(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: role,
      content: '',
      createdAt: DateTime.now(),
    );
  }
}

/// Lightweight row for the Solve history drawer (GET /api/solve/sessions).
class SolveSummary {
  final String id;
  final String title;
  final String source;          // 'text' | 'image'
  final String? language;
  final DateTime createdAt;

  SolveSummary({
    required this.id,
    required this.title,
    required this.source,
    required this.createdAt,
    this.language,
  });

  factory SolveSummary.fromJson(Map<String, dynamic> j) {
    return SolveSummary(
      id: j['id'] as String,
      title: j['title'] as String? ?? '(untitled)',
      source: j['source'] as String? ?? 'text',
      language: j['language'] as String?,
      createdAt: DateTime.parse(j['created_at'] as String),
    );
  }
}

/// Full Solve session — problem statement + model response + metadata.
/// Used by the Solve screen to rehydrate a past solve from the history.
class SolveDetail {
  final String id;
  final String title;
  final String description;
  final String response;
  final String? language;
  final String source;
  final String? imagePath;
  final String? visionModel;
  final String? codeModel;
  final int latencyMs;
  final DateTime createdAt;

  SolveDetail({
    required this.id,
    required this.title,
    required this.description,
    required this.response,
    required this.source,
    required this.latencyMs,
    required this.createdAt,
    this.language,
    this.imagePath,
    this.visionModel,
    this.codeModel,
  });

  factory SolveDetail.fromJson(Map<String, dynamic> j) {
    return SolveDetail(
      id: j['id'] as String,
      title: j['title'] as String? ?? '(untitled)',
      description: j['description'] as String? ?? '',
      response: j['response'] as String? ?? '',
      language: j['language'] as String?,
      source: j['source'] as String? ?? 'text',
      imagePath: j['image_path'] as String?,
      visionModel: j['vision_model'] as String?,
      codeModel: j['code_model'] as String?,
      latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(j['created_at'] as String),
    );
  }
}


/// A conversation summary as returned by GET /api/conversations.
class ConversationSummary {
  final String id;
  final String title;
  final DateTime updatedAt;

  ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    return ConversationSummary(
      id: json['id'] as String,
      title: json['title'] as String,
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

/// A persisted live-interview session (org name + created date) for the
/// Live module's history sidebar.
class LiveSessionSummary {
  final String id;
  final String title; // org name
  final String orgName;
  final DateTime? startedAt;
  final int messageCount;

  LiveSessionSummary({
    required this.id,
    required this.title,
    required this.orgName,
    required this.startedAt,
    required this.messageCount,
  });

  factory LiveSessionSummary.fromJson(Map<String, dynamic> json) {
    final started = json['started_at'] as String?;
    return LiveSessionSummary(
      id: json['id'] as String,
      title: (json['title'] as String?) ?? 'Interview',
      orgName: (json['org_name'] as String?) ?? (json['title'] as String? ?? ''),
      startedAt: started != null ? DateTime.tryParse(started) : null,
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One event from the /api/chat/stream SSE endpoint.
///
/// Event types: "meta", "token", "done", "error".
class StreamEvent {
  final String event;
  final Map<String, dynamic> data;

  StreamEvent(this.event, this.data);
}

/// A summary row for the resume list (GET /api/resumes).
class ResumeSummary {
  final String id;
  final String displayName;
  final String filename;
  final DateTime createdAt;

  ResumeSummary({
    required this.id,
    required this.displayName,
    required this.filename,
    required this.createdAt,
  });

  factory ResumeSummary.fromJson(Map<String, dynamic> json) {
    return ResumeSummary(
      id: json['id'] as String,
      displayName: json['display_name'] as String,
      filename: json['filename'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Full resume + parsed profile (POST /api/resume/upload, GET /api/resume/{id}).
class ResumeDetail {
  final String id;
  final String displayName;
  final String filename;
  final Map<String, dynamic> profile;
  final DateTime createdAt;

  ResumeDetail({
    required this.id,
    required this.displayName,
    required this.filename,
    required this.profile,
    required this.createdAt,
  });

  /// The upload endpoint returns "resume_id" instead of "id"; the detail
  /// endpoint returns "id". This factory accepts either shape.
  factory ResumeDetail.fromJson(Map<String, dynamic> json) {
    return ResumeDetail(
      id: (json['id'] ?? json['resume_id']) as String,
      displayName: json['display_name'] as String,
      filename: json['filename'] as String,
      profile: (json['profile'] as Map?)?.cast<String, dynamic>() ?? {},
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
