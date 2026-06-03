/// Slide-out drawer showing what the system remembers about the user.
///
/// Architecture.md §7:
///   "Editable — the user owns their memory."
///
/// Lists preferences, strong stories, weak areas; each row has an edit
/// pencil and a delete button. Backed by [SemanticMemory] on the server.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class MemoryEntry {
  final String id;
  final String text;
  final String kind;           // 'preference' | 'pattern' | 'gap' | 'strength'
  final double confidence;
  const MemoryEntry({
    required this.id,
    required this.text,
    required this.kind,
    required this.confidence,
  });
}

class MemoryDrawer extends StatelessWidget {
  final List<MemoryEntry> entries;
  final ValueChanged<MemoryEntry>? onEdit;
  final ValueChanged<MemoryEntry>? onDelete;

  const MemoryDrawer({
    super.key,
    required this.entries,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Drawer(
      backgroundColor: t.palette.surface,
      width: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xl, t.space.lg, t.space.md),
            child: Text(
              'What I remember',
              style: TextStyle(
                color: t.palette.textPrimary,
                fontSize: t.type.lg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.lg),
            child: Text(
              'Editable. You own this.',
              style: TextStyle(color: t.palette.textMuted, fontSize: t.type.sm),
            ),
          ),
          SizedBox(height: t.space.lg),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      'No memories yet.',
                      style: TextStyle(color: t.palette.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.symmetric(horizontal: t.space.lg),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => SizedBox(height: t.space.sm),
                    itemBuilder: (context, i) => _MemoryRow(
                      entry: entries[i],
                      onEdit: onEdit,
                      onDelete: onDelete,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  final MemoryEntry entry;
  final ValueChanged<MemoryEntry>? onEdit;
  final ValueChanged<MemoryEntry>? onDelete;

  const _MemoryRow({required this.entry, this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      padding: EdgeInsets.all(t.space.md),
      decoration: BoxDecoration(
        color: t.palette.elevated,
        border: Border.all(color: t.palette.border),
        borderRadius: BorderRadius.circular(t.radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.text,
                  style: TextStyle(color: t.palette.textPrimary, fontSize: t.type.sm),
                ),
                SizedBox(height: t.space.xs),
                Text(
                  entry.kind,
                  style: TextStyle(color: t.palette.textMuted, fontSize: t.type.xs),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit == null ? null : () => onEdit!(entry),
            icon: Icon(Icons.edit_outlined, size: 16, color: t.palette.textMuted),
          ),
          IconButton(
            onPressed: onDelete == null ? null : () => onDelete!(entry),
            icon: Icon(Icons.delete_outline, size: 16, color: t.palette.danger),
          ),
        ],
      ),
    );
  }
}
