/// Markdown that renders progressively as tokens arrive.
///
/// Wraps `flutter_markdown` with a live cursor and an auto-scroll hook.
/// Architecture.md §7:
///   "tokens arrive, markdown renders progressively (no flash, no reflow
///   jank). Code blocks materialize when their fence closes."
///
/// TODO: switch to a token-buffered markdown parser that holds partial
/// fences open until they close, to remove the flicker when the first
/// half of a code block arrives. The current implementation is a thin
/// wrapper — good enough for plain prose, imperfect for half-streamed
/// code blocks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../design/tokens.dart';

class StreamingMarkdown extends StatelessWidget {
  final String text;
  final bool isStreaming;
  final bool selectable;

  const StreamingMarkdown({
    super.key,
    required this.text,
    this.isStreaming = false,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final body = isStreaming ? '$text▌' : text;
    return MarkdownBody(
      data: body,
      selectable: selectable,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: t.palette.textPrimary,
          fontSize: t.type.md,
          height: t.type.lineBody,
        ),
        h1: TextStyle(
          color: t.palette.textPrimary,
          fontSize: t.type.xl,
          fontWeight: FontWeight.w700,
          height: t.type.lineHeading,
        ),
        h2: TextStyle(
          color: t.palette.textPrimary,
          fontSize: t.type.lg,
          fontWeight: FontWeight.w700,
          height: t.type.lineHeading,
        ),
        h3: TextStyle(
          color: t.palette.textPrimary,
          fontSize: t.type.md,
          fontWeight: FontWeight.w600,
        ),
        listBullet: TextStyle(color: t.palette.textPrimary),
        strong: TextStyle(color: t.palette.textPrimary, fontWeight: FontWeight.w700),
        em: TextStyle(color: t.palette.textPrimary, fontStyle: FontStyle.italic),
        code: TextStyle(
          color: t.palette.accent,
          backgroundColor: t.palette.codeBg,
          fontFamily: t.type.monoFamily,
          fontSize: t.type.sm,
        ),
        codeblockDecoration: BoxDecoration(
          color: t.palette.codeBg,
          borderRadius: BorderRadius.circular(t.radii.md),
        ),
        blockquote: TextStyle(color: t.palette.textMuted),
        a: TextStyle(color: t.palette.accent),
      ),
    );
  }
}
