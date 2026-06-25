import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

class RescueReviewScreen extends ConsumerStatefulWidget {
  const RescueReviewScreen({super.key});

  @override
  ConsumerState<RescueReviewScreen> createState() => _RescueReviewScreenState();
}

class _RescueReviewScreenState extends ConsumerState<RescueReviewScreen> {
  bool _submitting = false;

  static const _paymentOptions = [
    ('CASH', 'Cash'),
    ('UPI', 'UPI'),
    ('WALLET', 'Wallet'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rescueBookingProvider.notifier).loadEstimate();
    });
  }

  Future<void> _confirm() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await ref.read(rescueBookingProvider.notifier).createRescueRequest();
      if (!mounted) return;
      context.go(AppRoutes.rescueTracking);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not confirm rescue. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rescueBookingProvider);
    final est = s.estimate;

    return RescueScaffold(
      title: 'Review your rescue',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          RescueCard(
            child: RescueDualJourneySummary(
              pickup: s.pickup?.address ?? 'Pickup',
              userDrop: s.userDrop?.address ?? 'Drop',
              vehicleDrop: s.vehicleDrop?.address,
              hasVehicle: s.hasVehicle,
              vehicleDropSameAsDrop: s.vehicleDropSameAsDrop,
            ),
          ),
          const SizedBox(height: 12),
          RescueCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Price breakdown', style: RescueTheme.label),
                    const Spacer(),
                    if (est?.isStatic ?? true) const RescueStaticBadge(),
                  ],
                ),
                const SizedBox(height: 10),
                if (s.isLoadingEstimate)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(color: RescueTheme.accent),
                    ),
                  )
                else if (est != null) ...[
                  RescueFareRow(label: 'Passenger transport', amount: est.passengerTransport),
                  if (s.hasVehicle)
                    RescueFareRow(label: 'Vehicle delivery', amount: est.vehicleDelivery),
                  RescueFareRow(label: 'Platform fee', amount: est.platformFee, muted: true),
                  RescueFareRow(label: 'Insurance', amount: est.insurance, muted: true),
                  const Divider(color: RescueTheme.stroke),
                  RescueFareRow(label: 'Total', amount: est.total, bold: true),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          RescueCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Payment method', style: RescueTheme.label),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: _paymentOptions.map((o) {
                    final sel = s.paymentMethod == o.$1;
                    return ChoiceChip(
                      label: Text(o.$2),
                      selected: sel,
                      selectedColor: RescueTheme.accent.withValues(alpha: 0.15),
                      onSelected: (_) => ref
                          .read(rescueBookingProvider.notifier)
                          .setPaymentMethod(o.$1),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: _submitting || s.isLoadingEstimate ? null : _confirm,
          child: _submitting
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Confirm Rescue'),
        ),
      ),
    );
  }
}
