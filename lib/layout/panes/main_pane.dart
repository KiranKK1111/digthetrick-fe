/// Main pane — hosts the active screen (Chat / Live / Solve / etc.).
///
/// Kept intentionally thin so the existing screens drop in unchanged.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

class MainPane extends StatelessWidget {
  final Widget child;
  const MainPane({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return ColoredBox(
      color: t.palette.canvas,
      child: child,
    );
  }
}
