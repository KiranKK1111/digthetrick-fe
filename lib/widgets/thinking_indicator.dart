/// Three subtle pulsing dots — *not* bouncing.
///
/// Architecture.md §7:
///   "Replaced by tool-chips when agents start working — never a
///   generic 'loading'."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_ctrl.value + i * 0.2) % 1.0;
            final opacity = 0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: t.palette.textMuted.withOpacity(opacity),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
