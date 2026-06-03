/// A single chat message bubble.
///
/// User messages render as plain text in an accent-colored bubble on the
/// right. Assistant messages render as markdown (with custom code blocks) in
/// a surface-colored bubble on the left.
///
/// Theme-aware: text + bubble colours switch between dark / light. The
/// accent-colour user bubble is the same in both modes (purple stays
/// readable with white text either way).
library;

import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/theme.dart';
import 'artifact_card.dart';
import 'code_block.dart';
import 'document_download.dart';
import 'mermaid_renderer.dart';
import 'progress_loader.dart';

class MessageBubble extends StatelessWidget {
  final Message message;

  /// True while this assistant message is still being streamed into.
  /// Shows a subtle "typing" cursor.
  final bool isStreaming;

  /// When set, the assistant content renders this string instead of
  /// `message.content` — used by the chat screen's smooth typewriter to reveal
  /// the streamed text a little at a time (the full text still lives on the
  /// message, this is just the portion shown so far).
  final String? displayContent;

  /// When true, the assistant message renders without any bubble chrome
  /// (no background, no border, no margin, no max-width). The markdown
  /// — including the code block — sits directly on the page surface.
  /// Used by the Solve screen so the only dark surface visible is the
  /// code card itself; user messages still get a regular bubble.
  final bool frameless;

  // Per-message actions (chat). When any is provided, a hover action row is
  // shown under the bubble: user → copy/edit/retry; assistant →
  // copy/like/dislike/retry. Copy is handled internally (clipboard); the rest
  // call back into the chat screen. Solve passes none → no action row.
  final VoidCallback? onEdit;
  final VoidCallback? onRetry;
  /// Toggle feedback: receives 'thumb_up' | 'thumb_down' | null (clear).
  final ValueChanged<String?>? onFeedback;
  /// Resume an interrupted assistant turn (shown on incomplete messages).
  final VoidCallback? onContinue;

  /// When true, a user message renders an in-place editor (Cancel/Send)
  /// instead of the static bubble — Claude-style edit.
  final bool isEditing;
  final void Function(String text, List<ComposerAttachment> files)? onEditSubmit;
  final VoidCallback? onEditCancel;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.displayContent,
    this.frameless = false,
    this.onEdit,
    this.onRetry,
    this.onFeedback,
    this.onContinue,
    this.isEditing = false,
    this.onEditSubmit,
    this.onEditCancel,
  });

  bool get _hasActions =>
      onEdit != null || onRetry != null || onFeedback != null;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    // Frameless mode applies only to assistant messages — user messages
    // still need a visible bubble to read as the user's input.
    if (frameless && !isUser) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message.intent != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _IntentChip(intent: message.intent!),
                ),
              ),
            _MemoAssistantContent(
              content: message.content,
              isStreaming: isStreaming,
              artifacts: message.artifacts,
              stagePhase: message.stagePhase,
            ),
          ],
        ),
      );
    }

    // Inline edit mode for a user message — an editor in place of the bubble.
    if (isUser && isEditing && onEditSubmit != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: _InlineEditor(
            initial: message.content,
            initialFiles: message.files,
            initialNames: message.attachments,
            onSubmit: onEditSubmit!,
            onCancel: onEditCancel ?? () {},
          ),
        ),
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final assistantBg =
        dark ? AppPalette.darkSurface : AppPalette.lightSurface;
    final assistantBorder =
        dark ? AppPalette.darkBorder : AppPalette.lightBorder;

    // Diagrams render with their own ChatGPT-style toolbar (Download / Code /
    // Play / Expand) on the MermaidBlock itself — no bubble-level "⋯" menu.
    final bubbleBody = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? AppPalette.accent : assistantBg,
        borderRadius: BorderRadius.circular(12),
        border: isUser ? null : Border.all(color: assistantBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Intent chip on assistant messages, when known.
          if (!isUser && message.intent != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _IntentChip(intent: message.intent!),
            ),
          // Attached files on a user message: image attachments render as a
          // clickable thumbnail (opens in the right-side preview, like a PDF);
          // every other file type renders as a small pill.
          if (isUser && message.attachments.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: message.content.isEmpty ? 0 : 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in message.attachments)
                    if (_isImageAttachment(f))
                      _AttachmentThumb(
                        name: f,
                        bytes: _localImageBytes(message, f),
                        localPath: _localImagePath(message, f),
                        fetchPath: _imageRefPath(message, f),
                      )
                    else
                      _FilePill(name: f),
                ],
              ),
            ),
          if (isUser)
            if (message.content.isNotEmpty)
              Text(
                message.content,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              )
            else
              const SizedBox.shrink()
          else
            _MemoAssistantContent(
              content: displayContent ?? message.content,
              isStreaming: isStreaming,
              artifacts: message.artifacts,
              stagePhase: message.stagePhase,
            ),
          // Document card ONLY when the user explicitly asked to generate a
          // document (backend-flagged + persisted). Not shown for summaries.
          if (!isUser && message.isDocument && !isStreaming)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _DocumentChip(
                content: message.content,
                format: message.documentFormat,
              ),
            ),
        ],
      ),
    );

    // No action callbacks (e.g. Solve) → original plain bubble.
    if (!_hasActions) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: bubbleBody,
        ),
      );
    }

    // Chat: bubble + a hover action row aligned to the message's side.
    return _MessageWithActions(
      isUser: isUser,
      message: message,
      isStreaming: isStreaming,
      bubble: bubbleBody,
      onEdit: onEdit,
      onRetry: onRetry,
      onFeedback: onFeedback,
      onContinue: onContinue,
    );
  }
}


/// Wraps a message bubble with a hover-revealed action row (copy / edit /
/// retry for the user; copy / like / dislike / retry for the assistant).
class _MessageWithActions extends StatefulWidget {
  const _MessageWithActions({
    required this.isUser,
    required this.message,
    required this.isStreaming,
    required this.bubble,
    this.onEdit,
    this.onRetry,
    this.onFeedback,
    this.onContinue,
  });

  final bool isUser;
  final Message message;
  final bool isStreaming;
  final Widget bubble;
  final VoidCallback? onEdit;
  final VoidCallback? onRetry;
  final ValueChanged<String?>? onFeedback;
  final VoidCallback? onContinue;

  @override
  State<_MessageWithActions> createState() => _MessageWithActionsState();
}

class _MessageWithActionsState extends State<_MessageWithActions> {
  bool _hover = false;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.message.content));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fb = widget.message.feedback;
    final actions = <Widget>[
      _ActionIcon(
        icon: _copied ? Icons.check : Icons.copy_outlined,
        tooltip: _copied ? 'Copied' : 'Copy',
        active: _copied,
        onTap: _copy,
      ),
      if (widget.isUser && widget.onEdit != null)
        _ActionIcon(icon: Icons.edit_outlined, tooltip: 'Edit', onTap: widget.onEdit!),
      if (!widget.isUser && widget.onFeedback != null) ...[
        _ActionIcon(
          icon: fb == 'thumb_up' ? Icons.thumb_up : Icons.thumb_up_outlined,
          tooltip: 'Good response',
          active: fb == 'thumb_up',
          onTap: () => widget.onFeedback!(fb == 'thumb_up' ? null : 'thumb_up'),
        ),
        _ActionIcon(
          icon: fb == 'thumb_down' ? Icons.thumb_down : Icons.thumb_down_outlined,
          tooltip: 'Bad response',
          active: fb == 'thumb_down',
          onTap: () => widget.onFeedback!(fb == 'thumb_down' ? null : 'thumb_down'),
        ),
      ],
      if (widget.onRetry != null)
        _ActionIcon(icon: Icons.refresh, tooltip: 'Retry', onTap: widget.onRetry!),
    ];

    // Reserve the action row's height so the list doesn't jump on hover; fade
    // it in. Hide entirely while this message is still streaming.
    final showActions = !widget.isStreaming;

    return Align(
      alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: Column(
            crossAxisAlignment:
                widget.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.bubble,
              // Persistent "interrupted" bar with Continue / Retry on an
              // assistant turn that was cut short.
              if (!widget.isUser &&
                  widget.message.incomplete &&
                  !widget.isStreaming)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _InterruptedBar(
                    onContinue: widget.onContinue,
                    onRetry: widget.onRetry,
                  ),
                ),
              SizedBox(
                height: 30,
                child: AnimatedOpacity(
                  opacity: showActions && _hover ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !(showActions && _hover),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final a in actions) a,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Persistent bar shown under an assistant turn that was cut short, offering
/// to resume (Continue) or regenerate (Retry).
class _InterruptedBar extends StatelessWidget {
  const _InterruptedBar({this.onContinue, this.onRetry});
  final VoidCallback? onContinue;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('Response interrupted',
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          if (onContinue != null)
            TextButton.icon(
              onPressed: onContinue,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: scheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Continue'),
            ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: scheme.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}


class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}


/// In-place editor for a user message (Claude-style): an autofocused multiline
/// field with Cancel / Send. Esc cancels, Ctrl/Cmd+Enter sends.
class _InlineEditor extends StatefulWidget {
  const _InlineEditor({
    required this.initial,
    required this.initialFiles,
    required this.initialNames,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initial;
  final List<ComposerAttachment> initialFiles;
  /// Attachment file names from a reloaded conversation (the backend keeps
  /// names + RAG vectors, not the original bytes). Any name without a matching
  /// retained file becomes a display-only, removable chip.
  final List<String> initialNames;
  final void Function(String text, List<ComposerAttachment> files) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_InlineEditor> createState() => _InlineEditorState();
}

class _InlineEditorState extends State<_InlineEditor> {
  static const List<String> _kAllowedExtensions = [
    'pdf', 'docx', 'xlsx', 'json', 'md', 'markdown', 'txt', 'csv',
    'png', 'jpg', 'jpeg', 'webp',
  ];

  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  final FocusNode _focus = FocusNode();
  // Retained in-session files (with bytes) first, then any history-loaded
  // names that have no matching retained file → display-only chips. Both are
  // removable; only the uploadable ones get re-sent (the persisted ones are
  // already covered by the conversation's RAG context).
  late final List<ComposerAttachment> _files = [
    ...widget.initialFiles,
    for (final n in widget.initialNames)
      if (!widget.initialFiles.any((f) => f.name == n))
        ComposerAttachment(name: n, sizeBytes: 0, persisted: true),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.selection =
          TextSelection.collapsed(offset: _ctrl.text.length);
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() => widget.onSubmit(_ctrl.text, _files);

  Future<void> _addFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: _kAllowedExtensions,
      );
      if (result == null) return;
      setState(() {
        for (final f in result.files) {
          _files.add(ComposerAttachment(
            name: f.name, sizeBytes: f.size, path: f.path, bytes: f.bytes,
          ));
        }
      });
    } catch (_) {/* picker cancelled / failed — non-fatal */}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 10),
        decoration: BoxDecoration(
          // Neutral, theme-aligned card (not accent-tinted).
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Attached files (removable) + an always-present "Add file" button,
            // so you can add/replace files on any message you edit.
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < _files.length; i++)
                      _EditFileChip(
                        name: _files[i].name,
                        onRemove: () => setState(() => _files.removeAt(i)),
                      ),
                    _AddFileButton(onTap: _addFiles),
                  ],
                ),
              ),
            ),
            // Esc to cancel, Ctrl/Cmd+Enter to send.
            Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
                SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _SubmitIntent(),
                SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _SubmitIntent(),
              },
              child: Actions(
                actions: {
                  _CancelIntent: CallbackAction<_CancelIntent>(
                      onInvoke: (_) => widget.onCancel()),
                  _SubmitIntent: CallbackAction<_SubmitIntent>(
                      onInvoke: (_) => _submit()),
                },
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 10,
                  style: TextStyle(color: scheme.onSurface, fontSize: 15, height: 1.4),
                  decoration: const InputDecoration(
                    // Borderless + no fill so it blends into the card.
                    filled: false,
                    fillColor: Colors.transparent,
                    isCollapsed: true,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Edit your message…',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  ),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// True when an attachment filename looks like a previewable image.
bool _isImageAttachment(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.png') ||
      n.endsWith('.jpg') ||
      n.endsWith('.jpeg') ||
      n.endsWith('.gif') ||
      n.endsWith('.webp') ||
      n.endsWith('.bmp');
}

/// In-session image bytes for [name] (web uploads carry bytes directly).
List<int>? _localImageBytes(Message m, String name) {
  for (final f in m.files) {
    if (f.name == name && f.bytes != null) return f.bytes;
  }
  return null;
}

/// In-session on-disk path for [name] (desktop uploads stream from a path).
String? _localImagePath(Message m, String name) {
  for (final f in m.files) {
    if (f.name == name && f.path != null && f.path!.isNotEmpty) return f.path;
  }
  return null;
}

/// Persisted blob path for [name] (after reload — fetched from the backend).
String? _imageRefPath(Message m, String name) {
  for (final r in m.imageRefs) {
    if ((r['name'] ?? '').toString() == name) {
      final p = (r['path'] ?? '').toString();
      if (p.isNotEmpty) return p;
    }
  }
  return null;
}

/// A clickable thumbnail for an image attachment on a user message. Resolves
/// its bytes from (in priority) in-session bytes, an on-disk path, or the
/// persisted blob endpoint, then opens them in the right-side preview panel.
class _AttachmentThumb extends StatefulWidget {
  const _AttachmentThumb({
    required this.name,
    this.bytes,
    this.localPath,
    this.fetchPath,
  });
  final String name;
  final List<int>? bytes;
  final String? localPath;
  final String? fetchPath;

  @override
  State<_AttachmentThumb> createState() => _AttachmentThumbState();
}

class _AttachmentThumbState extends State<_AttachmentThumb> {
  Uint8List? _data;
  bool _loading = true;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    Uint8List? bytes;
    try {
      if (widget.bytes != null) {
        bytes = Uint8List.fromList(widget.bytes!);
      } else if (widget.localPath != null) {
        bytes = await File(widget.localPath!).readAsBytes();
      } else if (widget.fetchPath != null) {
        final fetched = await ApiService().fetchAttachmentImage(widget.fetchPath!);
        if (fetched != null) bytes = Uint8List.fromList(fetched);
      }
    } catch (_) {
      bytes = null;
    }
    if (!mounted) return;
    setState(() {
      _data = bytes;
      _loading = false;
    });
  }

  void _open() {
    if (_data == null) return;
    context.read<AppState>().openImage(bytes: _data!, name: widget.name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget inner;
    if (_loading) {
      inner = const Center(
        child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (_data != null) {
      inner = Image.memory(_data!, fit: BoxFit.cover);
    } else {
      // Couldn't resolve bytes (e.g. an old turn with no persisted blob) →
      // degrade to a pill so the attachment is still labelled.
      return _FilePill(name: widget.name);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: Tooltip(
          message: 'Open ${widget.name}',
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 132,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _hover
                    ? Colors.white.withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.3),
                width: _hover ? 1.5 : 1,
              ),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                inner,
                if (_hover && _data != null)
                  Container(
                    color: Colors.black.withValues(alpha: 0.28),
                    child: const Center(
                      child: Icon(Icons.open_in_full,
                          size: 22, color: Colors.white),
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

/// A small file chip shown on a user message that carried attachments.
class _FilePill extends StatelessWidget {
  const _FilePill({required this.name});
  final String name;

  IconData get _icon {
    final n = name.toLowerCase();
    if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') ||
        n.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.xlsx') || n.endsWith('.csv')) return Icons.table_chart_outlined;
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}


class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}


class _EditFileChip extends StatelessWidget {
  const _EditFileChip({required this.name, required this.onRemove});
  final String name;
  final VoidCallback onRemove;

  IconData get _icon {
    final n = name.toLowerCase();
    if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') ||
        n.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.xlsx') || n.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurface)),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}


class _AddFileButton extends StatelessWidget {
  const _AddFileButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        foregroundColor: scheme.onSurfaceVariant,
      ),
      icon: const Icon(Icons.attach_file_rounded, size: 14),
      label: const Text('Add file', style: TextStyle(fontSize: 12)),
    );
  }
}

/// Memoizes [_AssistantContent] so a completed message's Markdown is parsed
/// ONCE, not on every list rebuild.
///
/// Markdown parsing (flutter_markdown) is the expensive part of rendering a
/// chat. During streaming the whole list rebuilds ~16×/s; without this, every
/// visible assistant bubble would re-parse its Markdown each frame. We cache
/// the built [_AssistantContent] *widget instance* and return the identical
/// instance when nothing relevant changed — Flutter then short-circuits and
/// skips rebuilding that subtree (`identical(old, new)` early-out). Only the
/// actively-streaming bubble (whose content changes) actually re-parses.
class _MemoAssistantContent extends StatefulWidget {
  const _MemoAssistantContent({
    required this.content,
    required this.isStreaming,
    required this.artifacts,
    required this.stagePhase,
  });

  final String content;
  final bool isStreaming;
  final List<Map<String, dynamic>> artifacts;
  final String? stagePhase;

  @override
  State<_MemoAssistantContent> createState() => _MemoAssistantContentState();
}

class _MemoAssistantContentState extends State<_MemoAssistantContent> {
  Widget? _cached;
  String? _cContent;
  bool? _cStreaming;
  Brightness? _cBrightness;
  String? _cStage;
  int? _cArtifacts;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final stale = _cached == null ||
        _cContent != widget.content ||
        _cStreaming != widget.isStreaming ||
        _cBrightness != brightness ||
        _cStage != widget.stagePhase ||
        _cArtifacts != widget.artifacts.length;
    if (stale) {
      _cached = _AssistantContent(
        content: widget.content,
        isStreaming: widget.isStreaming,
        artifacts: widget.artifacts,
        stagePhase: widget.stagePhase,
      );
      _cContent = widget.content;
      _cStreaming = widget.isStreaming;
      _cBrightness = brightness;
      _cStage = widget.stagePhase;
      _cArtifacts = widget.artifacts.length;
    }
    return _cached!;
  }
}

/// Renders assistant markdown with the custom code-block builder.
class _AssistantContent extends StatelessWidget {
  final String content;
  final bool isStreaming;
  final List<Map<String, dynamic>> artifacts;
  final String? stagePhase;

  const _AssistantContent({
    required this.content,
    required this.isStreaming,
    this.artifacts = const [],
    this.stagePhase,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    // Theme-aware palette.
    final textColor = dark ? AppPalette.darkText : AppPalette.lightText;
    final mutedColor =
        dark ? AppPalette.darkTextMuted : AppPalette.lightTextMuted;
    final headingColor = dark ? Colors.white : AppPalette.lightText;
    final inlineCodeBg = dark
        ? const Color(0xFF11151C)
        : const Color(0xFFEEF0F4);
    final inlineCodeFg =
        dark ? const Color(0xFF06B6D4) : const Color(0xFFB45309);
    final tableBorderColor =
        dark ? AppPalette.darkBorder : AppPalette.lightBorder;

    // While streaming and still empty, show the progressive loader —
    // a single word that mirrors the backend's current stage
    // (Thinking / Searching / Coding / Verifying / …).
    if (content.isEmpty && isStreaming) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ProgressLoader(stage: stagePhase),
      );
    }

    // Append a block cursor while streaming so the user sees live progress.
    final displayText = isStreaming ? '$content▌' : content;

    // selectable:false here on purpose — the surrounding
    // SelectionArea (mounted by chat/solve/resume) owns selection so
    // a drag can span paragraphs, bullets, and code blocks. With
    // selectable:true the MarkdownBody installs its own per-element
    // SelectableText, which limits a drag to a single text node.
    final markdown = MarkdownBody(
      // Strip ```mermaid``` blocks here — they're rendered as actual diagrams
      // below (MermaidBlock), so leaving them in the markdown would show the
      // raw source as a duplicate code block above the diagram.
      data: _stripMermaid(displayText),
      selectable: false,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: textColor, fontSize: 15, height: 1.45),
        h1: TextStyle(
            color: headingColor, fontSize: 20, fontWeight: FontWeight.bold),
        h2: TextStyle(
            color: headingColor, fontSize: 18, fontWeight: FontWeight.bold),
        h3: TextStyle(
            color: headingColor, fontSize: 16, fontWeight: FontWeight.bold),
        listBullet: TextStyle(color: textColor, fontSize: 15),
        strong:
            TextStyle(color: headingColor, fontWeight: FontWeight.bold),
        em: TextStyle(color: textColor, fontStyle: FontStyle.italic),
        // Inline `code` styling. Fenced blocks go through the builder.
        code: TextStyle(
          color: inlineCodeFg,
          fontFamily: 'monospace',
          fontSize: 13,
          backgroundColor: inlineCodeBg,
        ),
        blockquote: TextStyle(color: mutedColor, fontSize: 15),
        a: const TextStyle(color: AppPalette.accent),
        // Tables: bordered, padded cells with a faintly tinted header row so
        // comparisons read cleanly (the model's tables now arrive well-formed
        // thanks to the backend markdown enforcer).
        tableHead: TextStyle(
            color: headingColor, fontWeight: FontWeight.bold, fontSize: 14),
        tableBody: TextStyle(color: textColor, fontSize: 14, height: 1.4),
        tableBorder: TableBorder.all(color: tableBorderColor, width: 1),
        tableHeadAlign: TextAlign.left,
        tableCellsPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        tableCellsDecoration: const BoxDecoration(color: Colors.transparent),
        tableColumnWidth: const IntrinsicColumnWidth(),
        // CRITICAL: suppress flutter_markdown's default code-block wrapper.
        // Without these two overrides, the package paints its own gray
        // container around our custom CodeBlock widget, producing a
        // visible "box-inside-a-box" frame around every code snippet.
        codeblockDecoration: const BoxDecoration(),
        codeblockPadding: EdgeInsets.zero,
      ),
      builders: {
        'code': _CodeBlockBuilder(),
      },
      // Render markdown images (![alt](url)) nicely: rounded corners, a
      // width cap, a loading spinner, and a graceful fallback chip when the
      // image can't load. Handles http(s) and data: URIs.
      sizedImageBuilder: (config) =>
          _MarkdownImage(uri: config.uri, alt: config.alt),
    );

    // Detect ```mermaid``` fenced blocks; if any exist, render them
    // as MermaidBlocks below the markdown (the markdown widget drops
    // them into a code block, but they're more useful as diagrams).
    final mermaid = _extractMermaid(displayText);

    final hasArtifacts = artifacts.isNotEmpty;
    if (!hasArtifacts && mermaid.isEmpty) {
      return markdown;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        markdown,
        for (final m in mermaid)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: MermaidBlock(source: m),
          ),
        if (hasArtifacts) ...[
          const SizedBox(height: 12),
          ArtifactCard(
            artifacts: [
              for (final a in artifacts)
                Artifact(
                  filename: a['filename'] as String? ?? 'snippet',
                  language: a['language'] as String? ?? 'txt',
                  content: a['content'] as String? ?? '',
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Inline "document" card (Claude-style) that opens the preview panel on tap.
class _DocumentChip extends StatelessWidget {
  const _DocumentChip({required this.content, this.format = 'pdf'});
  final String content;
  final String format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stem = _downloadStem(content).replaceAll('_', ' ');
    void open() => context.read<AppState>().openDocument(
          content: content,
          title: stem,
          name: _downloadStem(content),
          format: format,
        );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: open,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.article_outlined,
                    color: theme.colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(stem,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text('Document · click to preview',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Direct download in the generated format — NO dropdown. Tapping
              // downloads; clicking elsewhere on the card opens the preview.
              Material(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => exportAndSave(
                    context,
                    content: content,
                    format: format,
                    suggestedName: _downloadStem(content),
                    title: stem,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download_outlined,
                            size: 16, color: theme.colorScheme.onPrimary),
                        const SizedBox(width: 6),
                        Text('Download ${format.toUpperCase()}',
                            style: TextStyle(
                              color: theme.colorScheme.onPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a markdown image with rounded corners, a width cap, a loading
/// spinner, and a graceful fallback. Supports http(s) network URLs and
/// inline `data:` URIs (base64). Unknown schemes show an alt-text chip.
class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({required this.uri, this.alt});
  final Uri uri;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget image;
    // When we have raw bytes (data: URI), clicking opens the right-side preview.
    Uint8List? previewBytes;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      image = Image.network(
        uri.toString(),
        fit: BoxFit.contain,
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : const SizedBox(
                height: 120,
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))),
        errorBuilder: (ctx, err, st) => _fallback(scheme),
      );
    } else if (uri.scheme == 'data') {
      try {
        final data = UriData.fromUri(uri).contentAsBytes();
        previewBytes = data;
        image = Image.memory(data,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, st) => _fallback(scheme));
      } catch (_) {
        image = _fallback(scheme);
      }
    } else {
      image = _fallback(scheme);
    }
    Widget framed = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: image,
      ),
    );
    if (previewBytes != null) {
      final bytes = previewBytes;
      framed = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => context.read<AppState>().openImage(
                bytes: bytes,
                name: (alt != null && alt!.isNotEmpty) ? alt! : 'Image',
              ),
          child: framed,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: framed,
    );
  }

  Widget _fallback(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              (alt != null && alt!.isNotEmpty) ? alt! : 'image',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pull every ```mermaid```-fenced block out of [text].
List<String> _extractMermaid(String text) {
  final out = <String>[];
  final re = RegExp(r'```mermaid\s*\n(.*?)```', dotAll: true);
  for (final m in re.allMatches(text)) {
    final src = m.group(1)?.trim();
    if (src != null && src.isNotEmpty) out.add(src);
  }
  return out;
}

/// A short, file-safe name guessed from the answer's first heading or line,
/// used as the default filename when downloading a response as a document.
String _downloadStem(String content) {
  for (final raw in content.split('\n')) {
    final line = raw.replaceFirst(RegExp(r'^#{1,6}\s*'), '').trim();
    if (line.isEmpty) continue;
    final words = line.split(RegExp(r'\s+')).take(6).join(' ');
    final safe = words.replaceAll(RegExp(r'[^\w \-]'), '').trim();
    if (safe.isNotEmpty) return safe.replaceAll(' ', '_');
  }
  return 'response';
}

/// Remove completed ```mermaid``` blocks from markdown text so they aren't
/// shown as raw code above the rendered diagram. Incomplete (still-streaming)
/// blocks are left untouched until their closing fence arrives.
String _stripMermaid(String text) {
  final stripped =
      text.replaceAll(RegExp(r'```mermaid\s*\n.*?```', dotAll: true), '');
  // Collapse the blank gap the removal can leave behind.
  return stripped.replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// Tells flutter_markdown to render fenced code blocks via our [CodeBlock].
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(element, preferredStyle) {
    // Only fenced blocks have a language class or live inside a <pre>; inline
    // `code` is short and single-line. We treat multi-line content as a block.
    final text = element.textContent;
    var language = '';
    final className = element.attributes['class'];
    if (className != null && className.startsWith('language-')) {
      language = className.substring('language-'.length);
    }
    // Inline code (no newline, no language) — let the default styling handle it.
    if (language.isEmpty && !text.contains('\n')) {
      return null;
    }
    return CodeBlock(code: text.trimRight(), language: language);
  }
}

/// Small colored chip showing which intent the Sense->Plan step picked.
class _IntentChip extends StatelessWidget {
  final String intent;
  const _IntentChip({required this.intent});

  @override
  Widget build(BuildContext context) {
    final colors = <String, Color>{
      'behavioral': const Color(0xFF34D399),
      'coding': const Color(0xFF06B6D4),
      'concept': const Color(0xFFFBBF24),
      'general': const Color(0xFF9CA3AF),
    };
    final color = colors[intent] ?? const Color(0xFF9CA3AF);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        intent,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
