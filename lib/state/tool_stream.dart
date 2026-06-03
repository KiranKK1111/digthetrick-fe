/// Live view of one turn's agent activity.
///
/// The Chat screen pushes SSE events into this notifier as they
/// arrive; the WorkspaceShell's context pane subscribes and renders
/// tool-chips + the final episode id (so 👍/👎 work).
///
/// One [ToolStream] per [AppState] — turns are mutually exclusive
/// (the user can only have one in-flight). When a new turn starts,
/// call [startTurn] to clear the previous state.
///
/// The supervisor forwards a `data` payload on `tool` frames for the
/// whitelist `{evidence, memory_hits, grounding, critiques,
/// suggestions}`. We stash the latest payload per slot so the context
/// pane can render typed sections — suggestions in a rail, memory
/// hits in a list, critic issues as a bulleted set, evidence chunks
/// as numbered citations.
library;

import 'package:flutter/foundation.dart';

class ToolActivity {
  /// Agent name (e.g. "retriever", "memory", "grounder").
  final String name;
  /// Blackboard slot that was written (e.g. "evidence", "critiques").
  /// Empty for higher-level supervisor events.
  final String key;
  /// "running" | "done" | "flagged".
  String status;
  final DateTime at;

  ToolActivity({
    required this.name,
    required this.key,
    this.status = 'done',
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

class MemoryHit {
  final String id;
  final String question;
  final String preview;
  final String intent;
  final String? feedback;
  const MemoryHit({
    required this.id,
    required this.question,
    required this.preview,
    required this.intent,
    this.feedback,
  });

  factory MemoryHit.fromJson(Map<String, dynamic> j) => MemoryHit(
        id: j['id'] as String? ?? '',
        question: j['question'] as String? ?? '',
        preview: (j['final_preview'] ?? j['final'] ?? '') as String,
        intent: j['intent'] as String? ?? 'general',
        feedback: j['feedback'] as String?,
      );
}

class EvidenceChunkView {
  final String text;
  final String source;
  final double score;
  const EvidenceChunkView({
    required this.text,
    required this.source,
    required this.score,
  });

  factory EvidenceChunkView.fromJson(Map<String, dynamic> j) {
    final raw = j['score'];
    return EvidenceChunkView(
      text: j['text'] as String? ?? '',
      source: j['source'] as String? ?? '',
      score: (raw is num) ? raw.toDouble() : 0.0,
    );
  }
}

class ToolStream extends ChangeNotifier {
  final List<ToolActivity> _events = [];
  String? _intent;
  String? _episodeId;
  String? _conversationId;
  String? _sessionId;
  int _latencyMs = 0;

  // Latest payload per (slot key). Populated by `onTool` when the
  // server attached a `data` field.
  List<String> _suggestions = const [];
  List<MemoryHit> _memoryHits = const [];
  List<String> _criticIssues = const [];
  List<String> _criticSuggestions = const [];
  List<String> _verifiedClaims = const [];
  List<String> _unverifiedClaims = const [];
  List<EvidenceChunkView> _evidence = const [];
  // Architecture.md §"Conversation link graph" — candidate prior
  // sessions this turn might continue. The ContextPane renders these
  // as confirm-suggest chips.
  List<Map<String, dynamic>> _continuations = const [];

  List<ToolActivity> get events => List.unmodifiable(_events);
  String? get intent => _intent;
  String? get episodeId => _episodeId;
  String? get conversationId => _conversationId;
  String? get sessionId => _sessionId;
  int get latencyMs => _latencyMs;

  List<String> get suggestions => _suggestions;
  List<MemoryHit> get memoryHits => _memoryHits;
  List<String> get criticIssues => _criticIssues;
  List<String> get criticSuggestions => _criticSuggestions;
  List<String> get verifiedClaims => _verifiedClaims;
  List<String> get unverifiedClaims => _unverifiedClaims;
  List<EvidenceChunkView> get evidence => _evidence;
  List<Map<String, dynamic>> get continuations => _continuations;

  /// Most recent activity per (name+key) — collapses chatty writes
  /// into one chip per agent slot.
  List<ToolActivity> get groupedActivity {
    final byKey = <String, ToolActivity>{};
    for (final a in _events) {
      byKey['${a.name}:${a.key}'] = a;
    }
    final out = byKey.values.toList();
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  void startTurn() {
    _events.clear();
    _intent = null;
    _episodeId = null;
    _latencyMs = 0;
    _suggestions = const [];
    _memoryHits = const [];
    _criticIssues = const [];
    _criticSuggestions = const [];
    _verifiedClaims = const [];
    _unverifiedClaims = const [];
    _evidence = const [];
    _continuations = const [];
    notifyListeners();
  }

  void onMeta(Map<String, dynamic> data) {
    if (data.containsKey('conversation_id')) {
      _conversationId = data['conversation_id'] as String?;
    }
    if (data.containsKey('session_id')) {
      _sessionId = data['session_id'] as String?;
    }
    final intent = data['intent'];
    if (intent is Map && intent['type'] is String) {
      _intent = intent['type'] as String;
    } else if (intent is String) {
      _intent = intent;
    }
    notifyListeners();
  }

  void onTool(Map<String, dynamic> data) {
    // Continuation suggestions arrive as a synthetic tool event with
    // `kind == 'continuation'` (the chat screen funnels the
    // `continuation` SSE frame through here). Capture them separately
    // so the ContextPane can render confirm-suggest chips.
    if (data['kind'] == 'continuation') {
      final cands = (data['candidates'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const [];
      _continuations = cands;
      notifyListeners();
      return;
    }

    final name = (data['name'] as String?) ?? 'tool';
    final key = (data['key'] as String?) ?? '';
    final status = (data['status'] as String?) ?? 'done';
    _events.add(ToolActivity(name: name, key: key, status: status));

    // Parse the payload for whitelisted slots. The server (supervisor
    // _serialize_slot) only includes `data` for the whitelist, so this
    // is a no-op for chatty supervisor housekeeping writes.
    final payload = data['data'];
    if (payload is Map<String, dynamic>) {
      _absorbPayload(key, payload);
    }
    notifyListeners();
  }

  /// User accepted or dismissed a continuation suggestion. Clears the
  /// chip strip so it doesn't linger across turns.
  void clearContinuations() {
    if (_continuations.isEmpty) return;
    _continuations = const [];
    notifyListeners();
  }

  void _absorbPayload(String slotKey, Map<String, dynamic> payload) {
    switch (slotKey) {
      case 'suggestions':
        final proactive = payload['proactive'];
        if (proactive is List) {
          _suggestions =
              proactive.whereType<String>().toList(growable: false);
        }
        break;
      case 'memory_hits':
        final eps = payload['episodes'];
        if (eps is List) {
          _memoryHits = eps
              .whereType<Map>()
              .map((m) => MemoryHit.fromJson(m.cast<String, dynamic>()))
              .toList(growable: false);
        }
        break;
      case 'critiques':
        final issues = payload['issues'];
        final sugg = payload['suggestions'];
        if (issues is List) {
          _criticIssues =
              issues.whereType<String>().toList(growable: false);
        }
        if (sugg is List) {
          _criticSuggestions =
              sugg.whereType<String>().toList(growable: false);
        }
        break;
      case 'grounding':
        final v = payload['verified_claims'];
        final u = payload['unverified'];
        if (v is List) {
          _verifiedClaims = v.whereType<String>().toList(growable: false);
        }
        if (u is List) {
          _unverifiedClaims = u.whereType<String>().toList(growable: false);
        }
        break;
      case 'evidence':
        final chunks = payload['chunks'];
        if (chunks is List) {
          _evidence = chunks
              .whereType<Map>()
              .map((m) => EvidenceChunkView.fromJson(m.cast<String, dynamic>()))
              .toList(growable: false);
        }
        break;
    }
  }

  void onDone(Map<String, dynamic> data) {
    _episodeId = data['episode_id'] as String?;
    final l = data['latency_ms'];
    _latencyMs = (l is num) ? l.toInt() : 0;
    notifyListeners();
  }

  void onError(String detail) {
    _events.add(
      ToolActivity(name: 'error', key: detail, status: 'flagged'),
    );
    notifyListeners();
  }
}
