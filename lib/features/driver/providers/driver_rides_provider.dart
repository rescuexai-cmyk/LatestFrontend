import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../core/services/api_client.dart';

/// Calculate ETA from distance string (e.g., "1.5 km" -> "5 min away")
/// Assumes average city traffic speed of 20 km/h
String _calculateEtaFromDistance(String distanceStr) {
  final cleanStr = distanceStr.toLowerCase().trim();
  double distanceKm = 0;
  
  if (cleanStr.contains('km')) {
    final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
    distanceKm = double.tryParse(numStr) ?? 0;
  } else if (cleanStr.contains('m')) {
    final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
    distanceKm = (double.tryParse(numStr) ?? 0) / 1000;
  } else {
    distanceKm = double.tryParse(cleanStr.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
  }
  
  if (distanceKm <= 0) return '0 min away';
  
  const avgSpeedKmh = 20.0;
  final etaMinutes = (distanceKm / avgSpeedKmh * 60).ceil();
  
  if (etaMinutes < 1) return '< 1 min away';
  if (etaMinutes == 1) return '1 min away';
  if (etaMinutes >= 60) {
    final hours = etaMinutes ~/ 60;
    final mins = etaMinutes % 60;
    return mins > 0 ? '$hours hr $mins min away' : '$hours hr away';
  }
  return '$etaMinutes min away';
}

// Ride offer model
class RideOffer {
  final String id;
  final String type;
  final double earning;
  final String pickupDistance;
  final String pickupTime;
  final String dropDistance;
  final String dropTime;
  final String pickupAddress;
  final String dropAddress;
  final LatLng? pickupLocation;
  final LatLng? destinationLocation;
  final String? riderName;
  final String? riderPhone;
  final String? riderId; // Passenger user ID for chat
  final String? otp; // OTP for ride verification
  final String paymentMethod; // 'cash' or 'prepaid' (online/wallet)
  final bool isGolden;
  final DateTime createdAt;

  RideOffer({
    required this.id,
    required this.type,
    required this.earning,
    required this.pickupDistance,
    required this.pickupTime,
    required this.dropDistance,
    required this.dropTime,
    required this.pickupAddress,
    required this.dropAddress,
    this.pickupLocation,
    this.destinationLocation,
    this.riderName,
    this.riderPhone,
    this.riderId,
    this.otp,
    this.paymentMethod = 'cash', // Default to cash
    this.isGolden = false,
    required this.createdAt,
  });

  bool get isCashPayment => paymentMethod.toLowerCase() == 'cash';

  /// Parse ride offer from backend response.
  ///
  /// Backend sends two different formats:
  /// 1. REST API (GET /api/rides/available): snake_case fields (pickup_location, etc.)
  /// 2. Socket.io (new-ride-request): camelCase fields (pickupLocation, etc.)
  ///
  /// This factory handles both formats.
  factory RideOffer.fromJson(Map<String, dynamic> json) {
    // Handle both camelCase (socket) and snake_case (REST) field names
    final pickupLoc = json['pickupLocation'] ?? json['pickup_location'];
    final dropLoc = json['dropLocation'] ??
        json['destination_location'] ??
        json['drop_location'];

    // Parse pickup location
    LatLng? pickupLatLng;
    if (pickupLoc is Map) {
      pickupLatLng = LatLng(
        (pickupLoc['lat'] ?? pickupLoc['latitude'] ?? 0).toDouble(),
        (pickupLoc['lng'] ?? pickupLoc['longitude'] ?? 0).toDouble(),
      );
    }

    // Parse drop location
    LatLng? dropLatLng;
    if (dropLoc is Map) {
      dropLatLng = LatLng(
        (dropLoc['lat'] ?? dropLoc['latitude'] ?? 0).toDouble(),
        (dropLoc['lng'] ?? dropLoc['longitude'] ?? 0).toDouble(),
      );
    }

    // Parse addresses - handle both nested (socket) and flat (REST) formats
    String pickupAddr = 'Unknown';
    if (pickupLoc is Map && pickupLoc['address'] != null) {
      pickupAddr = pickupLoc['address'].toString();
    } else if (json['pickup_address'] != null) {
      pickupAddr = json['pickup_address'].toString();
    } else if (json['pickupAddress'] != null) {
      pickupAddr = json['pickupAddress'].toString();
    }

    String dropAddr = 'Unknown';
    if (dropLoc is Map && dropLoc['address'] != null) {
      dropAddr = dropLoc['address'].toString();
    } else if (json['destination_address'] != null) {
      dropAddr = json['destination_address'].toString();
    } else if (json['drop_address'] != null) {
      dropAddr = json['drop_address'].toString();
    } else if (json['dropAddress'] != null) {
      dropAddr = json['dropAddress'].toString();
    }

    // Parse fare - handle both camelCase (socket/SSE) and snake_case (REST) field names
    final fare = (json['estimatedFare'] ??
            json['earning'] ??
            json['fare'] ??
            json['totalFare'] ??
            json['total_fare'] ??
            0)
        .toDouble();

    // Parse rider name - handle both field names
    final riderName = json['passengerName'] ?? json['rider_name'];

    // Parse timestamp
    DateTime createdAt;
    final timestamp =
        json['timestamp'] ?? json['created_at'] ?? json['createdAt'];
    if (timestamp != null) {
      try {
        createdAt = DateTime.parse(timestamp.toString());
      } catch (_) {
        createdAt = DateTime.now();
      }
    } else {
      createdAt = DateTime.now();
    }

    // Parse distance - calculate from coordinates if not provided
    final distance = json['distance'];
    String pickupDistStr = json['pickup_distance'] ?? '0 km';
    String dropDistStr = json['drop_distance'] ?? '0 km';
    if (distance != null && pickupDistStr == '0 km') {
      final distKm = (distance as num).toDouble();
      dropDistStr = '${distKm.toStringAsFixed(1)} km';
    }
    
    // Calculate ETA from distance (average 20 km/h in city traffic)
    String pickupTimeStr = json['pickup_time'] ?? '';
    String dropTimeStr = json['drop_time'] ?? '';
    
    if (pickupTimeStr.isEmpty || pickupTimeStr == '0 min away' || pickupTimeStr == '0 min') {
      pickupTimeStr = _calculateEtaFromDistance(pickupDistStr);
    }
    if (dropTimeStr.isEmpty || dropTimeStr == '0 min away' || dropTimeStr == '0 min') {
      dropTimeStr = _calculateEtaFromDistance(dropDistStr);
    }

    // Parse payment method - handle various field names from backend
    final paymentMethod = (json['paymentMethod'] ??
            json['payment_method'] ??
            json['paymentType'] ??
            'cash')
        .toString()
        .toLowerCase();

    final passenger =
        json['passenger'] is Map ? json['passenger'] as Map : null;
    final riderPhone = (json['rider_phone'] ??
            json['riderPhone'] ??
            json['passenger_phone'] ??
            json['passengerPhone'] ??
            json['phone'] ??
            passenger?['phone'])
        ?.toString();

    return RideOffer(
      id: (json['rideId'] ?? json['id'] ?? '').toString(),
      type: json['vehicleType'] ??
          json['ride_type'] ??
          json['type'] ??
          'Standard',
      earning: fare,
      pickupDistance: pickupDistStr,
      pickupTime: pickupTimeStr,
      dropDistance: dropDistStr,
      dropTime: dropTimeStr,
      pickupAddress: pickupAddr,
      dropAddress: dropAddr,
      pickupLocation: pickupLatLng,
      destinationLocation: dropLatLng,
      riderName: riderName,
      riderPhone: riderPhone,
      riderId: json['passengerId'] ??
          json['passenger_id'] ??
          json['riderId'] ??
          json['rider_id'],
      otp: json['otp']?.toString(), // OTP from REST API (not in socket events)
      paymentMethod: paymentMethod,
      isGolden: json['is_golden'] ?? false,
      createdAt: createdAt,
    );
  }
}

// State for driver rides
class DriverRidesState {
  final List<RideOffer> rideOffers;
  final bool isLoading;
  final String? error;
  final RideOffer? acceptedRide;

  DriverRidesState({
    this.rideOffers = const [],
    this.isLoading = false,
    this.error,
    this.acceptedRide,
  });

  DriverRidesState copyWith({
    List<RideOffer>? rideOffers,
    bool? isLoading,
    String? error,
    RideOffer? acceptedRide,
  }) {
    return DriverRidesState(
      rideOffers: rideOffers ?? this.rideOffers,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      acceptedRide: acceptedRide ?? this.acceptedRide,
    );
  }
}

// Provider notifier
class DriverRidesNotifier extends StateNotifier<DriverRidesState> {
  final ApiClient _apiClient;

  DriverRidesNotifier(this._apiClient) : super(DriverRidesState());

  Future<void> fetchAvailableRides({double? lat, double? lng}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // lat and lng are required by the backend
      final driverLat = lat ?? 28.6139; // Default to Delhi if not provided
      final driverLng = lng ?? 77.2090;

      final response = await _apiClient.getAvailableRides(
        lat: driverLat,
        lng: driverLng,
        radius: 10,
      );

      if (response['success'] == true) {
        // Backend returns: { success, data: { rides: [...], total } }
        final data = response['data'] as Map<String, dynamic>?;
        final ridesJson = data?['rides'] as List<dynamic>? ?? [];
        final rides = ridesJson
            .map((json) => RideOffer.fromJson(json as Map<String, dynamic>))
            .toList();

        debugPrint('Fetched ${rides.length} available rides');
        state = state.copyWith(rideOffers: rides, isLoading: false);
      } else {
        state = state.copyWith(
          isLoading: false,
          error: response['message']?.toString() ?? 'Failed to fetch rides',
        );
      }
    } catch (e) {
      debugPrint('Error fetching rides: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to fetch rides: $e',
      );
    }
  }

  /// Accept a ride as a driver.
  /// Uses POST /api/rides/:id/accept (driver self-accept endpoint).
  /// Handles 409 Conflict when ride is already taken by another driver.
  /// After accepting, updates driver location to pickup location for navigation.
  Future<bool> acceptRide(String rideId, {required String driverId}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Use the new acceptRide endpoint for driver self-accept
      final response = await _apiClient.acceptRide(rideId);

      if (response['success'] == true) {
        // Find the accepted ride and set it
        RideOffer? acceptedRide;
        try {
          acceptedRide = state.rideOffers.firstWhere((r) => r.id == rideId);
        } catch (_) {
          acceptedRide =
              state.rideOffers.isNotEmpty ? state.rideOffers.first : null;
        }

        // Remove accepted ride from available list
        final updatedOffers =
            state.rideOffers.where((r) => r.id != rideId).toList();

        state = state.copyWith(
          rideOffers: updatedOffers,
          acceptedRide: acceptedRide,
          isLoading: false,
        );

        debugPrint('✅ Ride $rideId accepted');

        // Update driver location to pickup location for navigation/tracking
        // This allows the rider to see the driver approaching the pickup point
        if (acceptedRide?.pickupLocation != null) {
          try {
            await _apiClient.updateDriverLocation(
              driverId,
              acceptedRide!.pickupLocation!.latitude,
              acceptedRide.pickupLocation!.longitude,
            );
            debugPrint(
                '📍 Driver location updated to pickup: ${acceptedRide.pickupLocation}');
          } catch (e) {
            // Non-critical - don't fail the accept if location update fails
            debugPrint('⚠️ Failed to update driver location to pickup: $e');
          }
        }

        return true;
      } else {
        // Handle specific error codes
        final code = response['code'] as String?;
        String errorMessage;

        if (code == 'RIDE_ALREADY_TAKEN') {
          errorMessage =
              'This ride has already been accepted by another driver';
          // Remove the ride from available list since it's taken
          final updatedOffers =
              state.rideOffers.where((r) => r.id != rideId).toList();
          state = state.copyWith(
            rideOffers: updatedOffers,
            isLoading: false,
            error: errorMessage,
          );
        } else if (code == 'FORBIDDEN') {
          errorMessage =
              response['message'] ?? 'You are not authorized to accept rides';
          state = state.copyWith(isLoading: false, error: errorMessage);
        } else {
          errorMessage = response['message'] ?? 'Failed to accept ride';
          state = state.copyWith(isLoading: false, error: errorMessage);
        }

        return false;
      }
    } catch (e) {
      debugPrint('❌ Error accepting ride: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to accept ride: $e',
      );
      return false;
    }
  }

  /// Remove a ride from the available list (e.g., when it's taken by another driver)
  void removeRide(String rideId) {
    final updatedOffers =
        state.rideOffers.where((r) => r.id != rideId).toList();
    state = state.copyWith(rideOffers: updatedOffers);
  }

  /// Add a new ride offer (from socket event)
  void addRideOffer(RideOffer offer) {
    // Avoid duplicates
    if (state.rideOffers.any((r) => r.id == offer.id)) return;
    state = state.copyWith(rideOffers: [...state.rideOffers, offer]);
  }

  void clearAcceptedRide() {
    // Must create new state directly — copyWith(acceptedRide: null) keeps old value due to ??
    state = DriverRidesState(
      rideOffers: state.rideOffers,
      isLoading: state.isLoading,
      error: state.error,
      acceptedRide: null,
    );
  }

  /// Hydrate accepted ride from external events (e.g. notification action replay)
  /// while keeping the same active-ride navigation flow in UI.
  void setAcceptedRide(RideOffer ride) {
    final updatedOffers =
        state.rideOffers.where((r) => r.id != ride.id).toList();
    state = DriverRidesState(
      rideOffers: updatedOffers,
      isLoading: false,
      error: null,
      acceptedRide: ride,
    );
  }
}

// Provider
final driverRidesProvider =
    StateNotifierProvider<DriverRidesNotifier, DriverRidesState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DriverRidesNotifier(apiClient);
});
