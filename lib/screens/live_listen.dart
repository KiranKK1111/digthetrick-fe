/// Live Listen screen: real-time interview / meeting Q&A.
///
/// Opens a WebSocket to the backend and listens to a Zoom / Teams / Meet
/// call. Two capture sources:
///
///  - **Interviewer (system audio)** — the DEFAULT. The backend captures
///    the system loopback (WASAPI on Windows): whatever the speakers are
///    playing, i.e. the OTHER party's voice. Nothing is sent from the
///    client; we just send a `start_capture` control frame. This is what
///    makes it transcribe the interviewer, not the candidate.
///  - **My microphone** — the `record` package captures the user's mic PCM
///    and streams raw int16 chunks over the WebSocket. Useful for practice
///    or to capture the user's own side.
///
/// Detected questions stream back as transcripts + classifier metadata,
/// then answers stream token-by-token below them. On the audio path the
/// backend only answers utterances classified as questions.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/ws_client.dart';
import '../layout/modules.dart' show kModuleLive;
import '../state/app_state.dart';
import '../theme/theme.dart';
import '../widgets/composer_keys.dart';
import '../widgets/message_bubble.dart';
import '../widgets/question_card.dart';
import '../widgets/sidebar_recents.dart';

class LiveListenScreen extends StatefulWidget {
  const LiveListenScreen({super.key});

  @override
  State<LiveListenScreen> createState() => _LiveListenScreenState();
}

class _LiveListenScreenState extends State<LiveListenScreen> {
  WsClient? _ws;
  StreamSubscription<LiveEvent>? _events;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;

  // Conversation log: alternating question cards and assistant bubbles.
  final List<_LiveItem> _items = [];
  // Concurrent answers: route streaming events to the right bubble by qid.
  final Map<String, Message> _answerByQid = {};
  final Map<String, _LiveItem> _questionByQid = {};
  final Set<String> _streamingQids = {};
  bool _connected = false;
  bool _connecting = false;
  bool _listening = false;
  String? _error;

  // Audio capture source. 'system_loopback' = the other party's voice via
  // the backend (default, for interviews/meetings); 'mic' = the user's own
  // microphone captured client-side.
  String _source = 'system_loopback';
  bool get _systemMode => _source == 'system_loopback';
  bool _uploadingResume = false;
  bool _disposing = false; // set in dispose() to block setState during teardown

  // Persisted live-interview history (org sidebar).
  String? _liveSessionId; // the current/viewed session's DB id
  List<LiveSessionSummary> _sessions = const [];
  bool _sessionsLoading = false;
  bool _viewingHistory = false; // showing a past session read-only

  // Diagnostic log written to %TEMP%\digthetrick_live.log so connection
  // problems can be inspected without copy-pasting from the UI.
  void _diag(String msg) {
    try {
      final f = File('${Directory.systemTemp.path}/digthetrick_live.log');
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $msg\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {/* logging must never break the UI */}
  }

  // This screen's module id (see lib/layout/modules.dart).
  static const String _kModuleId = kModuleLive;
  VoidCallback? _activeTabListener;

  @override
  void initState() {
    super.initState();
    // IndexedStack keeps Live alive across tab switches, so build()
    // doesn't re-run on tab return. Re-publish header chrome whenever
    // the user navigates back to Live.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      _activeTabListener = () {
        if (mounted && state.activeSurface.value == _kModuleId) {
          _publishHeaderActions();
          _loadSessions(); // refresh interview history on tab return
        }
      };
      state.activeSurface.addListener(_activeTabListener!);
      // Load the interview history once on first mount.
      if (state.activeSurface.value == _kModuleId) _loadSessions();
    });
  }

  @override
  void dispose() {
    // Mark disposing FIRST so the teardown below (which calls _stop →
    // _stopListening) never calls setState on a defunct element.
    _disposing = true;
    // Clear our header buttons so the next tab doesn't see Live's
    // connect / mic linger on. Use mounted check via try/catch — the
    // AppState may already be disposing.
    try {
      final state = context.read<AppState>();
      state.setHeaderActions(const []);
      state.setSidebarExtras(null);
      if (_activeTabListener != null) {
        state.activeSurface.removeListener(_activeTabListener!);
      }
    } catch (_) {}
    _stop();
    super.dispose();
  }

  /// Push the connect / mic icons into the shell's header. Called
  /// from build so the icons re-render whenever connect/mic state
  /// flips. Cheap — the ValueNotifier only fires when the list
  /// reference changes.
  ///
  /// **Guard:** only publishes when Live is the active tab.
  /// IndexedStack keeps Live mounted; without this guard, an AppState
  /// notifyListeners() from elsewhere (stealth toggle, theme change)
  /// would re-run Live's build and overwrite the visible tab's
  /// header actions with Connect/Mic — even when Chat is on screen.
  void _publishHeaderActions() {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (state.activeSurface.value != _kModuleId) return;
    // Connect / Source / Listen all live in the body control bar. The header
    // carries only the Upload-resume action as a labelled pill (used to ground
    // answers in the candidate's background); when a resume is loaded the same
    // pill shows its name.
    final resume = state.activeResume;
    final scheme = Theme.of(context).colorScheme;
    final list = <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: OutlinedButton.icon(
          onPressed: _uploadingResume ? null : _uploadResume,
          icon: _uploadingResume
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(
                  resume != null
                      ? Icons.check_circle_outline
                      : Icons.upload_file_outlined,
                  size: 16),
          label: Text(
            resume != null ? 'Resume: ${resume.displayName}' : 'Upload Resume',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: resume != null ? AppPalette.success : null,
            side: BorderSide(
              color: (resume != null ? AppPalette.success : scheme.primary)
                  .withValues(alpha: 0.5),
            ),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            textStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    ];
    // Defer until after the build phase to avoid a setState-during-
    // build assertion in the ancestor that consumes headerActions.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && state.activeSurface.value == _kModuleId) {
        state.setHeaderActions(list);
      }
    });
  }

  Future<void> _toggleConnect() async {
    _diag('connect tapped (connecting=$_connecting connected=$_connected)');
    if (_connecting) return; // ignore taps mid-connect
    if (_connected) {
      await _stop();
      return;
    }
    final state = context.read<AppState>();

    // Ask which organization is conducting the interview, then create a
    // PERSISTED live session titled with it. The Q&A is saved under this id.
    final org = await _askOrgName();
    if (org == null || !mounted) return; // cancelled
    String sessionId;
    try {
      final created = await ApiService(baseUrl: state.baseUrl).createLiveSession(org);
      sessionId = created.id;
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start session: $e');
      return;
    }

    final ws = WsClient(
      baseUrl: state.baseUrl,
      wsPath: state.config.wsPath,
      resumeId: state.activeResume?.id,
      sessionId: sessionId,
    );
    _diag('built WsClient session=$sessionId -> url=${ws.url}');

    setState(() {
      _ws = ws;
      _error = null;
      _connecting = true;
      _liveSessionId = sessionId;
      _viewingHistory = false;
      _items.clear(); // fresh session view
      _answerByQid.clear();
      _questionByQid.clear();
      _streamingQids.clear();
    });

    try {
      final stream = ws.connect();
      _events = stream.listen(_handleEvent, onError: (e) {
        _diag('stream onError: $e');
        if (mounted) setState(() => _error = 'WebSocket error: $e');
      });
      _diag('awaiting ws.ready …');
      // `connect()` is lazy — await the handshake so a refused/closed port
      // actually surfaces here instead of failing silently. The timeout is a
      // backstop in case `.ready` never settles.
      await ws.ready.timeout(const Duration(seconds: 10));
      _diag('ws.ready COMPLETED -> connected');
      if (!mounted) return;
      setState(() {
        _connected = true;
        _connecting = false;
      });
      _loadSessions(); // surface the new interview in the sidebar
    } catch (e) {
      _diag('connect FAILED: ${e.runtimeType}: $e');
      // Clean up the half-open channel so a retry starts fresh.
      await _events?.cancel();
      _events = null;
      await ws.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connected = false;
        _ws = null;
        _error = "Couldn't connect to ${ws.url}\n"
            'Reason: $e\n'
            'Check the backend is running (uvicorn on port 8000), then tap '
            'Connect again.';
      });
    }
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await _stopListening();
      return;
    }
    if (_systemMode) {
      // The backend captures system loopback (the other party's voice).
      // Nothing to capture on the client — just ask it to start.
      _ws?.startCapture(source: 'system_loopback');
      setState(() {
        _listening = true;
        _error = null;
      });
      return;
    }
    // Microphone mode: capture client-side and stream PCM.
    _recorder = AudioRecorder();
    if (!await _recorder!.hasPermission()) {
      setState(() => _error = 'Microphone permission denied.');
      return;
    }
    final stream = await _recorder!.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ));
    _audioSub = stream.listen((chunk) {
      _ws?.sendPcm(chunk);
    });
    setState(() {
      _listening = true;
      _error = null;
    });
  }

  Future<void> _stopListening() async {
    if (_systemMode) {
      _ws?.stopCapture();
    } else {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder?.stop();
      _recorder = null;
      _ws?.sendText({'type': 'flush'});
    }
    if (mounted && !_disposing) setState(() => _listening = false);
  }

  Future<void> _stop() async {
    await _stopListening();
    await _events?.cancel();
    _events = null;
    await _ws?.close();
    _ws = null;
    if (mounted && !_disposing) setState(() => _connected = false);
  }

  void _handleEvent(LiveEvent event) {
    _diag('event: ${event.type} ${event.data}');
    // Each detected question gets a `qid` from the backend; answers for two
    // questions can stream CONCURRENTLY, so we route every event to its own
    // question card / answer bubble by qid rather than a single "current" one.
    final qid = event.data['qid'] as String?;
    setState(() {
      switch (event.type) {
        case 'ready':
          break;
        case 'transcript':
          final q = _LiveItem.question(text: event.data['text'] ?? '', qid: qid);
          final ans = Message.placeholder(role: 'assistant');
          final a = _LiveItem.answer(ans, qid: qid);
          _items.add(q);
          _items.add(a);
          if (qid != null) {
            _questionByQid[qid] = q;
            _answerByQid[qid] = ans;
            _streamingQids.add(qid);
          }
          break;
        case 'meta':
          // Annotate this qid's question card with the agent's prediction.
          final card = qid != null ? _questionByQid[qid] : _lastQuestion();
          if (card != null) {
            // Backend sends the question class under "qtype" ("type" is the
            // event envelope kind).
            card.type = (event.data['qtype'] ?? event.data['type']) as String?;
            card.isFollowup = event.data['is_followup'] == true;
            card.topic = event.data['topic'] as String?;
            card.confidence = (event.data['confidence'] as num?)?.toDouble();
            // Show the cleaned, predicted question (agent fixes STT errors /
            // filler) instead of the raw transcript when available.
            final predicted = (event.data['question'] as String?)?.trim();
            if (predicted != null && predicted.isNotEmpty) {
              card.predicted = predicted;
            }
          }
          break;
        case 'capture':
          final st = event.data['state'] as String?;
          if (st == 'error') {
            _error = (event.data['detail'] as String?) ??
                'System audio capture failed.';
            _listening = false;
          } else if (st == 'stopped') {
            _listening = false;
          }
          break;
        case 'tool':
          break; // tool chips not surfaced in Live yet
        case 'token':
          final t = event.data['text'] as String? ?? '';
          final msg = qid != null ? _answerByQid[qid] : _lastAnswer();
          if (msg != null) msg.content += t;
          break;
        case 'done':
          if (qid != null) {
            _streamingQids.remove(qid);
            _answerByQid.remove(qid);
            _questionByQid.remove(qid);
          }
          break;
        case 'error':
          _error = (event.data['detail'] as String?) ?? 'Unknown error';
          if (qid != null) {
            _streamingQids.remove(qid);
            _answerByQid.remove(qid);
          }
          break;
        case 'closed':
          _connected = false;
          _streamingQids.clear();
          break;
      }
    });
  }

  /// Fallback for events that arrive without a qid (legacy / typed path).
  _LiveItem? _lastQuestion() {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].isQuestion) return _items[i];
    }
    return null;
  }

  Message? _lastAnswer() {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (!_items[i].isQuestion) return _items[i].message;
    }
    return null;
  }

  void _sendTyped(String text) {
    if (text.trim().isEmpty) return;
    _ws?.sendText({'type': 'text', 'content': text.trim()});
  }

  /// Ask which organization is conducting the interview. Returns the org name,
  /// or null if cancelled.
  Future<String?> _askOrgName() async {
    final ctrl = TextEditingController();
    String submit() => ctrl.text.trim().isEmpty ? 'Interview' : ctrl.text.trim();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start interview'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Which organization is conducting this interview?'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: 'e.g. Acme Corp',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => Navigator.pop(ctx, submit()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, submit()),
            child: const Text('Start'),
          ),
        ],
      ),
    );
  }

  /// Load the list of past live interviews and publish the sidebar.
  Future<void> _loadSessions() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    setState(() => _sessionsLoading = true);
    try {
      final s = await ApiService(baseUrl: state.baseUrl).listLiveSessions();
      if (!mounted) return;
      setState(() {
        _sessions = s;
        _sessionsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _sessionsLoading = false);
    }
    _publishSidebar();
  }

  /// Build + publish the interview-history sidebar (org name + created date).
  void _publishSidebar() {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (state.activeSurface.value != _kModuleId) return;
    final items = _sessions
        .map((s) => SidebarRecentItem(
              id: s.id,
              title: s.orgName.isNotEmpty ? s.orgName : 'Interview',
              timestamp: s.startedAt,
              badge: s.messageCount >= 2 ? '${s.messageCount ~/ 2} Q' : null,
            ))
        .toList();
    final widget = SidebarRecents(
      heading: 'Interviews',
      items: items,
      activeId: _liveSessionId,
      loading: _sessionsLoading,
      newLabel: 'New interview',
      emptyLabel: 'No interviews yet.',
      onSelect: _loadSession,
      onNew: _startNewInterview,
      onDelete: _deleteSession,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && state.activeSurface.value == _kModuleId) {
        state.setSidebarExtras(widget);
      }
    });
  }

  /// Load a past interview's transcript (read-only) into the view.
  Future<void> _loadSession(String id) async {
    final state = context.read<AppState>();
    // Don't yank an active session out from under a live interview.
    if (_connected) await _stop();
    setState(() {
      _liveSessionId = id;
      _viewingHistory = true;
      _items.clear();
      _answerByQid.clear();
      _questionByQid.clear();
      _streamingQids.clear();
      _error = null;
    });
    try {
      final res = await ApiService(baseUrl: state.baseUrl)
          .getConversationMessages(id);
      if (!mounted) return;
      setState(() {
        _items.clear();
        for (final m in res.messages) {
          if (m.role == 'user') {
            _items.add(_LiveItem.question(text: m.content));
          } else {
            _items.add(_LiveItem.answer(m));
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load interview: $e');
    }
    _publishSidebar();
  }

  /// Clear the view to start a fresh interview (the org modal appears on Connect).
  Future<void> _startNewInterview() async {
    if (_connected) await _stop();
    setState(() {
      _liveSessionId = null;
      _viewingHistory = false;
      _items.clear();
      _answerByQid.clear();
      _questionByQid.clear();
      _streamingQids.clear();
    });
    _publishSidebar();
  }

  Future<void> _deleteSession(String id) async {
    final state = context.read<AppState>();
    try {
      await ApiService(baseUrl: state.baseUrl).deleteConversation(id);
    } catch (_) {}
    if (_liveSessionId == id) {
      setState(() {
        _liveSessionId = null;
        _items.clear();
      });
    }
    _loadSessions();
  }

  /// Upload a resume to ground the answers in the candidate's background.
  /// (The Resume module was folded into Live — this is its upload flow.)
  Future<void> _uploadResume() async {
    final state = context.read<AppState>();
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'txt'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) return;
    setState(() {
      _uploadingResume = true;
      _error = null;
    });
    try {
      final detail = await ApiService(baseUrl: state.baseUrl)
          .uploadResume(bytes: bytes, filename: f.name);
      state.setActiveResume(detail);
    } catch (e) {
      if (mounted) setState(() => _error = 'Resume upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploadingResume = false);
    }
  }

  /// Always-visible control bar in the body: Connect/Disconnect, the audio
  /// source picker, and Start/Stop listening. These mirror the title-bar
  /// icons but are labelled and easy to find — the header power icon was too
  /// easy to miss.
  Widget _controlBar(BuildContext context, bool dark) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Connect / Disconnect — the primary on/off control.
          FilledButton.icon(
            onPressed: _connecting ? null : _toggleConnect,
            icon: _connecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_connected ? Icons.power_settings_new : Icons.power,
                    size: 18),
            label: Text(_connecting
                ? 'Connecting…'
                : (_connected ? 'Disconnect' : 'Connect')),
            style: FilledButton.styleFrom(
              backgroundColor: _connected ? AppPalette.error : null,
            ),
          ),
          // Audio source picker — locked while listening.
          _SourcePicker(
            source: _source,
            enabled: _connected && !_listening,
            onChanged: (s) => setState(() => _source = s),
          ),
          // Start / Stop listening — enabled once connected.
          OutlinedButton.icon(
            onPressed: _connected ? _toggleListen : null,
            icon: Icon(
              _listening
                  ? Icons.stop_circle
                  : (_systemMode ? Icons.hearing : Icons.mic),
              size: 18,
            ),
            label: Text(_listening
                ? 'Stop listening'
                : (_systemMode ? 'Start listening' : 'Start mic')),
            style: OutlinedButton.styleFrom(
              foregroundColor:
                  _listening ? AppPalette.error : theme.colorScheme.primary,
            ),
          ),
          // (Resume upload lives in the header now.)
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Push our tab-specific buttons into the shell header. The shell
    // renders them between the title and the global icons.
    _publishHeaderActions();
    _publishSidebar();
    return Scaffold(
      // No AppBar — the shell now owns the header. We add a slim
      // status banner inside the body that mirrors the old subtitle
      // ("connected · resume: <name>" / "not connected").
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connected ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Live Listen — ${_connected
                      ? [
                          state.activeResume != null
                              ? "connected · resume: ${state.activeResume!.displayName}"
                              : "connected · no resume loaded",
                          if (_listening)
                            _systemMode
                                ? "🎧 listening to interviewer (system audio)"
                                : "🎙 listening to your mic",
                        ].join(" · ")
                      : "not connected"}',
                  style: TextStyle(
                    fontSize: 12,
                    color: dark
                        ? AppPalette.darkTextMuted
                        : AppPalette.lightTextMuted,
                  ),
                ),
              ],
            ),
          ),
          _controlBar(context, dark),
          Expanded(
            child: Column(
        children: [
          if (_error != null) _ErrorBanner(message: _error!),
          if (!_connected && !_viewingHistory)
            const Expanded(child: _DisconnectedHint())
          else
            Expanded(
              child: _items.isEmpty
                  ? _AwaitingHint(listening: _listening, systemMode: _systemMode)
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        if (item.isQuestion) {
                          return QuestionCard(
                            question: (item.predicted?.isNotEmpty ?? false)
                                ? item.predicted!
                                : item.text,
                            questionType: item.type,
                            isFollowup: item.isFollowup,
                            topic: item.topic,
                            confidence: item.confidence,
                          );
                        }
                        final isStreamingThis =
                            item.qid != null && _streamingQids.contains(item.qid);
                        return MessageBubble(
                          message: item.message!,
                          isStreaming: isStreamingThis,
                        );
                      },
                    ),
            ),
          if (_connected) _TextInput(onSend: _sendTyped),
        ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LiveItem {
  final bool isQuestion;
  final String text;
  final String? qid; // links a question card + its answer bubble
  String? type;
  bool isFollowup;
  String? topic;
  double? confidence;
  String? predicted; // agent's cleaned question (overrides raw transcript)
  final Message? message;

  _LiveItem.question({required this.text, this.qid})
      : isQuestion = true,
        message = null,
        isFollowup = false;

  _LiveItem.answer(this.message, {this.qid})
      : isQuestion = false,
        text = '',
        isFollowup = false;
}

/// A labelled chip that opens the audio-source menu (Interviewer / Mic).
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.source,
    required this.enabled,
    required this.onChanged,
  });
  final String source;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final system = source == 'system_loopback';
    final label = system ? 'Interviewer (system audio)' : 'My microphone';
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'Audio source',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: 'system_loopback',
          checked: system,
          child: const Text('Interviewer (system audio)'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'mic',
          checked: !system,
          child: const Text('My microphone'),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
          color: enabled ? null : theme.disabledColor.withValues(alpha: 0.05),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(system ? Icons.hearing : Icons.mic_none,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodyMedium),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _DisconnectedHint extends StatelessWidget {
  const _DisconnectedHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.podcasts, size: 48, color: AppPalette.darkTextMuted),
            const SizedBox(height: 12),
            Text(
              'Live interview & meeting assistant.\n\n'
              'Tap "Connect" above, then "Start listening".\n'
              'Default source is the interviewer (system audio) — it\n'
              'transcribes the other side of your Zoom / Teams / Meet call,\n'
              'auto-detects questions, and answers them on the fly.\n\n'
              'Switch the source to "My microphone" for practice,\n'
              'or just type a question below.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppPalette.darkTextMuted
                    : AppPalette.lightTextMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AwaitingHint extends StatelessWidget {
  const _AwaitingHint({required this.listening, required this.systemMode});
  final bool listening;
  final bool systemMode;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted =
        dark ? AppPalette.darkTextMuted : AppPalette.lightTextMuted;
    final String msg;
    if (!listening) {
      msg = 'Tap "Start listening" to begin, or type a question below.';
    } else if (systemMode) {
      msg = 'Listening to the call… questions from the other side will\n'
          'appear here and get answered automatically.';
    } else {
      msg = 'Listening to your microphone… ask a question or type below.';
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(listening ? Icons.graphic_eq : Icons.hearing,
              size: 32, color: muted),
          const SizedBox(height: 10),
          Text(
            msg,
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 14, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      color: dark ? AppPalette.errorBg : AppPalette.errorBgLight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppPalette.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppPalette.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextInput extends StatefulWidget {
  final void Function(String) onSend;
  const _TextInput({required this.onSend});

  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: dark ? AppPalette.darkSurface : AppPalette.lightSurface,
        border: Border(
          top: BorderSide(
            color: dark ? AppPalette.darkBorder : AppPalette.lightBorder,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            // Enter sends; Alt/Shift+Enter insert a newline.
            child: ComposerKeyboard(
              controller: _ctrl,
              onSubmit: _submit,
              child: TextField(
                controller: _ctrl,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Type a question (or speak)…',
                  filled: true,
                  fillColor: dark
                      ? AppPalette.darkSurfaceAlt
                      : AppPalette.lightSurfaceAlt,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _submit,
            icon: const Icon(Icons.send, size: 20),
          ),
        ],
      ),
    );
  }
}
