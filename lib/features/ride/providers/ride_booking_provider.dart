import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A stop between pickup and destination (Ola/Uber/Rapido style)
class RideStop {
  final String address;
  final LatLng location;
  const RideStop({required this.address, required this.location});
}

/// State class to hold ride booking information
class RideBookingState {
  final String? rideId;
  final String? rideOtp; // OTP for ride verification (share with driver)
  final String? pickupAddress;
  final String? destinationAddress;
  final LatLng? pickupLocation;
  final LatLng? destinationLocation;
  final List<RideStop> stops; // Intermediate stops between pickup and destination
  final String distanceText;
  final String durationText;
  final double distance; // in meters
  final int duration; // in seconds
  final double fare;
  final int selectedRideType; // Index of selected cab type
  final String selectedCabTypeId; // ID of selected cab type (auto, cab_mini, cab_xl, cab_premium)
  final String selectedCabTypeName; // Display name of selected cab type
  final int driverCount;
  final List<LatLng> polylinePoints;

  const RideBookingState({
    this.rideId,
    this.rideOtp,
    this.pickupAddress,
    this.destinationAddress,
    this.pickupLocation,
    this.destinationLocation,
    this.stops = const [],
    this.distanceText = '',
    this.durationText = '',
    this.distance = 0,
    this.duration = 0,
    this.fare = 0,
    this.selectedRideType = 0,
    this.selectedCabTypeId = 'bike_rescue',
    this.selectedCabTypeName = 'Bike Rescue',
    this.driverCount = 1,
    this.polylinePoints = const [],
  });

  RideBookingState copyWith({
    String? rideId,
    String? rideOtp,
    String? pickupAddress,
    String? destinationAddress,
    LatLng? pickupLocation,
    LatLng? destinationLocation,
    List<RideStop>? stops,
    String? distanceText,
    String? durationText,
    double? distance,
    int? duration,
    double? fare,
    int? selectedRideType,
    String? selectedCabTypeId,
    String? selectedCabTypeName,
    int? driverCount,
    List<LatLng>? polylinePoints,
  }) {
    return RideBookingState(
      rideId: rideId ?? this.rideId,
      rideOtp: rideOtp ?? this.rideOtp,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      destinationAddress: destinationAddress ?? this.destinationAddress,
      pickupLocation: pickupLocation ?? this.pickupLocation,
      destinationLocation: destinationLocation ?? this.destinationLocation,
      stops: stops ?? this.stops,
      distanceText: distanceText ?? this.distanceText,
      durationText: durationText ?? this.durationText,
      distance: distance ?? this.distance,
      duration: duration ?? this.duration,
      fare: fare ?? this.fare,
      selectedRideType: selectedRideType ?? this.selectedRideType,
      selectedCabTypeId: selectedCabTypeId ?? this.selectedCabTypeId,
      selectedCabTypeName: selectedCabTypeName ?? this.selectedCabTypeName,
      driverCount: driverCount ?? this.driverCount,
      polylinePoints: polylinePoints ?? this.polylinePoints,
    );
  }
}

/// Notifier to manage ride booking state
class RideBookingNotifier extends StateNotifier<RideBookingState> {
  RideBookingNotifier() : super(const RideBookingState());

  void setPickupLocation(String address, LatLng location) {
    state = state.copyWith(
      pickupAddress: address,
      pickupLocation: location,
    );
  }

  void setDestinationLocation(String address, LatLng location) {
    state = state.copyWith(
      destinationAddress: address,
      destinationLocation: location,
    );
  }

  void setStops(List<RideStop> stops) {
    state = state.copyWith(stops: stops);
  }

  void addStop(String address, LatLng location) {
    state = state.copyWith(
      stops: [...state.stops, RideStop(address: address, location: location)],
    );
  }

  void removeStopAt(int index) {
    if (index < 0 || index >= state.stops.length) return;
    state = state.copyWith(
      stops: [...state.stops]..removeAt(index),
    );
  }

  void updateStopAt(int index, String address, LatLng location) {
    if (index < 0 || index >= state.stops.length) return;
    final updated = [...state.stops];
    updated[index] = RideStop(address: address, location: location);
    state = state.copyWith(stops: updated);
  }

  void updateRouteInfo({
    LatLng? pickupLocation,
    String? pickupAddress,
    LatLng? destinationLocation,
    String? destinationAddress,
    double? distance,
    int? duration,
    double? fare,
    List<LatLng>? polylinePoints,
  }) {
    // Format distance text
    String distanceText = '';
    if (distance != null) {
      if (distance >= 1000) {
        distanceText = '${(distance / 1000).toStringAsFixed(1)} km';
      } else {
        distanceText = '${distance.toInt()} m';
      }
    }
    
    // Format duration text
    String durationText = '';
    if (duration != null) {
      if (duration >= 3600) {
        final hours = duration ~/ 3600;
        final minutes = (duration % 3600) ~/ 60;
        durationText = '${hours}h ${minutes}min';
      } else {
        durationText = '${(duration / 60).ceil()} min';
      }
    }
    
    state = state.copyWith(
      pickupLocation: pickupLocation,
      pickupAddress: pickupAddress,
      destinationLocation: destinationLocation,
      destinationAddress: destinationAddress,
      distance: distance,
      duration: duration,
      fare: fare,
      distanceText: distanceText,
      durationText: durationText,
      polylinePoints: polylinePoints,
    );
  }

  void setRideType(int type) {
    state = state.copyWith(selectedRideType: type);
  }

  void setCabType({required String id, required String name, required double fare}) {
    state = state.copyWith(
      selectedCabTypeId: id,
      selectedCabTypeName: name,
      fare: fare,
    );
  }

  void setDriverCount(int count) {
    state = state.copyWith(driverCount: count);
  }

  void setRideId(String rideId) {
    state = state.copyWith(rideId: rideId);
  }

  void setRideOtp(String otp) {
    state = state.copyWith(rideOtp: otp);
  }

  void setRideDetails({String? rideId, String? otp}) {
    state = state.copyWith(rideId: rideId, rideOtp: otp);
  }

  void reset() {
    state = const RideBookingState();
  }

  /// Clear ride ID and OTP only — keep pickup, drop, fare, cab type for a new search.
  /// Use when driver cancels (before OTP) so user can search again with same booking.
  void clearRideOnly() {
    state = RideBookingState(
      rideId: null,
      rideOtp: null,
      pickupAddress: state.pickupAddress,
      destinationAddress: state.destinationAddress,
      pickupLocation: state.pickupLocation,
      destinationLocation: state.destinationLocation,
      stops: state.stops,
      distanceText: state.distanceText,
      durationText: state.durationText,
      distance: state.distance,
      duration: state.duration,
      fare: state.fare,
      selectedRideType: state.selectedRideType,
      selectedCabTypeId: state.selectedCabTypeId,
      selectedCabTypeName: state.selectedCabTypeName,
      driverCount: state.driverCount,
      polylinePoints: state.polylinePoints,
    );
  }
}

/// Provider for ride booking state
final rideBookingProvider = StateNotifierProvider<RideBookingNotifier, RideBookingState>(
  (ref) => RideBookingNotifier(),
);
