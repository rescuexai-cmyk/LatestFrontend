import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../data/rescue_repository.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

class RescueLandingScreen extends ConsumerStatefulWidget {
  const RescueLandingScreen({super.key});

  @override
  ConsumerState<RescueLandingScreen> createState() =>
      _RescueLandingScreenState();
}

class _RescueLandingScreenState extends ConsumerState<RescueLandingScreen> {
  List<RescueRequestSummary> _recent = [];
  bool _loadingRecent = true;
  bool _checkingActive = true;

  @override
  void initState() {
    super.initState();
    _checkActiveRescue();
    _loadRecent();
  }

  Future<void> _checkActiveRescue() async {
    try {
      final active = await ref.read(rescueRepositoryProvider).getActiveRescue();
      if (!mounted) return;
      if (active != null) {
        ref.read(rescueBookingProvider.notifier).setRescueId(active.id);
        if (active.isSearching) {
          context.go('${AppRoutes.rescueSearching}?rescueId=${active.id}');
          return;
        } else if (active.isLive) {
          context.go('${AppRoutes.rescueJourneyHub}?rescueId=${active.id}');
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _checkingActive = false);
  }

  Future<void> _loadRecent() async {
    try {
      final list =
          await ref.read(rescueRepositoryProvider).getHistory(limit: 3);
      if (mounted) setState(() => _recent = list);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingRecent = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(rescueBookingProvider).serviceType;

    return RescueScaffold(
      title: 'Need help moving?',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Select the type of rescue you need',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 16),
          ...RescueServiceType.values.map((type) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RescueSelectTile(
                title: type.label,
                subtitle: type.subtitle,
                selected: selected == type,
                leading: Icon(
                  _iconFor(type),
                  color: selected == type
                      ? RescueTheme.accent
                      : RescueTheme.textMuted,
                ),
                onTap: () => ref
                    .read(rescueBookingProvider.notifier)
                    .setServiceType(type),
              ),
            );
          }),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent requests', style: RescueTheme.label),
              TextButton(
                onPressed: () => context.push(AppRoutes.history),
                child: Text(
                  'View all',
                  style: GoogleFonts.poppins(color: RescueTheme.accent),
                ),
              ),
            ],
          ),
          if (_loadingRecent)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: CircularProgressIndicator(color: RescueTheme.accent),
              ),
            )
          else if (_recent.isEmpty)
            Text(
              'No recent rescue requests',
              style: RescueTheme.body.copyWith(fontSize: 13),
            )
          else
            ..._recent.map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RescueSelectTile(
                  title: r.pickupAddress ?? 'Rescue',
                  subtitle: rescueStatusLabel(r.status),
                  selected: false,
                  onTap: () {
                    ref.read(rescueBookingProvider.notifier).setRescueId(r.id);
                    context.push(AppRoutes.rescueJourneyPath(r.id));
                  },
                ),
              ),
            ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: () => context.push(AppRoutes.rescueReason),
          child: const Text('Continue'),
        ),
      ),
    );
  }

  IconData _iconFor(RescueServiceType t) {
    switch (t) {
      case RescueServiceType.traffic:
        return Icons.traffic;
      case RescueServiceType.vehicle:
        return Icons.local_shipping_outlined;
      case RescueServiceType.passengerAndVehicle:
        return Icons.groups_2_outlined;
      case RescueServiceType.breakdown:
        return Icons.build_outlined;
      case RescueServiceType.emergency:
        return Icons.emergency_outlined;
    }
  }
}
