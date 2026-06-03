/// Live transcript with partial / finalized styling.
///
/// Architecture.md §7:
///   "Partial text in muted gray, becomes white when finalized.
///   Speaker labels if diarization on. Question detection animates a
///   card sliding in."
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class TranscriptSegment {
  final String text;
  final bool finalized;
  final String? speaker;
  const TranscriptSegment({
    required this.text,
    this.finalized = false,
    this.speaker,
  });
}

class LiveTranscript extends StatelessWidget {
  final List<TranscriptSegment> segments;
  const LiveTranscript({super.key, required this.segments});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.all(t.space.lg),
      child: RichText(
        text: TextSpan(
          children: segments.map((s) {
            return TextSpan(
              text: '${s.speaker != null ? "${s.speaker}: " : ""}${s.text} ',
              style: TextStyle(
                color: s.finalized ? t.palette.textPrimary : t.palette.textMuted,
                fontSize: t.type.md,
                height: t.type.lineBody,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
