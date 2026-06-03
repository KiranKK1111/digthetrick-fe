/// `WorkspaceShell` — the three-pane Linear/Raycast-style frame.
///
/// Architecture.md §7 layout:
///   ┌────────────────────────────────────────────────────────────────┐
///   │  ☰  Title           ⌘K Search           ⚙   👤  Connected      │  top bar
///   ├──────┬───────────────────────────────────────┬─────────────────┤
///   │  NAV │           MAIN PANE                   │  CONTEXT PANE   │
///   ├──────┴───────────────────────────────────────┴─────────────────┤
///   │  Status: Idle • Main: Llama 3.3 (Groq) • STT: Whisper base     │  status bar
///   └────────────────────────────────────────────────────────────────┘
///
/// Mobile collapses to a single pane + bottom tabs; tablet shows nav +
/// main; laptop and desktop show all three.
library;

import 'package:flutter/material.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import 'panes/context_pane.dart';
import 'panes/main_pane.dart';
import 'panes/nav_pane.dart';

class WorkspaceShell extends StatefulWidget {
  final Widget mainContent;
  final Widget? contextContent;
  final Widget? topBarActions;
  final Widget? statusBarChild;
  final int selectedNavIndex;
  final ValueChanged<int>? onNavSelected;

  const WorkspaceShell({
    super.key,
    required this.mainContent,
    this.contextContent,
    this.topBarActions,
    this.statusBarChild,
    this.selectedNavIndex = 0,
    this.onNavSelected,
  });

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  @override
  Widget build(BuildContext context) {
    final tokens = DesignTokens.of(context);
    final formFactor = Breakpoints.from(context);
    final paneCount = Breakpoints.paneCount(formFactor);

    return ColoredBox(
      color: tokens.palette.canvas,
      child: SafeArea(
        child: Column(
          children: [
            _TopBar(
              actions: widget.topBarActions,
            ),
            Expanded(
              child: Row(
                children: [
                  if (paneCount >= 2)
                    NavPane(
                      selected: widget.selectedNavIndex,
                      onSelected: widget.onNavSelected,
                    ),
                  Expanded(child: MainPane(child: widget.mainContent)),
                  if (paneCount >= 3 && widget.contextContent != null)
                    ContextPane(child: widget.contextContent!),
                ],
              ),
            ),
            _StatusBar(child: widget.statusBarChild),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Widget? actions;
  const _TopBar({this.actions});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: t.palette.surface,
        border: Border(bottom: BorderSide(color: t.palette.border)),
      ),
      padding: EdgeInsets.symmetric(horizontal: t.space.lg),
      child: Row(
        children: [
          Icon(Icons.menu, color: t.palette.textMuted, size: 18),
          SizedBox(width: t.space.md),
          Text(
            'DigTheTrick AI',
            style: TextStyle(
              color: t.palette.textPrimary,
              fontSize: t.type.md,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (actions != null) actions!,
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final Widget? child;
  const _StatusBar({this.child});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: t.palette.surface,
        border: Border(top: BorderSide(color: t.palette.border)),
      ),
      padding: EdgeInsets.symmetric(horizontal: t.space.lg),
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle(
        style: TextStyle(
          color: t.palette.textMuted,
          fontSize: t.type.xs,
        ),
        child: child ?? const Text('Ready'),
      ),
    );
  }
}
