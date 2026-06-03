/// Motion tokens — durations and curves used across the app.
///
/// Architecture.md §7:
///   "All transitions: 200ms ease-out, except micro-interactions at 120ms."
///   "Reduced-motion mode respected throughout — animations replaced with
///   instant transitions."
library;

import 'package:flutter/widgets.dart';

@immutable
class Motion {
  final Duration micro;
  final Duration short;
  final Duration medium;
  final Duration long;
  final Curve standard;
  final Curve emphasized;

  const Motion({
    this.micro = const Duration(milliseconds: 120),
    this.short = const Duration(milliseconds: 200),
    this.medium = const Duration(milliseconds: 320),
    this.long = const Duration(milliseconds: 480),
    this.standard = Curves.easeOut,
    this.emphasized = Curves.easeOutCubic,
  });

  /// Resolve to instant transitions when the user has reduced-motion on.
  Duration resolve(Duration intended, {required bool reducedMotion}) {
    return reducedMotion ? Duration.zero : intended;
  }
}
