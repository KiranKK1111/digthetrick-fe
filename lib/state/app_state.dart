/// Global app state — single [ChangeNotifier] held at the root via Provider.
///
/// Holds:
///   - the backend base URL,
///   - the live [AppConfig] (mirror of /api/settings),
///   - the current theme mode + accent,
///   - the currently loaded resume (id + display name + profile),
///   - a persistent session id used by the orchestrator to thread
///     follow-up context across questions on the same tab.
///
/// Screens read fields via `context.watch<AppState>()` and trigger
/// mutations via `context.read<AppState>().setX(...)`.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import '../services/stealth_mode.dart';
import 'tool_stream.dart';

class AppState extends ChangeNotifier {
  AppState({required this.baseUrl, required AppConfig config})
      : _config = config,
        _themeMode = _modeFromString(config.themeDefault);

  /// Where the backend lives. Defaults to local dev; user can change.
  final String baseUrl;

  AppConfig _config;
  AppConfig get config => _config;

  ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;

  ResumeDetail? _activeResume;
  ResumeDetail? get activeResume => _activeResume;

  String? _sessionId;
  String get sessionId =>
      _sessionId ??= 'sess-${DateTime.now().microsecondsSinceEpoch}';

  // ---- Document preview panel (Claude-style right-side artifact panel) ----
  String? _docContent;
  String? _docTitle;
  String? _docName;
  String _docFormat = 'pdf';
  String? get docContent => _docContent;
  String? get docTitle => _docTitle;
  String? get docName => _docName;
  String get docFormat => _docFormat;

  // Image preview — the same right-docked panel, but rendering raw image bytes
  // (clicked from a chat attachment) instead of a paged PDF render.
  Uint8List? _imageBytes;
  String? _imageName;
  // Identifies the widget that opened the current image preview (e.g. a diagram
  // card). Lets that widget collapse itself while it's the one being previewed.
  Object? _imageOwnerId;
  Uint8List? get imageBytes => _imageBytes;
  String? get imageName => _imageName;
  Object? get imageOwnerId => _imageOwnerId;
  bool get isImagePreview => _imageBytes != null;

  bool get isDocumentPanelOpen => _docContent != null || _imageBytes != null;

  /// Open the panel previewing a raw image (e.g. a clicked chat attachment or
  /// an expanded diagram). [ownerId] tags which widget opened it.
  void openImage({required Uint8List bytes, String? name, Object? ownerId}) {
    _imageBytes = bytes;
    _imageName =
        (name == null || name.trim().isEmpty) ? 'Image' : name.trim();
    _imageOwnerId = ownerId;
    // Switch the panel into image mode (clear any document being shown).
    _docContent = null;
    notifyListeners();
  }

  /// True while the cursor is over an interactive in-chat diagram, so the chat
  /// list freezes its own scrolling and the diagram's pan/zoom takes the input.
  final ValueNotifier<bool> chatScrollLocked = ValueNotifier<bool>(false);

  /// Open the document panel previewing [content] (Markdown). [title] is the
  /// shown heading; [name] is the default download filename stem; [format] is
  /// the file format to download (pdf/docx/…).
  void openDocument({
    required String content,
    String? title,
    String? name,
    String format = 'pdf',
  }) {
    _docContent = content;
    _docTitle = (title == null || title.trim().isEmpty) ? 'Document' : title.trim();
    _docName = name;
    _docFormat = format;
    // Switch the panel into document mode (clear any image being shown), so an
    // open diagram/image preview is replaced by the newly opened document.
    _imageBytes = null;
    _imageName = null;
    _imageOwnerId = null;
    notifyListeners();
  }

  void closeDocument() {
    if (_docContent == null && _imageBytes == null) return;
    _docContent = null;
    _docTitle = null;
    _docName = null;
    _imageBytes = null;
    _imageName = null;
    _imageOwnerId = null;
    notifyListeners();
  }

  /// Live tool-chip stream for the current agents turn. Hosted on
  /// [AppState] so the chat screen (which pushes events) and the
  /// workspace shell's context pane (which renders chips) can share it.
  final ToolStream toolStream = ToolStream();

  bool _ready = false;
  bool get ready => _ready;
  String? _bootError;
  String? get bootError => _bootError;

  /// Stealth mode — hides the window from screen-capture / share and
  /// the taskbar. Wired to the top-bar toggle. Persisted across
  /// restarts; applied on startup once [applyStealthFromDisk] runs.
  bool _stealthMode = false;
  bool get stealthMode => _stealthMode;

  /// Stealth "minimize" — instead of an OS minimize (which, with the taskbar
  /// hidden, drops to the ugly legacy minimized-window stub + the Windows
  /// system menu), we shrink the window to a small themed box (icon + title)
  /// floating in a corner. Tapping it restores the window. This keeps the
  /// minimized state fully inside Flutter — no system menu, on-brand chrome.
  bool _miniMode = false;
  bool get miniMode => _miniMode;
  Rect? _restoreBounds;
  bool _wasAlwaysOnTop = false;

  Future<void> enterMiniMode() async {
    if (_miniMode) return;
    try {
      _restoreBounds = await windowManager.getBounds();
      _wasAlwaysOnTop = await windowManager.isAlwaysOnTop();
      // Switch the UI to the mini box BEFORE shrinking, so the full shell is
      // never laid out at the tiny size (which overflowed RenderFlex).
      _miniMode = true;
      notifyListeners();
      await windowManager.setMinimumSize(const Size(170, 44));
      await windowManager.setSize(const Size(240, 54));
      await windowManager.setAlignment(Alignment.bottomRight);
      await windowManager.setAlwaysOnTop(true);
    } catch (e) {
      debugPrint('enterMiniMode failed: $e');
      _miniMode = true;
      notifyListeners();
    }
  }

  Future<void> exitMiniMode() async {
    if (!_miniMode) return;
    try {
      // Grow back to full size FIRST (still showing the mini box), then switch
      // the UI back to the full shell — so the shell never lays out tiny.
      await windowManager.setMinimumSize(const Size(960, 640));
      if (_restoreBounds != null) {
        await windowManager.setBounds(_restoreBounds);
      }
      await windowManager.setAlwaysOnTop(_wasAlwaysOnTop);
      await windowManager.focus();
    } catch (e) {
      debugPrint('exitMiniMode failed: $e');
    }
    _miniMode = false;
    notifyListeners();
  }

  /// Header actions slot — the active screen pushes its tab-specific
  /// buttons (e.g. Live's connect / mic) into here, and the shell
  /// renders them in the top bar between the title and the global
  /// icons. Inactive screens clear it on dispose.
  final ValueNotifier<List<Widget>> headerActions =
      ValueNotifier<List<Widget>>(const []);

  /// Header subtitle slot — the active screen can publish a short
  /// status line that the shell renders under the tab title. Examples:
  /// chat shows "backend ok · gemini · …"; solve shows the active solve
  /// title. Clear by setting to null.
  final ValueNotifier<String?> headerSubtitle =
      ValueNotifier<String?>(null);

  /// Sidebar contextual extras slot — the active screen publishes a
  /// widget (typically a "Recents" list) that the shell renders below
  /// the primary menu in the persistent sidebar. Inactive screens
  /// clear it on dispose so stale lists don't bleed across tabs.
  final ValueNotifier<Widget?> sidebarExtras =
      ValueNotifier<Widget?>(null);

  /// Index of the currently-visible tab. The shell writes this; the
  /// active screen subscribes via ValueListenableBuilder so it can
  /// re-publish its chrome (header actions, subtitle, sidebar) when
  /// the user navigates back to it. Without this signal screens kept
  /// alive inside IndexedStack would never know the user returned.
  final ValueNotifier<int> activeTab = ValueNotifier<int>(0);

  /// Id of the currently-visible surface — a module id from
  /// [lib/layout/modules.dart] (e.g. 'chat', 'solve', 'settings',
  /// 'providers'). The shell writes this on EVERY navigation, including
  /// opening/closing the footer surfaces (Settings/Providers). Screens watch
  /// it (instead of the int [activeTab]) to know when they become active and
  /// re-publish their chrome. Because opening Settings changes it to
  /// 'settings' and the back button changes it back to the tab id, the value
  /// always changes on a transition — so the active screen reliably
  /// re-publishes and stale sidebar/header content can't leak across surfaces.
  final ValueNotifier<String> activeSurface = ValueNotifier<String>('chat');

  /// Set by ChatScreen; the RootShell's window-wide drop target calls this
  /// when files are dropped anywhere in the app, so they land in the chat
  /// composer regardless of which screen is showing. Receives `XFile`s.
  void Function(List<Object> files)? filesDroppedHandler;

  /// Helper for screens: call once after a relevant state change. The
  /// shell rebuilds via ValueListenableBuilder so this is cheap. The
  /// owning screen MUST clear via `setHeaderActions(const [])` in
  /// dispose so a stale set doesn't bleed into the next tab.
  ///
  /// Defensive deferral: if the caller fires this from inside a build
  /// (the typical case is `initState → _refreshHistory → publish`, all
  /// synchronous before the first await), writing the ValueNotifier
  /// would mark our shell's ValueListenableBuilder dirty mid-build,
  /// which is a framework assertion. We detect that phase and post the
  /// write to the next frame instead. Outside build, the write is
  /// immediate so chrome updates feel instant.
  void setHeaderActions(List<Widget> widgets) {
    _safeSet(() => headerActions.value = widgets);
  }

  void setHeaderSubtitle(String? text) {
    _safeSet(() => headerSubtitle.value = text);
  }

  void setSidebarExtras(Widget? widget) {
    _safeSet(() => sidebarExtras.value = widget);
  }

  static void _safeSet(VoidCallback f) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final inBuild = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.transientCallbacks;
    if (inBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) => f());
    } else {
      f();
    }
  }

  void markReady() {
    _ready = true;
    notifyListeners();
  }

  void markBootError(String message) {
    _bootError = message;
    _ready = true;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    _persistTheme();
  }

  /// Toggle stealth mode. Applies + persists. The actual Win32 calls
  /// happen inside [StealthMode.setEnabled]; this method owns the
  /// in-process boolean + persistence.
  ///
  /// All FFI failures are swallowed — the boolean still flips so the
  /// UI reflects the user's intent, even when the underlying platform
  /// can't honour it (very old Windows, no window_manager init, etc).
  Future<void> setStealthMode(bool enabled) async {
    if (_stealthMode == enabled) return;
    _stealthMode = enabled;
    notifyListeners();
    try {
      await StealthMode.setEnabled(enabled);
    } catch (e, st) {
      debugPrint('setStealthMode failed: $e\n$st');
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('stealthMode', enabled);
    } catch (e) {
      debugPrint('stealth persist failed: $e');
    }
  }

  /// On startup, restore the persisted stealth state and apply it.
  ///
  /// Two safety rules learned the hard way:
  ///
  ///   1. If the user never opted in (the default), DO NOTHING. The
  ///      native runner already initialises the window with
  ///      `WDA_NONE` and the taskbar shown, so there's nothing to
  ///      change. Calling `setSkipTaskbar(false)` against an
  ///      already-visible window during early startup was killing
  ///      the engine ("Lost connection to device").
  ///
  ///   2. When the user *did* opt in, defer the actual Win32 calls
  ///      until after the first frame via `addPostFrameCallback`.
  ///      That way the Flutter engine has finished plumbing its
  ///      window-state callbacks before we re-style the window.
  Future<void> applyStealthFromDisk() async {
    final p = await SharedPreferences.getInstance();
    final persisted = p.getBool('stealthMode') ?? false;
    _stealthMode = persisted;
    notifyListeners();
    if (!persisted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await StealthMode.setEnabled(true);
      } catch (_) {
        // Never let a stealth failure take down startup.
      }
    });
  }

  void setActiveResume(ResumeDetail? resume) {
    _activeResume = resume;
    notifyListeners();
    _persistActiveResume();
  }

  /// Refresh after a /api/settings POST.
  void replaceConfig(AppConfig newConfig) {
    _config = newConfig;
    // Theme might have been changed via the settings screen.
    final desired = _modeFromString(newConfig.themeDefault);
    if (desired != _themeMode) {
      _themeMode = desired;
    }
    notifyListeners();
  }

  /// Reset the session — used by "New Conversation" / "Clear context".
  void newSession() {
    _sessionId = 'sess-${DateTime.now().microsecondsSinceEpoch}';
    notifyListeners();
  }

  // ---- Persistence -------------------------------------------------------
  Future<void> _persistTheme() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('themeMode', _themeMode.name);
  }

  Future<void> _persistActiveResume() async {
    final p = await SharedPreferences.getInstance();
    if (_activeResume == null) {
      await p.remove('activeResumeId');
    } else {
      await p.setString('activeResumeId', _activeResume!.id);
    }
  }

  /// Restore theme + resume id from disk. Returns the saved resume id (if any).
  static Future<({ThemeMode? theme, String? resumeId})> loadPersisted() async {
    final p = await SharedPreferences.getInstance();
    ThemeMode? mode;
    final stored = p.getString('themeMode');
    if (stored != null) {
      mode = ThemeMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => ThemeMode.system,
      );
    }
    return (theme: mode, resumeId: p.getString('activeResumeId'));
  }
}

ThemeMode _modeFromString(String s) {
  switch (s) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}
