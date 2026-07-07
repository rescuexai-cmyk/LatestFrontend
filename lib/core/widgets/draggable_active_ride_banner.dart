import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ride/providers/ride_booking_provider.dart';
import 'active_ride_banner.dart';

/// Overlay wrapper that keeps [ActiveRideBanner] at the bottom by default,
/// but lets the user drag it anywhere on screen so it does not block controls.
class DraggableActiveRideBanner extends ConsumerStatefulWidget {
  const DraggableActiveRideBanner({super.key, this.wrapSafeArea = false});

  /// When true, applies [SafeArea] insets when clamping and positioning
  /// (used on the home selection screen).
  final bool wrapSafeArea;

  static const double _horizontalInset = 16;
  static const double _bottomInset = 16;
  static const double _tapSlop = 10;
  static const double _fallbackBannerHeight = 72;

  @override
  ConsumerState<DraggableActiveRideBanner> createState() =>
      _DraggableActiveRideBannerState();
}

class _DraggableActiveRideBannerState
    extends ConsumerState<DraggableActiveRideBanner> {
  final GlobalKey _bannerKey = GlobalKey();
  Offset? _offset;
  String? _offsetRideId;
  double _panAccumulated = 0;
  double _bannerHeight = DraggableActiveRideBanner._fallbackBannerHeight;
  bool _captureScheduled = false;

  void _scheduleCaptureBannerHeight() {
    if (_captureScheduled) return;
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      _captureBannerHeight();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!activeRideBannerShouldShow(context, ref)) {
      return const SizedBox.shrink();
    }

    final rideId = ref.watch(rideBookingProvider.select((b) => b.rideId));
    if (rideId != _offsetRideId) {
      _offsetRideId = rideId;
      _offset = null;
    }

    _scheduleCaptureBannerHeight();

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (stackSize.width <= 0 || stackSize.height <= 0) {
          return const SizedBox.shrink();
        }

        final safe = widget.wrapSafeArea
            ? MediaQuery.paddingOf(context)
            : EdgeInsets.zero;
        final bannerSize = _bannerSize(stackSize, safe);
        final position =
            _offset ?? _defaultOffset(stackSize, safe, bannerSize);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              width: bannerSize.width,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  _panAccumulated = 0;
                  _captureBannerHeight();
                },
                onPanUpdate: (details) {
                  _panAccumulated += details.delta.distance;
                  final current = _offset ??
                      _defaultOffset(stackSize, safe, bannerSize);
                  final next = current + details.delta;
                  setState(() {
                    _offset = _clampOffset(next, stackSize, safe, bannerSize);
                  });
                },
                onPanEnd: (_) {
                  if (_panAccumulated < DraggableActiveRideBanner._tapSlop) {
                    activeRideBannerHandleTap(context, ref);
                  }
                  _panAccumulated = 0;
                },
                child: ActiveRideBanner(
                  key: _bannerKey,
                  handleOwnTap: false,
                  omitSideMargin: true,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _captureBannerHeight() {
    if (!mounted) return;
    final measured = _bannerKey.currentContext?.size;
    if (measured == null || measured.height <= 0) return;
    if ((measured.height - _bannerHeight).abs() > 0.5) {
      setState(() => _bannerHeight = measured.height);
    }
  }

  Size _bannerSize(Size stackSize, EdgeInsets safe) {
    final width = stackSize.width -
        (DraggableActiveRideBanner._horizontalInset * 2) -
        safe.left -
        safe.right;
    return Size(width, _bannerHeight);
  }

  Offset _defaultOffset(Size stackSize, EdgeInsets safe, Size bannerSize) {
    return Offset(
      DraggableActiveRideBanner._horizontalInset + safe.left,
      stackSize.height -
          safe.bottom -
          bannerSize.height -
          DraggableActiveRideBanner._bottomInset,
    );
  }

  Offset _clampOffset(
    Offset offset,
    Size stackSize,
    EdgeInsets safe,
    Size bannerSize,
  ) {
    final minX = DraggableActiveRideBanner._horizontalInset + safe.left;
    final maxX = stackSize.width -
        bannerSize.width -
        DraggableActiveRideBanner._horizontalInset -
        safe.right;
    final minY = safe.top + DraggableActiveRideBanner._horizontalInset;
    final maxY = stackSize.height -
        bannerSize.height -
        safe.bottom -
        DraggableActiveRideBanner._bottomInset;

    return Offset(
      offset.dx.clamp(minX, maxX),
      offset.dy.clamp(minY, maxY),
    );
  }
}
