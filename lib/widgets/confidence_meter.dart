/// ConfidenceMeter — a tiny horizontal bar showing classifier confidence.
///
/// Used on question cards in Live Listen / Resume Q&A so the user can see
/// at a glance whether the classifier was sure of itself.
library;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class ConfidenceMeter extends StatelessWidget {
  final double value;  // 0.0–1.0
  final double width;
  final double height;

  const ConfidenceMeter({
    super.key,
    required this.value,
    this.width = 60,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    final color = _colorForConfidence(v);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: AppPalette.darkBorder.withOpacity(0.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: width * v,
              height: height,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${(v * 100).round()}%',
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Color _colorForConfidence(double v) {
    if (v < 0.5) return AppPalette.error;
    if (v < 0.75) return AppPalette.warning;
    return AppPalette.success;
  }
}
