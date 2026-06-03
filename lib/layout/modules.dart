/// Module registry — the single source of truth for every surface the shell
/// can show. The [RootShell] derives the sidebar rail (primary modules), the
/// IndexedStack of screens, and the footer (secondary modules) entirely from
/// [kModules], so adding/removing a surface is one list entry.
///
/// Each module owns its own chrome (sidebar list, header actions, subtitle):
/// it watches [AppState.activeSurface] and re-publishes when its [id] becomes
/// active. The shell clears chrome on every transition, so a module that
/// publishes nothing (Resume) simply shows an empty sidebar — no stale content
/// from another module can leak in.
library;

import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../screens/live_listen.dart';
import '../screens/providers.dart';
import '../screens/settings.dart';
import '../screens/solve.dart';

/// One navigable surface (a tab or a footer screen).
class ModuleDef {
  const ModuleDef({
    required this.id,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.build,
    this.requiresStealth = false,
    this.isSecondary = false,
  });

  /// Stable id, also used as [AppState.activeSurface] value and the screen's
  /// `_moduleId` self-check.
  final String id;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Hidden from the rail unless stealth mode is on (capture-sensitive tools).
  final bool requiresStealth;

  /// Secondary surfaces (Settings, Providers) live in the sidebar footer and
  /// render over the tab stack with a back button — not in the rail.
  final bool isSecondary;

  /// Builds the screen widget.
  final WidgetBuilder build;
}

// Module ids — referenced by screens for their activeSurface self-check.
const String kModuleChat = 'chat';
const String kModuleLive = 'live';
const String kModuleResume = 'resume';
const String kModuleSolve = 'solve';
const String kModuleProviders = 'providers';
const String kModuleSettings = 'settings';

/// The full registry. Order defines rail order (primary) and footer order
/// (secondary).
final List<ModuleDef> kModules = [
  ModuleDef(
    id: kModuleChat,
    label: 'Chat',
    icon: Icons.chat_bubble_outline,
    activeIcon: Icons.chat_bubble,
    build: (_) => const ChatScreen(),
  ),
  ModuleDef(
    id: kModuleLive,
    label: 'Live',
    icon: Icons.podcasts_outlined,
    activeIcon: Icons.podcasts,
    requiresStealth: true,
    build: (_) => const LiveListenScreen(),
  ),
  // Resume module removed — resume upload now lives inside the Live module.
  ModuleDef(
    id: kModuleSolve,
    label: 'Solve',
    icon: Icons.bolt_outlined,
    activeIcon: Icons.bolt,
    requiresStealth: true,
    build: (_) => const SolveScreen(),
  ),
  ModuleDef(
    id: kModuleProviders,
    label: 'Providers',
    icon: Icons.alt_route,
    activeIcon: Icons.alt_route,
    isSecondary: true,
    build: (_) => const ProvidersScreen(),
  ),
  ModuleDef(
    id: kModuleSettings,
    label: 'Settings',
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    isSecondary: true,
    build: (_) => const SettingsScreen(),
  ),
];

/// Primary modules (rail tabs), in order.
final List<ModuleDef> kPrimaryModules =
    kModules.where((m) => !m.isSecondary).toList(growable: false);

/// Secondary modules (footer surfaces), in order.
final List<ModuleDef> kSecondaryModules =
    kModules.where((m) => m.isSecondary).toList(growable: false);

ModuleDef moduleById(String id) => kModules.firstWhere((m) => m.id == id);
