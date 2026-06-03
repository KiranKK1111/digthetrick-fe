/// Custom window controls — minimize, maximize/restore, close.
///
/// The native OS title bar is hidden in [main.dart] so we can draw
/// our own controls. This gives the app:
///   * a consistent chrome between **normal** and **stealth** modes
///     (Windows hides minimize/maximize when stealth flips on the
///     tool-window style; our buttons keep all three available);
///   * flush-right window controls that match the app's accent
///     palette and hover states;
///   * a draggable title region we own (see [DragToMoveArea] use
///     inside the top bar).
///
/// Non-Windows desktop targets work via the same window_manager API.
/// Web / mobile builds return an empty widget.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';

/// Native maximize channel (see `windows/runner/flutter_window.cpp`).
///
/// We strip `WS_MAXIMIZEBOX` in [main] to disable the Windows 11 Snap
/// Layouts flyout. That makes `windowManager.maximize()` (which posts
/// `SC_MAXIMIZE`) a no-op, so on Windows we maximize through this
/// channel's `ShowWindow(SW_MAXIMIZE)` instead. window_manager still
/// reports the state correctly and fires its maximize/unmaximize
/// events from the resulting `WM_SIZE`, so the listener below stays in
/// sync either way.
const MethodChannel _kWindowChannel = MethodChannel('digthetrick/window');


class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}


class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _maximized = false;

  bool get _supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    if (_supported) {
      windowManager.addListener(this);
      _syncMaximized();
    }
  }

  @override
  void dispose() {
    if (_supported) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    if (!_supported) return;
    final m = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = m);
  }

  @override
  void onWindowMaximize() => _syncMaximized();
  @override
  void onWindowUnmaximize() => _syncMaximized();
  @override
  void onWindowResize() => _syncMaximized();

  /// Maximize/restore.
  ///
  /// On Windows we go through the native [_kWindowChannel] (ShowWindow):
  /// `WS_MAXIMIZEBOX` is stripped to kill the Snap Layouts flyout, which
  /// makes window_manager's `SC_MAXIMIZE` path a no-op. ShowWindow still
  /// works, and window_manager's `title_bar_style == "hidden"`
  /// WM_NCCALCSIZE handler clamps the maximized frame to the monitor work
  /// area, so it fills the screen exactly without gaps or covering the
  /// taskbar. macOS/Linux keep the plain window_manager path.
  Future<void> _toggleMaximize() async {
    if (!_supported) return;
    final isMax = await windowManager.isMaximized();
    if (Platform.isWindows) {
      await _kWindowChannel.invokeMethod(isMax ? 'unmaximize' : 'maximize');
    } else if (isMax) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CtlButton(
          icon: Icons.remove,
          tooltip: 'Minimize',
          onTap: () {
            // In stealth mode the taskbar is hidden, so an OS minimize lands
            // on the legacy minimized-window stub + system menu. Shrink to our
            // own themed box instead.
            final app = context.read<AppState>();
            if (app.stealthMode) {
              app.enterMiniMode();
            } else {
              windowManager.minimize();
            }
          },
        ),
        _CtlButton(
          icon: _maximized ? Icons.filter_none : Icons.crop_square,
          tooltip: _maximized ? 'Restore' : 'Maximize',
          iconSize: _maximized ? 12 : 14,
          onTap: _toggleMaximize,
        ),
        _CtlButton(
          icon: Icons.close,
          tooltip: 'Close',
          // Windows convention: close goes red-on-hover with white
          // icon. We tint the hover background to match the app's
          // error scheme so the warning reads even in light mode.
          hoverBg: const Color(0xFFE81123),
          hoverFg: Colors.white,
          onTap: () => windowManager.close(),
          edge: _ButtonEdge.last,
          rightPadding: true,
          extraScheme: scheme,
        ),
      ],
    );
  }
}


enum _ButtonEdge { none, last }


class _CtlButton extends StatefulWidget {
  const _CtlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 14,
    this.hoverBg,
    this.hoverFg,
    this.edge = _ButtonEdge.none,
    this.rightPadding = false,
    this.extraScheme,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;
  final Color? hoverBg;
  final Color? hoverFg;
  final _ButtonEdge edge;
  final bool rightPadding;
  final ColorScheme? extraScheme;

  @override
  State<_CtlButton> createState() => _CtlButtonState();
}


class _CtlButtonState extends State<_CtlButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final defaultHover = scheme.onSurface.withValues(alpha: 0.08);
    final bg = _hover
        ? (widget.hoverBg ?? defaultHover)
        : Colors.transparent;
    final fg = _hover && widget.hoverFg != null
        ? widget.hoverFg!
        : scheme.onSurface.withValues(alpha: 0.78);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: 36,
            decoration: BoxDecoration(color: bg),
            child: Center(
              child: Icon(widget.icon, size: widget.iconSize, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
