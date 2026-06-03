/// Root shell — persistent left sidebar + single dynamic top header.
///
/// Layout:
///
///     ┌────────────┬─────────────────────────────────┬─────────────┐
///     │ 🧠 Brand   │ Tab title · subtitle …          │  [👁] [🌙]  │
///     │  + New     ├─────────────────────────────────┴─────────────┤
///     │  💬 Chat   │                                                │
///     │  📡 Live   │   active screen body                           │
///     │  📄 Resume │                                                │
///     │  ⚡ Solve  │                                                │
///     │  ─────     │                                                │
///     │  Recents   │                                                │
///     │   ...      │                                                │
///     │  ─────     │                                                │
///     │  ⚙ Settings│                                                │
///     │       [←]  │                                                │
///     └────────────┴────────────────────────────────────────────────┘
///
/// **Persistent sidebar:** open by default at 264 px; the only way to
/// collapse is the chevron in the sidebar footer. Collapsing keeps a
/// 68 px icon rail; the chevron flips to ► to expand again. No menu
/// icon clutters the header — the sidebar is its own affordance.
///
/// **Single header rule:** child screens MUST NOT mount their own
/// AppBar. They publish:
///   * tab-specific actions     → [AppState.headerActions]
///   * a one-line subtitle      → [AppState.headerSubtitle]
///   * a "Recents" sidebar list → [AppState.sidebarExtras]
///
/// **Right-edge icons:** Stealth + Theme buttons sit flush against
/// the right edge of the window (no trailing padding) so they read
/// as window-level controls.
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import 'modules.dart';
import '../theme/theme.dart' show AppTheme, DesignTokens;
import '../widgets/document_panel.dart';
import '../widgets/mermaid_renderer.dart' show MermaidRenderHost;
import '../widgets/stealth_toggle.dart';
import '../widgets/window_controls.dart';

/// Responsive width for the docked document preview panel.
double _docPanelWidth(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  return (w * 0.46).clamp(360.0, 760.0);
}

/// A thin draggable divider that resizes the document panel. Reports the
/// horizontal drag delta (drag left → panel grows).
class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({required this.onDelta});
  final ValueChanged<double> onDelta;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hover || _drag;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _drag = true),
        onHorizontalDragEnd: (_) => setState(() => _drag = false),
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              decoration: BoxDecoration(
                color: active ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _TabDef {
  const _TabDef({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.requiresStealth,
  });
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool requiresStealth;
}


/// The rail tabs, derived from the module registry ([kPrimaryModules]) so the
/// registry is the single source of truth. Indexes line up with the screens
/// built in [build] from the same registry.
final List<_TabDef> _kTabs = [
  for (final m in kPrimaryModules)
    _TabDef(
      label: m.label,
      icon: m.icon,
      activeIcon: m.activeIcon,
      requiresStealth: m.requiresStealth,
    ),
];


// Sidebar widths. 68 px is wide enough for a 24 px icon with hover
// padding centered inside; 264 px shows the labels + recents list
// titles without truncating.
const double _kSidebarExpandedWidth = 264;
const double _kSidebarCollapsedWidth = 68;
const Duration _kSidebarAnim = Duration(milliseconds: 220);


class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}


/// Secondary surfaces reached from the sidebar footer (Settings, Providers).
/// They render inside the shell — same chrome as the tab screens (persistent
/// sidebar + top bar + window controls) — rather than as a pushed Scaffold,
/// so the window controls stay visible and the frame doesn't change.
enum _Secondary { none, settings, providers }

class _RootShellState extends State<RootShell> {
  int _index = 0;
  // Open by default — user explicitly collapses when they want screen
  // real estate.
  bool _sidebarOpen = true;
  // A footer surface overlaid on the main pane, or `none` for the active tab.
  _Secondary _secondary = _Secondary.none;
  // True while files are dragged anywhere over the window (shows the overlay).
  bool _dragging = false;
  // User-dragged width of the document preview panel (null = responsive default).
  double? _docPanelW;

  /// Files dropped anywhere in the app → switch to Chat and hand them to the
  /// chat composer (registered via [AppState.filesDroppedHandler]).
  void _handleDrop(List<Object> files) {
    setState(() => _dragging = false);
    final chatIdx = kPrimaryModules.indexWhere((m) => m.id == kModuleChat);
    if (chatIdx != -1) _selectTab(chatIdx);
    context.read<AppState>().filesDroppedHandler?.call(files);
  }

  /// The active surface's module id (a tab's id, or the open footer surface).
  String get _activeSurfaceId {
    switch (_secondary) {
      case _Secondary.settings:
        return kModuleSettings;
      case _Secondary.providers:
        return kModuleProviders;
      case _Secondary.none:
        return kPrimaryModules[_index].id;
    }
  }

  /// Single funnel for EVERY navigation. Clears the previous surface's chrome
  /// (so nothing leaks), keeps [activeTab] in sync for legacy readers, and —
  /// crucially — sets [activeSurface] to the new id. Because that value
  /// changes on every transition (incl. opening/closing Settings), the active
  /// screen's listener reliably fires and re-publishes its own chrome.
  void _syncChrome() {
    final state = context.read<AppState>();
    state.setHeaderActions(const []);
    state.setHeaderSubtitle(null);
    state.setSidebarExtras(null);
    state.activeTab.value = _index;
    state.activeSurface.value = _activeSurfaceId;
  }

  void _openSecondary(_Secondary s) {
    // Leaving the Chat surface → close its right-docked preview panel so it
    // doesn't linger over Settings/Providers.
    context.read<AppState>().closeDocument();
    setState(() => _secondary = s);
    _syncChrome();
  }

  void _closeSecondary() {
    setState(() => _secondary = _Secondary.none);
    _syncChrome();
  }

  /// Tabs the user can actually see right now. Hidden tabs are
  /// dropped from the side rail; if the user was on one and
  /// stealth flips off, fall back to Chat.
  List<int> _visibleIndexes(bool stealth) {
    final out = <int>[];
    for (int i = 0; i < _kTabs.length; i++) {
      if (!_kTabs[i].requiresStealth || stealth) out.add(i);
    }
    return out;
  }

  void _selectTab(int i) {
    // No-op only when already on this exact tab with no footer surface open.
    if (_secondary == _Secondary.none && _index == i) return;
    // Switching tabs → close the Chat preview panel (it belongs to Chat).
    context.read<AppState>().closeDocument();
    setState(() {
      _secondary = _Secondary.none;
      _index = i;
    });
    _syncChrome();
  }

  AppTheme _resolveAppTheme(BuildContext context, ThemeMode mode) {
    switch (mode) {
      case ThemeMode.dark:
        return AppTheme.dark;
      case ThemeMode.light:
        return AppTheme.light;
      case ThemeMode.system:
        return MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? AppTheme.dark
            : AppTheme.light;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final visible = _visibleIndexes(state.stealthMode);
    final designTheme = _resolveAppTheme(context, state.themeMode);

    // Stealth "minimized" → render only the small themed box (no OS minimize,
    // no Windows system menu). Tap restores the full window.
    if (state.miniMode) {
      return DesignTokens(
        theme: designTheme,
        palette: DesignTokens.paletteFor(designTheme),
        child: TooltipVisibility(
          visible: false,
          child: _StealthMiniBox(onRestore: state.exitMiniMode),
        ),
      );
    }

    // If the current tab was just hidden by a stealth-off flip,
    // bounce to Chat (always visible).
    if (!visible.contains(_index)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectTab(0);
        }
      });
    }

    final scaffold = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Row(
          children: [
            _Sidebar(
              open: _sidebarOpen,
              activeIndex: _index,
              visibleIndexes: visible,
              secondary: _secondary,
              onSelect: _selectTab,
              onToggle: () =>
                  setState(() => _sidebarOpen = !_sidebarOpen),
              onOpenSettings: () => _openSecondary(_Secondary.settings),
              onOpenProviders: () => _openSecondary(_Secondary.providers),
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    activeIndex: _index,
                    secondary: _secondary,
                    onBack: _closeSecondary,
                  ),
                  if (state.bootError != null)
                    _BootErrorBanner(message: state.bootError!),
                  // Footer surfaces (Settings / Providers) render in the
                  // main pane ON TOP of the tab stack — same chrome, no
                  // pushed route — so the sidebar + window controls stay.
                  //
                  // CRITICAL: the primary IndexedStack is ALWAYS mounted and
                  // Settings/Providers overlay it (rather than replacing it).
                  // This keeps the ChatScreen alive while Settings is open, so
                  // an in-flight streamed response keeps generating in the
                  // background and is still there when the user returns — just
                  // like Claude. (Replacing the stack used to dispose the chat
                  // and kill the stream.) IndexedStack also keeps every tab
                  // mounted so switching tabs preserves the composer draft,
                  // the resume's file, the live socket, etc.
                  Expanded(
                    child: LayoutBuilder(builder: (context, rowC) {
                      // The exact width available to (chat + preview panel).
                      final rowW = rowC.maxWidth.isFinite ? rowC.maxWidth : 0.0;
                      // The chat column must always keep at least this much width
                      // — the preview panel can't shrink it past here (left side
                      // capped, mirroring the right-side cap). On a window too
                      // narrow for both, the chat keeps priority.
                      const kMinChat = 440.0;
                      const kMinPanel = 320.0;
                      // Largest the panel may grow to while leaving the chat its
                      // minimum; also bounded to a sensible share of the row.
                      var panelMax = rowW - kMinChat;
                      final preferredMax = rowW * 0.6;
                      if (panelMax > preferredMax) panelMax = preferredMax;
                      if (panelMax < 0) panelMax = 0;
                      // Lower bound never exceeds the upper bound (no inverted
                      // clamp → no "Invalid argument(s)").
                      final panelMin = panelMax < kMinPanel ? panelMax : kMinPanel;
                      double panelW() => (_docPanelW ?? _docPanelWidth(context))
                          .clamp(panelMin, panelMax);

                      return Row(
                      children: [
                        // Main content — narrows when the document panel opens.
                        Expanded(
                          child: Stack(
                            children: [
                        IndexedStack(
                          index: _index,
                          children: [
                            for (final m in kPrimaryModules) m.build(context),
                          ],
                        ),
                        // Opaque Material so the overlay fully hides the chat
                        // behind it (the body screens are transparent on their
                        // own — they used to inherit the pane background).
                        if (_secondary == _Secondary.settings)
                          Positioned.fill(
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              child: moduleById(kModuleSettings).build(context),
                            ),
                          ),
                        if (_secondary == _Secondary.providers)
                          Positioned.fill(
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              child:
                                  moduleById(kModuleProviders).build(context),
                            ),
                          ),
                            ],
                          ),
                        ),
                        // Right-docked Claude-style document preview panel —
                        // resizable via the drag handle on its left edge, but
                        // never past panelMin/panelMax (chat keeps kMinChat).
                        if (state.isDocumentPanelOpen) ...[
                          _PanelResizeHandle(
                            onDelta: (dx) {
                              final cur = _docPanelW ?? _docPanelWidth(context);
                              setState(() => _docPanelW =
                                  (cur - dx).clamp(panelMin, panelMax));
                            },
                          ),
                          SizedBox(
                            width: panelW(),
                            child: const DocumentPanel(),
                          ),
                        ],
                      ],
                    );
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Stealth mode kills every Tooltip in the tree. Tooltips render
    // as floating overlay surfaces that may not inherit the
    // window's display-affinity flag on every Windows build, so
    // suppressing them entirely is the safe path.
    return DesignTokens(
      theme: designTheme,
      palette: DesignTokens.paletteFor(designTheme),
      child: TooltipVisibility(
        visible: !state.stealthMode,
        // Window-wide file drag-and-drop (Claude/ChatGPT style): drop anywhere
        // → the file lands in the chat composer.
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (detail) => _handleDrop(detail.files),
          child: Stack(
            children: [
              scaffold,
              if (_dragging) const _DropOverlay(),
              // One shared, off-screen webview that renders ALL mermaid
              // diagrams to cached images (so the chat has no live webviews).
              const MermaidRenderHost(),
            ],
          ),
        ),
      ),
    );
  }
}


/// The themed "minimized" pill shown in stealth mode instead of an OS
/// minimize. A gradient DigTheTrick badge + title, draggable to reposition,
/// and a tap (or the restore icon) brings the full window back. Fills the
/// shrunken window exactly, so there's no legacy stub and no system menu.
class _StealthMiniBox extends StatelessWidget {
  const _StealthMiniBox({required this.onRestore});
  final Future<void> Function() onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DragToMoveArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRestore,
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surfaceContainerHighest,
                  scheme.surfaceContainerHigh,
                ],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.45), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [scheme.primary, scheme.tertiary],
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.psychology_alt,
                        color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('DigTheTrick',
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700, height: 1.0)),
                        Text('tap to restore',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontSize: 9,
                                height: 1.1)),
                      ],
                    ),
                  ),
                  Icon(Icons.open_in_full,
                      size: 15, color: scheme.primary.withValues(alpha: 0.9)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Full-window overlay shown while files are dragged over the app — a frosted
/// backdrop with a glowing card. (No text underlines: every label sets
/// `decoration: TextDecoration.none` so nothing inherits a stray underline.)
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Positioned.fill(
      child: IgnorePointer(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            color: scheme.scrim.withValues(alpha: dark ? 0.45 : 0.30),
            alignment: Alignment.center,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 52, vertical: 44),
              decoration: BoxDecoration(
                color: (dark ? scheme.surfaceContainerHigh : scheme.surface)
                    .withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.55), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.25),
                    blurRadius: 48,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 40,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _DropIllustration(),
                  const SizedBox(height: 26),
                  Text(
                    'Add anything',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      height: 1.1,
                      color: scheme.onSurface,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Drop any file here to add it to the conversation',
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      color: scheme.onSurfaceVariant,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// The stacked-cards + upload-tile illustration in the drop overlay.
class _DropIllustration extends StatelessWidget {
  const _DropIllustration();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget ghostCard(double angle, double dx) => Transform.translate(
          offset: Offset(dx, 4),
          child: Transform.rotate(
            angle: angle,
            child: Container(
              width: 56,
              height: 70,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.30)),
              ),
            ),
          ),
        );

    return SizedBox(
      width: 124,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ghostCard(-0.22, -26),
          ghostCard(0.22, 26),
          // Foreground gradient tile with the upload glyph.
          Container(
            width: 66,
            height: 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary,
                  Color.lerp(scheme.primary, scheme.tertiary, 0.7) ??
                      scheme.tertiary,
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.upload_rounded,
                color: Colors.white, size: 34),
          ),
        ],
      ),
    );
  }
}


// ===========================================================================
// Sidebar
// ===========================================================================

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.open,
    required this.activeIndex,
    required this.visibleIndexes,
    required this.secondary,
    required this.onSelect,
    required this.onToggle,
    required this.onOpenSettings,
    required this.onOpenProviders,
  });

  final bool open;
  final int activeIndex;
  final List<int> visibleIndexes;
  final _Secondary secondary;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggle;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenProviders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final scheme = theme.colorScheme;
    final width = open ? _kSidebarExpandedWidth : _kSidebarCollapsedWidth;

    return AnimatedContainer(
      duration: _kSidebarAnim,
      curve: Curves.easeOutCubic,
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: _clipExpandSidebar(
        open,
        Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SidebarBrand(open: open),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Divider(
              height: 16,
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          for (final i in visibleIndexes)
            _RailItem(
              tab: _kTabs[i],
              // A footer surface (Settings/Providers) being open means no
              // tab is the active one — de-highlight the rail.
              selected: secondary == _Secondary.none && i == activeIndex,
              open: open,
              onTap: () => onSelect(i),
            ),
          // Contextual extras (e.g. chat conversation history).
          // Only shown when expanded — collapsed rail is icons-only.
          Expanded(
            child: ClipRect(
              child: open
                  ? ValueListenableBuilder<Widget?>(
                      valueListenable: state.sidebarExtras,
                      builder: (_, extra, __) {
                        if (extra == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: extra,
                        );
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Divider(
              height: 16,
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          _SidebarFooter(
            open: open,
            onToggle: onToggle,
            secondary: secondary,
            onOpenSettings: onOpenSettings,
            onOpenProviders: onOpenProviders,
          ),
          const SizedBox(height: 8),
        ],
        ),
      ),
    );
  }
}


/// During the sidebar's expand animation the open layout (icons + labels) would
/// be squeezed into the still-narrow container, throwing RenderFlex overflow
/// errors. We instead lay the open content out at the FULL expanded width and
/// let the [ClipRect] reveal it as the container grows — no overflow, smooth
/// slide-in. Collapsed content is small enough to never overflow, so it's laid
/// out naturally.
Widget _clipExpandSidebar(bool open, Widget child) {
  return ClipRect(
    child: open
        ? OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: _kSidebarExpandedWidth,
            maxWidth: _kSidebarExpandedWidth,
            child: SizedBox(width: _kSidebarExpandedWidth, child: child),
          )
        : child,
  );
}


class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand({required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final logo = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      // psychology = stylised brain — fits an AI assistant much
      // better than the generic diamond.
      child: const Icon(Icons.psychology_alt, color: Colors.white, size: 20),
    );

    if (!open) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Center(child: logo),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
      child: Row(
        children: [
          logo,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DigTheTrick',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
                Text(
                  'AI',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.tab,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final _TabDef tab;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}


class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = widget.selected
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.78);
    final bg = widget.selected
        ? scheme.primary.withValues(alpha: 0.12)
        : (_hover ? scheme.primary.withValues(alpha: 0.06) : Colors.transparent);
    final icon = widget.selected ? widget.tab.activeIcon : widget.tab.icon;

    // Collapsed rail: icon centered in a 44x44 button. Tooltip on
    // hover reveals the label that the row would otherwise show.
    if (!widget.open) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Tooltip(
            message: widget.tab.label,
            waitDuration: const Duration(milliseconds: 400),
            child: Material(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: widget.onTap,
                child: SizedBox(
                  height: 44,
                  child: Center(child: Icon(icon, size: 22, color: tint)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: tint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: TextStyle(
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: tint,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    Container(
                      width: 4,
                      height: 16,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({
    required this.open,
    required this.onToggle,
    required this.secondary,
    required this.onOpenSettings,
    required this.onOpenProviders,
  });

  final bool open;
  final VoidCallback onToggle;
  final _Secondary secondary;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenProviders;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget footerRow(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool selected = false,
    }) {
      final tint = selected
          ? scheme.primary
          : scheme.onSurface.withValues(alpha: 0.78);
      return Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: tint),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: tint,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (open) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Providers — manage LLM providers, keys, and fallback routing.
            footerRow(Icons.alt_route, 'Providers', onOpenProviders,
                selected: secondary == _Secondary.providers),
            Row(
              children: [
                Expanded(
                  child: footerRow(
                      Icons.settings_outlined, 'Settings', onOpenSettings,
                      selected: secondary == _Secondary.settings),
                ),
                IconButton(
                  tooltip: 'Collapse sidebar',
                  onPressed: onToggle,
                  icon: const Icon(Icons.chevron_left, size: 20),
                  splashRadius: 18,
                ),
              ],
            ),
          ],
        ),
      );
    }
    // Collapsed: stack the controls vertically, centered in the rail width.
    Color tint(bool sel) =>
        sel ? scheme.primary : scheme.onSurface.withValues(alpha: 0.78);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Providers',
          onPressed: onOpenProviders,
          icon: Icon(Icons.alt_route,
              size: 20, color: tint(secondary == _Secondary.providers)),
          splashRadius: 18,
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onOpenSettings,
          icon: Icon(Icons.settings_outlined,
              size: 20, color: tint(secondary == _Secondary.settings)),
          splashRadius: 18,
        ),
        IconButton(
          tooltip: 'Expand sidebar',
          onPressed: onToggle,
          icon: const Icon(Icons.chevron_right, size: 20),
          splashRadius: 18,
        ),
      ],
    );
  }
}


// ===========================================================================
// Single top header — dynamic per active tab
// ===========================================================================

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.activeIndex,
    required this.secondary,
    required this.onBack,
  });

  final int activeIndex;
  final _Secondary secondary;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final tab = _kTabs[activeIndex];

    final supportsDrag = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    // A footer surface (Settings / Providers) replaces the tab title with a
    // back button + that surface's title. Window controls stay either way.
    final isSecondary = secondary != _Secondary.none;
    final secIcon = secondary == _Secondary.providers
        ? Icons.alt_route
        : Icons.settings_outlined;
    final secLabel =
        secondary == _Secondary.providers ? 'Providers' : 'Settings';

    final Widget titleArea = isSecondary
        ? Padding(
            padding: const EdgeInsets.only(left: 4, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, size: 20),
                  splashRadius: 18,
                ),
                Icon(secIcon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  secLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        : ValueListenableBuilder<String?>(
            valueListenable: state.headerSubtitle,
            builder: (_, subtitle, __) {
              return Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tab.activeIcon,
                            size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            tab.label,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Row(
        children: [
          // Dynamic tab title + subtitle. Wrapped in DragToMoveArea
          // on desktop so users can drag the window by the title.
          Expanded(
            child: supportsDrag
                ? DragToMoveArea(child: Align(
                    alignment: Alignment.centerLeft,
                    child: titleArea,
                  ))
                : Align(alignment: Alignment.centerLeft, child: titleArea),
          ),
          // Tab-specific actions sit just left of the global icons,
          // separated by a faint divider so they read as belonging
          // to the tab and not to the window chrome. Hidden while a
          // footer surface (Settings / Providers) is showing.
          if (isSecondary)
            const SizedBox.shrink()
          else
          ValueListenableBuilder<List<Widget>>(
            valueListenable: state.headerActions,
            builder: (_, actions, __) {
              if (actions.isEmpty) return const SizedBox.shrink();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in actions) Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: a,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 22,
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 8),
                ],
              );
            },
          ),
          // Stealth toggle, then window controls. All flush right —
          // no trailing padding so they sit against the window edge.
          // Theme is configured in Settings (no header duplicate).
          const StealthToggleButton(),
          const SizedBox(width: 6),
          const WindowControls(),
        ],
      ),
    );
  }
}


class _BootErrorBanner extends StatelessWidget {
  final String message;
  const _BootErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber,
            color: theme.colorScheme.onErrorContainer,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
