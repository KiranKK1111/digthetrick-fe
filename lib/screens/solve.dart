/// Solve screen.
///
/// Tap **Solve** in the AppBar. The app silently captures the full
/// desktop (in-process GDI BitBlt — no Snipping Tool, no UI visible to
/// anyone watching), uploads the PNG to `/api/solve/image`, and streams
/// back a structured solution (Problem / Approach / Solution /
/// Complexity / Walkthrough).
///
/// Model selection lives in **Settings** (LLM provider, API keys, vision
/// & code models). This screen always uses whatever is configured there.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/screen_capture.dart';
import '../services/silent_capture.dart';
import '../layout/modules.dart' show kModuleSolve;
import '../state/app_state.dart';
import '../theme/theme.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sidebar_recents.dart';

class SolveScreen extends StatefulWidget {
  const SolveScreen({super.key});

  @override
  State<SolveScreen> createState() => _SolveScreenState();
}

class _SolveScreenState extends State<SolveScreen> {
  final ScreenCaptureService _capture = ScreenCaptureService();

  Message? _answer;
  String? _extractedProblem;     // OCR'd text from the screenshot
  String? _currentSolveTitle;    // shown above the answer in the history view
  String? _capturedImageUrl;     // set when a past image-solve is loaded
  bool _busy = false;
  String _status = '';
  String? _error;

  // Solve history sidebar — populated from /api/solve/sessions.
  List<SolveSummary> _history = const [];
  String? _activeSolveId;
  bool _loadingHistory = false;

  // This screen's module id (see lib/layout/modules.dart).
  static const String _kModuleId = kModuleSolve;
  VoidCallback? _activeTabListener;

  @override
  void initState() {
    super.initState();
    // Pull history on mount + auto-load the most recent solve so a
    // restart never leaves the user staring at an empty screen.
    _refreshHistory(autoLoadMostRecent: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _publishChrome();
      // Re-publish chrome whenever the user returns to this tab —
      // see chat_screen.dart for the rationale.
      final state = context.read<AppState>();
      _activeTabListener = () {
        if (mounted && state.activeSurface.value == _kModuleId) {
          _publishChrome();
        }
      };
      state.activeSurface.addListener(_activeTabListener!);
    });
  }

  @override
  void dispose() {
    // Clear our slots so the next tab doesn't inherit solve's chrome.
    try {
      final state = context.read<AppState>();
      state.setHeaderActions(const []);
      state.setHeaderSubtitle(null);
      state.setSidebarExtras(null);
      if (_activeTabListener != null) {
        state.activeSurface.removeListener(_activeTabListener!);
      }
    } catch (_) {}
    super.dispose();
  }

  /// Push our header buttons + active-solve subtitle + sidebar
  /// recents list into the shell. Called whenever any of those
  /// inputs change.
  void _publishChrome() {
    if (!mounted) return;
    final state = context.read<AppState>();
    // Only publish when Solve is the active surface — otherwise an async
    // history-load callback would overwrite another module's sidebar.
    if (state.activeSurface.value != _kModuleId) return;
    state.setHeaderSubtitle(
      _currentSolveTitle == null || _currentSolveTitle!.isEmpty
          ? null
          : _currentSolveTitle,
    );
    state.setHeaderActions([
      // "+ New solve" lives in the sidebar; the header keeps only the
      // primary action (the actual Solve / screen-capture trigger).
      ElevatedButton.icon(
        onPressed: _busy ? null : _solve,
        icon: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.bolt, size: 16),
        label: const Text('Solve'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppPalette.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ]);
    state.setSidebarExtras(
      SidebarRecents(
        heading: 'Solve history',
        newLabel: 'New solve',
        emptyLabel: 'No solves yet.\nTap Solve to capture a problem.',
        items: [
          for (final s in _history)
            SidebarRecentItem(
              id: s.id,
              title: s.title.isEmpty ? '(untitled)' : s.title,
              timestamp: s.createdAt,
              badge: s.source == 'image'
                  ? 'image'
                  : (s.language?.isNotEmpty == true ? s.language : null),
            ),
        ],
        activeId: _activeSolveId,
        loading: _loadingHistory,
        onSelect: _loadSolve,
        onNew: () {
          if (_busy) return;
          _newSolve();
        },
        onDelete: (id) async {
          await _deleteSolve(id);
        },
      ),
    );
  }

  ApiService _api() {
    final state = context.read<AppState>();
    return ApiService(baseUrl: state.baseUrl);
  }

  /// Refresh the history list. With `autoLoadMostRecent=true` the
  /// newest solve is loaded into the main view; without it (the
  /// post-solve path) we just refresh the drawer without disturbing
  /// the current view.
  Future<void> _refreshHistory({bool autoLoadMostRecent = false}) async {
    if (_loadingHistory) return;
    setState(() => _loadingHistory = true);
    _publishChrome();
    try {
      final history = await _api().listSolveSessions();
      if (!mounted) return;
      setState(() => _history = history);
      _publishChrome();
      if (autoLoadMostRecent && _answer == null && history.isNotEmpty) {
        await _loadSolve(history.first.id);
      }
    } on ApiException {
      // Soft-fail — history is a convenience, not a critical path.
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
        _publishChrome();
      }
    }
  }

  /// Load one past solve into the main view.
  Future<void> _loadSolve(String solveId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Loading…';
    });
    try {
      final detail = await _api().getSolveSession(solveId);
      if (!mounted) return;
      setState(() {
        _activeSolveId = detail.id;
        _currentSolveTitle = detail.title;
        _extractedProblem = detail.description;
        _capturedImageUrl = (detail.source == 'image' && detail.imagePath != null)
            ? _api().solveImageUrl(detail.id)
            : null;
        _answer = Message(
          id: detail.id,
          role: 'assistant',
          content: detail.response,
          createdAt: detail.createdAt,
        );
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
        _publishChrome();
      }
    }
  }

  /// Pull the freshly persisted title from the backend after a solve
  /// finishes. Covers both:
  ///   - text solves (no `extracted` SSE event, so the header would
  ///     otherwise stay blank)
  ///   - image solves (the LLM auto-title task may have replaced the
  ///     placeholder seconds after the row was created)
  ///
  /// Polls a couple of times because the auto_title task is async on
  /// the server and may not have committed yet when `done` fires.
  Future<void> _hydrateTitleFromServer(String solveId) async {
    String? lastSeen;
    for (int attempt = 0; attempt < 4; attempt++) {
      try {
        final detail = await _api().getSolveSession(solveId);
        final title = detail.title.trim();
        if (title.isNotEmpty && title != lastSeen) {
          lastSeen = title;
          if (!mounted) return;
          setState(() => _currentSolveTitle = title);
          _publishChrome();
        }
      } on ApiException {
        // Quietly give up — the sidebar refresh covers the long path.
        return;
      }
      // Backoff: 0ms (now), 600ms, 1500ms, 3000ms. Picks up the LLM
      // auto-title's commit without spamming requests.
      if (attempt < 3) {
        await Future<void>.delayed(
          Duration(milliseconds: [600, 1500, 3000][attempt]),
        );
        if (!mounted || _activeSolveId != solveId) return;
      }
    }
  }

  /// Title extractor that knows about the OCR's section markers.
  /// Skips a leading `=== TITLE ===` / `## Problem` style marker and
  /// returns the next non-empty line — matching the backend's
  /// SolveRepo._derive_title behaviour.
  String _deriveTitleFromOcr(String text) {
    if (text.isEmpty) return '';
    final markerRe = RegExp(
      r'^\s*[#=*\-]{0,6}\s*'
      r'(TITLE|FUNCTION\s*SIGNATURE|PROBLEM(?:\s*STATEMENT)?|QUESTION|'
      r'EXAMPLES?|CONSTRAINTS?|INPUT|OUTPUT|NOTES?|APPROACH|SOLUTION)'
      r'\s*[#=*\-]{0,6}\s*[:\-]?\s*$',
      caseSensitive: false,
    );
    bool skipped = false;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (markerRe.hasMatch(line)) {
        if (skipped) break;          // two markers in a row — bail
        skipped = true;
        continue;
      }
      // Strip "Title:" / "Problem:" / "Question:" inline prefixes.
      var cleaned = line;
      for (final prefix in const ['Title:', 'Problem:', 'Question:']) {
        if (cleaned.toLowerCase().startsWith(prefix.toLowerCase())) {
          cleaned = cleaned.substring(prefix.length).trim();
          break;
        }
      }
      if (cleaned.isNotEmpty) return cleaned;
    }
    return '';
  }

  /// Remove a past solve from history. If the deleted row is the
  /// currently-loaded one, clear the view too.
  Future<void> _deleteSolve(String solveId) async {
    try {
      await _api().deleteSolveSession(solveId);
      if (!mounted) return;
      setState(() {
        _history = _history.where((s) => s.id != solveId).toList();
        if (_activeSolveId == solveId) {
          _answer = null;
          _extractedProblem = null;
          _currentSolveTitle = null;
          _activeSolveId = null;
        }
      });
      _publishChrome();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Reset the view for a fresh capture — clears the answer + extracted
  /// problem, doesn't touch the history list.
  void _newSolve() {
    setState(() {
      _answer = null;
      _extractedProblem = null;
      _currentSolveTitle = null;
      _capturedImageUrl = null;
      _activeSolveId = null;
      _error = null;
      _status = '';
    });
    _publishChrome();
  }

  Future<void> _solve() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _answer = null;
      _extractedProblem = null;
      _currentSolveTitle = null;
      _capturedImageUrl = null;
      _activeSolveId = null;
      _status = 'Capturing screen…';
    });
    _publishChrome();

    try {
      final shot = await _capture.capture();
      if (shot == null) {
        setState(() {
          _busy = false;
          _status = '';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _status = 'Analyzing problem…';
        _answer = Message.placeholder(role: 'assistant');
      });

      const extraContext =
          'Use whichever programming language is visible in the code '
          'editor portion of the screenshot. If no editor or language '
          'indicator is visible, default to Python. Be exhaustive about '
          'time complexity and space complexity — derive them from the '
          'final code, not from approximations. Include at least 4 edge '
          'cases. Be precise about correctness.';

      // No per-call model overrides — the backend uses cfg.llm.vision_model
      // and cfg.llm.code_model from Settings.
      final stream = _api().streamSolveImage(
        bytes: shot.bytes,
        filename: shot.filename,
        extraContext: extraContext,
      );
      await for (final ev in stream) {
        if (!mounted) return;
        switch (ev.event) {
          case 'meta':
            break;
          case 'status':
            setState(() => _status = ev.data['text'] as String? ?? _status);
            break;
          case 'extracted':
            // OCR'd problem statement — derive a short title and
            // capture the full text so the user sees what the vision
            // model read before tokens stream in.
            final text = (ev.data['text'] as String?) ?? '';
            String title = _deriveTitleFromOcr(text);
            if (title.length > 120) title = '${title.substring(0, 117)}…';
            setState(() {
              _extractedProblem = text;
              _currentSolveTitle = title;
            });
            break;
          case 'token':
            setState(() {
              _answer!.content += ev.data['text'] as String? ?? '';
            });
            break;
          case 'error':
            setState(() {
              _error = ev.data['detail'] as String? ?? 'Unknown error';
            });
            break;
          case 'done':
            // Pin the new id so the drawer highlights it after refresh.
            final id = ev.data['solve_id'] as String?;
            setState(() {
              _activeSolveId = id;
              _status = '';
            });
            // Pull the freshly persisted title from the backend. Two
            // reasons:
            //   (1) Text solves don't emit `extracted`, so the header
            //       has no title until we fetch one here.
            //   (2) The LLM auto-title task may have replaced the
            //       placeholder seconds after persistence; this fetch
            //       picks up whichever title is current.
            if (id != null) {
              // Don't block the stream finalisation — fire and forget.
              // ignore: unawaited_futures
              _hydrateTitleFromServer(id);
            }
            break;
        }
      }
    } on SilentCaptureError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _publishChrome();
        // Refresh history so the new solve appears in the sidebar.
        // ignore: unawaited_futures
        _refreshHistory();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasAnything = _capturedImageUrl != null ||
        (_extractedProblem != null && _extractedProblem!.isNotEmpty) ||
        _answer != null;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(
        children: [
          if (_error != null) _ErrorBanner(message: _error!),
          if (_status.isNotEmpty) _StatusBar(text: _status),
          if (!hasAnything && _status.isEmpty)
            const Expanded(child: _EmptyHint())
          else
            Expanded(
              child: _SolveAccordion(
                capturedImageUrl: _capturedImageUrl,
                extractedProblem: _extractedProblem,
                answer: _answer,
                isStreaming: _busy && _status != 'Capturing screen…',
              ),
            ),
        ],
      ),
    );
  }
}


// ===========================================================================
// Accordion (Captured Screen / Problem Statement / Solution Walkthrough)
// ===========================================================================

enum _Panel { image, problem, walkthrough }


/// Three-panel accordion: at most one expanded at a time.
///
/// When a new answer arrives, the walkthrough opens automatically so
/// the user sees the result immediately. Tapping any header expands
/// that panel and collapses the others; tapping the open panel
/// collapses it entirely.
class _SolveAccordion extends StatefulWidget {
  const _SolveAccordion({
    required this.capturedImageUrl,
    required this.extractedProblem,
    required this.answer,
    required this.isStreaming,
  });

  final String? capturedImageUrl;
  final String? extractedProblem;
  final Message? answer;
  final bool isStreaming;

  @override
  State<_SolveAccordion> createState() => _SolveAccordionState();
}


class _SolveAccordionState extends State<_SolveAccordion> {
  _Panel? _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = _defaultExpanded();
  }

  @override
  void didUpdateWidget(_SolveAccordion old) {
    super.didUpdateWidget(old);
    // A fresh answer just appeared — pop the walkthrough open so the
    // user lands on the result instead of staring at the same panel
    // they had open before the solve started.
    if (widget.answer != null && old.answer == null) {
      setState(() => _expanded = _Panel.walkthrough);
    }
  }

  _Panel? _defaultExpanded() {
    if (widget.answer != null) return _Panel.walkthrough;
    if (widget.extractedProblem?.isNotEmpty == true) return _Panel.problem;
    if (widget.capturedImageUrl != null) return _Panel.image;
    return null;
  }

  void _toggle(_Panel p) {
    setState(() {
      _expanded = _expanded == p ? null : p;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <_TileSpec>[];

    // Every panel fills the full available height when expanded (so
    // Captured Screen and Problem Statement get the same full-height,
    // responsive treatment as Solution Walkthrough).
    if (widget.capturedImageUrl != null) {
      tiles.add(_TileSpec(
        panel: _Panel.image,
        tile: _Tile(
          label: 'CAPTURED SCREEN',
          icon: Icons.image_outlined,
          expanded: _expanded == _Panel.image,
          onToggle: () => _toggle(_Panel.image),
          fillAvailable: _expanded == _Panel.image,
          body: _ImageBody(url: widget.capturedImageUrl!),
        ),
      ));
    }

    if (widget.extractedProblem?.isNotEmpty == true) {
      tiles.add(_TileSpec(
        panel: _Panel.problem,
        tile: _Tile(
          label: 'PROBLEM STATEMENT',
          icon: Icons.text_snippet_outlined,
          expanded: _expanded == _Panel.problem,
          onToggle: () => _toggle(_Panel.problem),
          fillAvailable: _expanded == _Panel.problem,
          body: _ProblemBody(text: widget.extractedProblem!),
        ),
      ));
    }

    if (widget.answer != null) {
      tiles.add(_TileSpec(
        panel: _Panel.walkthrough,
        tile: _Tile(
          label: 'SOLUTION WALKTHROUGH',
          icon: Icons.auto_awesome_outlined,
          expanded: _expanded == _Panel.walkthrough,
          onToggle: () => _toggle(_Panel.walkthrough),
          fillAvailable: _expanded == _Panel.walkthrough,
          body: _WalkthroughBody(
            message: widget.answer!,
            isStreaming: widget.isStreaming,
          ),
        ),
      ));
    }

    // Unified, fully responsive layout: the ONE expanded panel fills the
    // remaining height (Expanded); the collapsed panels are just headers
    // stacked above/below it. Works the same no matter which panel is open.
    final hasExpanded = tiles.any((t) => t.panel == _expanded);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in tiles)
          if (t.panel == _expanded)
            Expanded(child: t.tile)
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: t.tile,
            ),
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: content,
    );
    // With something expanded the Column needs the bounded height it gets
    // from the parent Expanded. With nothing expanded, the headers stack and
    // scroll (no Expanded child inside an unbounded scroll view).
    return hasExpanded
        ? padded
        : SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: content,
          );
  }
}


class _TileSpec {
  final _Panel panel;
  final Widget tile;
  const _TileSpec({required this.panel, required this.tile});
}


/// Generic accordion tile. The header is always visible; the body
/// appears below when [expanded] is true, smoothly via [AnimatedSize].
class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.icon,
    required this.expanded,
    required this.onToggle,
    required this.body,
    this.fillAvailable = false,
  });

  final String label;
  final IconData icon;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget body;

  /// When true, the expanded body fills available height (used by the
  /// walkthrough tile so the answer takes the remaining screen).
  /// Otherwise the body sizes to its content, capped internally.
  final bool fillAvailable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: expanded
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: fillAvailable
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                    label: label,
                    icon: icon,
                    expanded: expanded,
                    onTap: onToggle),
                if (expanded)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: body,
                    ),
                  ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                    label: label,
                    icon: icon,
                    expanded: expanded,
                    onTap: onToggle),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: body,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
    );
  }
}


class _Header extends StatelessWidget {
  const _Header({
    required this.label,
    required this.icon,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Icon(icon,
                size: 16,
                color: expanded
                    ? scheme.primary
                    : scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: expanded
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more,
                  size: 18, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}


// ----- Panel bodies --------------------------------------------------------

class _ImageBody extends StatefulWidget {
  const _ImageBody({required this.url});
  final String url;

  @override
  State<_ImageBody> createState() => _ImageBodyState();
}


class _ImageBodyState extends State<_ImageBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Fills the panel's full (responsive) height when expanded; large
    // screenshots scroll within it.
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(4),
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(
            widget.url,
            fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Image not available (blob may have been deleted).',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
            ),
          ),
        ),
    );
  }
}

class _ProblemBody extends StatefulWidget {
  const _ProblemBody({required this.text});
  final String text;

  @override
  State<_ProblemBody> createState() => _ProblemBodyState();
}


class _ProblemBodyState extends State<_ProblemBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Fills the panel's full (responsive) height when expanded; long
    // problem statements scroll within it.
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(4),
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.only(right: 10),
        child: SelectionArea(
          child: Text(
            widget.text,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }
}


class _WalkthroughBody extends StatelessWidget {
  const _WalkthroughBody({required this.message, required this.isStreaming});
  final Message message;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: MessageBubble(
          message: message,
          isStreaming: isStreaming,
          frameless: true,
        ),
      ),
    );
  }
}


// ===========================================================================
// Banners / hints
// ===========================================================================

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(Icons.bolt,
                    size: 32, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(
                'Open the problem on screen, then tap Solve.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A screenshot is captured silently and analysed. You get a '
                'full solution — Problem, Approach, Solution, Complexity, '
                'and Walkthrough — pick the LLM provider and models in '
                'Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _StatusBar extends StatelessWidget {
  final String text;
  const _StatusBar({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: scheme.surfaceContainerHigh,
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
            ),
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

