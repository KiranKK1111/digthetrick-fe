/// QuestionCard — renders a detected interview question plus its
/// classifier metadata (type, follow-up flag, topic, confidence).
///
/// Used by the Live Listen screen and the Resume Q&A screen.
library;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'confidence_meter.dart';

class QuestionCard extends StatelessWidget {
  final String question;
  final String? questionType;     // behavioral | technical_concept | coding | ...
  final bool isFollowup;
  final String? topic;
  final double? confidence;       // 0.0–1.0

  const QuestionCard({
    super.key,
    required this.question,
    this.questionType,
    this.isFollowup = false,
    this.topic,
    this.confidence,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final border = dark ? AppPalette.darkBorder : AppPalette.lightBorder;
    final surface = dark ? AppPalette.darkSurface : AppPalette.lightSurface;
    final textColor = dark ? AppPalette.darkText : AppPalette.lightText;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (questionType != null) _TypeChip(label: questionType!),
              if (isFollowup) ...[
                const SizedBox(width: 6),
                const _MetaChip(label: 'follow-up', color: AppPalette.info),
              ],
              if (topic != null && topic!.isNotEmpty) ...[
                const SizedBox(width: 6),
                _MetaChip(label: topic!, color: AppPalette.warning),
              ],
              const Spacer(),
              if (confidence != null)
                ConfidenceMeter(value: confidence!),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            question,
            style: TextStyle(color: textColor, fontSize: 15, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  const _TypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = _colorForType(label);
    return _MetaChip(label: label.replaceAll('_', ' '), color: color);
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'behavioral':
        return AppPalette.success;
      case 'coding':
        return AppPalette.info;
      case 'technical_concept':
        return AppPalette.warning;
      case 'clarification':
        return AppPalette.accent;
      case 'smalltalk':
        return AppPalette.darkTextMuted;
      default:
        return AppPalette.darkTextMuted;
    }
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final Color color;
  const _MetaChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
