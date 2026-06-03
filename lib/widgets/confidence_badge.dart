/// Confidence indicator: subtle dot next to each answer.
///
/// Architecture.md §7:
///   "green (well-grounded), amber (partial), gray (no claims to verify).
///   Hover reveals breakdown."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

enum ConfidenceLevel { high, medium, none }

class ConfidenceBadge extends StatelessWidget {
  final ConfidenceLevel level;
  final String? tooltip;

  const ConfidenceBadge({super.key, required this.level, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final color = switch (level) {
      ConfidenceLevel.high => t.palette.success,
      ConfidenceLevel.medium => t.palette.warning,
      ConfidenceLevel.none => t.palette.textMuted,
    };
    return Tooltip(
      message: tooltip ?? _defaultMessage(level),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  String _defaultMessage(ConfidenceLevel l) => switch (l) {
        ConfidenceLevel.high => 'Well-grounded in sources.',
        ConfidenceLevel.medium => 'Partially verified.',
        ConfidenceLevel.none => 'No claims to verify.',
      };
}
