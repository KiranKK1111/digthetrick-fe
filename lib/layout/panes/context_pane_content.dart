/// What goes inside the [ContextPane] on tablet+ widths.
///
/// Subscribes to [AppState.toolStream] and renders, top to bottom:
///   1. The current turn's intent chip + latency
///   2. Tool-chip stream (one chip per agent activity)
///   3. Feedback bar (👍 / 👎) when the turn has finished
///   4. (TODO) memory hits and source citations
///
/// One widget so the parent doesn't have to wire three providers.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/tokens.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../state/tool_stream.dart';
import '../../widgets/source_citation.dart';
import '../../widgets/suggestions_rail.dart';
import '../../widgets/tool_chip.dart';

class ContextPaneContent extends StatelessWidget {
  const ContextPaneContent({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final stream = appState.toolStream;
    final tokens = DesignTokens.of(context);

    return AnimatedBuilder(
      animation: stream,
      builder: (context, _) {
        final activity = stream.groupedActivity;
        final hasContent = activity.isNotEmpty ||
            stream.intent != null ||
            stream.episodeId != null;

        return ListView(
          padding: EdgeInsets.all(tokens.space.lg),
          children: [
            _SectionHeader(label: 'CURRENT TURN'),
            if (stream.intent != null)
              Padding(
                padding: EdgeInsets.only(top: tokens.space.sm),
                child: Row(
                  children: [
                    _IntentBadge(intent: stream.intent!),
                    if (stream.latencyMs > 0) ...[
                      SizedBox(width: tokens.space.sm),
                      Text(
                        '${stream.latencyMs} ms',
                        style: TextStyle(
                          color: tokens.palette.textMuted,
                          fontSize: tokens.type.xs,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            // Architecture.md §"Conversation link graph" — continuation
            // suggestions surface as chips here so the user can confirm
            // (or ignore) before the next turn.
            if (stream.continuations.isNotEmpty) ...[
              SizedBox(height: tokens.space.md),
              _SectionHeader(label: 'CONTINUES FROM'),
              SizedBox(height: tokens.space.sm),
              Wrap(
                spacing: tokens.space.sm,
                runSpacing: tokens.space.sm,
                children: [
                  for (final c in stream.continuations)
                    _ContinuationChip(
                      sessionId: c['session_id'] as String? ?? '',
                      confidence: (c['confidence'] as num?)?.toDouble() ?? 0.0,
                      keywords: (c['matched_keywords'] as List?)
                              ?.cast<String>() ??
                          const [],
                      onDismiss: stream.clearContinuations,
                    ),
                ],
              ),
            ],
            SizedBox(height: tokens.space.md),
            _SectionHeader(label: 'AGENTS'),
            SizedBox(height: tokens.space.sm),
            if (activity.isEmpty)
              Text(
                hasContent ? 'No agent activity.' : 'Idle.',
                style: TextStyle(
                  color: tokens.palette.textMuted,
                  fontSize: tokens.type.sm,
                ),
              )
            else
              Wrap(
                spacing: tokens.space.sm,
                runSpacing: tokens.space.sm,
                children: activity.map(_renderChip).toList(),
              ),
            if (stream.suggestions.isNotEmpty) ...[
              SizedBox(height: tokens.space.xl),
              SuggestionsRail(
                suggestions: [
                  for (var i = 0; i < stream.suggestions.length; i++)
                    Suggestion(id: 's$i', text: stream.suggestions[i]),
                ],
              ),
            ],
            if (stream.memoryHits.isNotEmpty) ...[
              SizedBox(height: tokens.space.xl),
              _SectionHeader(label: 'MEMORY HITS'),
              SizedBox(height: tokens.space.sm),
              ...stream.memoryHits.map((h) => _MemoryHitTile(hit: h)),
            ],
            if (stream.evidence.isNotEmpty) ...[
              SizedBox(height: tokens.space.xl),
              _SectionHeader(label: 'SOURCES'),
              SizedBox(height: tokens.space.sm),
              SourcePanel(
                sources: [
                  for (final c in stream.evidence)
                    SourceEntry(
                      label: c.source,
                      text: c.text,
                      confidence: c.score,
                    ),
                ],
              ),
            ],
            if (stream.unverifiedClaims.isNotEmpty ||
                stream.criticIssues.isNotEmpty) ...[
              SizedBox(height: tokens.space.xl),
              _SectionHeader(label: 'REVIEW'),
              SizedBox(height: tokens.space.sm),
              if (stream.unverifiedClaims.isNotEmpty)
                _ReviewBlock(
                  title: 'Unverified',
                  tint: tokens.palette.warning,
                  items: stream.unverifiedClaims,
                ),
              if (stream.criticIssues.isNotEmpty) ...[
                SizedBox(height: tokens.space.sm),
                _ReviewBlock(
                  title: 'Critic',
                  tint: tokens.palette.danger,
                  items: stream.criticIssues,
                ),
              ],
            ],
            if (stream.episodeId != null) ...[
              SizedBox(height: tokens.space.xl),
              _SectionHeader(label: 'FEEDBACK'),
              SizedBox(height: tokens.space.sm),
              _FeedbackBar(episodeId: stream.episodeId!),
            ],
          ],
        );
      },
    );
  }

  Widget _renderChip(ToolActivity a) {
    final icon = _iconFor(a.name);
    final status = switch (a.status) {
      'running' => ToolStatus.running,
      'flagged' => ToolStatus.flagged,
      _ => ToolStatus.done,
    };
    final label = a.key.isNotEmpty ? '${a.name} → ${a.key}' : a.name;
    return ToolChip(label: label, icon: icon, status: status);
  }

  IconData _iconFor(String agent) {
    switch (agent) {
      case 'retriever':
        return Icons.search;
      case 'memory':
        return Icons.psychology_outlined;
      case 'persona':
      case 'coder':
        return Icons.edit_note;
      case 'grounder':
        return Icons.verified_outlined;
      case 'critic':
        return Icons.rule;
      case 'suggester':
        return Icons.tips_and_updates_outlined;
      case 'reflector':
        return Icons.history_edu;
      case 'planner':
        return Icons.account_tree_outlined;
      case 'clarifier':
        return Icons.help_outline;
      case 'vision':
        return Icons.image_outlined;
      case 'web':
        return Icons.public;
      case 'error':
        return Icons.error_outline;
      default:
        return Icons.bolt;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Text(
      label,
      style: TextStyle(
        color: t.palette.textMuted,
        fontSize: t.type.xs,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _IntentBadge extends StatelessWidget {
  final String intent;
  const _IntentBadge({required this.intent});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: 2),
      decoration: BoxDecoration(
        color: t.palette.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(t.radii.sm),
      ),
      child: Text(
        intent,
        style: TextStyle(
          color: t.palette.accent,
          fontSize: t.type.xs,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FeedbackBar extends StatefulWidget {
  final String episodeId;
  const _FeedbackBar({required this.episodeId});

  @override
  State<_FeedbackBar> createState() => _FeedbackBarState();
}

class _FeedbackBarState extends State<_FeedbackBar> {
  String? _sent;

  Future<void> _send(String kind) async {
    if (_sent != null) return;
    setState(() => _sent = kind);
    try {
      final appState = context.read<AppState>();
      await ApiService(baseUrl: appState.baseUrl).sendEpisodeFeedback(
        episodeId: widget.episodeId,
        kind: kind,
      );
    } catch (_) {
      if (mounted) setState(() => _sent = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final disabled = _sent != null;
    return Row(
      children: [
        _btn(t, Icons.thumb_up_outlined, 'up', disabled),
        SizedBox(width: t.space.sm),
        _btn(t, Icons.thumb_down_outlined, 'down', disabled),
        SizedBox(width: t.space.md),
        if (_sent != null)
          Text(
            _sent == 'up' ? 'Thanks — that was useful.' : 'Noted — we\'ll do better.',
            style: TextStyle(color: t.palette.textMuted, fontSize: t.type.xs),
          ),
      ],
    );
  }

  Widget _btn(DesignTokens t, IconData icon, String kind, bool disabled) {
    final active = _sent == kind;
    return Material(
      color: active
          ? t.palette.accent.withOpacity(0.15)
          : t.palette.elevated,
      borderRadius: BorderRadius.circular(t.radii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radii.sm),
        onTap: disabled ? null : () => _send(kind),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: t.space.md,
            vertical: t.space.xs,
          ),
          child: Icon(
            icon,
            size: 16,
            color: active ? t.palette.accent : t.palette.textMuted,
          ),
        ),
      ),
    );
  }
}

class _MemoryHitTile extends StatelessWidget {
  final MemoryHit hit;
  const _MemoryHitTile({required this.hit});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: t.space.sm),
      padding: EdgeInsets.all(t.space.md),
      decoration: BoxDecoration(
        color: t.palette.elevated,
        border: Border.all(color: t.palette.border),
        borderRadius: BorderRadius.circular(t.radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hit.question,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.palette.textPrimary,
              fontSize: t.type.sm,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hit.preview.isNotEmpty) ...[
            SizedBox(height: t.space.xs),
            Text(
              hit.preview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.palette.textMuted,
                fontSize: t.type.xs,
              ),
            ),
          ],
          SizedBox(height: t.space.xs),
          Row(
            children: [
              _MiniBadge(text: hit.intent, color: t.palette.accent),
              if (hit.feedback == 'up') ...[
                SizedBox(width: t.space.xs),
                Icon(Icons.thumb_up,
                    size: 11, color: t.palette.success),
              ] else if (hit.feedback == 'down') ...[
                SizedBox(width: t.space.xs),
                Icon(Icons.thumb_down,
                    size: 11, color: t.palette.danger),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _MiniBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: t.type.xs - 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ReviewBlock extends StatelessWidget {
  final String title;
  final Color tint;
  final List<String> items;
  const _ReviewBlock({
    required this.title,
    required this.tint,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      padding: EdgeInsets.all(t.space.md),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.08),
        border: Border.all(color: tint.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(t.radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: tint,
              fontSize: t.type.xs,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          SizedBox(height: t.space.xs),
          ...items.map(
            (it) => Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '• $it',
                style: TextStyle(
                  color: t.palette.textPrimary,
                  fontSize: t.type.xs,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirm-suggest chip for a continuation candidate.
///
/// The chip shows the matched keywords + a confidence number and a
/// dismiss "x". A future iteration can wire `onAccept` through to
/// the chat screen so tapping it loads the prior conversation into
/// the current turn's context.
class _ContinuationChip extends StatelessWidget {
  const _ContinuationChip({
    required this.sessionId,
    required this.confidence,
    required this.keywords,
    required this.onDismiss,
  });

  final String sessionId;
  final double confidence;
  final List<String> keywords;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final label = keywords.isEmpty
        ? 'related session'
        : keywords.take(3).join(', ');
    return Material(
      color: t.palette.surface,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          // TODO: load the candidate into the current turn's context.
          // For now, just dismiss the chip on tap.
          onDismiss();
        },
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: t.space.sm,
            vertical: t.space.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.link,
                size: 12,
                color: t.palette.textMuted,
              ),
              SizedBox(width: t.space.xs),
              Text(
                label,
                style: TextStyle(
                  color: t.palette.textPrimary,
                  fontSize: t.type.xs,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(width: t.space.xs),
              Text(
                '${(confidence * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: t.palette.textMuted,
                  fontSize: t.type.xs,
                ),
              ),
              SizedBox(width: t.space.xs),
              GestureDetector(
                onTap: onDismiss,
                child: Icon(
                  Icons.close,
                  size: 12,
                  color: t.palette.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
