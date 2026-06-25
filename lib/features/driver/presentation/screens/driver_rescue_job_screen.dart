import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/widgets/slide_to_action_button.dart';
import '../../../rescue/rescue_theme.dart';
import '../../providers/driver_rides_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';

/// Pre-OTP rescue job flow for drivers (accept → partner → en route → OTP).
///
/// After OTP verification the linked user/vehicle ride opens on
/// [DriverActiveRideScreen].
class DriverRescueJobScreen extends ConsumerStatefulWidget {
  const DriverRescueJobScreen({super.key});

  @override
  ConsumerState<DriverRescueJobScreen> createState() =>
      _DriverRescueJobScreenState();
}

class _DriverRescueJobScreenState extends ConsumerState<DriverRescueJobScreen> {
  String? _driverRecordId;
  Timer? _pollTimer;
  bool _busy = false;
  String _otpError = '';
  final _otpController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _hydrateDriverRecordId();
    _startPollingIfNeeded();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _hydrateDriverRecordId() async {
    if (_driverRecordId != null && _driverRecordId!.isNotEmpty) return;
    try {
      final profile = await apiClient.getDriverProfile();
      final data = profile['data'];
      if (data is Map) {
        final id =
            (data['driver_id'] ?? data['driverId'] ?? data['id'])?.toString();
        if (id != null && id.isNotEmpty && mounted) {
          setState(() => _driverRecordId = id);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Rescue job: failed to resolve driver id: $e');
    }
  }

  String get _driverId => _driverRecordId ?? 'unknown';

  RideOffer? get _job => ref.read(driverRidesProvider).acceptedRide;

  void _startPollingIfNeeded() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final job = _job;
      if (job == null || !job.isRescue) return;
      if (!job.isWaitingForPartnerDriver) return;
      if (_driverId == 'unknown') return;

      await ref
          .read(driverRidesProvider.notifier)
          .refreshAcceptedRescue(driverId: _driverId);
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _markEnRoute() async {
    final job = _job;
    if (job == null || _busy) return;

    setState(() => _busy = true);
    try {
      final response = await apiClient.rescueDriverEnRoute(job.id);
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'];
        if (data is Map) {
          final updated = mergeRescuePayloadIntoOffer(
            job,
            Map<String, dynamic>.from(data as Map),
            driverId: _driverId,
          );
          ref.read(driverRidesProvider.notifier).updateAcceptedRescue(updated);
        }
        setState(() {});
      } else {
        AppMessenger.showDriverErrorBanner(
          context,
          response['message']?.toString() ?? 'Could not update rescue status',
        );
      }
    } catch (e) {
      if (mounted) {
        AppMessenger.showDriverErrorBanner(context, 'Failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markArrived() async {
    final job = _job;
    if (job == null || _busy) return;

    setState(() => _busy = true);
    try {
      final response = await apiClient.rescueDriverArrived(job.id);
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'];
        if (data is Map) {
          final updated = mergeRescuePayloadIntoOffer(
            job,
            Map<String, dynamic>.from(data as Map),
            driverId: _driverId,
          );
          ref.read(driverRidesProvider.notifier).updateAcceptedRescue(updated);
        }
        setState(() {});
      } else {
        AppMessenger.showDriverErrorBanner(
          context,
          response['message']?.toString() ?? 'Could not mark arrived',
        );
      }
    } catch (e) {
      if (mounted) {
        AppMessenger.showDriverErrorBanner(context, 'Failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyOtp() async {
    final job = _job;
    if (job == null || _busy) return;

    final otp = _otpController.text.trim();
    if (otp.length < 4) {
      setState(() => _otpError = 'Enter the 4-digit rescue PIN from the rider');
      return;
    }

    setState(() {
      _busy = true;
      _otpError = '';
    });

    try {
      final response = await apiClient.verifyRescueOtp(job.id, otp);
      if (!mounted) return;

      if (response['success'] == true) {
        final data = response['data'];
        var updated = job;
        if (data is Map) {
          updated = mergeRescuePayloadIntoOffer(
            job,
            Map<String, dynamic>.from(data as Map),
            driverId: _driverId,
          );
        }

        final notifier = ref.read(driverRidesProvider.notifier);
        notifier.updateAcceptedRescue(updated);
        notifier.promoteRescueToLinkedRide(updated);

        final linkedId = updated.linkedActiveRideId;
        if (linkedId != null && linkedId.isNotEmpty && mounted) {
          context.go('${AppRoutes.driverActiveRide}?rideId=$linkedId');
        }
        return;
      }

      setState(() {
        _otpError =
            response['message']?.toString() ?? 'Invalid PIN. Ask the rider.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _otpError = 'Verification failed. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(driverRidesProvider.select((s) => s.acceptedRide));

    if (job == null || !job.isRescue) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rescue')),
        body: Center(
          child: TextButton(
            onPressed: () => context.go(AppRoutes.driverHome),
            child: const Text('Back to home'),
          ),
        ),
      );
    }

    final status = job.rescueStatus?.toUpperCase() ?? 'PENDING';
    final isDriver1 = job.rescueDriverRole == 'driver1';
    final isDriver2 = job.rescueDriverRole == 'driver2';

    return Scaffold(
      backgroundColor: RescueTheme.screenBg,
      appBar: AppBar(
        backgroundColor: RescueTheme.screenBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: RescueTheme.textPrimary),
          onPressed: () => context.go(AppRoutes.driverHome),
        ),
        title: Text(
          'Rescue request',
          style: RescueTheme.titleMedium,
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: RescueTheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _statusLabel(status),
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: RescueTheme.accent,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _roleBanner(job, isDriver1, isDriver2),
            const SizedBox(height: 16),
            if (job.isWaitingForPartnerDriver && isDriver1)
              _waitingCard(),
            if (job.partnerDriverName != null &&
                job.partnerDriverName!.isNotEmpty)
              _partnerCard(job),
            const SizedBox(height: 12),
            _locationCard(
              icon: Icons.my_location,
              label: 'Pickup (rider location)',
              address: job.pickupAddress,
            ),
            const SizedBox(height: 10),
            _locationCard(
              icon: Icons.person_pin_circle,
              label: isDriver2 ? 'Your drop (vehicle)' : 'User drop',
              address: isDriver2 && job.vehicleDropAddress != null
                  ? job.vehicleDropAddress!
                  : job.dropAddress,
            ),
            if (job.hasVehicle && !isDriver2 && job.vehicleDropAddress != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _locationCard(
                  icon: Icons.two_wheeler,
                  label: 'Vehicle drop (partner driver)',
                  address: job.vehicleDropAddress!,
                ),
              ),
            const SizedBox(height: 24),
            ..._buildActions(job, status, isDriver1, isDriver2),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActions(
    RideOffer job,
    String status,
    bool isDriver1,
    bool isDriver2,
  ) {
    if (status == 'IN_PROGRESS') {
      final linkedId = job.linkedActiveRideId;
      return [
        FilledButton(
          onPressed: linkedId == null
              ? null
              : () => context.push(
                    '${AppRoutes.driverActiveRide}?rideId=$linkedId',
                  ),
          style: RescueTheme.primaryButton,
          child: const Text('Open active ride'),
        ),
      ];
    }

    if (status == 'DRIVERS_ARRIVED') {
      return [
        Text(
          'Ask the rider for their rescue PIN',
          style: RescueTheme.body,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: RescueTheme.fieldDecoration('4-digit PIN').copyWith(
            counterText: '',
            errorText: _otpError.isEmpty ? null : _otpError,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _verifyOtp,
          style: RescueTheme.primaryButton,
          child: _busy
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Verify PIN & start ride'),
        ),
      ];
    }

    if (status == 'DRIVERS_EN_ROUTE') {
      return [
        SlideToActionButton(
          text: 'Slide to mark arrived at pickup',
          icon: Icons.location_on,
          backgroundColor: RescueTheme.accent,
          enabled: !_busy,
          onSlideComplete: _markArrived,
        ),
      ];
    }

    if (status == 'BOTH_ACCEPTED') {
      if (isDriver1 && job.hasVehicle) {
        return [
          Text(
            'Pick up your partner driver, then head to the rider together.',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 16),
          SlideToActionButton(
            text: 'Slide — picked up partner, en route',
            icon: Icons.navigation,
            backgroundColor: RescueTheme.accent,
            enabled: !_busy,
            onSlideComplete: _markEnRoute,
          ),
        ];
      }

      return [
        Text(
          isDriver2
              ? 'Your partner is coordinating pickup. Head to the rider when ready.'
              : 'Head to the rider pickup location.',
          style: RescueTheme.body,
        ),
        const SizedBox(height: 16),
        SlideToActionButton(
          text: 'Slide to mark arrived at pickup',
          icon: Icons.location_on,
          backgroundColor: RescueTheme.accent,
          enabled: !_busy,
          onSlideComplete: _markArrived,
        ),
      ];
    }

    if (job.isWaitingForPartnerDriver && isDriver1) {
      return [
        Text(
          'You are driver 1. Waiting for a second driver to accept for the vehicle leg.',
          style: RescueTheme.body,
        ),
      ];
    }

    return [
      Text(
        'Rescue status: ${_statusLabel(status)}',
        style: RescueTheme.body,
      ),
    ];
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'DRIVER1_ACCEPTED':
        return 'Waiting for partner';
      case 'BOTH_ACCEPTED':
        return 'Team ready';
      case 'DRIVERS_EN_ROUTE':
        return 'En route';
      case 'DRIVERS_ARRIVED':
        return 'At pickup';
      case 'IN_PROGRESS':
        return 'In progress';
      default:
        return status.replaceAll('_', ' ').toLowerCase();
    }
  }

  Widget _roleBanner(RideOffer job, bool isDriver1, bool isDriver2) {
    final roleLabel = isDriver1
        ? 'Driver 1 — user ride'
        : isDriver2
            ? 'Driver 2 — vehicle ride'
            : 'Rescue driver';
    final subtitle = job.hasVehicle
        ? '${job.driversNeeded} drivers needed'
        : 'Single driver rescue';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: RescueTheme.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.emergency, color: RescueTheme.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(roleLabel, style: RescueTheme.label),
                const SizedBox(height: 2),
                Text(subtitle, style: RescueTheme.body.copyWith(fontSize: 13)),
              ],
            ),
          ),
          Text(
            '₹${job.earning.toStringAsFixed(0)}',
            style: RescueTheme.price.copyWith(color: RescueTheme.accent),
          ),
        ],
      ),
    );
  }

  Widget _waitingCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Waiting for a second driver to join…',
              style: RescueTheme.body,
            ),
          ),
        ],
      ),
    );
  }

  Widget _partnerCard(RideOffer job) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Partner driver', style: RescueTheme.label),
          const SizedBox(height: 6),
          Text(job.partnerDriverName ?? 'Assigned', style: RescueTheme.body),
          if (job.partnerDriverPhone != null &&
              job.partnerDriverPhone!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                job.partnerDriverPhone!,
                style: RescueTheme.body.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );
  }

  Widget _locationCard({
    required IconData icon,
    required String label,
    required String address,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: RescueTheme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: RescueTheme.label.copyWith(fontSize: 13)),
                const SizedBox(height: 4),
                Text(address, style: RescueTheme.body.copyWith(fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
