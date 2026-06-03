/// Inline superscript citation marker — `[1]` — linked to a source panel.
///
/// Architecture.md §7:
///   "Source citations — inline superscript numbers [1] link to a
///   slide-out source panel showing the exact resume chunks used,
///   with confidence scores."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class SourceCitation extends StatelessWidget {
  final int index;
  final VoidCallback? onTap;

  const SourceCitation({super.key, required this.index, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 2),
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: t.palette.accent.withOpacity(0.15),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          '$index',
          style: TextStyle(
            color: t.palette.accent,
            fontSize: t.type.xs - 1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Slide-out panel showing the exact chunks behind each citation.
class SourcePanel extends StatelessWidget {
  final List<SourceEntry> sources;
  const SourcePanel({super.key, required this.sources});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return ListView.separated(
      padding: EdgeInsets.all(t.space.lg),
      itemCount: sources.length,
      separatorBuilder: (_, __) => SizedBox(height: t.space.md),
      itemBuilder: (context, i) {
        final s = sources[i];
        return Container(
          padding: EdgeInsets.all(t.space.md),
          decoration: BoxDecoration(
            color: t.palette.elevated,
            border: Border.all(color: t.palette.border),
            borderRadius: BorderRadius.circular(t.radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '[${i + 1}] ${s.label}',
                    style: TextStyle(
                      color: t.palette.textMuted,
                      fontSize: t.type.xs,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(s.confidence * 100).round()}%',
                    style: TextStyle(
                      color: t.palette.success,
                      fontSize: t.type.xs,
                    ),
                  ),
                ],
              ),
              SizedBox(height: t.space.sm),
              Text(
                s.text,
                style: TextStyle(color: t.palette.textPrimary, fontSize: t.type.sm),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SourceEntry {
  final String label;
  final String text;
  final double confidence;
  const SourceEntry({required this.label, required this.text, required this.confidence});
}
