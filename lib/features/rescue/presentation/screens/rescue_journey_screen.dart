import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../data/rescue_repository.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_widgets.dart';

class RescueJourneyScreen extends ConsumerStatefulWidget {
  const RescueJourneyScreen({super.key, this.rescueId});

  final String? rescueId;

  @override
  ConsumerState<RescueJourneyScreen> createState() =>
      _RescueJourneyScreenState();
}

class _RescueJourneyScreenState extends ConsumerState<RescueJourneyScreen> {
  Timer? _pollTimer;
  RescueProgressSnapshot? _progress;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final fromQuery = widget.rescueId;
    if (fromQuery != null && fromQuery.isNotEmpty) {
      final current = ref.read(rescueBookingProvider).rescueId;
      if (current != fromQuery) {
        ref.read(rescueBookingProvider.notifier).setRescueId(fromQuery);
      }
    }
    await _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  Future<void> _poll() async {
    final id = ref.read(rescueBookingProvider).rescueId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final progress =
          await ref.read(rescueBookingProvider.notifier).fetchProgress();
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _loading = false;
      });
      if (progress.rescue.isCompleted) {
        _pollTimer?.cancel();
        context.go(AppRoutes.rescueComplete);
      } else if (progress.rescue.isCancelled) {
        _pollTimer?.cancel();
        context.go(AppRoutes.services);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmDelivery() async {
    await ref.read(rescueBookingProvider.notifier).confirmVehicleDelivery();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Vehicle delivery confirmed',
          style: RescueTheme.body.copyWith(color: Colors.white),
        ),
        backgroundColor: RescueTheme.success,
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rescueState = ref.watch(rescueBookingProvider);
    final summary = _progress?.rescue ?? rescueState.summary;
    final otp = summary?.rescueOtp;

    return RescueScaffold(
      title: 'Rescue journey',
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: RescueTheme.accent),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                RescueCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rescueStatusLabel(summary?.status ?? 'PENDING'),
                        style: RescueTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        summary?.pickupAddress ?? 'Pickup',
                        style: RescueTheme.body,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (otp != null && otp.isNotEmpty) ...[
                  RescueCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Share OTP with drivers', style: RescueTheme.label),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                otp,
                                style: RescueTheme.titleLarge.copyWith(
                                  letterSpacing: 8,
                                  color: RescueTheme.accent,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Copy OTP',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: otp));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('OTP copied')),
                                );
                              },
                              icon: const Icon(Icons.copy, color: RescueTheme.accent),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (rescueState.hasVehicle) ...[
                  _DriverLegCard(
                    title: 'Your ride',
                    driverName: _progress?.userDriverName ?? summary?.driver1Name,
                    status: _progress?.userRideStatus,
                  ),
                  const SizedBox(height: 12),
                  _DriverLegCard(
                    title: 'Vehicle delivery',
                    driverName:
                        _progress?.vehicleDriverName ?? summary?.driver2Name,
                    status: _progress?.vehicleRideStatus,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _confirmDelivery,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      foregroundColor: RescueTheme.accent,
                      side: const BorderSide(color: RescueTheme.accent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Confirm vehicle delivered'),
                  ),
                ] else
                  _DriverLegCard(
                    title: 'Rescue driver',
                    driverName: _progress?.userDriverName ?? summary?.driver1Name,
                    status: _progress?.userRideStatus,
                  ),
              ],
            ),
    );
  }
}

class _DriverLegCard extends StatelessWidget {
  const _DriverLegCard({
    required this.title,
    this.driverName,
    this.status,
  });

  final String title;
  final String? driverName;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return RescueCard(
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: RescueTheme.accent.withValues(alpha: 0.15),
            child: const Icon(Icons.person, color: RescueTheme.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: RescueTheme.label),
                const SizedBox(height: 4),
                Text(
                  driverName?.isNotEmpty == true ? driverName! : 'Assigning…',
                  style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
                ),
                if (status != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    status!.replaceAll('_', ' ').toLowerCase(),
                    style: RescueTheme.body.copyWith(
                      fontSize: 13,
                      color: RescueTheme.textMuted,
                    ),
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
