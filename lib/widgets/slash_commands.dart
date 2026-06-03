/// Slash-command picker — types `/` in an input to surface power-user commands.
///
/// Architecture.md §7 lists:
///   /redo  /shorter  /expand  /use-story <name>  /tone <formal|casual>
///   /regenerate-with <story>  /audit
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class SlashCommand {
  final String command;       // e.g. '/shorter'
  final String description;
  final List<String>? argHints;

  const SlashCommand({
    required this.command,
    required this.description,
    this.argHints,
  });
}

const List<SlashCommand> defaultSlashCommands = [
  SlashCommand(command: '/redo', description: 'Regenerate the last answer'),
  SlashCommand(command: '/shorter', description: 'Trim the last answer'),
  SlashCommand(command: '/expand', description: 'Add detail to the last answer'),
  SlashCommand(command: '/use-story', description: 'Force a specific story', argHints: ['<name>']),
  SlashCommand(command: '/tone', description: 'Change tone', argHints: ['formal', 'casual', 'concise']),
  SlashCommand(command: '/regenerate-with', description: 'Regenerate with a story', argHints: ['<story>']),
  SlashCommand(command: '/audit', description: 'Audit the last answer against sources'),
];

class SlashCommandMenu extends StatelessWidget {
  final String query;
  final ValueChanged<SlashCommand> onSelected;
  final List<SlashCommand> commands;

  const SlashCommandMenu({
    super.key,
    required this.query,
    required this.onSelected,
    this.commands = defaultSlashCommands,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final filtered = commands
        .where((c) => c.command.startsWith(query.toLowerCase()))
        .toList();
    if (filtered.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: t.palette.elevated,
        border: Border.all(color: t.palette.border),
        borderRadius: BorderRadius.circular(t.radii.md),
      ),
      constraints: BoxConstraints(maxHeight: 240),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: filtered.length,
        itemBuilder: (context, i) {
          final c = filtered[i];
          return ListTile(
            dense: true,
            title: Text(
              c.command + (c.argHints != null ? ' ${c.argHints!.first}' : ''),
              style: TextStyle(
                color: t.palette.textPrimary,
                fontFamily: t.type.monoFamily,
                fontSize: t.type.sm,
              ),
            ),
            subtitle: Text(
              c.description,
              style: TextStyle(color: t.palette.textMuted, fontSize: t.type.xs),
            ),
            onTap: () => onSelected(c),
          );
        },
      ),
    );
  }
}
