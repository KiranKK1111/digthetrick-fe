/// ⌘K command palette — fuzzy-search everything.
///
/// Architecture.md §7:
///   "switch chat, change model, toggle theme, upload resume, start live
///   session, open settings, run a code problem."
///
/// Usage:
///   showCommandPalette(context, items: [...]);
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/tokens.dart';

class CommandItem {
  final String label;
  final String? subtitle;
  final String? shortcut;
  final IconData? icon;
  final VoidCallback onSelect;
  final List<String> keywords;

  /// Category label shown small + dim before the label, à la VS Code
  /// "View: Toggle Sidebar". Renders as `Category: Label`.
  final String? category;

  CommandItem({
    required this.label,
    required this.onSelect,
    this.subtitle,
    this.shortcut,
    this.icon,
    this.category,
    this.keywords = const [],
  });
}

Future<void> showCommandPalette(
  BuildContext context, {
  required List<CommandItem> items,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, __) => _CommandPaletteDialog(items: items),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  final List<CommandItem> items;
  const _CommandPaletteDialog({required this.items});

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    _ctrl.addListener(() {
      setState(() => _highlight = 0);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<CommandItem> _filtered() {
    final q = _ctrl.text.toLowerCase().trim();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where((it) =>
            it.label.toLowerCase().contains(q) ||
            it.keywords.any((k) => k.toLowerCase().contains(q)))
        .toList();
  }

  void _runHighlight() {
    final f = _filtered();
    if (f.isEmpty) return;
    final idx = _highlight.clamp(0, f.length - 1);
    Navigator.of(context).pop();
    f[idx].onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final filtered = _filtered();
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Material(
          color: t.palette.elevated,
          borderRadius: BorderRadius.circular(t.radii.lg),
          elevation: 12,
          child: Container(
            width: 560,
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
            decoration: BoxDecoration(
              border: Border.all(color: t.palette.border),
              borderRadius: BorderRadius.circular(t.radii.lg),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.all(t.space.md),
                  child: KeyboardListener(
                    focusNode: FocusNode(),
                    onKeyEvent: (e) {
                      if (e is! KeyDownEvent) return;
                      if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                        setState(() => _highlight = (_highlight + 1).clamp(0, filtered.length - 1));
                      } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                        setState(() => _highlight = (_highlight - 1).clamp(0, filtered.length - 1));
                      } else if (e.logicalKey == LogicalKeyboardKey.enter) {
                        _runHighlight();
                      }
                    },
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      autofocus: true,
                      style: TextStyle(color: t.palette.textPrimary, fontSize: t.type.md),
                      decoration: InputDecoration(
                        hintText: 'Type a command…',
                        hintStyle: TextStyle(color: t.palette.textMuted),
                        prefixIcon: Icon(Icons.search, color: t.palette.textMuted, size: 18),
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _runHighlight(),
                    ),
                  ),
                ),
                Divider(color: t.palette.border, height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final it = filtered[i];
                      final selected = i == _highlight;
                      return Material(
                        color: selected ? t.palette.accent.withOpacity(0.12) : Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).pop();
                            it.onSelect();
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: t.space.lg,
                              vertical: t.space.md,
                            ),
                            child: Row(
                              children: [
                                if (it.icon != null) ...[
                                  Icon(it.icon, size: 16, color: t.palette.textMuted),
                                  SizedBox(width: t.space.md),
                                ],
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      style: TextStyle(
                                        color: t.palette.textPrimary,
                                        fontSize: t.type.sm,
                                      ),
                                      children: [
                                        if (it.category != null) ...[
                                          TextSpan(
                                            text: '${it.category}: ',
                                            style: TextStyle(
                                              color: t.palette.textMuted,
                                            ),
                                          ),
                                        ],
                                        TextSpan(text: it.label),
                                      ],
                                    ),
                                  ),
                                ),
                                if (it.shortcut != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: t.palette.border.withOpacity(0.4),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      it.shortcut!,
                                      style: TextStyle(
                                        color: t.palette.textMuted,
                                        fontSize: t.type.xs,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                if (it.subtitle != null) ...[
                                  if (it.shortcut != null)
                                    SizedBox(width: t.space.md),
                                  Text(
                                    it.subtitle!,
                                    style: TextStyle(color: t.palette.textMuted, fontSize: t.type.xs),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
