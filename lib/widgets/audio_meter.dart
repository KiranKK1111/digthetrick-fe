/// Audio waveform meter — real PCM, not faked.
///
/// Architecture.md §7:
///   "Audio meter (live mode): real waveform from PCM, not fake."
///
/// Accepts a stream of recent RMS levels (0..1) and draws a 1D bar
/// scope. Caller pushes new levels at the audio chunk cadence; the
/// painter clips the window so older values scroll off naturally.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

class AudioMeter extends StatelessWidget {
  /// Recent RMS levels, oldest first. Values in [0, 1].
  final List<double> levels;
  final double height;

  const AudioMeter({
    super.key,
    required this.levels,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _MeterPainter(levels: levels, fg: t.palette.accent, bg: t.palette.elevated),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final List<double> levels;
  final Color fg;
  final Color bg;
  _MeterPainter({required this.levels, required this.fg, required this.bg});

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = bg;
    canvas.drawRect(Offset.zero & size, bgPaint);
    if (levels.isEmpty) return;
    final barWidth = size.width / levels.length;
    final paint = Paint()..color = fg;
    for (int i = 0; i < levels.length; i++) {
      final v = levels[i].clamp(0.0, 1.0);
      final h = (size.height - 4) * v;
      final x = i * barWidth;
      final rect = Rect.fromLTWH(x, (size.height - h) / 2, barWidth - 1, h);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(1.5)), paint);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.levels != levels;
}
