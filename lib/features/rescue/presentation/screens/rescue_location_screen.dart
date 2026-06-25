import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../rescue_flow.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_location_picker_sheet.dart';
import '../widgets/rescue_widgets.dart';

class RescueLocationScreen extends ConsumerStatefulWidget {
  const RescueLocationScreen({super.key});

  @override
  ConsumerState<RescueLocationScreen> createState() =>
      _RescueLocationScreenState();
}

class _RescueLocationScreenState extends ConsumerState<RescueLocationScreen> {
  GoogleMapController? _mapController;
  bool _detecting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _detectLocation());
  }

  Future<void> _detectLocation() async {
    final existing = ref.read(rescueBookingProvider).pickup;
    if (existing != null) {
      setState(() => _detecting = false);
      return;
    }
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition();
      var address = 'Current location';
      try {
        final marks =
            await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final p = marks.first;
          address = [
            p.street,
            p.subLocality,
            p.locality,
            p.administrativeArea,
            p.postalCode,
          ].where((e) => e != null && e!.isNotEmpty).join(', ');
        }
      } catch (_) {}
      ref.read(rescueBookingProvider.notifier).setPickup(
            RescuePlace(
              address: address,
              location: LatLng(pos.latitude, pos.longitude),
            ),
          );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _changeLocation() async {
    final state = ref.read(rescueBookingProvider);
    final picked = await showRescueLocationPicker(
      context,
      title: 'Change pickup location',
      initial: state.pickup,
      bias: state.pickup?.location,
    );
    if (picked != null) {
      ref.read(rescueBookingProvider.notifier).setPickup(picked);
      _mapController?.animateCamera(CameraUpdate.newLatLng(picked.location));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rescueBookingProvider);
    final pickup = state.pickup;
    final center = pickup?.location ?? const LatLng(23.2599, 77.4126);

    return RescueScaffold(
      title: 'Your location',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Your current location is detected. Confirm or change it below.',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 220,
              child: _detecting
                  ? const Center(
                      child: CircularProgressIndicator(color: RescueTheme.accent),
                    )
                  : GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: center,
                        zoom: 15,
                      ),
                      onMapCreated: (c) => _mapController = c,
                      markers: pickup == null
                          ? {}
                          : {
                              Marker(
                                markerId: const MarkerId('pickup'),
                                position: pickup.location,
                              ),
                            },
                      myLocationEnabled: true,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                    ),
            ),
          ),
          const SizedBox(height: 14),
          RescueCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.place, color: RescueTheme.accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pickup?.address ?? 'Detecting location…',
                        style: RescueTheme.label,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _changeLocation,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 46),
                    foregroundColor: RescueTheme.accent,
                    side: const BorderSide(color: RescueTheme.accent),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Change Location'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Is your vehicle with you?', style: RescueTheme.label),
          const SizedBox(height: 10),
          RescueYesNoToggle(
            value: state.vehicleWithYou,
            onChanged: (v) =>
                ref.read(rescueBookingProvider.notifier).setVehicleWithYou(v),
          ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: !RescueFlow.canProceedFromLocation(state)
              ? null
              : () => context.push(RescueFlow.afterLocation(state)),
          child: const Text('Confirm Location'),
        ),
      ),
    );
  }
}
