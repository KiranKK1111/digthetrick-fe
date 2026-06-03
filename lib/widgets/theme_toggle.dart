/// Animated theme toggle for the top-right header.
///
/// Cycles through System → Light → Dark with a rotating-icon
/// transition (sun ↔ moon ↔ auto). Long-press opens a popup with
/// the 3 explicit choices so users who don't enjoy the cycle UX
/// can pick directly.
///
/// Wraps [AppState.setThemeMode] — persistence is already handled
/// by AppState via SharedPreferences.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  ThemeMode _next(ThemeMode current) {
    // Cycle: system → light → dark → system
    return switch (current) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
  }

  IconData _iconFor(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };
  }

  String _tooltipFor(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => 'Theme: System (tap to switch to Light)',
      ThemeMode.light => 'Theme: Light (tap to switch to Dark)',
      ThemeMode.dark => 'Theme: Dark (tap to switch to System)',
    };
  }

  Future<void> _pickExplicitly(BuildContext context, ThemeMode current) async {
    final picked = await showMenu<ThemeMode>(
      context: context,
      position: const RelativeRect.fromLTRB(10000, 60, 12, 0),
      items: [
        for (final m in ThemeMode.values)
          PopupMenuItem<ThemeMode>(
            value: m,
            child: Row(
              children: [
                Icon(_iconFor(m), size: 18),
                const SizedBox(width: 10),
                Text(_labelFor(m)),
                if (m == current) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check, size: 16),
                ],
              ],
            ),
          ),
      ],
    );
    if (picked != null && context.mounted) {
      context.read<AppState>().setThemeMode(picked);
    }
  }

  String _labelFor(ThemeMode m) => switch (m) {
        ThemeMode.system => 'System',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<AppState>().themeMode;
    final theme = Theme.of(context);
    final tint = theme.colorScheme.primary;

    return Tooltip(
      message: _tooltipFor(mode),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.read<AppState>().setThemeMode(_next(mode)),
        onLongPress: () => _pickExplicitly(context, mode),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) {
              return RotationTransition(
                turns: Tween<double>(begin: 0.5, end: 1.0).animate(anim),
                child: ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child),
                ),
              );
            },
            child: Icon(
              _iconFor(mode),
              key: ValueKey(mode),
              size: 20,
              color: tint,
            ),
          ),
        ),
      ),
    );
  }
}
