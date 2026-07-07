import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/driver_rides_provider.dart';
import 'ride_card.dart';

/// Displays a stack of ride offer cards using the new single-offer architecture.
/// 
/// Uses driverRidesProvider directly instead of a separate queue provider.
/// Shows up to 3 cards: the active offer on top, with pending offers behind.
class RideStackView extends ConsumerStatefulWidget {
  final Future<void> Function(RideOffer ride) onAccept;
  final Future<void> Function(RideOffer ride) onDecline;

  const RideStackView({
    super.key,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  ConsumerState<RideStackView> createState() => _RideStackViewState();
}

class _RideStackViewState extends ConsumerState<RideStackView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _promotionController;
  bool _isPromoting = false;
  bool _isProcessing = false;
  // True only while the accept API call is in flight. Renders a progress card
  // instead of the (swiped-off-screen) RideCard, so the sheet is never blank;
  // if accept fails, the RideCard subtree is recreated with its swipe reset.
  bool _isAcceptingOffer = false;

  @override
  void initState() {
    super.initState();
    _promotionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _promotionController.dispose();
    super.dispose();
  }

  Future<void> _handleAccept(RideOffer ride) async {
    if (_isPromoting || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _isAcceptingOffer = true;
    });

    try {
      await widget.onAccept(ride);
    } finally {
      // On success the overlay unmounts (activeOffer cleared) before this
      // runs; on failure this restores the card stack so the driver sees the
      // offer again instead of a blank sheet.
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isAcceptingOffer = false;
        });
      }
    }
  }

  Future<void> _handleDecline(RideOffer ride) async {
    if (_isPromoting || _isProcessing) return;

    _isProcessing = true;
    try {
      // Run decline immediately (updates activeOffer / queue synchronously inside).
      // Avoiding a promotion animation BEFORE this kept the overlay up with no card painted.
      await widget.onDecline(ride);
    } finally {
      if (mounted) {
        _isProcessing = false;
        _isPromoting = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final driverRidesState = ref.watch(driverRidesProvider);
    final visibleOffers = driverRidesState.visibleOffers;

    if (_isAcceptingOffer) {
      return _buildAcceptingIndicator();
    }

    if (visibleOffers.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              for (int i = visibleOffers.length - 1; i >= 0; i--)
                _buildAnimatedCard(
                  ride: visibleOffers[i],
                  index: i,
                  isTop: i == 0,
                ),
            ],
          ),
        );
      },
    );
  }

  /// Progress card shown while the accept API call is in flight, replacing
  /// the swiped-away RideCard so the sheet never appears blank.
  Widget _buildAcceptingIndicator() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFD0D0D0)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                strokeWidth: 3.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2ECC71)),
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Accepting ride…',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2C3E50),
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Confirming with the rider',
              style: TextStyle(fontSize: 14, color: Color(0xFF7F8C8D)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedCard({
    required RideOffer ride,
    required int index,
    required bool isTop,
  }) {
    if (isTop || !_isPromoting) {
      return Positioned(
        top: 0,
        left: 16,
        right: 16,
        bottom: 20,
        child: RideCard(
          key: ValueKey(ride.id),
          ride: ride,
          stackIndex: index,
          isTop: isTop,
          onAccept: () {
            unawaited(_handleAccept(ride));
          },
          onDecline: () {
            unawaited(_handleDecline(ride));
          },
        ),
      );
    }

    return AnimatedBuilder(
      animation: _promotionController,
      builder: (context, child) {
        final progress = Curves.easeOut.transform(_promotionController.value);
        final targetIndex = index - 1;
        
        final currentScale = 1.0 - (index * 0.05);
        final targetScale = 1.0 - (targetIndex * 0.05);
        final scale = currentScale + (targetScale - currentScale) * progress;
        
        final currentTranslateY = index * 10.0;
        final targetTranslateY = targetIndex * 10.0;
        final translateY = currentTranslateY + (targetTranslateY - currentTranslateY) * progress;

        return Positioned(
          top: translateY,
          left: 16,
          right: 16,
          bottom: 20 - translateY,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
      child: RideCard(
        key: ValueKey(ride.id),
        ride: ride,
        stackIndex: 0,
        isTop: false,
        onAccept: () {},
        onDecline: () {},
      ),
    );
  }
}
