/// Right context pane — sources, suggestions, memory hits, tool history.
///
/// On laptop+ widths this is always visible. On tablet it lifts out as
/// an overlay; on phone it becomes a swipe-up sheet (Architecture.md §7).
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

class ContextPane extends StatelessWidget {
  final Widget child;
  const ContextPane({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: t.palette.surface,
        border: Border(left: BorderSide(color: t.palette.border)),
      ),
      child: child,
    );
  }
}
