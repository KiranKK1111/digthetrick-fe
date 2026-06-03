/// Depth-on-demand controls — Architecture.md §"Depth control".
///
/// Inline 4-segment toggle: TL;DR / Standard / Deeper / Exhaustive.
/// The current selection is the value the next regeneration should
/// use. Tap a different value to call `onChanged`; the parent screen
/// re-sends the same question with the new depth and replaces the
/// answer in place.
///
/// Per the doc, the toggle lives next to every assistant message so
/// the user can shorten or expand any single answer without changing
/// the global default.
library;

import 'package:flutter/material.dart';

enum ResponseDepth { tldr, standard, deeper, exhaustive }

extension ResponseDepthLabel on ResponseDepth {
  String get apiValue => switch (this) {
        ResponseDepth.tldr => 'tldr',
        ResponseDepth.standard => 'standard',
        ResponseDepth.deeper => 'deeper',
        ResponseDepth.exhaustive => 'exhaustive',
      };

  String get label => switch (this) {
        ResponseDepth.tldr => 'TL;DR',
        ResponseDepth.standard => 'Standard',
        ResponseDepth.deeper => 'Deeper',
        ResponseDepth.exhaustive => 'Exhaustive',
      };
}

class DepthControls extends StatelessWidget {
  const DepthControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final ResponseDepth value;
  final ValueChanged<ResponseDepth> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ResponseDepth>(
      style: ButtonStyle(
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
        padding: WidgetStateProperty.all(
          EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 2 : 6),
        ),
        textStyle: WidgetStateProperty.all(
          TextStyle(fontSize: compact ? 11 : 13, fontWeight: FontWeight.w500),
        ),
      ),
      segments: const [
        ButtonSegment(value: ResponseDepth.tldr, label: Text('TL;DR')),
        ButtonSegment(value: ResponseDepth.standard, label: Text('Standard')),
        ButtonSegment(value: ResponseDepth.deeper, label: Text('Deeper')),
        ButtonSegment(value: ResponseDepth.exhaustive, label: Text('Exhaustive')),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (s) {
        if (s.isNotEmpty) onChanged(s.first);
      },
    );
  }
}
