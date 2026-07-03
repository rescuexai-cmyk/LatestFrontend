import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/directions_service.dart';
import '../../../rescue/providers/rescue_booking_provider.dart';
import '../../providers/ride_booking_provider.dart';
import '../widgets/figma_ride_selection_widgets.dart';

/// Post-vehicle-selection flow: pinpoint exact pickup on the map.
enum ConfirmLocationFlow { payment, rescue }

/// Uber/Rapido-style map pin step — shown **after** vehicle selection.
class ConfirmLocationOnMapScreen extends ConsumerStatefulWidget {
  const ConfirmLocationOnMapScreen({
    super.key,
    required this.flow,
    this.vehicleWithYou = true,
  });

  final ConfirmLocationFlow flow;

  /// For rescue flow: whether the user's vehicle is with them at pickup.
  final bool vehicleWithYou;

  static ConfirmLocationFlow flowFromQuery(String? raw) {
    if (raw == 'rescue') return ConfirmLocationFlow.rescue;
    return ConfirmLocationFlow.payment;
  }

  @override
  ConsumerState<ConfirmLocationOnMapScreen> createState() =>
      _ConfirmLocationOnMapScreenState();
}

class _ConfirmLocationOnMapScreenState
    extends ConsumerState<ConfirmLocationOnMapScreen> {
  static const _cream = Color(0xFFFBF2E8);
  static const _pinColor = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF231409);
  static const _textSecondary = Color(0xFF545052);

  /// Space reserved above/below the map so the pin sits on the road, not UI.
  static const _topMapPadding = 72.0;
  static const _bottomMapPadding = 210.0;

  final DirectionsService _directions = DirectionsService();

  GoogleMapController? _mapController;
  LatLng? _draftPosition;
  String _draftAddress = '';
  bool _isGeocoding = false;
  bool _isFinishing = false;
  Timer? _geocodeDebounce;

  @override
  void dispose() {
    _geocodeDebounce?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  double get _pinScreenY {
    final h = MediaQuery.of(context).size.height;
    return _topMapPadding + (h - _topMapPadding - _bottomMapPadding) / 2;
  }

  Future<LatLng?> _readPinLatLng() async {
    final controller = _mapController;
    if (controller == null) return null;
    final w = MediaQuery.of(context).size.width;
    return controller.getLatLng(
      ScreenCoordinate(x: (w / 2).round(), y: _pinScreenY.round()),
    );
  }

  Future<void> _onCameraIdle() async {
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(milliseconds: 350), () async {
      final latLng = await _readPinLatLng();
      if (!mounted || latLng == null) return;
      setState(() {
        _draftPosition = latLng;
        _isGeocoding = true;
      });
      final address = await _reverseGeocode(latLng);
      if (!mounted) return;
      setState(() {
        _draftAddress = address;
        _isGeocoding = false;
      });
    });
  }

  Future<String> _reverseGeocode(LatLng latLng) async {
    try {
      final marks = await placemarkFromCoordinates(
        latLng.latitude,
        latLng.longitude,
      );
      if (marks.isEmpty) return 'Selected location';
      final p = marks.first;
      final parts = [p.name, p.street, p.subLocality, p.locality]
          .whereType<String>()
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim());
      final joined = parts.join(', ');
      return joined.isNotEmpty ? joined : 'Selected location';
    } catch (_) {
      return 'Selected location';
    }
  }

  void _seedFromBooking() {
    final booking = ref.read(rideBookingProvider);
    _draftPosition = booking.pickupLocation;
    _draftAddress = booking.pickupAddress ?? '';
  }

  Future<void> _moveCameraTo(LatLng target) async {
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(target, 17.5),
    );
    await Future.delayed(const Duration(milliseconds: 400));
    await _onCameraIdle();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _seedFromBooking();
      final pos = _draftPosition;
      if (pos != null) await _moveCameraTo(pos);
    });
  }

  Future<void> _confirmStep() async {
    final latLng = await _readPinLatLng();
    if (latLng == null) return;

    final address = _draftAddress.trim().isNotEmpty
        ? _draftAddress.trim()
        : await _reverseGeocode(latLng);

    setState(() => _isFinishing = true);
    ref.read(rideBookingProvider.notifier).setPickupLocation(address, latLng);

    try {
      await _refreshRouteAndFare();
      if (!mounted) return;
      await _continueAfterPin();
    } catch (e) {
      if (mounted) {
        setState(() => _isFinishing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update route: $e')),
        );
      }
    }
  }

  Future<void> _refreshRouteAndFare() async {
    final booking = ref.read(rideBookingProvider);
    final pickup = booking.pickupLocation;
    final drop = booking.destinationLocation;
    if (pickup == null || drop == null) return;

    final waypoints = booking.stops
        .where((s) => s.location != null)
        .map((s) => s.location!)
        .toList();

    final route = await _directions.getRoute(
      origin: pickup,
      destination: drop,
      waypoints: waypoints.isEmpty ? null : waypoints,
    );

    double fare = booking.fare;
    try {
      final pricing = await apiClient.getRidePricing(
        pickupLat: pickup.latitude,
        pickupLng: pickup.longitude,
        dropLat: drop.latitude,
        dropLng: drop.longitude,
        vehicleType: booking.selectedCabTypeId,
        scheduledTime: booking.scheduledTime?.toUtc().toIso8601String(),
        distanceKm: route.distance / 1000,
        durationMin: (route.duration / 60).ceil(),
      );
      final data = pricing['data'] as Map<String, dynamic>? ?? {};
      final total = data['totalFare'] ?? data['total_fare'] ?? data['fare'];
      if (total is num) fare = total.toDouble();
    } catch (_) {
      // Keep previously selected vehicle fare if pricing refresh fails.
    }

    ref.read(rideBookingProvider.notifier).updateRouteInfo(
          pickupLocation: pickup,
          pickupAddress: booking.pickupAddress,
          destinationLocation: drop,
          destinationAddress: booking.destinationAddress,
          distance: route.distance,
          duration: route.duration.toInt(),
          fare: fare,
          polylinePoints: route.points,
        );

    ref.read(rideBookingProvider.notifier).setCabType(
          id: booking.selectedCabTypeId,
          name: booking.selectedCabTypeName,
          fare: fare,
          originalFare: booking.originalFare > 0 ? booking.originalFare : fare,
          subsidyAmount: booking.subsidyAmount,
          isSubsidyApplied: booking.isSubsidyApplied,
          isEcoPickup: booking.isEcoPickup,
          ecoPickupAddress: booking.ecoPickupAddress,
          ecoPickupLocation: booking.ecoPickupLocation,
        );
  }

  Future<void> _continueAfterPin() async {
    switch (widget.flow) {
      case ConfirmLocationFlow.payment:
        if (mounted) context.pushReplacement(AppRoutes.ridePayment);
        break;
      case ConfirmLocationFlow.rescue:
        ref.read(rescueBookingProvider.notifier).reset();
        ref.read(rescueBookingProvider.notifier).prefillFromRideBooking();
        ref.read(rescueBookingProvider.notifier)
            .setVehicleWithYou(widget.vehicleWithYou);
        if (mounted) context.pushReplacement(AppRoutes.rescueLanding);
        break;
    }
  }

  void _onBack() {
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    const pinColor = _pinColor;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: _cream,
        body: Stack(
          children: [
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _draftPosition ??
                    ref.read(rideBookingProvider).pickupLocation ??
                    const LatLng(28.6139, 77.2090),
                zoom: 17.5,
              ),
              onMapCreated: (c) => _mapController = c,
              onCameraIdle: _onCameraIdle,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              padding: const EdgeInsets.only(
                top: _topMapPadding,
                bottom: _bottomMapPadding,
              ),
            ),

            // Center pin
            Positioned(
              left: 0,
              right: 0,
              top: _pinScreenY - 42,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_on, size: 48, color: pinColor),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: pinColor.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Top bar
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _isFinishing ? null : _onBack,
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: _textPrimary,
                    ),
                    Expanded(
                      child: Text(
                        'Confirm pickup location',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom confirm card
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  20,
                  18,
                  20,
                  16 + MediaQuery.paddingOf(context).bottom,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          margin: const EdgeInsets.only(top: 5),
                          decoration: BoxDecoration(
                            color: pinColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _isGeocoding
                              ? Text(
                                  'Finding address…',
                                  style: GoogleFonts.poppins(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: _textSecondary,
                                  ),
                                )
                              : Text(
                                  _draftAddress.isNotEmpty
                                      ? _draftAddress
                                      : 'Move the map to set location',
                                  style: GoogleFonts.poppins(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: _textPrimary,
                                    height: 1.35,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Move the map to place the pin on your exact pickup point',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: _textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: (_isFinishing || _isGeocoding)
                            ? null
                            : _confirmStep,
                        style: FilledButton.styleFrom(
                          backgroundColor: FigmaSlideToBookButton.trackColor,
                          disabledBackgroundColor: FigmaSlideToBookButton.trackColor
                              .withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                        child: _isFinishing
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Confirm pickup & continue',
                                style: GoogleFonts.poppins(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
