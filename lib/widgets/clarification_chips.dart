/// Quick-reply chips shown under a clarifying question.
///
/// Architecture.md §7:
///   "Which role are you preparing for?"
///   [Frontend SWE] [Backend SWE] [Data] [Other...]
///   "Chips animate in, tap to send, free-text input always available."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class ClarificationChips extends StatelessWidget {
  final List<String> options;
  final ValueChanged<String> onSelected;

  const ClarificationChips({
    super.key,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Wrap(
      spacing: t.space.sm,
      runSpacing: t.space.sm,
      children: options
          .map(
            (opt) => Material(
              color: t.palette.elevated,
              borderRadius: BorderRadius.circular(t.radii.lg),
              child: InkWell(
                borderRadius: BorderRadius.circular(t.radii.lg),
                onTap: () => onSelected(opt),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: t.space.md,
                    vertical: t.space.sm,
                  ),
                  child: Text(
                    opt,
                    style: TextStyle(
                      color: t.palette.textPrimary,
                      fontSize: t.type.sm,
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
