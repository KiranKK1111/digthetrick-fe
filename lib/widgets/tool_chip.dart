/// Small pill that appears inside an assistant message as agents work.
///
/// `[🔍 Searching resume...]  [🧠 Recalling past answers...]  [✓ Grounded]`
///
/// Each chip is clickable — tapping expands a panel with the agent's
/// findings. Architecture.md §7:
///   "Tool-use chips: small pills that appear in the assistant message
///   as agents work. Each is clickable to expand."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

enum ToolStatus { running, done, flagged }

class ToolChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final ToolStatus status;
  final VoidCallback? onTap;

  const ToolChip({
    super.key,
    required this.label,
    required this.icon,
    this.status = ToolStatus.done,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final tint = switch (status) {
      ToolStatus.running => t.palette.accent,
      ToolStatus.done => t.palette.success,
      ToolStatus.flagged => t.palette.warning,
    };
    return Material(
      color: tint.withOpacity(0.12),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: t.space.md,
            vertical: t.space.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: tint),
              SizedBox(width: t.space.xs),
              Text(
                label,
                style: TextStyle(
                  color: tint,
                  fontSize: t.type.xs,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
