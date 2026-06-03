/// The chat screen: message list + composer in a Claude-style layout.
///
/// **Chrome ownership:** the shell owns the only top header and the
/// persistent sidebar. This screen publishes:
///   * a "New chat" button into [AppState.headerActions]
///   * a backend-status line into [AppState.headerSubtitle]
///   * a Conversations list into [AppState.sidebarExtras]
/// so the user gets a single, unified surround.
///
/// **Layout:** the messages stream into a centered column capped at
/// 768 px so long lines don't sprawl on wide displays. Assistant
/// messages render frameless (no bubble) so the rich markdown reads
/// like a document; user messages still get a small rounded chip on
/// the right. The composer is a single rounded card with the depth
/// chips inline above the input — fewer surfaces, more focus.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../layout/modules.dart' show kModuleChat;
import '../models/models.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../widgets/clarification_panel.dart';
import '../widgets/depth_controls.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sidebar_recents.dart';
import '../widgets/smart_composer.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _api = ApiService();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  // Per-message GlobalKeys so the right-side minimap can scroll to a turn.
  final Map<String, GlobalKey> _msgKeys = {};
  GlobalKey _keyFor(String id) => _msgKeys.putIfAbsent(id, () => GlobalKey());

  /// Smooth-scroll the message with [id] into view (minimap tap).
  ///
  /// The stream is a `ListView.builder`, so an off-screen target hasn't been
  /// built yet and has no `currentContext`. In that case we first animate to a
  /// rough offset (estimated from the message's index), which builds the target,
  /// then `ensureVisible` snaps it precisely — this is what makes the minimap
  /// actually redirect to messages that are scrolled out of view.
  void _jumpToMessage(String id) {
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
      return;
    }
    if (!_scroll.hasClients) return;
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final frac = _messages.length <= 1 ? 0.0 : idx / (_messages.length - 1);
    final pos = _scroll.position;
    final target = (pos.maxScrollExtent * frac).clamp(0.0, pos.maxScrollExtent);
    _scroll
        .animateTo(target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut)
        .then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _msgKeys[id]?.currentContext;
        if (c != null) {
          Scrollable.ensureVisible(
            c,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: 0.1,
          );
        }
      });
    });
  }

  final List<Message> _messages = [];
  String? _conversationId;
  // Id of the user message currently being edited inline (Claude-style),
  // rendered as an in-bubble editor with Cancel/Send. Null = not editing.
  String? _editingMessageId;

  List<ConversationSummary> _conversations = const [];
  bool _loadingHistory = false;

  bool _isStreaming = false;
  // Set when the user taps Stop; the stream loop breaks at the next event,
  // cancelling the request so the backend persists the partial.
  bool _stopRequested = false;
  String? _errorBanner;
  String _backendStatus = 'checking…';

  // ---- Smooth typewriter + auto-follow ----
  // A single vsync ticker drives BOTH the elegant character-by-character reveal
  // of the streaming reply AND a frame-eased scroll-follow. Tokens accumulate on
  // the message immediately; [_revealed] is how many characters are shown so far
  // and the ticker advances it toward the full length with an easing curve, so
  // the text glides in regardless of how bursty the network chunks are.
  Ticker? _typeTicker;
  int _revealed = 0;
  Duration _lastReveal = Duration.zero;
  // True while the last assistant reply is still being revealed — stays true
  // for a short tail AFTER the network stream ends so even a fast/short answer
  // gets the elegant typewriter instead of snapping in whole. The post-stream
  // work (reload-from-backend, doc auto-open) is deferred until this clears.
  bool _revealActive = false;
  VoidCallback? _onRevealComplete;
  // While true, the view eases itself to the bottom each frame. Disengaged the
  // instant the user scrolls up to re-read; re-engaged when they return to the
  // bottom. Programmatic follow-jumps never disengage it (they aren't user
  // scrolls), so generation and manual reading don't fight each other.
  bool _stickToBottom = true;

  // Claude-style multi-step "thinking" indicator. While we wait for the first
  // token (the provider's first-byte latency is the longest part of a turn),
  // cycle through these so the user sees real movement instead of a static
  // "Thinking". Stops the instant tokens arrive.
  Timer? _progressTimer;
  static const List<String> _kProgressSteps = [
    'Thinking',
    'Understanding the request',
    'Searching for context',
    'Reasoning it through',
    'Composing a response',
    'Refining the answer',
  ];

  ResponseDepth _depth = ResponseDepth.standard;
  List<ComposerAttachment> _attachments = const [];

  // Reverse pagination: a conversation opens with the most recent page and
  // fetches older batches as the user scrolls toward the top — so even a
  // 10k-message thread opens instantly.
  static const int _kPageSize = 50;
  bool _hasMoreOlder = false;
  bool _loadingOlder = false;

  // Floating "scroll to bottom" button — shown when scrolled away from the end.
  bool _showScrollDown = false;

  // File types accepted by drag-and-drop (matches the composer's picker).
  static const Set<String> _kAllowedDropExt = {
    'pdf', 'docx', 'xlsx', 'json', 'md', 'markdown', 'txt', 'csv',
    'png', 'jpg', 'jpeg', 'webp',
  };

  /// Files dropped anywhere in the app: keep the supported ones, attach them.
  Future<void> _onFilesDropped(List<XFile> files) async {
    final adds = <ComposerAttachment>[];
    var rejected = 0;
    var tooLarge = 0;
    for (final f in files) {
      final ext = f.name.contains('.')
          ? f.name.split('.').last.toLowerCase()
          : '';
      if (!_kAllowedDropExt.contains(ext)) {
        rejected++;
        continue;
      }
      try {
        final hasPath = f.path.isNotEmpty;
        // Get the size cheaply (no full read) so we can enforce the cap and,
        // on desktop, stream the file from its path during upload instead of
        // holding 100 MB in memory. Only fall back to reading bytes when the
        // platform gives us no path (web/mobile).
        final size = await f.length();
        if (size > kMaxUploadBytes) {
          tooLarge++;
          continue;
        }
        if (hasPath) {
          adds.add(ComposerAttachment(
            name: f.name,
            sizeBytes: size,
            path: f.path,
          ));
        } else {
          final bytes = await f.readAsBytes();
          adds.add(ComposerAttachment(
            name: f.name,
            sizeBytes: bytes.length,
            bytes: bytes,
          ));
        }
      } catch (_) {/* unreadable — skip */}
    }
    if (!mounted) return;
    // Cap the total at kMaxAttachments.
    final room = kMaxAttachments - _attachments.length;
    final accepted = room > 0 ? adds.take(room).toList() : <ComposerAttachment>[];
    final overflowed = adds.length - accepted.length;
    if (accepted.isNotEmpty) {
      setState(() => _attachments = [..._attachments, ...accepted]);
      _inputFocus.requestFocus();
    }
    if (tooLarge > 0 && accepted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Each file must be ${kMaxUploadBytes ~/ (1024 * 1024)} MB or '
            'smaller.'),
      ));
    } else if (overflowed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('You can attach up to $kMaxAttachments files.'),
      ));
    } else if (rejected > 0 && accepted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Unsupported file type. Allowed: pdf, docx, xlsx, json, md, '
            'txt, csv, png, jpg, jpeg, webp.'),
      ));
    }
  }

  // Claude-style AskUserQuestion: when the backend asks clarifying questions,
  // they render in a docked panel just above the composer (not as a bubble).
  // Empty = no pending clarification.
  List<ClarifyQuestion> _pendingClarification = const [];

  // Per-conversation composer drafts (text + attachments) so switching chat
  // sessions never leaks a half-typed prompt — each session keeps its own,
  // like Claude. Keyed by conversation id; '' is the unsaved "new chat" draft.
  final Map<String, _Draft> _drafts = {};
  String get _draftKey => _conversationId ?? '';

  /// Save the current composer contents under the active conversation.
  void _stashDraft() {
    _drafts[_draftKey] = _Draft(
      _input.text,
      List<ComposerAttachment>.from(_attachments),
    );
  }

  /// Load the composer contents for [key] (empty if none). Must run inside a
  /// setState so the attachment chips refresh.
  void _restoreDraft(String key) {
    final d = _drafts[key];
    _input.text = d?.text ?? '';
    _input.selection =
        TextSelection.collapsed(offset: _input.text.length);
    _attachments = d?.attachments ?? const [];
  }

  // This screen's module id (see lib/layout/modules.dart). We re-publish
  // chrome whenever this surface becomes active.
  static const String _kModuleId = kModuleChat;
  VoidCallback? _activeTabListener;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _checkBackend();
    _refreshHistory(autoLoadMostRecent: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _publishChrome();
      // Re-publish chrome every time the user returns to this tab —
      // IndexedStack keeps us alive but doesn't rebuild us on
      // tab-switch, so without this hook the shell's slots stay
      // empty after the user comes back.
      final state = context.read<AppState>();
      _activeTabListener = () {
        if (mounted && state.activeSurface.value == _kModuleId) {
          _publishChrome();
        }
      };
      state.activeSurface.addListener(_activeTabListener!);
      // Receive files dropped anywhere in the app (the shell owns the window-
      // wide DropTarget and routes them here).
      state.filesDroppedHandler =
          (files) => _onFilesDropped(files.cast<XFile>());
    });
  }

  @override
  void dispose() {
    // Clear our slots so the next tab doesn't inherit chat's buttons /
    // recents. Guard in try/catch because AppState may be disposing.
    try {
      final state = context.read<AppState>();
      state.setHeaderActions(const []);
      state.setHeaderSubtitle(null);
      state.setSidebarExtras(null);
      if (_activeTabListener != null) {
        state.activeSurface.removeListener(_activeTabListener!);
      }
      state.filesDroppedHandler = null;
    } catch (_) {}
    _typeTicker?.dispose();
    _progressTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Scroll handler: toggles the floating scroll-to-bottom button and triggers
  /// loading older messages when the user nears the top.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final showDown = (pos.maxScrollExtent - pos.pixels) > 400;
    if (showDown != _showScrollDown) {
      setState(() => _showScrollDown = showDown);
    }
    if (pos.pixels <= 200 && _hasMoreOlder && !_loadingOlder) {
      // ignore: unawaited_futures
      _loadOlder();
    }
  }

  /// Fetch the next older page and prepend it, keeping the viewport anchored on
  /// the same message (so scrolling up doesn't jump).
  Future<void> _loadOlder() async {
    final cid = _conversationId;
    final cursor = _messages.isNotEmpty ? _messages.first.createdAtIso : null;
    if (cid == null || cursor == null || _loadingOlder || !_hasMoreOlder) {
      return;
    }
    setState(() => _loadingOlder = true);
    try {
      final page = await _api.getConversationMessages(
        cid,
        limit: _kPageSize,
        before: cursor,
      );
      if (!mounted || _conversationId != cid) return;
      final beforeExtent =
          _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
      final beforePixels =
          _scroll.hasClients ? _scroll.position.pixels : 0.0;
      setState(() {
        _messages.insertAll(0, page.messages);
        _hasMoreOlder = page.hasMore;
        _loadingOlder = false;
      });
      // Anchor the view: the content above grew by (newExtent - oldExtent).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final afterExtent = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(beforePixels + (afterExtent - beforeExtent));
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// Push our header actions + subtitle + sidebar recents into the
  /// shell. Called whenever anything that affects them changes.
  void _publishChrome() {
    if (!mounted) return;
    final state = context.read<AppState>();
    // Only the active surface owns the chrome. Without this guard an async
    // callback (e.g. our own history load finishing after the user switched
    // away) would clobber another module's sidebar — the intermittent
    // "Solve history shows on Chat" bug.
    if (state.activeSurface.value != _kModuleId) return;
    state.setHeaderSubtitle(_backendStatus);
    // Chat has no per-tab header actions — the "+ New chat" lives in
    // the sidebar where it belongs (alongside the conversation list).
    state.setHeaderActions(const []);
    state.setSidebarExtras(
      SidebarRecents(
        heading: 'Conversations',
        newLabel: 'New chat',
        emptyLabel: 'No conversations yet.\nAsk anything to start one.',
        items: [
          for (final c in _conversations)
            SidebarRecentItem(
              id: c.id,
              title: c.title.isEmpty ? '(untitled)' : c.title,
              timestamp: c.updatedAt,
            ),
        ],
        activeId: _conversationId,
        loading: _loadingHistory,
        onSelect: _loadConversation,
        onNew: _isStreaming ? () {} : _newConversation,
        onRename: (id, newTitle) async {
          try {
            await _api.patchConversation(id, title: newTitle);
            await _refreshHistory();
          } on ApiException catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Rename failed: ${e.message}')),
            );
          }
        },
        onDelete: (id) async {
          try {
            await _api.deleteConversation(id);
            if (id == _conversationId) {
              setState(() {
                _conversationId = null;
                _messages.clear();
              });
            }
            await _refreshHistory();
          } on ApiException catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Delete failed: ${e.message}')),
            );
          }
        },
      ),
    );
  }

  Future<void> _checkBackend() async {
    try {
      final health = await _api.health();
      if (!mounted) return;
      setState(() {
        _backendStatus =
          '${health['provider']} · ${health['llm']} · ${health['model']}';
      });
      _publishChrome();
    } catch (_) {
      if (!mounted) return;
      setState(() => _backendStatus = 'backend unreachable');
      _publishChrome();
    }
  }

  /// Scroll to the bottom (used after sending / loading a conversation).
  ///
  /// Content keeps growing after the first layout — mermaid diagrams and images
  /// render asynchronously and extend the list — so a single scroll lands short
  /// of the true bottom. We nudge repeatedly over ~1s, re-scrolling whenever
  /// more content appears below, so it reliably reaches the very end. [jump]
  /// snaps instantly (used on conversation load); otherwise it animates.
  void _scrollToBottom({bool jump = false}) {
    var attempts = 0;
    // On load (jump), pin to the bottom for ~2s so a slow-rendering diagram
    // (webview) that extends the list afterwards is still caught.
    final maxAttempts = jump ? 14 : 8;
    void go() {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(max);
      } else {
        _scroll.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      attempts++;
      if (attempts < maxAttempts) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted || !_scroll.hasClients) return;
          // Load: keep re-pinning through late content growth. Send: stop once
          // we're already at the end (don't fight a user scrolling up).
          if (jump ||
              _scroll.position.pixels <
                  _scroll.position.maxScrollExtent - 4) {
            go();
          }
        });
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => go());
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels < 280;
  }

  /// Ensure the typewriter/auto-follow ticker is running. Cheap to call on
  /// every token — it only (re)starts when idle.
  void _ensureTyping() {
    _typeTicker ??= createTicker(_onTick);
    if (!_typeTicker!.isActive) {
      _lastReveal = Duration.zero;
      _typeTicker!.start();
    }
  }

  /// Per-frame driver: eases the scroll to the bottom every frame (cheap, no
  /// rebuild) and, throttled to ~30fps, reveals a few more characters of the
  /// streaming reply (which re-parses the markdown — hence the throttle).
  void _onTick(Duration elapsed) {
    _smoothFollow();

    // Throttle the text reveal + markdown reparse to ~33ms.
    if (elapsed - _lastReveal < const Duration(milliseconds: 33)) return;
    _lastReveal = elapsed;

    final idx = _messages.lastIndexWhere((m) => !m.isUser);
    if (idx == -1) {
      if (!_isStreaming) _completeReveal();
      return;
    }
    final full = _messages[idx].content.length;
    if (_revealed < full) {
      final backlog = full - _revealed;
      // Eased catch-up: far behind → reveal faster; near the tail → glide.
      var step = (backlog * 0.30).ceil();
      if (step < 2) step = 2;
      _revealed += step;
      if (_revealed > full) _revealed = full;
      if (mounted) setState(() {});
    } else if (!_isStreaming) {
      // Fully revealed and the stream is done → finish + run deferred tail.
      _completeReveal();
    }
  }

  /// Reveal finished (and the network stream has ended): stop the ticker, drop
  /// the typewriter clamp, and run whatever post-stream work was deferred.
  void _completeReveal() {
    if (!_revealActive && _onRevealComplete == null) {
      _typeTicker?.stop();
      return;
    }
    _revealActive = false;
    _typeTicker?.stop();
    final cb = _onRevealComplete;
    _onRevealComplete = null;
    if (mounted) setState(() {});
    cb?.call();
  }

  /// Glide the viewport toward the bottom (30% of the remaining gap per frame)
  /// while stuck-to-bottom — a smooth follow instead of a hard jump.
  void _smoothFollow() {
    if (!_stickToBottom || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = pos.maxScrollExtent;
    final diff = target - pos.pixels;
    if (diff <= 0.5) return;
    final next = pos.pixels + diff * 0.30;
    _scroll.jumpTo(next >= target ? target : next);
  }

  /// User-driven scroll: disengage auto-follow the moment they scroll up to
  /// re-read; re-engage once they return to the bottom.
  void _onUserScroll(ScrollDirection dir) {
    if (dir == ScrollDirection.forward) {
      // Scrolling up toward older messages.
      if (_stickToBottom) _stickToBottom = false;
    } else if (dir == ScrollDirection.reverse) {
      // Scrolling back down — resume following once at the bottom.
      if (!_stickToBottom && _isNearBottom) _stickToBottom = true;
    }
  }


  /// Begin cycling the progressive "thinking" steps for the streaming bubble.
  void _startProgress(String assistantId) {
    _progressTimer?.cancel();
    var i = 0;
    void apply() {
      final idx = _messages.indexWhere((m) => m.id == assistantId);
      if (idx == -1 || _messages[idx].content.isNotEmpty || !_isStreaming) {
        _progressTimer?.cancel();
        return;
      }
      setState(() => _messages[idx].stagePhase = _kProgressSteps[i]);
    }

    apply();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 1300), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      // Advance, holding on the last step until tokens arrive.
      if (i < _kProgressSteps.length - 1) i++;
      apply();
    });
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// Stop an in-flight generation. The stream loop breaks on the next event,
  /// which cancels the HTTP request; the backend saves the partial as
  /// incomplete and the bubble shows Continue / Retry.
  void _stopStreaming() {
    if (_isStreaming) setState(() => _stopRequested = true);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    // Allow sending with attachments only (no text needed to "analyze this").
    if ((text.isEmpty && _attachments.isEmpty) || _isStreaming) return;
    // Typing directly answers / dismisses any pending clarification panel.
    if (_pendingClarification.isNotEmpty) {
      setState(() => _pendingClarification = const []);
      _persistClarification(_conversationId, const []);
    }
    final attachments = List<ComposerAttachment>.from(_attachments);
    _input.clear();
    setState(() => _attachments = const []);
    await _sendMessage(text, attachments);
  }

  /// Core send used by both the composer and inline-edit re-sends.
  Future<void> _sendMessage(
    String text,
    List<ComposerAttachment> attachments, {
    Message? reuseUserMsg,
  }) async {
    if (_isStreaming) return;
    final appState = context.read<AppState>();
    final toolStream = appState.toolStream..startTurn();
    _stopRequested = false;

    setState(() {
      _errorBanner = null;
      _isStreaming = true;
      // Fresh turn → reset the typewriter and re-arm auto-follow.
      _revealed = 0;
      _revealActive = true;
      _onRevealComplete = null;
      _stickToBottom = true;
      // On a regenerate-in-place retry we keep the EXISTING user bubble (and
      // its attachment chips) instead of appending a duplicate.
      if (reuseUserMsg == null) {
        _messages.add(Message(
          id: 'local-user-${DateTime.now().microsecondsSinceEpoch}',
          role: 'user',
          content: text,
          createdAt: DateTime.now(),
          attachments: attachments.map((a) => a.name).toList(),
          files: attachments, // retained so an inline edit can show/replace them
        ));
      }
      _messages.add(Message.placeholder(role: 'assistant'));
    });
    _publishChrome();
    _scrollToBottom();

    final assistantMsg = _messages.last;
    _startProgress(assistantMsg.id); // cycle "thinking" steps until first token

    // Only attachments with real bytes/path can be multipart-uploaded.
    // History-loaded (persisted) chips carry just a name — their RAG vectors
    // already live in the conversation's vector collection, so a text-only
    // turn still retrieves them; no re-upload needed.
    final uploadable =
        attachments.where((a) => a.isUploadable).toList();

    // Attachments → multipart upload endpoint (RAG + vision routing);
    // otherwise the normal agents stream.
    final stream = uploadable.isNotEmpty
        ? _api.streamChatUpload(
            message: text,
            conversationId: _conversationId,
            sessionId: appState.sessionId,
            depth: _depth.apiValue,
            attachments: uploadable,
          )
        : _api.streamAgents(
            message: text,
            conversationId: _conversationId,
            sessionId: appState.sessionId,
            depth: _depth.apiValue,
          );

    // Set when the backend asks a clarifying question instead of answering.
    // The clarification cards live only in memory, so we must NOT reload the
    // conversation from the backend afterwards (that would wipe them).
    bool clarified = false;
    try {
      await for (final event in stream) {
        // Stop pressed: break out, which cancels the stream subscription and
        // closes the HTTP connection — the backend then persists the partial
        // (marked incomplete). The local partial is kept and flagged below.
        if (_stopRequested) break;
        switch (event.event) {
          case 'meta':
            toolStream.onMeta(event.data);
            final cid = event.data['conversation_id'] as String?;
            if (cid != null) _conversationId = cid;
            final intent = event.data['intent'];
            final intentLabel = intent is Map ? intent['type'] as String? : null;
            if (intentLabel != null) {
              setState(() {
                final idx = _messages.indexOf(assistantMsg);
                if (idx != -1) {
                  _messages[idx] = Message(
                    id: assistantMsg.id,
                    role: 'assistant',
                    content: assistantMsg.content,
                    intent: intentLabel,
                    createdAt: assistantMsg.createdAt,
                  );
                }
              });
            }
            break;

          case 'tool':
            toolStream.onTool(event.data);
            break;

          case 'clarify':
            // Structured AskUserQuestion payload → show the docked panel above
            // the composer and drop the empty assistant placeholder bubble.
            final qs = ClarifyQuestion.listFrom(event.data['questions']);
            if (qs.isNotEmpty) {
              clarified = true;
              setState(() {
                final idx =
                    _messages.indexWhere((m) => m.id == assistantMsg.id);
                if (idx != -1 && _messages[idx].content.isEmpty) {
                  _messages.removeAt(idx);
                }
                _pendingClarification = qs;
              });
              // Survive a restart: re-pops on this conversation until answered.
              // ignore: unawaited_futures
              _persistClarification(_conversationId, qs);
            }
            break;

          case 'token':
            // First token → the answer is arriving; stop cycling the steps.
            _stopProgress();
            // Append immediately (cheap); the ticker reveals + repaints the new
            // text smoothly instead of repainting on every raw chunk.
            final idx =
                _messages.indexWhere((m) => m.id == assistantMsg.id);
            if (idx != -1) {
              _messages[idx].content += event.data['text'] as String;
              _messages[idx].stagePhase = 'token';
            }
            _ensureTyping();
            break;

          case 'stage':
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
              if (idx != -1) {
                _messages[idx].stagePhase = event.data['name'] as String?;
              }
            });
            break;

          case 'artifacts':
            final items = (event.data['items'] as List?)
                    ?.cast<Map<String, dynamic>>() ??
                const [];
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
              if (idx != -1) {
                _messages[idx].artifacts = items;
              }
            });
            break;

          case 'continuation':
            final cands = (event.data['candidates'] as List?)
                    ?.cast<Map<String, dynamic>>() ??
                const [];
            if (cands.isNotEmpty) {
              toolStream.onTool({
                'kind': 'continuation',
                'candidates': cands,
              });
            }
            break;

          case 'done':
            toolStream.onDone(event.data);
            final realId = event.data['message_id'] as String?;
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
              if (idx != -1) {
                _messages[idx].stagePhase = null;
                // Adopt the backend id so feedback / retry target the real row.
                if (realId != null) _messages[idx].id = realId;
              }
            });
            break;

          case 'error':
            final detail = event.data['detail'] as String? ?? 'Unknown error';
            toolStream.onError(detail);
            setState(() => _errorBanner = detail);
            break;
        }
      }
    } on ApiException catch (e) {
      toolStream.onError(e.message);
      setState(() => _errorBanner = e.message);
    } catch (e) {
      toolStream.onError('$e');
      setState(() => _errorBanner = 'Unexpected error: $e');
    } finally {
      final stopped = _stopRequested;
      _stopRequested = false;
      _stopProgress();
      if (mounted) {
        // The post-stream tail — refresh history, re-pull rows from the backend
        // (so each carries its real id + feedback), and auto-open a document if
        // one was requested. Deferred until the typewriter finishes so the
        // reload (which replaces the message list) can't cut the reveal short.
        void finishUp() {
          if (!mounted) return;
          // ignore: unawaited_futures
          _refreshHistory();
          // Skipped on error, before a conversation id exists, when this turn
          // uploaded real files (reloading drops retained file bytes), or when
          // STOPPED — a stopped turn's partial is saved by a detached backend
          // task that may not have committed yet, so reloading now could wipe
          // the local partial. The next load reconciles.
          if (_conversationId != null &&
              _errorBanner == null &&
              uploadable.isEmpty &&
              !clarified &&
              !stopped) {
            // ignore: unawaited_futures
            _reloadMessages();
          }
          _publishChrome();

          // Only when the user EXPLICITLY asked to create a document.
          if (!stopped &&
              _errorBanner == null &&
              !clarified &&
              _docRequestInWindow(text) &&
              assistantMsg.content.trim().length > 400) {
            final fmt = _docFormatInWindow(text);
            setState(() {
              assistantMsg.isDocument = true;
              assistantMsg.documentFormat = fmt;
            });
            appState.openDocument(
              content: assistantMsg.content,
              title: _docTitleFrom(assistantMsg.content),
              name: _docTitleFrom(assistantMsg.content),
              format: fmt,
            );
          }
        }

        setState(() {
          _isStreaming = false;
          final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
          if (idx == -1) return;
          if (_messages[idx].content.isEmpty && _errorBanner != null) {
            _messages.removeAt(idx);
          } else if (stopped) {
            // Flag the local partial as interrupted so the bubble offers
            // Continue / Retry immediately (the backend saved it incomplete).
            _messages[idx].stagePhase = null;
            _messages[idx].incomplete = true;
          }
        });

        // On a clean finish, let the typewriter glide to the end, THEN run the
        // tail. On stop/error there's nothing to glide elegantly — snap the
        // partial to full and run the tail immediately.
        if (!stopped && _errorBanner == null) {
          _onRevealComplete = finishUp;
          _ensureTyping(); // drains remaining chars, then invokes finishUp
        } else {
          _revealActive = false;
          _onRevealComplete = null;
          _typeTicker?.stop();
          setState(() {});
          finishUp();
        }
      }
    }
  }

  /// True when the message asks to turn content into a document/file — either
  /// "<verb> … <document-noun>" or "<in|as|into> a <document-noun>"
  /// ("I want this in a document", "export it as Excel"). Mirrors the backend
  /// `app/documents/detect.py`.
  bool _isDocRequest(String msg) {
    final m = msg.toLowerCase();
    final asDoc = RegExp(
            r'\b(?:in|into|as)\s+(?:a |an )?(?:document|doc|pdf|word|docx|excel|xlsx|spreadsheet|csv|report|one[- ]?pager|deck|presentation)\b')
        .hasMatch(m);
    final verb = RegExp(
            r'\b(create|generate|make|build|export|produce|draft|prepare|compose|put|save|turn|convert|render|download|format|email|send|give me|write me)\b')
        .hasMatch(m);
    final noun = RegExp(
            r'\b(document|pdf|word|docx|excel|xlsx|spreadsheet|csv|report|whitepaper|letter|invoice|brochure|one[- ]?pager|deck|presentation|datasheet|resume|cv)\b')
        .hasMatch(m);
    return asDoc || (verb && noun);
  }

  /// Was a document requested in this message OR the recent clarification
  /// exchange (the format/title answers that precede generation)?
  bool _docRequestInWindow(String currentText) {
    if (_isDocRequest(currentText)) return true;
    final priorUsers =
        _messages.where((m) => m.isUser).toList().reversed.take(3);
    return priorUsers.any((m) => _isDocRequest(m.content));
  }

  /// The file format the user named across the recent window (mirrors the
  /// backend `document_format`). Defaults to pdf.
  String _docFormatInWindow(String currentText) {
    final recent = [
      currentText,
      ..._messages.where((m) => m.isUser).toList().reversed.take(3).map(
            (m) => m.content,
          ),
    ].join(' ').toLowerCase();
    if (RegExp(r'\bpdf\b').hasMatch(recent)) return 'pdf';
    if (RegExp(r'\b(word|docx|ms ?word)\b').hasMatch(recent)) return 'docx';
    if (RegExp(r'\b(excel|xlsx|spreadsheet)\b').hasMatch(recent)) return 'xlsx';
    if (RegExp(r'\bcsv\b').hasMatch(recent)) return 'csv';
    if (RegExp(r'\b(markdown|\.md)\b').hasMatch(recent)) return 'md';
    if (RegExp(r'\b(plain ?text|text file|\.txt)\b').hasMatch(recent)) {
      return 'txt';
    }
    return 'pdf';
  }

  /// A short title from the answer's first heading / line.
  String _docTitleFrom(String content) {
    for (final raw in content.split('\n')) {
      final line = raw.replaceFirst(RegExp(r'^#{1,6}\s*'), '').trim();
      if (line.isEmpty) continue;
      final t = line
          .split(RegExp(r'\s+'))
          .take(7)
          .join(' ')
          .replaceAll(RegExp(r'[^\w \-]'), '')
          .trim();
      if (t.isNotEmpty) return t;
    }
    return 'Document';
  }

  /// Refresh the open conversation's messages from the backend in place
  /// (real ids + feedback), without the loading spinner / scroll reset of
  /// [_loadConversation].
  Future<void> _reloadMessages() async {
    final cid = _conversationId;
    if (cid == null || _isStreaming) return;
    try {
      // Re-fetch a window covering everything currently shown (so any older
      // pages the user scrolled up to load aren't dropped), with a little
      // headroom for the just-added turn.
      final limit =
          (_messages.length + 2) < _kPageSize ? _kPageSize : _messages.length + 2;
      final page = await _api.getConversationMessages(cid, limit: limit);
      if (!mounted || _isStreaming || _conversationId != cid) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(page.messages);
        _hasMoreOlder = page.hasMore;
      });
    } catch (_) {/* keep the local copy on failure */}
  }

  // ---- Per-message actions ---------------------------------------------

  /// Resume an interrupted assistant turn. The cut-short answer is in the
  /// conversation history, so a short "Continue" makes the model pick up where
  /// it stopped. The bubble shows just "Continue"; the interrupted bar is
  /// cleared locally + on the server so it doesn't reappear after reload.
  Future<void> _continueFrom(Message msg) async {
    if (_isStreaming) return;
    setState(() => msg.incomplete = false);
    if (msg.hasServerId) {
      // ignore: unawaited_futures
      _api.resolveMessage(msg.id).catchError((_) {});
    }
    await _sendMessage('Continue', const []);
  }

  /// Toggle 👍/👎 on an assistant message; persist + reflect optimistically.
  Future<void> _setFeedback(Message msg, String? signal) async {
    if (!msg.hasServerId) return;
    final prev = msg.feedback;
    setState(() => msg.feedback = signal);
    try {
      await _api.sendMessageFeedback(msg.id, signal);
    } catch (e) {
      if (mounted) setState(() => msg.feedback = prev); // revert on failure
    }
  }

  /// Enter inline-edit mode for a user message (renders an editor in place).
  void _beginEdit(Message userMsg) {
    if (_isStreaming) return;
    setState(() => _editingMessageId = userMsg.id);
  }

  void _cancelEdit() {
    if (_editingMessageId != null) setState(() => _editingMessageId = null);
  }

  /// Submit an inline edit Claude-style: drop the message (and everything
  /// after it) and stream a fresh turn from the edited text + edited files.
  Future<void> _submitEdit(
    Message userMsg,
    String newText,
    List<ComposerAttachment> files,
  ) async {
    if (_isStreaming) return;
    newText = newText.trim();
    setState(() => _editingMessageId = null);
    if (newText.isEmpty && files.isEmpty) return;
    final idx = _messages.indexOf(userMsg);
    try {
      if (userMsg.hasServerId) {
        await _api.deleteMessage(userMsg.id, cascade: 'after');
      }
    } catch (e) {
      if (mounted) setState(() => _errorBanner = 'Edit failed: $e');
      return;
    }
    setState(() {
      if (idx != -1) _messages.removeRange(idx, _messages.length);
    });
    await _sendMessage(newText, files);
  }

  /// Regenerate from a message: delete it + everything after (server-side),
  /// then re-send the preceding user message → fresh response in place.
  Future<void> _retryFrom(Message msg) async {
    if (_isStreaming) return;
    final idx = _messages.indexOf(msg);
    if (idx == -1) return;
    // The user turn that drives the (re)generation.
    final userMsg = msg.isUser
        ? msg
        : _messages.sublist(0, idx).lastWhere(
              (m) => m.isUser,
              orElse: () => msg,
            );
    if (!userMsg.isUser) return;
    final text = userMsg.content;
    // Preserve the original turn's files so a retry re-attaches them (image /
    // doc). In-session these still carry their bytes; after a reload only the
    // names remain (doc RAG vectors are already stored, so text-only retrieval
    // still works for documents).
    final files = List<ComposerAttachment>.from(userMsg.files);
    // After a reload the in-session bytes are gone. Images are persisted to the
    // blob store, so re-fetch them and re-attach as real uploadable files —
    // otherwise the retry would route to a text model and ignore the picture.
    if (!files.any((f) => f.isUploadable) && userMsg.imageRefs.isNotEmpty) {
      for (final ref in userMsg.imageRefs) {
        final path = (ref['path'] ?? '').toString();
        final name = (ref['name'] ?? 'image').toString();
        if (path.isEmpty) continue;
        final bytes = await _api.fetchAttachmentImage(path);
        if (bytes == null) continue;
        // Replace any name-only placeholder for this image with a real one.
        files.removeWhere((f) => f.name == name && !f.isUploadable);
        files.add(ComposerAttachment(
          name: name,
          sizeBytes: bytes.length,
          bytes: bytes,
        ));
      }
    }
    final uidx = _messages.indexOf(userMsg);

    // Does a real assistant answer already exist after this user turn?
    final hasAnswer = _messages
        .skip(uidx + 1)
        .any((m) => !m.isUser && m.content.trim().isNotEmpty);

    if (hasAnswer) {
      // Answer exists → retry = ask again as a NEW turn: a fresh user bubble
      // (with the same text + attachment) plus a new response.
      await _sendMessage(text, files);
      return;
    }

    // No answer yet (generation failed / was empty) → regenerate IN PLACE:
    // keep the existing user bubble, just run the response again with the
    // attachment. Delete the stale server turn first to avoid a duplicate,
    // then reuse the local user bubble.
    try {
      if (userMsg.hasServerId) {
        await _api.deleteMessage(userMsg.id, cascade: 'after');
      }
    } catch (e) {
      if (mounted) setState(() => _errorBanner = 'Retry failed: $e');
      return;
    }
    setState(() {
      // Drop any empty assistant placeholder after the user bubble.
      if (uidx != -1 && uidx + 1 <= _messages.length) {
        _messages.removeRange(uidx + 1, _messages.length);
      }
    });
    await _sendMessage(text, files, reuseUserMsg: userMsg);
  }

  /// The user answered the docked clarification panel. Send their selections
  /// as the next user turn — the model now has the missing detail and answers
  /// the original request.
  Future<void> _submitClarification(String answerText) async {
    setState(() => _pendingClarification = const []);
    _persistClarification(_conversationId, const []);
    if (_isStreaming) return;
    final text = answerText.trim();
    if (text.isEmpty) return;
    await _sendMessage(text, const []);
  }

  /// User dismissed the clarification (X) — drop it without answering.
  void _dismissClarification() {
    setState(() => _pendingClarification = const []);
    _persistClarification(_conversationId, const []);
  }

  // ---- clarification persistence ---------------------------------------
  // Pending clarifications survive an app restart so an unanswered question
  // re-pops on the same conversation. Stored locally (this app is single-user
  // / device-local), keyed by conversation id, cleared on answer/dismiss/send.
  static const String _kClarifyPrefix = 'pending_clarify_';

  Future<void> _persistClarification(
      String? convId, List<ClarifyQuestion> qs) async {
    if (convId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = '$_kClarifyPrefix$convId';
    if (qs.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, ClarifyQuestion.encodeList(qs));
    }
  }

  Future<List<ClarifyQuestion>> _loadPersistedClarification(
      String convId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_kClarifyPrefix$convId');
      if (raw == null) return const [];
      return ClarifyQuestion.listFrom(jsonDecode(raw));
    } catch (_) {
      return const [];
    }
  }

  void _newConversation() {
    _stashDraft();
    setState(() {
      _messages.clear();
      _conversationId = null;
      _errorBanner = null;
      _hasMoreOlder = false;
      _showScrollDown = false;
      _pendingClarification = const [];
      _restoreDraft(''); // the fresh "new chat" draft (usually empty)
    });
    _publishChrome();
    _inputFocus.requestFocus();
  }

  Future<void> _refreshHistory({bool autoLoadMostRecent = false}) async {
    if (_loadingHistory) return;
    setState(() => _loadingHistory = true);
    _publishChrome();
    try {
      final convos = await _api.listConversations(type: 'chat');
      if (!mounted) return;
      setState(() => _conversations = convos);
      if (autoLoadMostRecent && _conversationId == null && convos.isNotEmpty) {
        await _loadConversation(convos.first.id);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = 'Could not load history: ${e.message}');
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
        _publishChrome();
      }
    }
  }

  Future<void> _loadConversation(String conversationId) async {
    if (_isStreaming) return;
    // Stash the current session's draft before switching away from it.
    _stashDraft();
    setState(() {
      _loadingHistory = true;
      _errorBanner = null;
    });
    _publishChrome();
    try {
      // Open at the most-recent page; older messages stream in on scroll-up.
      final page = await _api.getConversationMessages(
        conversationId,
        limit: _kPageSize,
      );
      // Restore any unanswered clarification for this conversation so it
      // re-pops after a restart / when the user switches back to it.
      final pending = await _loadPersistedClarification(conversationId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(page.messages);
        _conversationId = conversationId;
        _hasMoreOlder = page.hasMore;
        _pendingClarification = pending;
        _restoreDraft(conversationId); // this session's own draft
      });
      _scrollToBottom(jump: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = e.message);
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
        _publishChrome();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(
        children: [
          if (_errorBanner != null) _ErrorBanner(message: _errorBanner!),
          Expanded(
            child: _messages.isEmpty
                ? _EmptyState(
                    onSuggestionTap: (text) {
                      _input.text = text;
                      _inputFocus.requestFocus();
                    },
                  )
                : Stack(
                    children: [
                      // SelectionArea hoists selection to the whole stream so
                      // a drag can span paragraphs and code blocks.
                      SelectionArea(
                        child: _MessageStream(
                          messages: _messages,
                          scroll: _scroll,
                          isStreaming: _isStreaming,
                          revealChars: _revealed,
                          revealActive: _revealActive,
                          onUserScroll: _onUserScroll,
                          editingId: _editingMessageId,
                          keyFor: _keyFor,
                          onEdit: _beginEdit,
                          onEditSubmit: _submitEdit,
                          onEditCancel: _cancelEdit,
                          onRetry: _retryFrom,
                          onFeedback: _setFeedback,
                          onContinue: _continueFrom,
                        ),
                      ),
                      // ChatGPT-style minimap: a tick per user turn near the
                      // right edge; hover previews the message, tap scrolls to
                      // it. Inset from the edge so it clears the scrollbar's
                      // drag area (otherwise it intercepts scrollbar clicks).
                      if (_messages.where((m) => m.isUser).length >= 3)
                        Positioned(
                          top: 12,
                          bottom: 12,
                          right: 14,
                          child: _MessageMinimap(
                            messages: _messages,
                            onJump: _jumpToMessage,
                          ),
                        ),
                      // Loading-older spinner at the very top while paging up.
                      if (_loadingOlder)
                        const Positioned(
                          top: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      // Floating "scroll to bottom" button, centered above the
                      // composer; shown only when scrolled away from the end.
                      if (_showScrollDown)
                        Positioned(
                          bottom: 10,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _ScrollToBottomButton(
                              onTap: () {
                                _scrollToBottom();
                                // Returning to the bottom re-arms auto-follow.
                                _stickToBottom = true;
                                setState(() => _showScrollDown = false);
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          // Docked clarification panel (Claude-style), just above the composer.
          if (_pendingClarification.isNotEmpty)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: ClarificationPanel(
                    questions: _pendingClarification,
                    onSubmit: _submitClarification,
                    onDismiss: _dismissClarification,
                  ),
                ),
              ),
            ),
          SmartComposer(
            controller: _input,
            focusNode: _inputFocus,
            enabled: !_isStreaming,
            isStreaming: _isStreaming,
            onStop: _stopStreaming,
            onSend: _send,
            depth: _depth,
            onDepthChanged: (d) => setState(() => _depth = d),
            attachments: _attachments,
            onAttachmentsChanged: (a) => setState(() => _attachments = a),
            hintText: _pendingClarification.isNotEmpty
                ? 'Or reply directly…'
                : 'Ask anything…',
            disabledHintText: 'Waiting for reply…',
            outerMaxWidth: 800,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          ),
        ],
      ),
    );
  }
}

// ---- Sub-widgets --------------------------------------------------------

/// A saved composer draft for one conversation (text + attachments).
class _Draft {
  _Draft(this.text, this.attachments);
  final String text;
  final List<ComposerAttachment> attachments;
}

/// Floating pill that jumps the chat to the newest message. Shown only when
/// the user has scrolled up away from the bottom.
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Icon(Icons.keyboard_arrow_down,
              size: 22, color: scheme.onSurface),
        ),
      ),
    );
  }
}

class _MessageStream extends StatelessWidget {
  const _MessageStream({
    required this.messages,
    required this.scroll,
    required this.isStreaming,
    required this.revealChars,
    required this.revealActive,
    required this.onUserScroll,
    required this.editingId,
    required this.keyFor,
    required this.onEdit,
    required this.onEditSubmit,
    required this.onEditCancel,
    required this.onRetry,
    required this.onFeedback,
    required this.onContinue,
  });

  final List<Message> messages;
  final ScrollController scroll;
  final bool isStreaming;
  // How many characters of the last assistant message to reveal — the chat
  // screen's typewriter advances this each frame for a smooth reveal.
  final int revealChars;
  // True while that reveal is in progress (during the stream and a short tail
  // after it ends), so even fast replies type out instead of snapping in.
  final bool revealActive;
  // Fired on user-driven scroll direction so the screen can engage/disengage
  // stick-to-bottom (so manual scroll-up isn't fought by auto-follow).
  final void Function(ScrollDirection) onUserScroll;
  final String? editingId;
  final GlobalKey Function(String id) keyFor;
  final void Function(Message) onEdit;
  final void Function(Message, String, List<ComposerAttachment>) onEditSubmit;
  final VoidCallback onEditCancel;
  final void Function(Message) onRetry;
  final void Function(Message, String?) onFeedback;
  final void Function(Message) onContinue;

  @override
  Widget build(BuildContext context) {
    // Layout:
    //   * The ListView fills the full window width so its scrollbar
    //     can live flush against the window's right edge (where users
    //     expect to find it).
    //   * Each MessageBubble is centered + constrained to 800px so
    //     the reading column stays narrow on wide displays.
    //
    // Putting the ConstrainedBox INSIDE each row (instead of
    // wrapping the whole ListView) is what moves the scrollbar
    // from "edge of the 800px content" to "edge of the window".
    // Disable the ScrollBehavior's automatic scrollbar so it doesn't stack a
    // second thumb on top of our explicit one (the cause of the odd
    // double/resizing thumb). One thin, themed scrollbar only.
    final scheme = Theme.of(context).colorScheme;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      // RawScrollbar with a fixed `minThumbLength` → the thumb keeps a stable
      // size instead of ballooning/shrinking as ListView.builder re-estimates
      // its extent from variable-height bubbles (ChatGPT-style steady pill).
      child: RawScrollbar(
      controller: scroll,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(8),
      minThumbLength: 56,
      interactive: true,
      thumbColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
      // Report user-driven scroll direction so the screen can stop auto-follow
      // the instant the user drags/wheels up to re-read (and resume when they
      // come back to the bottom). Programmatic follow jumps don't fire this.
      child: NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          onUserScroll(n.direction);
          return false;
        },
        // Freeze the chat's own scrolling while the cursor is over an in-chat
        // diagram, so the diagram's pan/zoom takes the wheel/drag instead.
        child: ValueListenableBuilder<bool>(
          valueListenable: context.read<AppState>().chatScrollLocked,
          builder: (context, locked, _) => ListView.builder(
          controller: scroll,
          // Momentum physics → ChatGPT-like fling/glide instead of the hard
          // clamping stop, while still always scrollable for the follow logic.
          // NeverScrollable while a diagram is grabbing input.
          physics: locked
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
          // Lay out more off-screen content so the scroll-extent estimate (and
          // thus the thumb size + scroll feel) stays stable while scrolling.
          // ignore: deprecated_member_use
          cacheExtent: 1800,
          padding: const EdgeInsets.symmetric(vertical: 24),
          itemCount: messages.length,
          itemBuilder: (context, i) {
            final msg = messages[i];
            final isLast = i == messages.length - 1;
            final streaming = isStreaming && isLast && !msg.isUser;
            // The last assistant bubble is the one being typed out — both while
            // the stream is live and during the brief tail after it ends.
            final revealing = revealActive && isLast && !msg.isUser;
            String? display;
            if (revealing && revealChars < msg.content.length) {
              display = msg.content
                  .substring(0, revealChars.clamp(0, msg.content.length));
            }
            return Align(
              key: keyFor(msg.id),
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MessageBubble(
                    message: msg,
                    // Keep the typing cursor through the tail reveal too.
                    isStreaming: streaming || revealing,
                    displayContent: display,
                    isEditing: msg.id == editingId,
                    // User: copy/edit/retry. Assistant: copy/like/dislike/retry.
                    onEdit: msg.isUser ? () => onEdit(msg) : null,
                    onEditSubmit: (txt, files) => onEditSubmit(msg, txt, files),
                    onEditCancel: onEditCancel,
                    onRetry: () => onRetry(msg),
                    onFeedback:
                        msg.isUser ? null : (sig) => onFeedback(msg, sig),
                    onContinue: msg.isUser ? null : () => onContinue(msg),
                  ),
                ),
              ),
            );
          },
        ),
        ),
      ),
      ),
    );
  }
}

/// ChatGPT-style right-edge minimap: a compact strip of up to 10 evenly-spaced
/// ticks. Hovering the strip pops a panel listing EVERY user prompt in the
/// thread; clicking a row (or a tick) scrolls that turn into view.
class _MessageMinimap extends StatefulWidget {
  const _MessageMinimap({required this.messages, required this.onJump});
  final List<Message> messages;
  final void Function(String id) onJump;

  @override
  State<_MessageMinimap> createState() => _MessageMinimapState();
}

class _MessageMinimapState extends State<_MessageMinimap> {
  // Max ticks shown on the strip (the popup lists all prompts regardless).
  static const int _maxTicks = 10;

  bool _hover = false;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  // Small grace delay so moving the cursor from the strip onto the popup
  // doesn't flicker the popup closed.
  void _setHover(bool v) {
    _hideTimer?.cancel();
    if (v) {
      if (!_hover) setState(() => _hover = true);
    } else {
      _hideTimer = Timer(const Duration(milliseconds: 140), () {
        if (mounted) setState(() => _hover = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final users = widget.messages
        .where((m) => m.isUser && m.content.trim().isNotEmpty)
        .toList();
    if (users.length < 3) return const SizedBox.shrink();

    // Cap the strip to 10 ticks; with more turns, sample evenly so each tick
    // still maps to a real message.
    final List<Message> ticks;
    if (users.length <= _maxTicks) {
      ticks = users;
    } else {
      ticks = [
        for (int i = 0; i < _maxTicks; i++)
          users[(i * (users.length - 1) / (_maxTicks - 1)).round()]
      ];
    }

    // opaque:false → the hover region never blocks mouse events from the
    // scrollbar / content behind it. Only the popup and the tiny tick targets
    // absorb clicks, so the main scrollbar stays fully draggable.
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Hover popup: the full prompt list (ChatGPT-style).
          if (_hover)
            _MinimapPopup(
              messages: users,
              scheme: scheme,
              onJump: widget.onJump,
            ),
          // Compact, evenly-gapped tick strip. The column itself is transparent
          // to pointer-down (only the ticks below take taps), so dragging in the
          // gaps doesn't get swallowed.
          AnimatedOpacity(
            opacity: _hover ? 1.0 : 0.5,
            duration: const Duration(milliseconds: 150),
            child: SizedBox(
              width: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final m in ticks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: _MinimapTick(
                        scheme: scheme,
                        active: _hover,
                        onTap: () => widget.onJump(m.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single short line on the minimap strip.
class _MinimapTick extends StatefulWidget {
  const _MinimapTick(
      {required this.scheme, required this.active, required this.onTap});
  final ColorScheme scheme;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_MinimapTick> createState() => _MinimapTickState();
}

class _MinimapTickState extends State<_MinimapTick> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = _hover || widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 3,
          width: _hover ? 16 : 12,
          decoration: BoxDecoration(
            color: widget.scheme.primary.withValues(alpha: on ? 0.95 : 0.45),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// The hover panel: a fixed-size, scrollable list of every user prompt in the
/// thread. Long titles ellipsize; the scrollbar matches the app's themed one.
class _MinimapPopup extends StatefulWidget {
  const _MinimapPopup(
      {required this.messages, required this.scheme, required this.onJump});
  final List<Message> messages;
  final ColorScheme scheme;
  final void Function(String id) onJump;

  @override
  State<_MinimapPopup> createState() => _MinimapPopupState();
}

class _MinimapPopupState extends State<_MinimapPopup> {
  // Fixed footprint so the panel doesn't grow/shrink with the thread length.
  static const double _kWidth = 300;
  static const double _kHeight = 360;

  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  static String _preview(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 120 ? '${t.substring(0, 118)}…' : t;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Container(
      width: _kWidth,
      height: _kHeight,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        // Use an elevated, sidebar-like surface (not the chat's plain `surface`)
        // so the popup reads as a distinct panel over the chat instead of
        // blending in.
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(
              'MESSAGES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            // Same neutral, themed scrollbar as the rest of the app.
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: RawScrollbar(
                controller: _sc,
                thumbVisibility: true,
                thickness: 6,
                radius: const Radius.circular(8),
                thumbColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                child: ListView.builder(
                    controller: _sc,
                    primary: false,
                    padding: const EdgeInsets.only(bottom: 8, right: 2),
                    itemCount: widget.messages.length,
                    itemBuilder: (context, i) {
                      final m = widget.messages[i];
                      return _MinimapPromptRow(
                        index: i + 1,
                        text: _preview(m.content),
                        scheme: scheme,
                        onTap: () => widget.onJump(m.id),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
      ),
    );
  }
}

/// One clickable prompt row inside the minimap popup.
class _MinimapPromptRow extends StatefulWidget {
  const _MinimapPromptRow(
      {required this.index,
      required this.text,
      required this.scheme,
      required this.onTap});
  final int index;
  final String text;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  State<_MinimapPromptRow> createState() => _MinimapPromptRowState();
}

class _MinimapPromptRowState extends State<_MinimapPromptRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.scheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          color: _hover ? s.primary.withValues(alpha: 0.12) : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  '${widget.index}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: s.primary.withValues(alpha: _hover ? 1 : 0.7),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    color: _hover ? s.onSurface : s.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A starter-prompt category: label + icon + accent colour.
enum _Cat {
  behavioral('Behavioral', Icons.forum_outlined, Color(0xFFF59E0B)),
  coding('Coding', Icons.code_rounded, Color(0xFF06B6D4)),
  system('System', Icons.account_tree_outlined, Color(0xFF8B5CF6)),
  concept('Concept', Icons.lightbulb_outline, Color(0xFF22C55E));

  const _Cat(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestionTap});

  final ValueChanged<String> onSuggestionTap;

  static const _suggestions = <(_Cat, String)>[
    (_Cat.behavioral, 'Tell me about a time you handled a tough deadline.'),
    (_Cat.coding, 'Explain how a hash map handles collisions.'),
    (_Cat.system, 'Design a URL shortener like bit.ly.'),
    (_Cat.concept, "What's the difference between TCP and UDP?"),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Glowing gradient hero badge.
                    Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [scheme.primary, scheme.tertiary],
                        ),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.45),
                            blurRadius: 32,
                            spreadRadius: 1,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.auto_awesome,
                          color: Colors.white, size: 34),
                    ),
                    const SizedBox(height: 26),
                    // Gradient title.
                    ShaderMask(
                      shaderCallback: (rect) => LinearGradient(
                        colors: [
                          scheme.onSurface,
                          scheme.primary,
                          scheme.tertiary,
                        ],
                      ).createShader(rect),
                      child: Text(
                        'How can I help today?',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Ask anything — behavioral, coding, system design, '
                      'or concepts.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 36),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final s in _suggestions)
                          _SuggestionCard(
                            cat: s.$1,
                            prompt: s.$2,
                            onTap: () => onSuggestionTap(s.$2),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _SuggestionCard extends StatefulWidget {
  const _SuggestionCard({
    required this.cat,
    required this.prompt,
    required this.onTap,
  });

  final _Cat cat;
  final String prompt;
  final VoidCallback onTap;

  @override
  State<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<_SuggestionCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.cat.color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 322,
          transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
          transformAlignment: Alignment.center,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hover
                ? Color.alphaBlend(
                    c.withValues(alpha: 0.10),
                    scheme.surfaceContainerHighest.withValues(alpha: 0.35))
                : scheme.surfaceContainerHighest.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _hover
                  ? c.withValues(alpha: 0.55)
                  : scheme.outlineVariant.withValues(alpha: 0.45),
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: c.withValues(alpha: 0.20),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(widget.cat.icon, color: c, size: 20),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.cat.label,
                      style: TextStyle(
                        color: c,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.prompt,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.88),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Padding(
                  padding: const EdgeInsets.only(left: 6, top: 10),
                  child: Icon(Icons.arrow_forward_rounded, size: 16, color: c),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: scheme.onErrorContainer, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


