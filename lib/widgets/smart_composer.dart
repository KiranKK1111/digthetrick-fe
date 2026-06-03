/// Pill-shaped composer used by the Chat screen.
///
/// Looks like ChatGPT's input bar: rounded "pill" outer container, a
/// leading "+" button that pops a menu (Attach file, Select Mode →
/// TL;DR / Standard / Deeper / Extensive), single-line text field
/// that grows to a few lines, and a send button on the right.
///
/// The popover is built with [showMenu] so it lands directly under the
/// "+" anchor and dismisses on outside taps.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart'
    show ComposerAttachment, kMaxAttachments, kMaxUploadBytes;
import 'composer_keys.dart';
import 'depth_controls.dart' show ResponseDepth;

/// A large block of pasted text collapsed into a chip (Claude-style) instead of
/// flooding the input. Its [text] is folded back into the message on send.
class _PastedBlock {
  _PastedBlock({required this.id, required this.text, required this.lines});
  final int id;
  final String text;
  final int lines;
}


class SmartComposer extends StatefulWidget {
  const SmartComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSend,
    required this.depth,
    required this.onDepthChanged,
    this.isStreaming = false,
    this.onStop,
    this.attachments = const [],
    this.onAttachmentsChanged,
    this.hintText = 'Ask anything…',
    this.disabledHintText,
    this.maxLines = 8,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 12),
    this.outerMaxWidth,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSend;

  /// While true a streamed reply is in flight — the send button becomes a Stop
  /// button that calls [onStop] to cancel generation.
  final bool isStreaming;
  final VoidCallback? onStop;

  final ResponseDepth depth;
  final ValueChanged<ResponseDepth> onDepthChanged;

  /// Currently-attached files. The composer renders them as chips above
  /// the text field; pass an empty list when you don't care.
  final List<ComposerAttachment> attachments;
  final ValueChanged<List<ComposerAttachment>>? onAttachmentsChanged;

  final String hintText;
  final String? disabledHintText;
  final int maxLines;
  final EdgeInsets padding;
  final double? outerMaxWidth;

  @override
  State<SmartComposer> createState() => _SmartComposerState();
}


class _SmartComposerState extends State<SmartComposer> {
  final GlobalKey _plusKey = GlobalKey();
  // The whole composer box — the "+" popup anchors ABOVE this (not above the
  // button, which sits inside the box) so it never overlaps the input.
  final GlobalKey _composerKey = GlobalKey();

  // The input's own scroll controller, so a Scrollbar can show once the text
  // grows past a few lines (Alt/Shift+Enter or a paste).
  final ScrollController _textScroll = ScrollController();

  // Pastes above this many lines collapse into a chip instead of filling the
  // box; the whole message is capped at the line limit (warning shown over it).
  static const int _kPasteCollapseLines = 100;
  static const int _kMaxLines = 50000;

  final List<_PastedBlock> _pastes = [];
  int _pasteSeq = 0;
  int _totalLines = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_recountLines);
    _recountLines();
  }

  int _linesIn(String s) => s.isEmpty ? 0 : '\n'.allMatches(s).length + 1;

  void _recountLines() {
    var n = _linesIn(widget.controller.text);
    for (final p in _pastes) {
      n += p.lines;
    }
    if (n != _totalLines && mounted) setState(() => _totalLines = n);
  }

  bool get _overLineLimit => _totalLines > _kMaxLines;

  /// Insert [s] at the caret (replacing any selection) — used for normal,
  /// small pastes that we don't collapse into a chip.
  void _insertAtCaret(String s) {
    final v = widget.controller.value;
    final sel = v.selection;
    final start = sel.start < 0 ? v.text.length : sel.start;
    final end = sel.end < 0 ? v.text.length : sel.end;
    final newText = v.text.replaceRange(start, end, s);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + s.length),
      composing: TextRange.empty,
    );
  }

  /// Ctrl/Cmd+V: a big paste (>100 lines) collapses into a chip; anything
  /// smaller pastes inline as usual.
  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (_linesIn(text) > _kPasteCollapseLines) {
      setState(() => _pastes.add(_PastedBlock(
            id: _pasteSeq++,
            text: text,
            lines: _linesIn(text),
          )));
      _recountLines();
    } else {
      _insertAtCaret(text);
    }
  }

  void _removePaste(int id) {
    setState(() => _pastes.removeWhere((p) => p.id == id));
    _recountLines();
  }

  /// Fold any pasted blocks back into the message text, then send. Blocked when
  /// over the line cap (the warning banner explains why).
  void _handleSend() {
    if (!widget.enabled) return;
    if (_overLineLimit) return;
    if (_pastes.isNotEmpty) {
      final buf = StringBuffer();
      for (final p in _pastes) {
        buf.write(p.text);
        if (!p.text.endsWith('\n')) buf.write('\n');
        buf.write('\n');
      }
      buf.write(widget.controller.text);
      widget.controller.text = buf.toString();
      setState(() => _pastes.clear());
    }
    widget.onSend();
  }

  // Documents we RAG + images we send to a vision model (see backend
  // app/documents/parser.py + routes_attachments.py).
  static const List<String> _kAllowedExtensions = [
    'pdf', 'docx', 'xlsx', 'json', 'md', 'markdown', 'txt', 'csv',
    'png', 'jpg', 'jpeg', 'webp',
  ];

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: _kAllowedExtensions,
        withData: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux),
      );
      if (result == null || result.files.isEmpty) return;
      final next = [...widget.attachments];
      var dropped = 0;
      var tooLarge = 0;
      for (final f in result.files) {
        if (next.length >= kMaxAttachments) {
          dropped++;
          continue;
        }
        if (f.size > kMaxUploadBytes) {
          tooLarge++;
          continue;
        }
        next.add(ComposerAttachment(
          name: f.name,
          sizeBytes: f.size,
          // Prefer the on-disk path (desktop) so a big file streams from disk
          // instead of sitting in RAM; only keep bytes when there's no path.
          path: f.path,
          bytes: f.path != null ? null : f.bytes,
        ));
      }
      widget.onAttachmentsChanged?.call(next);
      if (mounted && (dropped > 0 || tooLarge > 0)) {
        final msg = tooLarge > 0
            ? 'Each file must be ${kMaxUploadBytes ~/ (1024 * 1024)} MB or '
                'smaller${dropped > 0 ? ' (max $kMaxAttachments files)' : ''}.'
            : 'You can attach up to $kMaxAttachments files.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      // Picker failures are non-fatal — the composer keeps working.
    }
  }

  void _removeAttachment(int index) {
    final next = [...widget.attachments];
    if (index < 0 || index >= next.length) return;
    next.removeAt(index);
    widget.onAttachmentsChanged?.call(next);
  }

  static const double _kMenuWidth = 252;
  OverlayEntry? _menuEntry;

  void _closeMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
  }

  /// Open the "+" menu as a custom overlay anchored so its BOTTOM sits a few
  /// px ABOVE the button (the composer is at the bottom of the window), so it
  /// never overlaps the input box. Dismisses on outside tap.
  void _showPlusMenu() {
    if (_menuEntry != null) {
      _closeMenu();
      return;
    }
    final ctx = _plusKey.currentContext;
    final composerCtx = _composerKey.currentContext;
    if (ctx == null || composerCtx == null) return;
    final overlayState = Overlay.of(ctx);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox;
    final btn = ctx.findRenderObject() as RenderBox;
    final composer = composerCtx.findRenderObject() as RenderBox;
    final btnLeft = btn.localToGlobal(Offset.zero, ancestor: overlayBox).dx;
    final composerTop =
        composer.localToGlobal(Offset.zero, ancestor: overlayBox).dy;
    final overlayH = overlayBox.size.height;
    final overlayW = overlayBox.size.width;
    // Left-align with the "+" button, clamped on-screen.
    final left = btnLeft.clamp(8.0, overlayW - _kMenuWidth - 8.0);
    // Card's bottom edge = composer top - 8px gap; grows upward from there, so
    // it sits cleanly above the whole input box.
    final bottom = overlayH - composerTop + 8;

    _menuEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Tap-away barrier.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeMenu,
            ),
          ),
          Positioned(
            left: left,
            bottom: bottom,
            width: _kMenuWidth,
            child: _PlusMenuCard(
              depth: widget.depth,
              onAttach: () {
                _closeMenu();
                _pickFile();
              },
              onMode: (d) {
                _closeMenu();
                widget.onDepthChanged(d);
              },
            ),
          ),
        ],
      ),
    );
    overlayState.insert(_menuEntry!);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_recountLines);
    _textScroll.dispose();
    _closeMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // ChatGPT-style: a rounded card with the text on its own line and the
    // controls (+ on the left, mode + send on the right) in a row beneath it.
    final box = Container(
      key: _composerKey,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Over the line cap → a warning sits on top of the input.
          if (_overLineLimit)
            _LimitWarning(lines: _totalLines, max: _kMaxLines),
          // Collapsed large pastes (Claude-style chips).
          if (_pastes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _pastes)
                    _PastedChip(
                      block: p,
                      onRemove: () => _removePaste(p.id),
                    ),
                ],
              ),
            ),
          if (widget.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 2),
                    child: Row(
                      children: [
                        Text(
                          '${widget.attachments.length}/$kMaxAttachments attached',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () =>
                              widget.onAttachmentsChanged?.call(const []),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            foregroundColor:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          icon: const Icon(Icons.close_rounded, size: 14),
                          label: const Text('Clear all',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < widget.attachments.length; i++)
                        _AttachmentChip(
                          attachment: widget.attachments[i],
                          onRemove: () => _removeAttachment(i),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          // Row 1: the text field, full width. Enter sends; Alt/Shift+Enter
          // insert a newline (see ComposerKeyboard). A Scrollbar appears once
          // the text grows past `maxLines`; Ctrl/Cmd+V collapses a big paste.
          ComposerKeyboard(
            controller: widget.controller,
            enabled: widget.enabled,
            onSubmit: _handleSend,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                    _handlePaste,
                const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                    _handlePaste,
              },
              child: Scrollbar(
            controller: _textScroll,
            thumbVisibility: true,
            thickness: 5,
            radius: const Radius.circular(8),
            child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            scrollController: _textScroll,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: widget.maxLines,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 15.5,
              height: 1.4,
            ),
            decoration: InputDecoration(
              hintText: widget.enabled
                  ? widget.hintText
                  : (widget.disabledHintText ?? 'Working…'),
              hintStyle: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 15.5,
              ),
              // The app theme fills + borders every TextField; the composer
              // already IS the card, so make this field fully transparent.
              filled: false,
              fillColor: Colors.transparent,
              isCollapsed: true,
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 2),
            ),
          ), // TextField
          ), // Scrollbar
          ), // CallbackShortcuts (paste)
          ), // ComposerKeyboard
          const SizedBox(height: 8),
          // Row 2: + on the left; mode + send on the right.
          Row(
            children: [
              _PlusButton(
                key: _plusKey,
                onTap: widget.enabled ? _showPlusMenu : null,
              ),
              const Spacer(),
              _ModeBadge(depth: widget.depth, onTap: () => _showPlusMenu()),
              const SizedBox(width: 8),
              _SendButton(
                enabled: widget.enabled && !_overLineLimit,
                isStreaming: widget.isStreaming,
                onTap: _handleSend,
                onStop: widget.onStop,
              ),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: widget.padding,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: widget.outerMaxWidth == null
            ? box
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.outerMaxWidth!),
                child: box,
              ),
      ),
    );
  }
}


class _PlusButton extends StatefulWidget {
  const _PlusButton({super.key, required this.onTap});
  final VoidCallback? onTap;

  @override
  State<_PlusButton> createState() => _PlusButtonState();
}


class _PlusButtonState extends State<_PlusButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: enabled
                ? (_hover
                    ? scheme.primary.withValues(alpha: 0.14)
                    : scheme.surface.withValues(alpha: 0.4))
                : scheme.surfaceContainerHigh,
            shape: BoxShape.circle,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(
            Icons.add,
            size: 18,
            color: enabled
                ? scheme.onSurface
                : scheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}


class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.onTap,
    this.isStreaming = false,
    this.onStop,
  });
  final bool enabled;
  final VoidCallback onTap;
  final bool isStreaming;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // While streaming, this is a Stop button — filled accent with a square.
    if (isStreaming) {
      return Material(
        color: scheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onStop,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(Icons.stop_rounded, size: 16, color: scheme.onPrimary),
          ),
        ),
      );
    }
    return Material(
      color: enabled ? scheme.primary : scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.arrow_upward,
            size: 18,
            color: enabled
                ? scheme.onPrimary
                : scheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}


class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.depth, required this.onTap});
  final ResponseDepth depth;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = switch (depth) {
      ResponseDepth.tldr => 'TL;DR',
      ResponseDepth.standard => 'Standard',
      ResponseDepth.deeper => 'Deeper',
      ResponseDepth.exhaustive => 'Extensive',
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Tooltip(
        message: 'Response mode',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune, size: 12, color: scheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// The "+" popup card (rendered in an Overlay above the composer): Attach
/// file + the four response modes.
class _PlusMenuCard extends StatelessWidget {
  const _PlusMenuCard({
    required this.depth,
    required this.onAttach,
    required this.onMode,
  });

  final ResponseDepth depth;
  final VoidCallback onAttach;
  final ValueChanged<ResponseDepth> onMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row(
              scheme,
              icon: Icons.attach_file_rounded,
              label: 'Attach file',
              onTap: onAttach,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Divider(
                  height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 12, 6),
              child: Text(
                'RESPONSE MODE',
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
            _modeRow(scheme, 'TL;DR', ResponseDepth.tldr),
            _modeRow(scheme, 'Standard', ResponseDepth.standard),
            _modeRow(scheme, 'Deeper', ResponseDepth.deeper),
            _modeRow(scheme, 'Extensive', ResponseDepth.exhaustive),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _modeRow(ColorScheme scheme, String label, ResponseDepth d) {
    final selected = depth == d;
    return InkWell(
      onTap: () => onMode(d),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                color: selected ? scheme.primary : scheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// A collapsed large paste, Claude-style: a preview of the first lines + a
/// "PASTED" badge, removable. The full text is restored into the message on send.
class _PastedChip extends StatelessWidget {
  const _PastedChip({required this.block, required this.onRemove});
  final _PastedBlock block;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = block.text.trim();
    return Container(
      width: 168,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  preview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.25,
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close_rounded,
                      size: 14, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text('PASTED',
                    style: TextStyle(
                        fontSize: 9.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
              ),
              const SizedBox(width: 6),
              Text('${block.lines} lines',
                  style: TextStyle(
                      fontSize: 10, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

/// A warning banner shown over the input when the message exceeds the line cap.
class _LimitWarning extends StatelessWidget {
  const _LimitWarning({required this.lines, required this.max});
  final int lines;
  final int max;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String fmt(int n) => n.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Message is too long — ${fmt(lines)} lines (max ${fmt(max)}). '
              'Trim it before sending.',
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final ComposerAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            attachment.displaySize,
            style: TextStyle(
                fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}


