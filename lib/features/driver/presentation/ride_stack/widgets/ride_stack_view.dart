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
    
    setState(() => _isProcessing = true);
    
    await widget.onAccept(ride);
    
    if (mounted) {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleDecline(RideOffer ride) async {
    if (_isPromoting || _isProcessing) return;
    
    _isPromoting = true;
    
    await _promotionController.forward(from: 0);
    
    if (mounted) {
      _isPromoting = false;
    }
    
    await widget.onDecline(ride);
  }

  @override
  Widget build(BuildContext context) {
    final driverRidesState = ref.watch(driverRidesProvider);
    final visibleOffers = driverRidesState.visibleOffers;

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
        bottom: 16,
        child: RideCard(
          key: ValueKey(ride.id),
          ride: ride,
          stackIndex: index,
          isTop: isTop,
          onAccept: () => _handleAccept(ride),
          onDecline: () => _handleDecline(ride),
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
          bottom: 16 - translateY,
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
