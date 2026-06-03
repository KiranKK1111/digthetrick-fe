/// Resume Q&A screen.
///
/// Upload a PDF/DOCX resume → backend extracts a structured profile → user
/// asks interview questions and the LLM answers IN FIRST PERSON as the
/// candidate, grounded in the parsed profile.
///
/// Top: upload zone showing the currently loaded resume.
/// Middle: streaming chat-style message list.
/// Bottom: preset question chips + free-form input.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../widgets/message_bubble.dart';

const _presetQuestions = <String>[
  'Tell me about yourself',
  'Walk me through your experience',
  'What is your biggest project?',
  'Why should we hire you?',
  'What are your strengths?',
  'What are your weaknesses?',
];

class ResumeScreen extends StatefulWidget {
  const ResumeScreen({super.key});

  @override
  State<ResumeScreen> createState() => _ResumeScreenState();
}

class _ResumeScreenState extends State<ResumeScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  ResumeDetail? _resume;
  final List<Message> _messages = [];

  bool _uploading = false;
  bool _isStreaming = false;
  String? _errorBanner;

  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    // Restoring an already-uploaded resume has to survive a race: main.dart's
    // _restoreActiveResume() runs async (a network round-trip) and is NOT
    // awaited, so this screen is usually built BEFORE it finishes. We cover
    // every ordering:
    //   1. Listen to AppState  → adopt the resume the moment restore lands.
    //   2. Post-frame adopt    → catch the case where restore already finished.
    //   3. _loadExistingResume → if AppState is still empty (restore failed or
    //      never ran), fetch the most recent resume from the backend directly.
    _appState = context.read<AppState>();
    _appState.addListener(_adoptActiveResume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _adoptActiveResume();
      if (_resume == null) _loadExistingResume();
    });
  }

  /// Adopt the AppState's active resume into this screen when we don't already
  /// have one. Guarded so a freshly uploaded resume is never clobbered.
  void _adoptActiveResume() {
    final active = _appState.activeResume;
    if (mounted && _resume == null && active != null) {
      setState(() => _resume = active);
      if (active.profile['_analyzing'] == true) {
        _pollProfileUntilReady(active.id);
      }
    }
  }

  /// Last-resort restore: pull the most recent resume straight from the backend
  /// so an already-uploaded resume always loads when this tab opens, even if
  /// the bootstrap restore didn't run or silently failed.
  Future<void> _loadExistingResume() async {
    try {
      final list = await _api.listResumes();
      if (!mounted || _resume != null || list.isEmpty) return;
      final detail = await _api.getResume(list.first.id);
      if (!mounted || _resume != null) return;
      setState(() => _resume = detail);
      _appState.setActiveResume(detail);
      if (detail.profile['_analyzing'] == true) {
        _pollProfileUntilReady(detail.id);
      }
    } catch (_) {
      // Backend unreachable / no resumes — leave the upload zone showing.
    }
  }

  @override
  void dispose() {
    _appState.removeListener(_adoptActiveResume);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'txt'],
      // withData ensures `bytes` is populated on every platform, including
      // mobile/desktop where it would otherwise be null in favor of `path`.
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) {
      setState(() => _errorBanner = 'Could not read the picked file.');
      return;
    }

    setState(() {
      _uploading = true;
      _errorBanner = null;
    });

    try {
      final resume = await _api.uploadResume(
        bytes: bytes,
        filename: picked.name,
      );
      if (!mounted) return;
      setState(() {
        _resume = resume;
        // Fresh resume → fresh conversation.
        _messages.clear();
      });
      // Persist active-resume id so the next app launch re-loads it
      // automatically without forcing the user to pick again.
      context.read<AppState>().setActiveResume(resume);
      // The structured profile (name, skills, …) is filled in by a background
      // task on the server. Poll until it lands so the header updates to the
      // candidate's name without needing an app restart.
      _pollProfileUntilReady(resume.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Poll GET /api/resume/{id} until the server's background extractor clears
  /// the `_analyzing` flag, then swap in the enriched profile. Bounded so it
  /// can't poll forever; stops early if the user replaces/clears the resume.
  Future<void> _pollProfileUntilReady(String resumeId) async {
    // Already done (e.g. the LLM was fast / heuristic-only path)? Stop.
    if (_resume?.profile['_analyzing'] != true) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || _resume?.id != resumeId) return;
      ResumeDetail updated;
      try {
        updated = await _api.getResume(resumeId);
      } catch (_) {
        continue; // transient — try again
      }
      if (!mounted || _resume?.id != resumeId) return;
      final analyzing = updated.profile['_analyzing'] == true;
      // Update the in-memory + persisted resume whenever the server row moved
      // on (name resolved, or analyzing finished), so the header reflects it.
      setState(() => _resume = updated);
      context.read<AppState>().setActiveResume(updated);
      if (!analyzing) return; // extraction finished
    }
  }

  Future<void> _ask(String question) async {
    final resume = _resume;
    if (resume == null || question.trim().isEmpty || _isStreaming) return;

    _input.clear();
    setState(() {
      _errorBanner = null;
      _isStreaming = true;
      _messages.add(Message(
        id: 'local-user-${DateTime.now().microsecondsSinceEpoch}',
        role: 'user',
        content: question,
        createdAt: DateTime.now(),
      ));
      _messages.add(Message.placeholder(role: 'assistant'));
    });
    _scrollToBottom();

    final assistantMsg = _messages.last;

    try {
      await for (final event in _api.streamResumeAsk(
        resumeId: resume.id,
        question: question,
      )) {
        switch (event.event) {
          case 'meta':
            // Nothing UI-visible to update; the resume is already known.
            break;
          case 'token':
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
              if (idx != -1) {
                _messages[idx].content += event.data['text'] as String;
              }
            });
            _scrollToBottom();
            break;
          case 'done':
            break;
          case 'error':
            setState(() {
              _errorBanner = event.data['detail'] as String? ?? 'Unknown error';
            });
            break;
        }
      }
    } on ApiException catch (e) {
      setState(() => _errorBanner = e.message);
    } catch (e) {
      setState(() => _errorBanner = 'Unexpected error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isStreaming = false;
          final idx = _messages.indexWhere((m) => m.id == assistantMsg.id);
          if (idx != -1 &&
              _messages[idx].content.isEmpty &&
              _errorBanner != null) {
            _messages.removeAt(idx);
          }
        });
      }
    }
  }

  /// Rebuild the Qdrant collection for the current resume from the
  /// Postgres chunks. Useful when vector search is empty despite the
  /// resume being uploaded — typically after a Qdrant volume wipe or
  /// a fresh container start that lost the local Chroma data.
  Future<void> _reindex() async {
    final resume = _resume;
    if (resume == null) return;
    setState(() {
      _errorBanner = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Rebuilding vector index from Postgres…')),
    );
    try {
      final n = await _api.reindexResume(resume.id);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            n == 0
                ? 'No chunks on file — please re-upload the resume.'
                : 'Re-indexed $n chunk${n == 1 ? '' : 's'}.',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Column(
        children: [
          _ResumeHeader(
            resume: _resume,
            uploading: _uploading,
            onPick: _uploading ? null : _pickAndUpload,
            onReindex: _resume == null || _uploading ? null : _reindex,
          ),
          if (_errorBanner != null) _ErrorBanner(message: _errorBanner!),
          Expanded(
            child: _resume == null
                ? const _EmptyState()
                : _messages.isEmpty
                    ? const _AwaitingQuestionState()
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final msg = _messages[i];
                            final streaming = _isStreaming &&
                                i == _messages.length - 1 &&
                                !msg.isUser;
                            return MessageBubble(
                              message: msg,
                              isStreaming: streaming,
                            );
                          },
                        ),
                      ),
          ),
          if (_resume != null) ...[
            _PresetChips(
              enabled: !_isStreaming,
              onTap: _ask,
            ),
            _InputBar(
              controller: _input,
              enabled: !_isStreaming,
              onSend: () => _ask(_input.text.trim()),
            ),
          ],
        ],
      ),
    );
  }
}

// ---- Sub-widgets --------------------------------------------------------

class _ResumeHeader extends StatelessWidget {
  final ResumeDetail? resume;
  final bool uploading;
  final VoidCallback? onPick;
  /// Rebuild the Qdrant collection from the Postgres chunks. Null
  /// disables the button (no resume loaded or upload in flight).
  final VoidCallback? onReindex;

  const _ResumeHeader({
    required this.resume,
    required this.uploading,
    required this.onPick,
    this.onReindex,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.description_outlined,
              color: scheme.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  resume == null
                      ? 'No resume loaded'
                      : resume!.displayName,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  resume == null
                      ? 'Upload a PDF, DOCX, or TXT to begin'
                      : resume!.profile['_analyzing'] == true
                          ? '${resume!.filename} · Analyzing résumé…'
                          : resume!.filename,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (uploading)
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            )
          else ...[
            if (onReindex != null)
              IconButton(
                tooltip:
                    'Re-index — rebuild vector search from Postgres chunks',
                icon: Icon(
                  Icons.autorenew,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: onReindex,
              ),
            TextButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.upload_file, size: 18),
              label: Text(resume == null ? 'Upload' : 'Replace'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.upload_file,
              size: 48,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            'Upload a resume to start the interview',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            'PDF · DOCX · TXT',
            style: TextStyle(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _AwaitingQuestionState extends StatelessWidget {
  const _AwaitingQuestionState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Pick a starter question below, or type your own.\n'
          'The AI will answer in first person as the candidate.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 14, height: 1.5),
        ),
      ),
    );
  }
}

class _PresetChips extends StatelessWidget {
  final bool enabled;
  final void Function(String) onTap;

  const _PresetChips({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: scheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final q in _presetQuestions) ...[
              ActionChip(
                label: Text(q),
                onPressed: enabled ? () => onTap(q) : null,
                backgroundColor: scheme.surfaceContainerHigh,
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                labelStyle: TextStyle(
                  color: enabled
                      ? scheme.onSurface
                      : scheme.onSurface.withValues(alpha: 0.45),
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ],
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
                  color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => enabled ? onSend() : null,
              style: TextStyle(color: scheme.onSurface, fontSize: 15),
              decoration: InputDecoration(
                hintText: enabled
                    ? 'Ask an interview question…'
                    : 'Waiting for answer…',
                hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: enabled
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: enabled ? onSend : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.send,
                  color: enabled
                      ? scheme.onPrimary
                      : scheme.onSurface.withValues(alpha: 0.4),
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
