/// Progressive single-word loader — Architecture.md §"Progressive loader".
///
/// Shows ONE word at a time reflecting the backend's actual phase:
///     Thinking → Searching → Analyzing → Coding → Verifying → Polishing → Streaming
///
/// Source of truth is the SSE `stage` event the agents/dsa/technical
/// pipelines emit. The mapping below converts a stage name → user-
/// facing word. Unknown stages fall back to "Thinking".
library;

import 'package:flutter/material.dart';

/// Conventional stage-name → display-word map.
///
/// Backend should emit `event: stage` with `data: {"name": "..."}`.
/// Keep this aligned with the agents / DSA / technical_pipeline stage names.
const Map<String, String> kStageWords = {
  'planner': 'Thinking',
  'extractor': 'Reading',
  'retriever': 'Searching',
  'classifier': 'Analyzing',
  'approaches': 'Coding',
  'examples': 'Tracing',
  'complexity': 'Reasoning',
  'verify': 'Verifying',
  'edge_cases': 'Polishing',
  'viz': 'Polishing',
  'markdown': 'Streaming',
  'token': 'Streaming',
};

/// Resolve a stage to a display label. Known backend stage *keys* map via
/// [kStageWords]; anything else (e.g. a ready-made phrase the chat screen
/// cycles through) is shown verbatim.
String stageWord(String? stageName) {
  if (stageName == null || stageName.isEmpty) return 'Thinking';
  return kStageWords[stageName] ?? stageName;
}

/// Single-word animated indicator. Pulses subtly to signal aliveness.
class ProgressLoader extends StatefulWidget {
  const ProgressLoader({super.key, this.stage});

  final String? stage;

  @override
  State<ProgressLoader> createState() => _ProgressLoaderState();
}

class _ProgressLoaderState extends State<ProgressLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final word = stageWord(widget.stage);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Tiny pulsing dot.
        FadeTransition(
          opacity: Tween(begin: 0.35, end: 1.0).animate(_ctrl),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            word,
            key: ValueKey(word),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
