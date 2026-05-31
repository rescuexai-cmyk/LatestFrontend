import 'package:flutter/material.dart';

/// Bottom spacing so overlays and bottom sheets clear system navigation.
///
/// Uses the portion of [MediaQuery.viewPadding] not already consumed by a
/// parent [SafeArea]. When both insets report zero (some edge-to-edge configs),
/// falls back to [minimum] so controls stay above gesture / 3-button nav.
double bottomOverlayInset(BuildContext context, {double minimum = 48.0}) {
  final mq = MediaQuery.of(context);
  final unresolved = mq.viewPadding.bottom - mq.padding.bottom;
  if (unresolved > 0) return unresolved;
  if (mq.viewPadding.bottom == 0 && mq.padding.bottom == 0) {
    return minimum;
  }
  return 0;
}
