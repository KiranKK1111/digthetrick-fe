/// Claude-style AskUserQuestion panel, docked just above the composer.
///
/// Shows one [ClarifyQuestion] at a time with pagination ("2 of 3"), and
/// adapts to the question [ClarifyKind]:
///   * single — numbered options, pick one (tap advances);
///   * multi  — checkboxes, pick one or more, then submit/next;
///   * rank   — drag the options to order them by priority.
///
/// Every question also offers a "Something else" free-text row and a "Skip".
/// On the last question the arrow submits: the selections across all
/// questions are flattened into a concise message and handed to [onSubmit],
/// which the chat screen sends as the next user turn. The X (or [onDismiss])
/// cancels without answering.
library;

import 'package:flutter/material.dart';

import '../models/models.dart';

class ClarificationPanel extends StatefulWidget {
  const ClarificationPanel({
    super.key,
    required this.questions,
    required this.onSubmit,
    required this.onDismiss,
  });

  final List<ClarifyQuestion> questions;
  final ValueChanged<String> onSubmit;
  final VoidCallback onDismiss;

  @override
  State<ClarificationPanel> createState() => _ClarificationPanelState();
}

class _ClarificationPanelState extends State<ClarificationPanel> {
  int _current = 0;

  late final List<int?> _single; // selected option index per question
  late final List<Set<int>> _multi;
  late final List<List<int>> _rank; // current order of option indices
  late final List<bool> _otherOn;
  late final List<TextEditingController> _otherCtrl;
  late final List<bool> _skipped;

  @override
  void initState() {
    super.initState();
    final n = widget.questions.length;
    _single = List<int?>.filled(n, null);
    _multi = List.generate(n, (_) => <int>{});
    _rank = List.generate(
      n,
      (q) => List<int>.generate(widget.questions[q].options.length, (i) => i),
    );
    _otherOn = List<bool>.filled(n, false);
    _otherCtrl = List.generate(n, (_) => TextEditingController());
    _skipped = List<bool>.filled(n, false);
  }

  @override
  void dispose() {
    for (final c in _otherCtrl) {
      c.dispose();
    }
    super.dispose();
  }

  ClarifyQuestion get _q => widget.questions[_current];
  bool get _isLast => _current == widget.questions.length - 1;

  void _advanceOrSubmit() {
    if (_isLast) {
      _submit();
    } else {
      setState(() => _current++);
    }
  }

  void _skip() {
    setState(() {
      _skipped[_current] = true;
      _single[_current] = null;
      _multi[_current].clear();
      _otherOn[_current] = false;
    });
    _advanceOrSubmit();
  }

  void _pickSingle(int i) {
    setState(() {
      _single[_current] = i;
      _otherOn[_current] = false;
      _skipped[_current] = false;
    });
    _advanceOrSubmit();
  }

  void _toggleMulti(int i) {
    setState(() {
      final s = _multi[_current];
      s.contains(i) ? s.remove(i) : s.add(i);
      _skipped[_current] = false;
    });
  }

  void _toggleOther() {
    setState(() {
      _otherOn[_current] = !_otherOn[_current];
      if (_otherOn[_current]) {
        if (_q.kind == ClarifyKind.single) _single[_current] = null;
        _skipped[_current] = false;
      }
    });
  }

  /// Flatten every answered question into a concise instruction.
  String _buildAnswer() {
    final lines = <String>[];
    for (var q = 0; q < widget.questions.length; q++) {
      if (_skipped[q]) continue;
      final question = widget.questions[q];
      final label = question.header.isNotEmpty ? question.header : 'Choice';
      final other = _otherOn[q] ? _otherCtrl[q].text.trim() : '';
      switch (question.kind) {
        case ClarifyKind.single:
          final val = other.isNotEmpty
              ? other
              : (_single[q] != null ? question.options[_single[q]!].label : '');
          if (val.isNotEmpty) lines.add('$label: $val');
          break;
        case ClarifyKind.multi:
          final vals = <String>[
            for (final i in _multi[q]) question.options[i].label,
            if (other.isNotEmpty) other,
          ];
          if (vals.isNotEmpty) lines.add('$label: ${vals.join(', ')}');
          break;
        case ClarifyKind.rank:
          final ordered = [
            for (var p = 0; p < _rank[q].length; p++)
              '${p + 1}. ${question.options[_rank[q][p]].label}'
          ];
          lines.add('$label by priority: ${ordered.join(', ')}');
          break;
      }
    }
    return lines.isEmpty
        ? 'Please proceed using your best, sensible defaults.'
        : lines.join('\n');
  }

  void _submit() => widget.onSubmit(_buildAnswer());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(scheme),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(child: _body(scheme)),
          ),
          const SizedBox(height: 10),
          _footer(scheme),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final total = widget.questions.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            _q.question,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(width: 10),
        if (total > 1) ...[
          _iconBtn(Icons.chevron_left, scheme,
              enabled: _current > 0,
              onTap: () => setState(() => _current--)),
          Text(
            '${_current + 1} of $total',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
          _iconBtn(Icons.chevron_right, scheme,
              enabled: _current < total - 1,
              onTap: () => setState(() => _current++)),
          const SizedBox(width: 4),
        ],
        _iconBtn(Icons.close, scheme, onTap: widget.onDismiss),
      ],
    );
  }

  Widget _body(ColorScheme scheme) {
    switch (_q.kind) {
      case ClarifyKind.single:
        return _singleBody(scheme);
      case ClarifyKind.multi:
        return _multiBody(scheme);
      case ClarifyKind.rank:
        return _rankBody(scheme);
    }
  }

  Widget _singleBody(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _q.options.length; i++)
          _OptionRow(
            leading: _numberBadge(i + 1, scheme,
                active: _single[_current] == i),
            option: _q.options[i],
            selected: _single[_current] == i,
            onTap: () => _pickSingle(i),
          ),
        _otherRow(scheme, checked: _otherOn[_current]),
      ],
    );
  }

  Widget _multiBody(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _q.options.length; i++)
          _OptionRow(
            leading: Icon(
              _multi[_current].contains(i)
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 20,
              color: _multi[_current].contains(i)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            option: _q.options[i],
            selected: _multi[_current].contains(i),
            onTap: () => _toggleMulti(i),
          ),
        _otherRow(scheme, checked: _otherOn[_current], checkbox: true),
      ],
    );
  }

  Widget _rankBody(ColorScheme scheme) {
    final order = _rank[_current];
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: order.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final item = order.removeAt(oldIndex);
          order.insert(newIndex, item);
          _skipped[_current] = false;
        });
      },
      itemBuilder: (context, pos) {
        final optIdx = order[pos];
        return Padding(
          key: ValueKey('rank-$_current-$optIdx'),
          padding: const EdgeInsets.only(bottom: 8),
          child: _OptionRow(
            leading: _numberBadge(pos + 1, scheme, active: true),
            option: _q.options[optIdx],
            selected: false,
            onTap: null,
            trailing: ReorderableDragStartListener(
              index: pos,
              child: Icon(Icons.drag_indicator,
                  size: 18, color: scheme.onSurfaceVariant),
            ),
          ),
        );
      },
    );
  }

  Widget _otherRow(ColorScheme scheme,
      {required bool checked, bool checkbox = false}) {
    // Resting state: a normal option row.
    if (!checked) {
      return _OptionRow(
        leading: checkbox
            ? Icon(Icons.check_box_outline_blank,
                size: 20, color: scheme.onSurfaceVariant)
            : Icon(Icons.edit_outlined,
                size: 18, color: scheme.onSurfaceVariant),
        option: ClarifyOption(
          label: 'Something else',
          description: 'Type your own — you can list several, comma-separated',
        ),
        selected: false,
        muted: true,
        onTap: _toggleOther,
      );
    }
    // Active: the row itself becomes editable — icon + inline text field on
    // the SAME line (Claude-style), not a separate box below.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggleOther,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              checkbox ? Icons.check_box : Icons.edit,
              size: checkbox ? 20 : 18,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _otherCtrl[_current],
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _advanceOrSubmit(),
              style: TextStyle(color: scheme.onSurface, fontSize: 14.5),
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                hintText: 'e.g. Python, Go, Rust',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(ColorScheme scheme) {
    final hint = switch (_q.kind) {
      ClarifyKind.multi =>
        '${_multi[_current].length} selected',
      ClarifyKind.rank => 'Drag to re-order your priorities',
      ClarifyKind.single => 'Pick one, or skip',
    };
    return Row(
      children: [
        Text(hint,
            style:
                TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
        const Spacer(),
        TextButton(
          onPressed: _skip,
          style: TextButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('Skip'),
        ),
        const SizedBox(width: 8),
        // Always present so a typed "Something else" (or a multi/rank choice)
        // can be confirmed; single-select also advances on tap.
        _SubmitArrow(isLast: _isLast, onTap: _advanceOrSubmit),
      ],
    );
  }

  Widget _numberBadge(int n, ColorScheme scheme, {required bool active}) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.18)
            : scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text('$n',
          style: TextStyle(
              color: active ? scheme.primary : scheme.onSurfaceVariant,
              fontSize: 12.5,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _iconBtn(IconData icon, ColorScheme scheme,
      {bool enabled = true, VoidCallback? onTap}) {
    return IconButton(
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      color: scheme.onSurfaceVariant,
      onPressed: enabled ? onTap : null,
    );
  }
}

class _OptionRow extends StatefulWidget {
  const _OptionRow({
    required this.leading,
    required this.option,
    required this.selected,
    required this.onTap,
    this.trailing,
    this.muted = false,
  });

  final Widget leading;
  final ClarifyOption option;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool muted;

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = widget.selected
        ? scheme.primary.withValues(alpha: 0.10)
        : (_hover
            ? scheme.onSurface.withValues(alpha: 0.05)
            : Colors.transparent);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              widget.leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.option.label,
                      style: TextStyle(
                        color: widget.muted
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.option.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.option.description,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12.5),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubmitArrow extends StatelessWidget {
  const _SubmitArrow({required this.isLast, required this.onTap});

  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            isLast ? Icons.arrow_upward : Icons.arrow_forward,
            size: 18,
            color: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}
