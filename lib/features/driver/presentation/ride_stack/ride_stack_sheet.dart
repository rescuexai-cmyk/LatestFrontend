import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/driver_rides_provider.dart';
import 'widgets/ride_stack_view.dart';

/// Bottom sheet for displaying ride offers in a stack.
/// Uses driverRidesProvider directly for state management.
class RideStackSheet extends ConsumerStatefulWidget {
  final Future<void> Function(RideOffer ride) onAccept;
  final Future<void> Function(RideOffer ride) onDecline;
  final VoidCallback onDismiss;

  const RideStackSheet({
    super.key,
    required this.onAccept,
    required this.onDecline,
    required this.onDismiss,
  });

  @override
  ConsumerState<RideStackSheet> createState() => _RideStackSheetState();
}

class _RideStackSheetState extends ConsumerState<RideStackSheet> {
  @override
  Widget build(BuildContext context) {
    final driverRidesState = ref.watch(driverRidesProvider);

    if (!driverRidesState.hasActiveOffer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onDismiss();
      });
      return const SizedBox.shrink();
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          widget.onDismiss();
        }
      },
      child: Container(
        height: MediaQuery.of(context).size.height * 0.5,
        decoration: const BoxDecoration(
          color: Color(0xFFF5F5F5),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            _buildHandle(),
            Expanded(
              child: RideStackView(
                onAccept: widget.onAccept,
                onDecline: widget.onDecline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

Future<void> showRideStackSheet({
  required BuildContext context,
  required WidgetRef ref,
  required Future<void> Function(RideOffer ride) onAccept,
  required Future<void> Function(RideOffer ride) onDecline,
}) async {
  await showModalBottomSheet(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (sheetContext) {
      return RideStackSheet(
        onAccept: onAccept,
        onDecline: onDecline,
        onDismiss: () {
          if (Navigator.of(sheetContext).canPop()) {
            Navigator.of(sheetContext).pop();
          }
        },
      );
    },
  );
}

/// Overlay widget for displaying ride offers as a stack from the bottom.
/// 
/// Uses driverRidesProvider.hasActiveOffer to determine visibility.
/// Animates in from bottom when offers are available.
class RideStackOverlay extends ConsumerStatefulWidget {
  final Future<void> Function(RideOffer ride) onAccept;
  final Future<void> Function(RideOffer ride) onDecline;

  const RideStackOverlay({
    super.key,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  ConsumerState<RideStackOverlay> createState() => _RideStackOverlayState();
}

class _RideStackOverlayState extends ConsumerState<RideStackOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;
  bool _isVisible = false;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _updateVisibility(bool hasActiveOffer) {
    if (hasActiveOffer && !_isVisible) {
      _isVisible = true;
      _slideController.forward();
    } else if (!hasActiveOffer && _isVisible) {
      _isVisible = false;
      _slideController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final driverRidesState = ref.watch(driverRidesProvider);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateVisibility(driverRidesState.hasActiveOffer);
    });

    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: 0.5,
          widthFactor: 1.0,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Column(
              children: [
                _buildHandle(),
                Expanded(
                  child: RideStackView(
                    onAccept: widget.onAccept,
                    onDecline: widget.onDecline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
