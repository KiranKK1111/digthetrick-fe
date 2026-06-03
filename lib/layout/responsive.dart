/// `Responsive` — picks the right child for the current breakpoint.
///
/// Each form factor gets a *designed* layout, not a stretched one. Pass
/// a builder per breakpoint; `Responsive` calls the right one inside a
/// [LayoutBuilder].
library;

import 'package:flutter/widgets.dart';

import '../design/breakpoints.dart';

typedef PaneBuilder = Widget Function(BuildContext context);

class Responsive extends StatelessWidget {
  final PaneBuilder phone;
  final PaneBuilder? tablet;
  final PaneBuilder? laptop;
  final PaneBuilder? desktop;

  const Responsive({
    super.key,
    required this.phone,
    this.tablet,
    this.laptop,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final f = Breakpoints.of(c.maxWidth);
        switch (f) {
          case FormFactor.desktop:
            return (desktop ?? laptop ?? tablet ?? phone)(context);
          case FormFactor.laptop:
            return (laptop ?? tablet ?? phone)(context);
          case FormFactor.tablet:
            return (tablet ?? phone)(context);
          case FormFactor.phone:
            return phone(context);
        }
      },
    );
  }
}
