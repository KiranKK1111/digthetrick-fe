/// Right-rail proactive suggestions from the Suggester agent.
///
/// Architecture.md §7:
///   "Bring up Project Atlas." / "You're stronger on backend than
///   frontend stories — focus there." Dismissible.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class Suggestion {
  final String id;
  final String text;
  const Suggestion({required this.id, required this.text});
}

class SuggestionsRail extends StatelessWidget {
  final List<Suggestion> suggestions;
  final ValueChanged<Suggestion>? onAccept;
  final ValueChanged<Suggestion>? onDismiss;

  const SuggestionsRail({
    super.key,
    required this.suggestions,
    this.onAccept,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.all(t.space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SUGGESTIONS',
            style: TextStyle(
              color: t.palette.textMuted,
              fontSize: t.type.xs,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          SizedBox(height: t.space.sm),
          ...suggestions.map(
            (s) => Container(
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
                  Text(s.text, style: TextStyle(color: t.palette.textPrimary, fontSize: t.type.sm)),
                  SizedBox(height: t.space.sm),
                  Row(
                    children: [
                      if (onAccept != null)
                        TextButton(onPressed: () => onAccept!(s), child: const Text('Use')),
                      if (onDismiss != null)
                        TextButton(onPressed: () => onDismiss!(s), child: const Text('Dismiss')),
                    ],
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
