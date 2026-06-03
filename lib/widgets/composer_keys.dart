/// Shared keyboard behaviour for the app's message composers.
///
/// Wrap any multi-line input [TextField] in [ComposerKeyboard] to get:
///   * **Enter**            → submit (calls `onSubmit` when `enabled`).
///   * **Alt+Enter**        → insert a newline at the cursor.
///   * **Shift+Enter**      → insert a newline at the cursor.
///
/// Implemented with [CallbackShortcuts]: a near-ancestor shortcut overrides
/// Flutter's default text-editing "Enter inserts a newline", so a plain Enter
/// sends and Alt/Shift+Enter add a line — consistently across the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Insert a newline at the current selection of [controller] (replacing any
/// selected range), leaving the caret just after the inserted break.
void insertNewlineAtCursor(TextEditingController controller) {
  final value = controller.value;
  final text = value.text;
  final sel = value.selection;
  final start = sel.start < 0 ? text.length : sel.start;
  final end = sel.end < 0 ? text.length : sel.end;
  final newText = text.replaceRange(start, end, '\n');
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start + 1),
    composing: TextRange.empty,
  );
}

class ComposerKeyboard extends StatelessWidget {
  const ComposerKeyboard({
    super.key,
    required this.controller,
    required this.onSubmit,
    required this.child,
    this.enabled = true,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final bool enabled;
  final Widget child;

  // Don't send while an IME composition is in progress (e.g. confirming a
  // Japanese/CJK candidate with Enter) — let the IME consume that Enter.
  void _submit() {
    if (controller.value.composing.isValid) return;
    if (enabled) onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        // Newline on Alt+Enter (and Shift+Enter, the usual convention).
        const SingleActivator(LogicalKeyboardKey.enter, alt: true): () =>
            insertNewlineAtCursor(controller),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            insertNewlineAtCursor(controller),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _submit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, alt: true): () =>
            insertNewlineAtCursor(controller),
        const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true): () =>
            insertNewlineAtCursor(controller),
      },
      child: child,
    );
  }
}
