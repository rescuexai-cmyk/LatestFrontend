import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../rescue_flow.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_location_picker_sheet.dart';
import '../widgets/rescue_widgets.dart';

class RescueDestinationScreen extends ConsumerWidget {
  const RescueDestinationScreen({super.key});

  Future<void> _pickUserDrop(BuildContext context, WidgetRef ref) async {
    final state = ref.read(rescueBookingProvider);
    final picked = await showRescueLocationPicker(
      context,
      title: 'Your destination',
      initial: state.userDrop,
      bias: state.pickup?.location,
    );
    if (picked != null) {
      ref.read(rescueBookingProvider.notifier).setUserDrop(picked);
    }
  }

  Future<void> _pickVehicleDrop(BuildContext context, WidgetRef ref) async {
    final state = ref.read(rescueBookingProvider);
    final picked = await showRescueLocationPicker(
      context,
      title: 'Vehicle destination',
      initial: state.vehicleDrop,
      bias: state.pickup?.location,
    );
    if (picked != null) {
      ref.read(rescueBookingProvider.notifier).setVehicleDrop(picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rescueBookingProvider);
    final pickup = state.pickup?.address ?? '';

    return RescueScaffold(
      title: 'Destination',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            state.hasVehicle
                ? 'Where should we take you and your vehicle?'
                : 'Where should we take you?',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 16),
          RescueLocationField(
            label: 'Pickup location',
            address: pickup,
            icon: Icons.trip_origin,
            onTap: () => context.push(AppRoutes.rescueLocation),
          ),
          const SizedBox(height: 16),
          RescueLocationField(
            label: 'Your destination',
            address: state.userDrop?.address ?? '',
            onTap: () => _pickUserDrop(context, ref),
          ),
          if (state.hasVehicle) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Same as your destination', style: RescueTheme.label),
              value: state.vehicleDropSameAsDrop,
              activeColor: RescueTheme.accent,
              onChanged: (v) => ref
                  .read(rescueBookingProvider.notifier)
                  .setVehicleDropSameAsDrop(v ?? true),
            ),
            if (!state.vehicleDropSameAsDrop) ...[
              const SizedBox(height: 8),
              RescueLocationField(
                label: 'Vehicle destination',
                address: state.vehicleDrop?.address ?? '',
                icon: Icons.local_shipping_outlined,
                onTap: () => _pickVehicleDrop(context, ref),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'You can track both journeys separately in real-time.',
              style: RescueTheme.body.copyWith(
                fontSize: 13,
                color: RescueTheme.textMuted,
              ),
            ),
          ],
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: !RescueFlow.canProceedFromDestination(state)
              ? null
              : () => context.push(AppRoutes.rescueReview),
          child: const Text('Continue'),
        ),
      ),
    );
  }
}
