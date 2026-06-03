/// Stealth mode — hide the window from screen capture, screen share,
/// and the taskbar / Alt-Tab.
///
/// Implementation lives in the **native runner** (Windows C++) and
/// is reached via a method channel. The runner owns our HWND
/// directly, so there's no FFI / FindWindow ambiguity. Two side-
/// effects are applied to that single HWND:
///
///   1. **`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`** —
///      Windows 10 build 19041+. The compositor omits this window
///      from any screen capture API (Zoom, Teams, Meet, OBS,
///      Snipping Tool, Print Screen, Win+Shift+S, browser
///      screen-share). The local user still sees the window on
///      their own monitor.
///
///   2. **Tool-window style swap** (`+WS_EX_TOOLWINDOW −WS_EX_APPWINDOW`)
///      — removes the entry from the taskbar AND the Alt-Tab list.
///      The runner toggles the style bits *without* doing a
///      `ShowWindow(HIDE) → SHOW` cycle (which previously crashed
///      the Flutter engine). Explorer refreshes the taskbar on the
///      next focus / mouse-over event — usually within a second.
///
/// **What this does NOT hide:**
///   * Task Manager — impossible without rootkit-level cloaking,
///     which we explicitly don't do. Any non-elevated app must
///     remain visible to its owner in Task Manager.
///   * Hardware capture cards / external recorders / a phone
///     pointed at the screen — those don't go through the
///     compositor.
///
/// macOS / Linux are no-ops; capture-exclusion needs platform-
/// specific equivalents (`NSWindow.sharingType = .none` etc.).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';


const MethodChannel _kChannel = MethodChannel('digthetrick/stealth');


class StealthResult {
  const StealthResult({
    required this.captureExclusion,
    required this.taskbarHidden,
  });
  final bool captureExclusion;
  final bool taskbarHidden;

  bool get anyEffect => captureExclusion || taskbarHidden;
}


class StealthMode {
  StealthMode._();

  /// True when the platform supports capture-exclusion. macOS / Linux
  /// return false today (the toggle becomes informational there).
  static bool get hasCaptureExclusion {
    if (kIsWeb) return false;
    return Platform.isWindows;
  }

  /// Apply / undo stealth via the native runner. Never throws —
  /// failures are logged and the call returns a result reporting
  /// what (if anything) succeeded.
  static Future<StealthResult> setEnabled(bool enabled) async {
    if (kIsWeb || !Platform.isWindows) {
      return const StealthResult(captureExclusion: false, taskbarHidden: false);
    }
    try {
      final reply = await _kChannel.invokeMethod<Map<Object?, Object?>>(
        'setEnabled',
        enabled,
      );
      if (reply == null) {
        return const StealthResult(captureExclusion: false, taskbarHidden: false);
      }
      return StealthResult(
        captureExclusion: reply['capture'] as bool? ?? false,
        taskbarHidden: reply['taskbar'] as bool? ?? false,
      );
    } on MissingPluginException {
      debugPrint(
        'stealth: native channel not available — the runner may need a clean rebuild',
      );
      return const StealthResult(captureExclusion: false, taskbarHidden: false);
    } catch (e) {
      debugPrint('stealth: setEnabled failed: $e');
      return const StealthResult(captureExclusion: false, taskbarHidden: false);
    }
  }
}
