/// Stealth toggle for the top-right header.
///
/// One tap → enable / disable stealth mode (hide from screen-capture
/// + taskbar). The icon morphs between an "open eye" and a
/// "closed eye" with a subtle rotation, plus a fill color shift to
/// the danger-red palette when active so the user immediately notices
/// the window is "invisible" to screen sharing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/stealth_mode.dart';
import '../state/app_state.dart';

class StealthToggleButton extends StatelessWidget {
  const StealthToggleButton({super.key});

  String _tooltip(bool on, bool supported) {
    if (!supported) {
      return 'Stealth mode: screen-capture exclusion is not available on this platform.';
    }
    return on
        ? 'Stealth ON — hidden from screen capture / screen-share. Tap to show.'
        : 'Tap to hide from screen capture / screen-share.';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final on = state.stealthMode;
    final supported = StealthMode.hasCaptureExclusion;

    final activeBg = theme.colorScheme.errorContainer;
    final activeFg = theme.colorScheme.error;
    final idleBg = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.6,
    );
    final idleFg = theme.colorScheme.primary;

    return Tooltip(
      message: _tooltip(on, supported),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final next = !on;
          await context.read<AppState>().setStealthMode(next);
          if (!context.mounted) return;
          // Confirmation snackbar — important UX cue since the
          // change is otherwise invisible. Includes platform caveats.
          final msg = next
              ? supported
                  ? 'Stealth ON — invisible to screen capture / screen-share.'
                  : 'Screen-capture exclusion not supported on this platform.'
              : 'Stealth OFF — visible to screen capture again.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? activeBg : idleBg,
            border: Border.all(
              color: on
                  ? activeFg.withValues(alpha: 0.7)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
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
              on ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              key: ValueKey(on),
              size: 20,
              color: on ? activeFg : idleFg,
            ),
          ),
        ),
      ),
    );
  }
}
