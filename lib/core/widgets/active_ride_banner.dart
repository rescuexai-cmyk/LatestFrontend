import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/ride/providers/ride_booking_provider.dart';
import '../../features/ride/providers/ride_provider.dart';
import '../models/ride.dart';
import '../router/app_routes.dart';

/// A persistent bottom banner that shows active ride info.
///
/// Shows during the entire ride lifecycle:
///   1. Searching for drivers  → "SEARCHING FOR DRIVER"  → no OTP
///   2. Driver accepted/arriving → "RIDE ACTIVE"          → shows OTP (until verified)
///   3. Ride in progress       → "RIDE ACTIVE"           → OTP hidden (already verified)
///   4. Completed / Cancelled  → banner hidden
///
/// Tapping navigates to the correct screen for the current phase.
class ActiveRideBanner extends ConsumerWidget {
  const ActiveRideBanner({super.key});

  static const _accent = Color(0xFFD4956A);
  static const _dark = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booking = ref.watch(rideBookingProvider);
    final rideState = ref.watch(activeRideProvider);

    // ── Determine if we should show the banner ──
    final hasRideId = booking.rideId != null && booking.rideId!.isNotEmpty;
    if (!hasRideId) return const SizedBox.shrink();

    // Determine ride phase
    final _BannerPhase phase;
    if (rideState.activeRide != null) {
      final status = rideState.activeRide!.status;
      if (status == RideStatus.completed || status == RideStatus.cancelled) {
        // Ride is done — hide the banner
        return const SizedBox.shrink();
      }
      phase = _phaseFromStatus(status);
    } else {
      // No activeRide set yet — we're still searching for a driver
      phase = _BannerPhase.searching;
    }

    // ── Don't show if already on the target screen ──
    final currentRoute = GoRouterState.of(context).matchedLocation;
    if (currentRoute == AppRoutes.searchingDrivers ||
        currentRoute == AppRoutes.driverAssigned ||
        currentRoute.startsWith('/ride/')) {
      return const SizedBox.shrink();
    }

    final pickup = booking.pickupAddress ?? 'Pickup';
    final destination = booking.destinationAddress ?? 'Destination';
    final otp = booking.rideOtp ?? '----';

    // OTP only before ride start (driver arriving); hide once OTP verified / in progress
    final showOtp = phase == _BannerPhase.driverArriving;
    
    // Get driver info if available
    final driver = rideState.activeRide?.driver;
    final driverName = driver?.name;
    final vehicleInfo = driver?.vehicleInfo;
    final vehicleText = vehicleInfo != null 
        ? '${vehicleInfo.displayName} • ${vehicleInfo.plateNumber}'.trim()
        : null;

    return GestureDetector(
      onTap: () => _navigate(context, phase, booking.rideId!),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _dark,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Pulsing status dot
            _StatusDot(phase: phase),
            const SizedBox(width: 12),

            // Ride info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Phase label or driver info
                  if (showOtp && driverName != null) ...[
                    Text(
                      phase.label,
                      style: TextStyle(
                        color: phase.labelColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      driverName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (vehicleText != null && vehicleText.isNotEmpty)
                      Text(
                        vehicleText,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ] else ...[
                    Text(
                      phase.label,
                      style: TextStyle(
                        color: phase.labelColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _shorten(destination, 30),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'From: ${_shorten(pickup, 28)}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),

            // OTP badge — only before ride start (driver arriving)
            if (showOtp)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'PIN',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      otp,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                      ),
                    ),
                  ],
                ),
              ),

            // "Searching..." indicator when no driver yet
            if (phase == _BannerPhase.searching)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Searching',
                      style: TextStyle(
                        color: _accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.5),
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  /// Navigate to the correct screen based on ride phase.
  void _navigate(BuildContext context, _BannerPhase phase, String rideId) {
    switch (phase) {
      case _BannerPhase.searching:
        context.push(AppRoutes.searchingDrivers);
        break;
      case _BannerPhase.driverArriving:
      case _BannerPhase.inProgress:
        context.push(AppRoutes.driverAssigned);
        break;
    }
  }

  _BannerPhase _phaseFromStatus(RideStatus status) {
    switch (status) {
      case RideStatus.requested:
        return _BannerPhase.searching;
      case RideStatus.accepted:
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return _BannerPhase.driverArriving;
      case RideStatus.inProgress:
        return _BannerPhase.inProgress;
      case RideStatus.completed:
      case RideStatus.cancelled:
        return _BannerPhase.searching; // Won't reach here (filtered above)
    }
  }

  String _shorten(String text, int max) {
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }
}

/// Internal ride phase for the banner.
enum _BannerPhase {
  searching,
  driverArriving,
  inProgress;

  String get label {
    switch (this) {
      case searching:
        return 'Searching for Driver';
      case driverArriving:
        return 'Ride Active';
      case inProgress:
        return 'Ride Active';
    }
  }

  Color get labelColor {
    switch (this) {
      case searching:
        return const Color(0xFFD4956A);
      case driverArriving:
        return const Color(0xFFD4956A);
      case inProgress:
        return const Color(0xFFD4956A);
    }
  }

  Color get dotColor {
    switch (this) {
      case searching:
        return const Color(0xFFD4956A);
      case driverArriving:
        return const Color(0xFF4CAF50);
      case inProgress:
        return const Color(0xFF4CAF50);
    }
  }
}

/// Pulsing status dot with phase-appropriate color.
class _StatusDot extends StatelessWidget {
  final _BannerPhase phase;
  const _StatusDot({required this.phase});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: phase.dotColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: phase.dotColor.withValues(alpha: 0.5),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }
}
