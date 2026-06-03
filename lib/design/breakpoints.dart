/// Layout breakpoints — drive the responsive shell, not media-query CSS.
///
/// Architecture.md §7 calls for distinct layouts at each width band, not
/// stretching one design.
library;

import 'package:flutter/widgets.dart';

enum FormFactor { phone, tablet, laptop, desktop }

class Breakpoints {
  static const double phoneMax = 600;
  static const double tabletMax = 900;
  static const double laptopMax = 1400;

  static FormFactor of(double width) {
    if (width < phoneMax) return FormFactor.phone;
    if (width < tabletMax) return FormFactor.tablet;
    if (width < laptopMax) return FormFactor.laptop;
    return FormFactor.desktop;
  }

  /// Convenience: form factor from the surrounding context.
  static FormFactor from(BuildContext context) =>
      of(MediaQuery.of(context).size.width);

  /// Number of visible panes per form factor (nav + main + context).
  static int paneCount(FormFactor f) {
    switch (f) {
      case FormFactor.phone:
        return 1;
      case FormFactor.tablet:
        return 2;
      case FormFactor.laptop:
      case FormFactor.desktop:
        return 3;
    }
  }
}
