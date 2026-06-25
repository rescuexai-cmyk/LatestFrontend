import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_widgets.dart';

class RescueSearchingScreen extends ConsumerStatefulWidget {
  const RescueSearchingScreen({super.key});

  @override
  ConsumerState<RescueSearchingScreen> createState() =>
      _RescueSearchingScreenState();
}

class _RescueSearchingScreenState extends ConsumerState<RescueSearchingScreen>
    with SingleTickerProviderStateMixin {
  Timer? _pollTimer;
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _startPolling();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    final id = ref.read(rescueBookingProvider).rescueId;
    if (id == null || !mounted) return;
    try {
      final summary =
          await ref.read(rescueBookingProvider.notifier).refreshRescue();
      if (!mounted) return;
      if (summary.isCancelled) {
        _pollTimer?.cancel();
        context.go(AppRoutes.services);
        return;
      }
      if (!summary.isSearching) {
        _pollTimer?.cancel();
        context.go(AppRoutes.rescueJourneyPath(summary.id));
      }
    } catch (_) {
      // Keep polling — transient network errors are expected.
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel rescue?', style: RescueTheme.titleMedium),
        content: Text(
          'Your rescue request will be cancelled.',
          style: RescueTheme.body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Cancel', style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(rescueBookingProvider.notifier).cancelRescue(
            reason: 'Cancelled by rider',
          );
      if (!mounted) return;
      context.go(AppRoutes.services);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel rescue')),
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(rescueBookingProvider).summary;
    final status = summary?.status ?? 'PENDING';

    return RescueScaffold(
      title: 'Finding drivers',
      onBack: () => _cancel(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.08).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: RescueTheme.accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.emergency_share_outlined,
                    size: 56,
                    color: RescueTheme.accent,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                rescueStatusLabel(status),
                textAlign: TextAlign.center,
                style: RescueTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                ref.watch(rescueBookingProvider).hasVehicle
                    ? 'Matching two rescue drivers for you and your vehicle.'
                    : 'Matching a rescue driver for your trip.',
                textAlign: TextAlign.center,
                style: RescueTheme.body,
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: RescueTheme.accent),
            ],
          ),
        ),
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: OutlinedButton(
          onPressed: _cancel,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            side: const BorderSide(color: RescueTheme.stroke),
            foregroundColor: RescueTheme.textPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text('Cancel rescue'),
        ),
      ),
    );
  }
}
