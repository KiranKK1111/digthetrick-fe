/// Left navigation pane — the 5 destinations from the existing RootShell.
///
/// On phone/tablet this collapses to a bottom NavigationBar (handled by
/// the calling [WorkspaceShell]); this widget is the laptop/desktop sidebar.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';

class NavPane extends StatelessWidget {
  final int selected;
  final ValueChanged<int>? onSelected;

  const NavPane({super.key, required this.selected, this.onSelected});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: t.palette.surface,
        border: Border(right: BorderSide(color: t.palette.border)),
      ),
      child: ListView(
        padding: EdgeInsets.symmetric(vertical: t.space.md),
        children: [
          _NavItem(label: 'Live', icon: Icons.podcasts_outlined, index: 0, selected: selected, onSelected: onSelected),
          _NavItem(label: 'Chat', icon: Icons.chat_bubble_outline, index: 1, selected: selected, onSelected: onSelected),
          _NavItem(label: 'Resume', icon: Icons.description_outlined, index: 2, selected: selected, onSelected: onSelected),
          _NavItem(label: 'Solve', icon: Icons.flash_on_outlined, index: 3, selected: selected, onSelected: onSelected),
          _NavItem(label: 'Settings', icon: Icons.settings_outlined, index: 4, selected: selected, onSelected: onSelected),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final int index;
  final int selected;
  final ValueChanged<int>? onSelected;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.index,
    required this.selected,
    this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final isSelected = selected == index;
    final fg = isSelected ? t.palette.textPrimary : t.palette.textMuted;
    final bg = isSelected ? t.palette.accent.withOpacity(0.12) : Colors.transparent;
    return Material(
      color: bg,
      child: InkWell(
        onTap: () => onSelected?.call(index),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: t.space.lg,
            vertical: t.space.md,
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: fg),
              SizedBox(width: t.space.md),
              Text(
                label,
                style: TextStyle(color: fg, fontSize: t.type.base),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
