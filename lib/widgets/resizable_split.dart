/// Two-child resizable split (horizontal OR vertical).
///
/// VS Code's workbench is built out of nested splits — sidebar |
/// editor | aux bar, plus editor / panel vertically. This widget is
/// the primitive that backs them all: it lays out two children with
/// a dragger between, persists nothing (the caller owns the size and
/// can persist it to SharedPreferences if it wants), and clamps the
/// drag inside sensible min / max bounds.
///
/// The dragger itself is a 6-px hit-area but only paints a 1-px line.
/// Wider hit-area, narrower visual — matches the VS Code feel: easy
/// to grab without taking up real estate.
library;

import 'package:flutter/material.dart';


enum SplitAxis { horizontal, vertical }


class ResizableSplit extends StatefulWidget {
  const ResizableSplit({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.initialFirstSize,
    required this.onSizeChanged,
    this.minFirst = 120,
    this.minSecond = 120,
  });

  /// `horizontal` puts the two children side-by-side and drags
  /// left/right; `vertical` stacks them and drags up/down.
  final SplitAxis axis;
  final Widget first;
  final Widget second;
  final double initialFirstSize;
  final ValueChanged<double> onSizeChanged;
  final double minFirst;
  final double minSecond;

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}


class _ResizableSplitState extends State<ResizableSplit> {
  late double _firstSize = widget.initialFirstSize;

  @override
  void didUpdateWidget(ResizableSplit old) {
    super.didUpdateWidget(old);
    if (old.initialFirstSize != widget.initialFirstSize) {
      _firstSize = widget.initialFirstSize;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final total = widget.axis == SplitAxis.horizontal ? c.maxWidth : c.maxHeight;
      final maxFirst = (total - widget.minSecond).clamp(widget.minFirst, total);
      final clamped = _firstSize.clamp(widget.minFirst, maxFirst);

      if (widget.axis == SplitAxis.horizontal) {
        return Row(
          children: [
            SizedBox(width: clamped, child: widget.first),
            _Dragger(
              axis: widget.axis,
              onDelta: (delta) => _resize(delta, maxFirst),
            ),
            Expanded(child: widget.second),
          ],
        );
      }
      return Column(
        children: [
          SizedBox(height: clamped, child: widget.first),
          _Dragger(
            axis: widget.axis,
            onDelta: (delta) => _resize(delta, maxFirst),
          ),
          Expanded(child: widget.second),
        ],
      );
    });
  }

  void _resize(double delta, double maxFirst) {
    setState(() {
      _firstSize =
          (_firstSize + delta).clamp(widget.minFirst, maxFirst);
    });
    widget.onSizeChanged(_firstSize);
  }
}


class _Dragger extends StatefulWidget {
  const _Dragger({required this.axis, required this.onDelta});
  final SplitAxis axis;
  final ValueChanged<double> onDelta;

  @override
  State<_Dragger> createState() => _DraggerState();
}


class _DraggerState extends State<_Dragger> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isH = widget.axis == SplitAxis.horizontal;
    final showHighlight = _hover || _drag;

    final hitArea = SizedBox(
      width: isH ? 6 : null,
      height: isH ? null : 6,
      child: Container(
        color: Colors.transparent,
        child: Center(
          child: Container(
            width: isH ? 1 : double.infinity,
            height: isH ? double.infinity : 1,
            color: showHighlight
                ? scheme.primary.withValues(alpha: 0.6)
                : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
    );

    return MouseRegion(
      cursor: isH
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart:
            isH ? (_) => setState(() => _drag = true) : null,
        onHorizontalDragEnd:
            isH ? (_) => setState(() => _drag = false) : null,
        onHorizontalDragUpdate:
            isH ? (d) => widget.onDelta(d.delta.dx) : null,
        onVerticalDragStart:
            isH ? null : (_) => setState(() => _drag = true),
        onVerticalDragEnd:
            isH ? null : (_) => setState(() => _drag = false),
        onVerticalDragUpdate:
            isH ? null : (d) => widget.onDelta(d.delta.dy),
        child: hitArea,
      ),
    );
  }
}
