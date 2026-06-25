import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

/// Figma screen 7 — Live tracking with dual status cards.
class RescueTrackingScreen extends ConsumerStatefulWidget {
  const RescueTrackingScreen({super.key});

  @override
  ConsumerState<RescueTrackingScreen> createState() =>
      _RescueTrackingScreenState();
}

class _RescueTrackingScreenState extends ConsumerState<RescueTrackingScreen> {
  Timer? _pollTimer;
  RescueProgressSnapshot? _progress;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    final id = ref.read(rescueBookingProvider).rescueId;
    if (id == null) return;
    try {
      final p = await ref.read(rescueBookingProvider.notifier).fetchProgress();
      if (!mounted) return;
      setState(() => _progress = p);
      final status = p.rescue.status;
      if (p.rescue.isCancelled) {
        _pollTimer?.cancel();
        context.go(AppRoutes.services);
        return;
      }
      if (status == 'DRIVERS_ARRIVED' &&
          !ref.read(rescueBookingProvider).handoverCompleted) {
        _pollTimer?.cancel();
        context.go(AppRoutes.rescueHandover);
      }
    } catch (_) {}
  }

  Future<void> _cancelRescue() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel rescue?', style: RescueTheme.titleMedium),
        content: Text(
          'Are you sure you want to cancel this rescue? Drivers may already be on their way.',
          style: RescueTheme.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep rescue'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Cancel', style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelling = true);
    try {
      await ref.read(rescueBookingProvider.notifier).cancelRescue(
            reason: 'Cancelled by rider from tracking',
          );
      if (!mounted) return;
      ref.read(rescueBookingProvider.notifier).reset();
      context.go(AppRoutes.services);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel rescue. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rescueBookingProvider);
    final pickup = s.pickup?.location ?? const LatLng(23.2599, 77.4126);
    final summary = _progress?.rescue ?? s.summary;
    final status = summary?.status ?? 'PENDING';

    final canCancel = status == 'PENDING' ||
        status == 'DRIVER1_ACCEPTED' ||
        status == 'BOTH_ACCEPTED' ||
        status == 'DRIVERS_EN_ROUTE';

    return RescueScaffold(
      title: 'Live tracking',
      showBack: true,
      onBack: canCancel ? _cancelRescue : null,
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: pickup, zoom: 14),
              markers: {
                Marker(markerId: const MarkerId('pickup'), position: pickup),
              },
              myLocationEnabled: true,
              zoomControlsEnabled: false,
            ),
          ),
          Expanded(
            flex: 4,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(rescueStatusLabel(status), style: RescueTheme.titleMedium),
                const SizedBox(height: 12),
                RescueStatusCard(
                  title: 'You',
                  subtitle: _progress?.userDriverName != null
                      ? 'Rider arriving in ${_progress?.userEtaMin ?? '—'} min'
                      : 'Finding your rider…',
                  icon: Icons.two_wheeler,
                ),
                if (s.hasVehicle) ...[
                  const SizedBox(height: 10),
                  RescueStatusCard(
                    title: 'Your vehicle',
                    subtitle: _progress?.vehicleDriverName != null
                        ? 'Driver arriving in ${_progress?.vehicleEtaMin ?? '—'} min'
                        : 'Matching vehicle driver…',
                    icon: Icons.directions_car_outlined,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Vehicle: Pickup after verification',
                    style: RescueTheme.body.copyWith(fontSize: 13),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  style: RescueTheme.primaryButton.copyWith(
                    minimumSize: WidgetStateProperty.all(
                      const Size(double.infinity, 48),
                    ),
                  ),
                  onPressed: summary == null
                      ? null
                      : () => context.push(AppRoutes.rescueJourneyHub),
                  child: const Text('View Journey Hub'),
                ),
                if (canCancel) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _cancelling ? null : _cancelRescue,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      side: BorderSide(color: Colors.red.shade300),
                      foregroundColor: Colors.red.shade700,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _cancelling
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.red.shade700,
                            ),
                          )
                        : const Text('Cancel Rescue'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
