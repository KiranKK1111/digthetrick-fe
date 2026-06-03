/// DigTheTrick AI — app entry point.
///
/// Bootstraps the global [AppState] from a `/api/settings` fetch, then
/// builds a 5-tab shell:
///   1. Live Listen — real-time interview Q&A over WebSocket
///   2. Chat        — generic interview-prep chat
///   3. Resume Q&A  — upload + persona-mode answers (with RAG)
///   4. Solve       — code-problem solver (text or screenshot)
///   5. Settings    — schema-driven settings (theme, model, provider, ...)
///
/// Run:
///   flutter run -d chrome
///   flutter run -d windows
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'layout/root_shell.dart';
import 'screens/mcp_tools_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'state/app_state.dart';
import 'theme/theme.dart';

const String _kBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialise window_manager on desktop so the Solve screen can
  // minimize our own window before screenshotting (so the LeetCode tab
  // underneath ends up in the screenshot, not our UI).
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    // Hide the OS title bar so we can draw our own controls inside
    // the app — this gives us three things at once:
    //   1. consistent chrome between normal + stealth modes (Windows
    //      hides minimize/maximize when stealth toggles to
    //      WS_EX_TOOLWINDOW; our custom controls keep all three);
    //   2. flush-right stealth / theme icons that read as part of
    //      the same window-control row;
    //   3. a draggable title region under our complete control.
    const opts = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(960, 640),
      title: 'DigTheTrick AI',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      // Strip WS_MAXIMIZEBOX so Windows 11 stops offering the Snap
      // Layouts flyout (the split-zone bar that drops down when the
      // window is dragged to the top / its maximize affordance is
      // hovered). We still maximize on demand from our custom window
      // controls via the native `digthetrick/window` channel
      // (ShowWindow(SW_MAXIMIZE)), which works without the maximize box;
      // see lib/widgets/window_controls.dart. No-op on other platforms.
      if (Platform.isWindows) {
        await windowManager.setMaximizable(false);
      }
      // Paint the native window background dark so a resize (e.g. the stealth
      // mini box) never flashes the default WHITE Win32 brush. The app's
      // opaque Scaffold covers this in normal use; it only shows during the
      // brief resize frames and behind the stealth pill.
      try {
        await windowManager.setBackgroundColor(const Color(0xFF0E1013));
      } catch (_) {}
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const DigTheTrickAIApp());
}

class DigTheTrickAIApp extends StatelessWidget {
  const DigTheTrickAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      // Build AppState eagerly with a placeholder config; resolve real
      // config asynchronously in the FutureBuilder below.
      create: (_) => AppState(
        baseUrl: _kBackendBaseUrl,
        config: AppConfig(const {}),
      ),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          return MaterialApp(
            title: 'DigTheTrick AI',
            debugShowCheckedModeBanner: false,
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: state.themeMode,
            home: const _Bootstrap(),
            routes: {
              // Workspace setup screen is retired — storage config
              // moved into Settings. The MCP tools screen is the
              // only auxiliary route the app pushes today.
              '/tools': (_) => McpToolsScreen(baseUrl: state.baseUrl),
            },
          );
        },
      ),
    );
  }
}

/// Loads the live config from /api/settings, then mounts the [RootShell].
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  // Splash gates the first launch — once it signals ready (workspace
  // exists OR user picked "Skip"), we move to the real bootstrap.
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _bootstrap() async {
    final state = context.read<AppState>();
    try {
      final persisted = await AppState.loadPersisted();
      if (persisted.theme != null) state.setThemeMode(persisted.theme!);
      // Apply persisted stealth mode BEFORE we mark the app ready —
      // the user's choice ("hidden") should be in effect by the time
      // the window is actually rendered, so it never flashes visible
      // to a screen-capture tool that's already recording.
      // Errors are swallowed by StealthMode itself.
      // ignore: unawaited_futures
      state.applyStealthFromDisk();
      final cfg = await fetchAppConfig(state.baseUrl);
      state.replaceConfig(cfg);
      state.markReady();

      // Restore the active resume *after* markReady so the UI is already
      // visible while we fetch — the Resume tab then pops into view with
      // the right resume preloaded. Postgres is the source of truth, so
      // chunks + embeddings persisted across restart are reused.
      // ignore: unawaited_futures
      _restoreActiveResume(state, persisted.resumeId);
    } catch (e) {
      state.markBootError(
        'Could not reach backend at ${state.baseUrl}. Is it running? ($e)',
      );
    }
  }

  /// Bring back the previously-active resume.
  ///
  /// Priority:
  ///   1. The resume id SharedPreferences remembers from last session.
  ///   2. The most recent resume the backend reports for this user.
  /// Failures are silent — the Resume tab still shows the upload zone.
  ///
  /// Important: when the remembered id 404s (resume was deleted
  /// server-side), we explicitly clear the persisted id before falling
  /// through. Otherwise every subsequent launch would repeat the
  /// failed lookup forever.
  Future<void> _restoreActiveResume(AppState state, String? rememberedId) async {
    final api = ApiService(baseUrl: state.baseUrl);
    try {
      if (rememberedId != null) {
        try {
          final r = await api.getResume(rememberedId);
          state.setActiveResume(r);
          return;
        } on ApiException {
          // The remembered resume was deleted server-side. Clear the
          // persisted id so we don't try this lookup again on the
          // next launch, then fall through to "most recent".
          state.setActiveResume(null);
        }
      }
      final list = await api.listResumes();
      if (list.isNotEmpty) {
        final r = await api.getResume(list.first.id);
        state.setActiveResume(r);
      }
    } catch (_) {
      // Backend unreachable / no resumes — no-op. The user can still
      // upload from the Resume tab.
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!_splashDone) {
      // Splash → workspace check → set _splashDone = true → start real
      // bootstrap. The same gate flips on the user's "Skip" tap so an
      // offline / first-launch user can still reach the app.
      return SplashScreen(
        baseUrl: state.baseUrl,
        onReady: () {
          if (mounted) {
            setState(() => _splashDone = true);
            _bootstrap();
          }
        },
      );
    }
    if (!state.ready) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading config from backend…'),
              ],
            ),
          ),
        ),
      );
    }
    return const RootShell();
  }
}

// RootShell + the per-tab layout live in [lib/layout/root_shell.dart].
// Splitting them out keeps main.dart focused on bootstrap.
