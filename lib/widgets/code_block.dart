/// Code block widget — Claude-style: one unified dark card with a
/// lightweight header row.
///
///   ┌──────────────────────────────────┐
///   │ java                       □ Copy│
///   ├──────────────────────────────────┤
///   │ public class Foo {               │
///   │     ...                          │
///   │ }                                │
///   └──────────────────────────────────┘
///
/// One surface colour throughout (no "panel-on-panel" division), a thin
/// dimmed rule between the header and code, language label always
/// visible top-left, Copy button always visible top-right (icon + text).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';

// Card colours, tuned to feel like the reference (image 3): a single
// rich dark fill for the whole card, with a faint header separator.
const _kDarkSurface = Color(0xFF1E222A);
const _kDarkBorder = Color(0xFF2A313D);
const _kDarkHeaderRule = Color(0xFF2A313D);
const _kDarkLabel = Color(0xFF8B95A7);
const _kDarkButtonText = Color(0xFFB8C0D0);

const _kLightSurface = Color(0xFFF6F8FA);
const _kLightBorder = Color(0xFFD8DCE3);
const _kLightHeaderRule = Color(0xFFE5E7EB);
const _kLightLabel = Color(0xFF6B7280);
const _kLightButtonText = Color(0xFF374151);

const _kCopiedColor = Color(0xFF34D399);

class CodeBlock extends StatefulWidget {
  final String code;

  /// Language hint from the markdown fence (e.g. ```python). May be empty.
  final String language;

  const CodeBlock({super.key, required this.code, this.language = ''});

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;
  final ScrollController _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? _kDarkSurface : _kLightSurface;
    final border = dark ? _kDarkBorder : _kLightBorder;
    final headerRule = dark ? _kDarkHeaderRule : _kLightHeaderRule;
    final labelColor = dark ? _kDarkLabel : _kLightLabel;
    final buttonText = dark ? _kDarkButtonText : _kLightButtonText;

    // flutter_highlight's themes ship with their own background on the
    // `root` entry. Strip it so the card colour shows through cleanly
    // instead of getting a second darker rectangle behind the code.
    final baseTheme = dark ? atomOneDarkTheme : atomOneLightTheme;
    final transparentTheme = <String, TextStyle>{
      ...baseTheme,
      'root': (baseTheme['root'] ?? const TextStyle())
          .copyWith(backgroundColor: Colors.transparent),
    };

    final lang = widget.language.isEmpty ? 'plaintext' : widget.language;
    final labelText = widget.language.isEmpty ? 'code' : widget.language;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row: language label on the left, Copy button on the right.
          // Same surface colour as the body — only the bottom rule separates
          // them, so the card reads as one unit, not two stacked panels.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: headerRule, width: 1),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  labelText,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    letterSpacing: 0.2,
                  ),
                ),
                _CopyButton(
                  copied: _copied,
                  onTap: _copy,
                  textColor: buttonText,
                ),
              ],
            ),
          ),
          // Code body — horizontally scrollable for long lines, with an
          // always-visible scrollbar so it's obvious content continues to the
          // right (otherwise long log/stacktrace lines just look cut off).
          Scrollbar(
            controller: _hScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
              child: HighlightView(
                widget.code,
                language: lang,
                theme: transparentTheme,
                padding: EdgeInsets.zero,
                textStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback onTap;
  final Color textColor;

  const _CopyButton({
    required this.copied,
    required this.onTap,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = copied ? _kCopiedColor : textColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                copied ? Icons.check : Icons.copy,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                copied ? 'Copied' : 'Copy',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
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
