/// Splash screen — minimal first-paint placeholder.
///
/// Architecture moved storage configuration into Settings (Settings
/// → Database / Vector / Cache / Blob), so the splash no longer
/// gates on a Workspace setup wizard. It just gives the backend a
/// moment to come up and transitions into the main shell.
library;

import 'package:flutter/material.dart';


class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.baseUrl, required this.onReady});

  final String baseUrl;

  /// Called once we're ready to mount the main shell. The caller
  /// swaps this widget out of the tree.
  final VoidCallback onReady;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}


class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _hand_off();
  }

  Future<void> _hand_off() async {
    // Tiny grace period so we don't immediately flash the main
    // shell. Backend first-request latency is usually < 200ms.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted) widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.diamond_outlined,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'DigTheTrick AI',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
