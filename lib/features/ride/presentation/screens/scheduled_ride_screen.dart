import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../../../core/models/ride.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../driver/presentation/widgets/driver_trip_route_summary.dart';
import '../../data/pending_ride_storage.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import 'package:ride_hailing_flutter/core/widgets/figma_square_back_button.dart';

/// Confirmation screen for rides booked for later — no live driver search yet.
class ScheduledRideScreen extends ConsumerStatefulWidget {
  const ScheduledRideScreen({super.key});

  @override
  ConsumerState<ScheduledRideScreen> createState() =>
      _ScheduledRideScreenState();
}

class _ScheduledRideScreenState extends ConsumerState<ScheduledRideScreen> {
  Timer? _pollTimer;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _syncRideFromBackend();
    });
    unawaited(_syncRideFromBackend());
  }

  Future<void> _syncRideFromBackend() async {
    final rideId = ref.read(rideBookingProvider).rideId;
    if (rideId == null || rideId.isEmpty || !mounted) return;

    try {
      final response = await apiClient.getRide(rideId);
      final ride = Ride.fromJson(Ride.unwrapRidePayload(response));
      if (!mounted) return;

      final status = ride.status;
      if (status == RideStatus.cancelled) {
        _clearAndGoHome(showMessage: 'Your scheduled ride was cancelled');
        return;
      }

      if (status == RideStatus.accepted ||
          status == RideStatus.arriving ||
          status == RideStatus.driverArriving ||
          status == RideStatus.inProgress) {
        ref.read(activeRideProvider.notifier).setActiveRide(ride);
        ref.read(rideBookingProvider.notifier).setScheduledTime(null);
        await PendingRideStorage.save(
          ref.read(rideBookingProvider).copyWith(clearScheduledTime: true),
        );
        if (!mounted) return;
        context.pushReplacement(AppRoutes.driverAssigned);
        return;
      }

      // Backend started matching — hand off to searching screen.
      if (_shouldHandOffToSearching(ride)) {
        ref.read(rideBookingProvider.notifier).setScheduledTime(null);
        await PendingRideStorage.save(
          ref.read(rideBookingProvider).copyWith(clearScheduledTime: true),
        );
        if (!mounted) return;
        context.pushReplacement(AppRoutes.searchingDrivers);
      }
    } catch (_) {
      // Best-effort sync only.
    }
  }

  bool _shouldHandOffToSearching(Ride ride) {
    if (ride.status != RideStatus.requested) return false;
    final booking = ref.read(rideBookingProvider);
    final scheduled = booking.scheduledTime;
    if (scheduled == null) return true;
    return DateTime.now().isAfter(scheduled.subtract(const Duration(minutes: 30)));
  }

  String _formatScheduledLabel(DateTime scheduled) {
    final lang = ref.read(settingsProvider).languageCode;
    final locId = lang == 'hi' ? 'hi_IN' : 'en_IN';
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final timeStr = DateFormat.jm(locId).format(scheduled);

    if (scheduled.year == now.year &&
        scheduled.month == now.month &&
        scheduled.day == now.day) {
      return 'Today, $timeStr';
    }
    if (scheduled.year == tomorrow.year &&
        scheduled.month == tomorrow.month &&
        scheduled.day == tomorrow.day) {
      return 'Tomorrow, $timeStr';
    }
    return '${DateFormat.yMMMd(locId).format(scheduled)}, $timeStr';
  }

  Future<void> _clearAndGoHome({String? showMessage}) async {
    ref.read(activeRideProvider.notifier).clearActiveRide();
    ref.read(rideBookingProvider.notifier).reset();
    if (!mounted) return;
    if (showMessage != null) {
      AppMessenger.showErrorBanner(context, showMessage);
    }
    context.go(AppRoutes.services);
  }

  Future<void> _cancelScheduledRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('cancel_ride_question')),
        content: const Text(
          'Are you sure you want to cancel this scheduled ride?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ref.tr('no_continue')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Yes, Cancel',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final rideId = ref.read(rideBookingProvider).rideId;
    setState(() => _cancelling = true);
    try {
      if (rideId != null && rideId.isNotEmpty) {
        realtimeService.cancelRide(rideId, reason: 'Cancelled by rider');
        await apiClient.cancelRide(rideId, reason: 'Cancelled by rider');
      }
    } catch (_) {
      // Still clear local state if API fails.
    }
    if (!mounted) return;
    setState(() => _cancelling = false);
    await _clearAndGoHome(showMessage: 'Scheduled ride cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final booking = ref.watch(rideBookingProvider);
    final scheduled = booking.scheduledTime;
    final pickup = booking.pickupAddress ?? 'Pickup';
    final drop = booking.destinationAddress ?? 'Drop-off';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  FigmaSquareBackButton(
                    onPressed: () => context.pop(),
                  ),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6B7280),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'Scheduled',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6B7280)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(
                                  Icons.schedule_rounded,
                                  color: Color(0xFF6B7280),
                                  size: 26,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Ride scheduled',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF1A1A1A),
                                      ),
                                    ),
                                    if (scheduled != null)
                                      Text(
                                        _formatScheduledLabel(scheduled),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Color(0xFF6B7280),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'A driver will be assigned closer to your pickup time. '
                            'We\'ll notify you when your driver is on the way.',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.45,
                              color: Color(0xFF666666),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Trip details',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                          const SizedBox(height: 16),
                          DriverTripRouteSummary(
                            pickupAddress: pickup,
                            dropAddress: drop,
                            stops: booking.stops,
                            compact: true,
                          ),
                          if (booking.selectedCabTypeName.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _detailRow(
                              Icons.directions_car_outlined,
                              booking.selectedCabTypeName,
                            ),
                          ],
                          if (booking.fare > 0) ...[
                            const SizedBox(height: 10),
                            _detailRow(
                              Icons.payments_outlined,
                              '₹${booking.fare.toStringAsFixed(0)} estimated',
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (booking.pickupLocation != null &&
                        booking.destinationLocation != null) ...[
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: SizedBox(
                          height: 160,
                          child: GoogleMap(
                            initialCameraPosition: CameraPosition(
                              target: booking.pickupLocation!,
                              zoom: 12,
                            ),
                            markers: {
                              Marker(
                                markerId: const MarkerId('pickup'),
                                position: booking.pickupLocation!,
                                icon: BitmapDescriptor.defaultMarkerWithHue(
                                  BitmapDescriptor.hueGreen,
                                ),
                              ),
                              Marker(
                                markerId: const MarkerId('drop'),
                                position: booking.destinationLocation!,
                                icon: BitmapDescriptor.defaultMarkerWithHue(
                                  BitmapDescriptor.hueRed,
                                ),
                              ),
                            },
                            zoomControlsEnabled: false,
                            myLocationButtonEnabled: false,
                            liteModeEnabled: true,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _cancelling ? null : _cancelScheduledRide,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _cancelling
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Cancel ride',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF444444),
            ),
          ),
        ),
      ],
    );
  }
}

/// Navigate to the correct post-booking screen for the current booking.
void navigateAfterRideCreated(BuildContext context, WidgetRef ref) {
  final booking = ref.read(rideBookingProvider);
  if (booking.isScheduledRide) {
    context.push(AppRoutes.scheduledRide);
  } else {
    context.push(AppRoutes.searchingDrivers);
  }
}

/// Resume an in-progress booking (after payment or cold start).
void resumePendingRideNavigation(BuildContext context, WidgetRef ref) {
  final booking = ref.read(rideBookingProvider);
  if (!booking.hasActiveRideId) return;
  if (booking.isScheduledRide) {
    context.push(AppRoutes.scheduledRide);
  } else {
    context.push(AppRoutes.searchingDrivers);
  }
}
