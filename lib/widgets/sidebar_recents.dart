/// Compact "Recents" list rendered inside the persistent sidebar.
///
/// This is the in-sidebar twin of [HistoryDrawer] — same data shape
/// (title + timestamp + optional badge) and same per-row actions
/// (open, rename, delete) but laid out for a 264 px column instead of
/// a 340 px overlay drawer.
///
/// The hosting screen (chat, solve) builds this widget once with its
/// current list + callbacks, then publishes it via
/// `AppState.setSidebarExtras(...)` so the shell renders it under the
/// primary menu. Re-publish whenever the list changes.
library;

import 'package:flutter/material.dart';

class SidebarRecentItem {
  SidebarRecentItem({
    required this.id,
    required this.title,
    this.timestamp,
    this.badge,
  });

  final String id;
  final String title;
  final DateTime? timestamp;
  final String? badge;
}


class SidebarRecents extends StatefulWidget {
  const SidebarRecents({
    super.key,
    required this.heading,
    required this.items,
    required this.activeId,
    required this.loading,
    required this.onSelect,
    required this.onNew,
    this.onRename,
    this.onDelete,
    this.newLabel = 'New chat',
    this.emptyLabel = 'No recents yet.',
  });

  final String heading;
  final List<SidebarRecentItem> items;
  final String? activeId;
  final bool loading;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;
  final Future<void> Function(String id, String newTitle)? onRename;
  final Future<void> Function(String id)? onDelete;
  final String newLabel;
  final String emptyLabel;

  @override
  State<SidebarRecents> createState() => _SidebarRecentsState();
}


class _SidebarRecentsState extends State<SidebarRecents> {
  final _filterCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  List<SidebarRecentItem> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where((s) => s.title.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: _NewButton(
            label: widget.newLabel,
            onTap: widget.onNew,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.heading.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10.5,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (widget.items.length > 5)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _filterCtrl,
                onChanged: (v) => setState(() => _filter = v),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter…',
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 28,
                  ),
                  filled: true,
                  fillColor: scheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: scheme.primary, width: 1),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 4),
                ),
              ),
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(
                    widget.loading ? 'Loading…' : widget.emptyLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final item = list[i];
                    return _Row(
                      item: item,
                      active: item.id == widget.activeId,
                      onSelect: () => widget.onSelect(item.id),
                      onRename: widget.onRename == null
                          ? null
                          : () => _promptRename(item),
                      onDelete: widget.onDelete == null
                          ? null
                          : () => _confirmDelete(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _promptRename(SidebarRecentItem item) async {
    final ctrl = TextEditingController(text: item.title);
    final out = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'New title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (out == null || out.isEmpty || out == item.title) return;
    await widget.onRename?.call(item.id, out);
  }

  Future<void> _confirmDelete(SidebarRecentItem item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(
          '"${item.title}" will be removed. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.onDelete?.call(item.id);
  }
}


class _NewButton extends StatelessWidget {
  const _NewButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(Icons.add, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _Row extends StatefulWidget {
  const _Row({
    required this.item,
    required this.active,
    required this.onSelect,
    this.onRename,
    this.onDelete,
  });

  final SidebarRecentItem item;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  State<_Row> createState() => _RowState();
}


class _RowState extends State<_Row> {
  bool _hover = false;

  String _relative(DateTime ts) {
    final diff = DateTime.now().toUtc().difference(ts.toUtc());
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = widget.active
        ? scheme.primary.withValues(alpha: 0.14)
        : (_hover
            ? scheme.primary.withValues(alpha: 0.05)
            : Colors.transparent);
    final titleColor = widget.active
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.85);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 12.5,
                          fontWeight: widget.active
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                      if (widget.item.timestamp != null ||
                          widget.item.badge != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              if (widget.item.badge != null) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    widget.item.badge!,
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              if (widget.item.timestamp != null)
                                Text(
                                  _relative(widget.item.timestamp!),
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 10.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // Always render the menu so any row can be acted on
                // (rename / delete) — not only the selected one. The
                // icon brightens on hover; sits at low opacity at rest
                // so it doesn't compete with the title at idle.
                SizedBox(
                  width: 24,
                  height: 24,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    tooltip: 'More',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 14,
                      color: scheme.onSurfaceVariant.withValues(
                        alpha: (_hover || widget.active) ? 1.0 : 0.55,
                      ),
                    ),
                      onSelected: (v) {
                        if (v == 'rename') widget.onRename?.call();
                        if (v == 'delete') widget.onDelete?.call();
                      },
                      itemBuilder: (_) => [
                        if (widget.onRename != null)
                          const PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit_outlined, size: 16),
                                SizedBox(width: 8),
                                Text('Rename'),
                              ],
                            ),
                          ),
                        if (widget.onDelete != null)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline, size: 16),
                                SizedBox(width: 8),
                                Text('Delete'),
                              ],
                            ),
                          ),
                      ],
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
