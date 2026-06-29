import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../core/services/api_client.dart';
import '../../../core/models/ride_stop.dart';
import 'personal_driver_onboarding_provider.dart';

const Duration _offerFreshnessWindow = Duration(seconds: 90);
const Set<String> _allowedIncomingStatuses = {'searching', 'pending'};
const Set<String> _terminalStatuses = {'cancelled', 'completed', 'expired'};

/// Normalizes rider/backend/driver vehicle strings into one comparable slug.
///
/// Returns null when the incoming type is ambiguous (e.g. [standard]) so callers
/// avoid hiding offers the app cannot classify reliably.
String? canonicalVehicleServiceType(String? raw) {
  if (raw == null) return null;
  var t = raw.toLowerCase().trim().replaceAll(RegExp(r'[\s\-]+'), '_');
  if (t.isEmpty) return null;

  // Personal rescue driver (passenger leg — no vehicle)
  if (t == 'personal_driver' ||
      t.contains('personal_driver') ||
      t.contains('personal_rescue')) {
    return 'personal_driver';
  }

  // Two-wheel / rescue (driver onboarding uses `motorbike`, riders use `bike_rescue`)
  if (t.contains('bike_rescue') ||
      t == 'motorbike' ||
      t.contains('motorbike') ||
      (t.contains('bike') && t.contains('rescue')) ||
      t == 'bike' ||
      t == 'motorcycle') {
    return 'bike_rescue';
  }

  // Ambiguous default from some APIs — don't filter on this alone
  if (t == 'standard') return null;

  // Auto / e-rickshaw
  if (t == 'auto' || t.contains('rickshaw') || t.contains('e_rickshaw')) {
    return 'auto';
  }

  // Cab tiers (more specific first)
  if (t.contains('cab_xl') ||
      (t.contains('xl') && (t.contains('cab') || t.contains('commercial')))) {
    return 'cab_xl';
  }
  if (t.contains('cab_premium') ||
      (t.contains('premium') &&
          (t.contains('cab') || t.contains('luxury'))) ||
      (t.contains('suv') && t.contains('premium'))) {
    return 'cab_premium';
  }
  if (t.contains('cab_mini') ||
      t == 'mini' ||
      t.endsWith('_mini') ||
      t.startsWith('mini_') ||
      (t.contains('mini') && t.contains('cab')) ||
      t.contains('hatch')) {
    return 'cab_mini';
  }

  // Private car / generic cab (driver `commercial_car`, generic backend `cab`)
  if (t == 'commercial_car' ||
      t.contains('commercial_car') ||
      (t.contains('commercial') && t.contains('car')) ||
      t == 'sedan' ||
      (t == 'cab' || t == 'car') ||
      (t.contains('cab') &&
          !t.contains('mini') &&
          !t.contains('xl') &&
          !t.contains('premium'))) {
    return 'commercial_car';
  }

  return t;
}

/// Flattens Socket/EventBus envelopes so [RideOffer.fromJson] sees ride fields.
Map<String, dynamic> normalizeRideOfferEventJson(Map<String, dynamic> raw) {
  final merged = Map<String, dynamic>.from(raw);
  final payload = raw['payload'];
  if (payload is Map) {
    for (final entry in Map<String, dynamic>.from(payload as Map).entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
  }
  final nestedRide = raw['ride'];
  if (nestedRide is Map) {
    for (final entry in Map<String, dynamic>.from(nestedRide as Map).entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
  }
  return merged;
}

/// Resolves a ride id from realtime / websocket cancellation payloads.
String? rideIdFromRealtimePayload(Map<String, dynamic> data) {
  final id = data['rideId'] ?? data['ride_id'] ?? data['id'];
  if (id == null) return null;
  final normalized = id.toString().trim();
  return normalized.isEmpty ? null : normalized;
}

/// True when [rideId] refers to the same trip as [offer] (handles rescue leg ids).
bool rideOfferMatchesId(RideOffer? offer, String? rideId) {
  if (offer == null || rideId == null || rideId.isEmpty) return false;
  final normalized = rideId.trim();
  final candidates = <String>{
    offer.id,
    if (offer.userRideId != null && offer.userRideId!.isNotEmpty)
      offer.userRideId!,
    if (offer.vehicleRideId != null && offer.vehicleRideId!.isNotEmpty)
      offer.vehicleRideId!,
    if (offer.linkedActiveRideId != null && offer.linkedActiveRideId!.isNotEmpty)
      offer.linkedActiveRideId!,
  };
  return candidates.contains(normalized);
}

/// Frontend guard: only enqueue offers that match the driver's registered vehicle class.
///
/// Car/cab tiers are grouped (commercial_car drivers receive cab_mini/cab/cab_xl/etc.).
/// When either side is unclassified, returns true (legacy permissive behavior).
@visibleForTesting
bool rideOfferMatchesDriverVehicle(
  String offerVehicleType,
  String? driverRegisteredType,
) {
  if (driverRegisteredType == null ||
      driverRegisteredType.trim().isEmpty) {
    return true;
  }

  final offerCanon = canonicalVehicleServiceType(offerVehicleType);
  if (offerCanon == null) return true;

  final driverCanon = canonicalVehicleServiceType(driverRegisteredType);
  if (driverCanon == null) return true;

  final offerFamily = _vehicleServiceFamily(offerCanon) ?? offerCanon;
  final driverFamily = _vehicleServiceFamily(driverCanon) ?? driverCanon;
  if (offerFamily == driverFamily) return true;

  // Unknown backend slugs: do not block (old APK had no client-side vehicle filter).
  if (!_knownVehicleFamilies.contains(offerFamily) ||
      !_knownVehicleFamilies.contains(driverFamily)) {
    return true;
  }

  return false;
}

/// Personal rescue drivers only receive passenger-leg rescue offers (driver1).
@visibleForTesting
bool rescueOfferMatchesPersonalDriver(RideOffer offer) {
  if (!offer.isRescueRequest) return false;
  final role = offer.rescueRoleNeeded?.toLowerCase();
  if (role == 'driver2') return false;
  return true;
}

/// Ride-share drivers: rescue offers for vehicle/bike leg (driver2) or unassigned dual rescue.
@visibleForTesting
bool rescueOfferMatchesRideShareDriver(
  RideOffer offer,
  String? driverRegisteredType,
) {
  if (!offer.isRescueRequest) return true;
  final role = offer.rescueRoleNeeded?.toLowerCase();
  if (role == 'driver1') return false;
  if (role == 'driver2') return true;
  if (offer.hasVehicle) {
    final canon = canonicalVehicleServiceType(driverRegisteredType);
    return canon == 'bike_rescue' || canon == 'auto';
  }
  return true;
}

/// Whether an incoming offer should be shown to this driver profile.
@visibleForTesting
bool offerMatchesDriverProfile(
  RideOffer offer, {
  required bool isPersonalRescueDriver,
  String? registeredVehicleType,
}) {
  if (isPersonalRescueDriver) {
    return rescueOfferMatchesPersonalDriver(offer);
  }
  if (offer.isRescueRequest) {
    return rescueOfferMatchesRideShareDriver(offer, registeredVehicleType);
  }
  return rideOfferMatchesDriverVehicle(offer.type, registeredVehicleType);
}

const _knownVehicleFamilies = {'two_wheeler', 'auto', 'four_wheel_cab', 'personal_driver'};

String? _vehicleServiceFamily(String canon) {
  switch (canon) {
    case 'bike_rescue':
      return 'two_wheeler';
    case 'auto':
      return 'auto';
    case 'personal_driver':
      return 'personal_driver';
    case 'commercial_car':
    case 'cab_mini':
    case 'cab_xl':
    case 'cab_premium':
      return 'four_wheel_cab';
    default:
      return null;
  }
}

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

/// True for generic backend placeholders that should not override a real name.
bool isPlaceholderRidePassengerName(String? raw) {
  if (raw == null) return true;
  final t = raw.trim().toLowerCase();
  return t.isEmpty ||
      t == 'passenger' ||
      t == 'rider' ||
      t == 'user' ||
      t == 'customer' ||
      t == 'unknown';
}

/// Best display name for the rider from REST/socket-shaped ride JSON.
String? resolveRidePassengerDisplayNameFromRideJson(Map<String, dynamic> json) {
  Map<String, dynamic>? mapFrom(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  final passenger = mapFrom(json['passenger']);
  final rider = mapFrom(json['rider']);
  final user = mapFrom(json['user']);

  String? trimmed(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  String? combinedName(Map<String, dynamic>? m) {
    if (m == null) return null;
    final fn = trimmed(m['firstName']) ?? '';
    final ln = trimmed(m['lastName']) ?? '';
    final c = '$fn $ln'.trim();
    return c.isEmpty ? null : c;
  }

  final candidates = <String?>[
    trimmed(json['passengerName']),
    trimmed(json['passenger_name']),
    trimmed(json['riderName']),
    trimmed(json['rider_name']),
    trimmed(json['customerName']),
    trimmed(json['customer_name']),
    combinedName(passenger),
    combinedName(rider),
    trimmed(passenger?['name']),
    trimmed(passenger?['fullName']),
    trimmed(passenger?['full_name']),
    trimmed(rider?['name']),
    trimmed(rider?['fullName']),
    trimmed(rider?['full_name']),
    trimmed(user?['name']),
    trimmed(user?['fullName']),
    trimmed(user?['full_name']),
  ];

  for (final c in candidates) {
    if (c != null && !isPlaceholderRidePassengerName(c)) return c;
  }
  return null;
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
  final List<RideStop> stops;
  final LatLng? pickupLocation;
  final LatLng? destinationLocation;
  final String? riderName;
  final String? riderPhone;
  final String? riderId; // Passenger user ID for chat
  final String? otp; // OTP for ride verification
  final String paymentMethod; // 'cash' or 'prepaid' (online/wallet)
  final bool isGolden;
  final DateTime createdAt;
  final String status;

  /// Rescue-specific metadata (populated from realtime broadcast or accept API).
  final bool isRescueRequest;
  final bool rescueMultiDriver;
  final int driversNeeded;
  final bool hasVehicle;
  final String? vehicleDropAddress;
  /// Backend [RescueStatus] e.g. PENDING, DRIVER1_ACCEPTED, BOTH_ACCEPTED.
  final String? rescueStatus;
  /// Set after accept: `driver1` or `driver2`.
  final String? rescueDriverRole;
  /// Before accept: which rescue slot this broadcast targets (`driver1` / `driver2`).
  final String? rescueRoleNeeded;
  final String? partnerDriverId;
  final String? partnerDriverName;
  final String? partnerDriverPhone;
  final String? userRideId;
  final String? vehicleRideId;

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
    this.stops = const [],
    this.pickupLocation,
    this.destinationLocation,
    this.riderName,
    this.riderPhone,
    this.riderId,
    this.otp,
    this.paymentMethod = 'cash', // Default to cash
    this.isGolden = false,
    required this.createdAt,
    this.status = 'pending',
    this.isRescueRequest = false,
    this.rescueMultiDriver = false,
    this.driversNeeded = 1,
    this.hasVehicle = false,
    this.vehicleDropAddress,
    this.rescueStatus,
    this.rescueDriverRole,
    this.rescueRoleNeeded,
    this.partnerDriverId,
    this.partnerDriverName,
    this.partnerDriverPhone,
    this.userRideId,
    this.vehicleRideId,
  });

  bool get isCashPayment => paymentMethod.toLowerCase() == 'cash';

  bool get isRescue => isRescueRequest;

  bool get hasIntermediateStops => stops.isNotEmpty;

  int get stopCount => stops.length;

  bool get isWaitingForPartnerDriver =>
      isRescue &&
      hasVehicle &&
      (rescueStatus?.toUpperCase() == 'DRIVER1_ACCEPTED');

  bool get isRescueReadyAtPickup {
    final s = rescueStatus?.toUpperCase();
    return s == 'BOTH_ACCEPTED' ||
        s == 'DRIVERS_EN_ROUTE' ||
        s == 'DRIVERS_ARRIVED';
  }

  /// Ride id for [DriverActiveRideScreen] after OTP verification.
  String? get linkedActiveRideId {
    if (!isRescue) return id;
    if (rescueDriverRole == 'driver2') {
      return vehicleRideId ?? id;
    }
    return userRideId ?? id;
  }

  RideOffer copyWith({
    String? id,
    String? type,
    double? earning,
    String? pickupDistance,
    String? pickupTime,
    String? dropDistance,
    String? dropTime,
    String? pickupAddress,
    String? dropAddress,
    List<RideStop>? stops,
    LatLng? pickupLocation,
    LatLng? destinationLocation,
    String? riderName,
    String? riderPhone,
    String? riderId,
    String? otp,
    String? paymentMethod,
    bool? isGolden,
    DateTime? createdAt,
    String? status,
    bool? isRescueRequest,
    bool? rescueMultiDriver,
    int? driversNeeded,
    bool? hasVehicle,
    String? vehicleDropAddress,
    String? rescueStatus,
    String? rescueDriverRole,
    String? rescueRoleNeeded,
    String? partnerDriverId,
    String? partnerDriverName,
    String? partnerDriverPhone,
    String? userRideId,
    String? vehicleRideId,
  }) {
    return RideOffer(
      id: id ?? this.id,
      type: type ?? this.type,
      earning: earning ?? this.earning,
      pickupDistance: pickupDistance ?? this.pickupDistance,
      pickupTime: pickupTime ?? this.pickupTime,
      dropDistance: dropDistance ?? this.dropDistance,
      dropTime: dropTime ?? this.dropTime,
      pickupAddress: pickupAddress ?? this.pickupAddress,
      dropAddress: dropAddress ?? this.dropAddress,
      stops: stops ?? this.stops,
      pickupLocation: pickupLocation ?? this.pickupLocation,
      destinationLocation: destinationLocation ?? this.destinationLocation,
      riderName: riderName ?? this.riderName,
      riderPhone: riderPhone ?? this.riderPhone,
      riderId: riderId ?? this.riderId,
      otp: otp ?? this.otp,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      isGolden: isGolden ?? this.isGolden,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      isRescueRequest: isRescueRequest ?? this.isRescueRequest,
      rescueMultiDriver: rescueMultiDriver ?? this.rescueMultiDriver,
      driversNeeded: driversNeeded ?? this.driversNeeded,
      hasVehicle: hasVehicle ?? this.hasVehicle,
      vehicleDropAddress: vehicleDropAddress ?? this.vehicleDropAddress,
      rescueStatus: rescueStatus ?? this.rescueStatus,
      rescueDriverRole: rescueDriverRole ?? this.rescueDriverRole,
      rescueRoleNeeded: rescueRoleNeeded ?? this.rescueRoleNeeded,
      partnerDriverId: partnerDriverId ?? this.partnerDriverId,
      partnerDriverName: partnerDriverName ?? this.partnerDriverName,
      partnerDriverPhone: partnerDriverPhone ?? this.partnerDriverPhone,
      userRideId: userRideId ?? this.userRideId,
      vehicleRideId: vehicleRideId ?? this.vehicleRideId,
    );
  }

  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value == 1 || value == '1' || value == 'true') return true;
    return false;
  }

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

    final pickupLatLng = parsePickupLatLngFromJson(json);
    final dropLatLng = parseDropLatLngFromJson(json);

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

    final rawNameFallback =
        (json['passengerName'] ?? json['rider_name'])?.toString().trim();
    final riderName = resolveRidePassengerDisplayNameFromRideJson(json) ??
        (rawNameFallback != null &&
                rawNameFallback.isNotEmpty &&
                !isPlaceholderRidePassengerName(rawNameFallback)
            ? rawNameFallback
            : null);

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

    final status = (json['status'] ??
            json['rideStatus'] ??
            json['ride_status'] ??
            json['requestStatus'] ??
            'pending')
        .toString()
        .toLowerCase();

    final rideType = (json['rideType'] ?? json['ride_type'] ?? '')
        .toString()
        .toUpperCase();
    final isRescueRequest = _parseBool(json['isRescueRequest']) ||
        _parseBool(json['is_rescue_request']) ||
        rideType == 'RESCUE';
    final rescueMultiDriver = _parseBool(json['rescueMultiDriver']) ||
        _parseBool(json['rescue_multi_driver']);
    final hasVehicle = _parseBool(json['hasVehicle']) ||
        _parseBool(json['has_vehicle']) ||
        rescueMultiDriver;
    final driversNeeded = (json['driversNeeded'] ?? json['drivers_needed']) is num
        ? (json['driversNeeded'] ?? json['drivers_needed']).toInt()
        : (hasVehicle ? 2 : 1);
    final vehicleDropAddress =
        json['vehicleDropAddress'] ?? json['vehicle_drop_address'];
    final rescueStatusRaw = json['rescueStatus'] ?? json['rescue_status'];
    final rescueStatus = rescueStatusRaw?.toString();
    final rescueRoleNeededRaw = json['rescueRoleNeeded'] ??
        json['rescue_role_needed'] ??
        json['requiredRescueRole'] ??
        json['required_rescue_role'] ??
        json['driverRoleNeeded'] ??
        json['driver_role_needed'];
    final rescueRoleNeeded = rescueRoleNeededRaw?.toString();

    final riderPhone = (json['rider_phone'] ??
            json['riderPhone'] ??
            json['passenger_phone'] ??
            json['passengerPhone'] ??
            json['phone'] ??
            passenger?['phone'])
        ?.toString();

    final stops = parseRideStopsFromJson(
      json['stops'] ?? json['intermediateStops'] ?? json['waypoints'],
    );

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
      stops: stops,
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
      status: status,
      isRescueRequest: isRescueRequest,
      rescueMultiDriver: rescueMultiDriver,
      driversNeeded: driversNeeded,
      hasVehicle: hasVehicle,
      vehicleDropAddress: vehicleDropAddress?.toString(),
      rescueStatus: rescueStatus,
      rescueRoleNeeded: rescueRoleNeeded,
      userRideId: json['userRideId'] ?? json['user_ride_id']?.toString(),
      vehicleRideId:
          json['vehicleRideId'] ?? json['vehicle_ride_id']?.toString(),
    );
  }
}

/// Applies rescue accept / refresh API payload onto a local [RideOffer].
RideOffer mergeRescuePayloadIntoOffer(
  RideOffer offer,
  Map<String, dynamic> rescue, {
  required String driverId,
}) {
  final status = (rescue['status'] ?? '').toString().toUpperCase();
  final driver1Id = rescue['driver1Id'] ?? rescue['driver1_id'];
  final driver2Id = rescue['driver2Id'] ?? rescue['driver2_id'];
  final driver1 = rescue['driver1'] is Map
      ? Map<String, dynamic>.from(rescue['driver1'] as Map)
      : null;
  final driver2 = rescue['driver2'] is Map
      ? Map<String, dynamic>.from(rescue['driver2'] as Map)
      : null;

  String? role;
  if (driver1Id?.toString() == driverId) {
    role = 'driver1';
  } else if (driver2Id?.toString() == driverId) {
    role = 'driver2';
  }

  String? partnerName;
  String? partnerPhone;
  String? partnerId;
  if (role == 'driver1' && driver2 != null) {
    partnerId = driver2['id']?.toString();
    partnerName = _driverDisplayName(driver2);
    partnerPhone = driver2['phone']?.toString();
  } else if (role == 'driver2' && driver1 != null) {
    partnerId = driver1['id']?.toString();
    partnerName = _driverDisplayName(driver1);
    partnerPhone = driver1['phone']?.toString();
  }

  return offer.copyWith(
    isRescueRequest: true,
    rescueStatus: status.isNotEmpty ? status : offer.rescueStatus,
    rescueDriverRole: role ?? offer.rescueDriverRole,
    hasVehicle: rescue['hasVehicle'] == true || offer.hasVehicle,
    rescueMultiDriver:
        rescue['hasVehicle'] == true || offer.rescueMultiDriver,
    driversNeeded: (rescue['hasVehicle'] == true) ? 2 : 1,
    vehicleDropAddress: rescue['vehicleDropAddress']?.toString() ??
        offer.vehicleDropAddress,
    partnerDriverId: partnerId ?? offer.partnerDriverId,
    partnerDriverName: partnerName ?? offer.partnerDriverName,
    partnerDriverPhone: partnerPhone ?? offer.partnerDriverPhone,
    userRideId: rescue['userRideId']?.toString() ?? offer.userRideId,
    vehicleRideId: rescue['vehicleRideId']?.toString() ?? offer.vehicleRideId,
    otp: rescue['rescueOtp']?.toString() ?? offer.otp,
  );
}

String _driverDisplayName(Map<String, dynamic> driver) {
  final first = driver['firstName']?.toString().trim() ?? '';
  final last = driver['lastName']?.toString().trim() ?? '';
  final combined = '$first $last'.trim();
  return combined.isNotEmpty ? combined : 'Partner driver';
}

/// State for driver rides - Single Offer Card Architecture
/// 
/// Only ONE active offer is shown at a time. Additional offers are queued.
/// This eliminates the tiles UI and provides a focused experience.
class DriverRidesState {
  /// The currently displayed offer (shown as fullscreen/halfscreen card)
  final RideOffer? activeOffer;
  
  /// Queue of pending offers waiting to be shown
  final Queue<RideOffer> pendingOffers;
  
  /// Set of offer IDs that have been declined/dismissed (to filter duplicates)
  final Set<String> dismissedOfferIds;
  
  /// Set of offer IDs we've already seen (to prevent duplicate processing)
  final Set<String> seenOfferIds;
  
  /// Loading state for API calls
  final bool isLoading;
  
  /// Error message from last operation
  final String? error;
  
  /// The ride that has been accepted and is in progress
  final RideOffer? acceptedRide;

  DriverRidesState({
    this.activeOffer,
    Queue<RideOffer>? pendingOffers,
    Set<String>? dismissedOfferIds,
    Set<String>? seenOfferIds,
    this.isLoading = false,
    this.error,
    this.acceptedRide,
  })  : pendingOffers = pendingOffers ?? Queue<RideOffer>(),
        dismissedOfferIds = dismissedOfferIds ?? <String>{},
        seenOfferIds = seenOfferIds ?? <String>{};

  /// Whether there's an active offer to display
  bool get hasActiveOffer => activeOffer != null;
  
  /// Total number of offers (active + pending)
  int get totalOffers => (activeOffer != null ? 1 : 0) + pendingOffers.length;
  
  /// Get visible offers for stack display (max 3: active + up to 2 pending)
  List<RideOffer> get visibleOffers {
    final List<RideOffer> offers = [];
    if (activeOffer != null) {
      offers.add(activeOffer!);
    }
    offers.addAll(pendingOffers.take(2));
    return offers;
  }

  DriverRidesState copyWith({
    RideOffer? activeOffer,
    Queue<RideOffer>? pendingOffers,
    Set<String>? dismissedOfferIds,
    Set<String>? seenOfferIds,
    bool? isLoading,
    String? error,
    RideOffer? acceptedRide,
    bool clearActiveOffer = false,
    bool clearAcceptedRide = false,
  }) {
    return DriverRidesState(
      activeOffer: clearActiveOffer ? null : (activeOffer ?? this.activeOffer),
      pendingOffers: pendingOffers ?? Queue<RideOffer>.from(this.pendingOffers),
      dismissedOfferIds: dismissedOfferIds ?? Set<String>.from(this.dismissedOfferIds),
      seenOfferIds: seenOfferIds ?? Set<String>.from(this.seenOfferIds),
      isLoading: isLoading ?? this.isLoading,
      error: error,
      acceptedRide: clearAcceptedRide ? null : (acceptedRide ?? this.acceptedRide),
    );
  }
}

/// Provider notifier for driver rides - Single Offer Card Architecture
class DriverRidesNotifier extends StateNotifier<DriverRidesState> {
  final ApiClient _apiClient;

  /// From [driverOnboardingProvider] or personal driver flow.
  String? _registeredDriverVehicleType;
  bool _isPersonalRescueDriver = false;

  DriverRidesNotifier(this._apiClient) : super(DriverRidesState());

  void setRegisteredDriverVehicleType(String? type) {
    final t = type?.trim();
    final next = (t == null || t.isEmpty) ? null : t;
    if (next == _registeredDriverVehicleType) return;
    _registeredDriverVehicleType = next;
    debugPrint('🚕 Driver rides filter vehicle: $_registeredDriverVehicleType');
  }

  void setPersonalRescueDriverMode(bool enabled) {
    if (_isPersonalRescueDriver == enabled) return;
    _isPersonalRescueDriver = enabled;
    if (enabled) {
      _registeredDriverVehicleType = PersonalDriverOnboardingState.vehicleTypeId;
    }
    debugPrint('🚕 Personal rescue driver mode: $_isPersonalRescueDriver');
  }

  bool _isOfferStatusValid(RideOffer offer) {
    final status = offer.status.toLowerCase();
    if (_terminalStatuses.contains(status)) return false;
    return _allowedIncomingStatuses.contains(status);
  }

  bool _isOfferFresh(RideOffer offer, {Duration maxAge = _offerFreshnessWindow}) {
    final age = DateTime.now().difference(offer.createdAt);
    return age.inSeconds <= maxAge.inSeconds;
  }

  bool _isOfferValid(RideOffer offer, {Duration maxAge = _offerFreshnessWindow}) {
    return _isOfferStatusValid(offer) && _isOfferFresh(offer, maxAge: maxAge);
  }

  /// Fetch available rides from backend and populate the offer queue
  Future<void> fetchAvailableRides({double? lat, double? lng}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final driverLat = lat ?? 28.6139;
      final driverLng = lng ?? 77.2090;

      final response = await _apiClient.getAvailableRides(
        lat: driverLat,
        lng: driverLng,
        radius: 10,
      );

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>?;
        final ridesJson = data?['rides'] as List<dynamic>? ?? [];
        final rides = ridesJson
            .map((json) => RideOffer.fromJson(json as Map<String, dynamic>))
            .toList();

        final validRides = rides.where((offer) => _isOfferValid(offer)).toList();

        debugPrint(
            'Fetched ${rides.length} available rides, valid=${validRides.length}');
        
        // Process fetched rides through the offer flow
        for (final ride in validRides) {
          _processIncomingOffer(ride);
        }
        
        state = state.copyWith(isLoading: false);
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

  /// Process a new incoming offer (from socket, SSE, push, or REST)
  /// 
  /// Flow:
  /// - If offer was dismissed, ignore
  /// - If offer was already seen, ignore (prevents duplicates)
  /// - If no activeOffer, set as activeOffer
  /// - Else, add to pendingOffers queue
  ///
  /// Returns false if the offer was ignored (stale, dismissed, duplicate, etc.).
  bool _processIncomingOffer(RideOffer offer) {
    if (!_isOfferValid(offer)) {
      debugPrint(
          '🧹 Ignoring stale/invalid offer ${offer.id} (status=${offer.status}, age=${DateTime.now().difference(offer.createdAt).inSeconds}s)');
      return false;
    }

    // Skip offers that don't match this driver's profile (vehicle class / rescue role).
    if (!offerMatchesDriverProfile(
      offer,
      isPersonalRescueDriver: _isPersonalRescueDriver,
      registeredVehicleType: _registeredDriverVehicleType,
    )) {
      debugPrint(
          '🛑 Offer ${offer.id} filtered (type=${offer.type}, rescue=${offer.isRescueRequest}, role=${offer.rescueRoleNeeded}, personal=$_isPersonalRescueDriver)');
      return false;
    }

    // Skip if already dismissed
    if (state.dismissedOfferIds.contains(offer.id)) {
      debugPrint('🚫 Offer ${offer.id} was dismissed, ignoring');
      return false;
    }
    
    // Skip if already seen (duplicate prevention)
    if (state.seenOfferIds.contains(offer.id)) {
      debugPrint('🔄 Offer ${offer.id} already seen, ignoring duplicate');
      return false;
    }
    
    // Skip if this is the current active offer
    if (state.activeOffer?.id == offer.id) {
      debugPrint('🔄 Offer ${offer.id} is already active, ignoring');
      return false;
    }
    
    // Skip if already in pending queue
    if (state.pendingOffers.any((o) => o.id == offer.id)) {
      debugPrint('🔄 Offer ${offer.id} already in queue, ignoring');
      return false;
    }
    
    // Mark as seen
    final newSeenIds = Set<String>.from(state.seenOfferIds)..add(offer.id);
    
    if (state.activeOffer == null) {
      // No active offer - show this one immediately
      debugPrint('✅ Setting offer ${offer.id} as active offer');
      state = state.copyWith(
        activeOffer: offer,
        seenOfferIds: newSeenIds,
      );
    } else {
      // Already have an active offer - queue this one
      debugPrint('📥 Queuing offer ${offer.id} (active: ${state.activeOffer!.id})');
      final newQueue = Queue<RideOffer>.from(state.pendingOffers)..add(offer);
      state = state.copyWith(
        pendingOffers: newQueue,
        seenOfferIds: newSeenIds,
      );
    }
    return true;
  }

  /// Add a new ride offer (from socket/SSE/push event)
  /// Public API for external callers
  ///
  /// Returns false when the offer was discarded (duplicate, stale, or vehicle mismatch).
  bool addRideOffer(RideOffer offer) {
    cleanupStaleOffers();
    return _processIncomingOffer(offer);
  }

  /// Decline the current active offer
  /// 
  /// Flow:
  /// 1. Add to dismissedOfferIds
  /// 2. Clear activeOffer
  /// 3. Promote next offer from queue (if any)
  void declineActiveOffer() {
    final currentOffer = state.activeOffer;
    if (currentOffer == null) {
      debugPrint('⚠️ No active offer to decline');
      return;
    }
    
    debugPrint('❌ Declining offer ${currentOffer.id}');
    
    // Add to dismissed set
    final newDismissedIds = Set<String>.from(state.dismissedOfferIds)
      ..add(currentOffer.id);
    
    // Promote next offer from queue
    RideOffer? nextOffer;
    final newQueue = Queue<RideOffer>.from(state.pendingOffers);
    if (newQueue.isNotEmpty) {
      nextOffer = newQueue.removeFirst();
      debugPrint('📤 Promoting next offer ${nextOffer.id} from queue');
    }
    
    state = state.copyWith(
      activeOffer: nextOffer,
      pendingOffers: newQueue,
      dismissedOfferIds: newDismissedIds,
      clearActiveOffer: nextOffer == null,
    );
  }

  /// Remove a specific offer by ID (e.g., when taken by another driver)
  /// 
  /// Handles both active offer and pending queue
  void removeRide(String rideId) {
    debugPrint('🗑️ Removing ride $rideId');
    
    // Add to dismissed to prevent re-adding
    final newDismissedIds = Set<String>.from(state.dismissedOfferIds)
      ..add(rideId);

    final clearAccepted =
        rideOfferMatchesId(state.acceptedRide, rideId);
    
    if (state.activeOffer?.id == rideId) {
      // Active offer was removed - promote next from queue
      RideOffer? nextOffer;
      final newQueue = Queue<RideOffer>.from(state.pendingOffers);
      if (newQueue.isNotEmpty) {
        nextOffer = newQueue.removeFirst();
        debugPrint('📤 Active offer removed, promoting ${nextOffer.id}');
      }
      
      state = state.copyWith(
        activeOffer: nextOffer,
        pendingOffers: newQueue,
        dismissedOfferIds: newDismissedIds,
        clearActiveOffer: nextOffer == null,
        clearAcceptedRide: clearAccepted,
      );
    } else {
      // Remove from pending queue
      final newQueue = Queue<RideOffer>.from(state.pendingOffers)
        ..removeWhere((o) => o.id == rideId);
      
      state = state.copyWith(
        pendingOffers: newQueue,
        dismissedOfferIds: newDismissedIds,
        clearAcceptedRide: clearAccepted,
      );
    }
  }

  /// Handle offer expiry (timeout)
  /// 
  /// Same as decline but triggered by timer
  void handleOfferExpiry(String rideId) {
    debugPrint('⏰ Offer $rideId expired');
    
    if (state.activeOffer?.id == rideId) {
      declineActiveOffer();
    } else {
      // Remove from pending queue
      final newQueue = Queue<RideOffer>.from(state.pendingOffers)
        ..removeWhere((o) => o.id == rideId);
      
      final newDismissedIds = Set<String>.from(state.dismissedOfferIds)
        ..add(rideId);
      
      state = state.copyWith(
        pendingOffers: newQueue,
        dismissedOfferIds: newDismissedIds,
      );
    }
  }

  /// Accept an incoming offer — routes to rescue or standard ride API.
  Future<bool> acceptOffer(RideOffer offer, {required String driverId}) async {
    if (offer.isRescue) {
      return acceptRescueOffer(offer, driverId: driverId);
    }
    return acceptRide(offer.id, driverId: driverId);
  }

  /// Accept a rescue request as an assigned driver (driver1 and/or driver2).
  Future<bool> acceptRescueOffer(
    RideOffer offer, {
    required String driverId,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.acceptRescueRequest(offer.id);

      if (response['success'] == true) {
        final rescueRaw = response['data'];
        final rescue = rescueRaw is Map
            ? Map<String, dynamic>.from(rescueRaw as Map)
            : <String, dynamic>{};

        var acceptedRide = mergeRescuePayloadIntoOffer(
          offer,
          rescue,
          driverId: driverId,
        );

        debugPrint(
          '✅ Rescue ${offer.id} accepted as ${acceptedRide.rescueDriverRole} '
          '(status=${acceptedRide.rescueStatus})',
        );

        state = DriverRidesState(
          activeOffer: null,
          pendingOffers: Queue<RideOffer>(),
          dismissedOfferIds: state.dismissedOfferIds,
          seenOfferIds: state.seenOfferIds,
          isLoading: false,
          error: null,
          acceptedRide: acceptedRide,
        );

        if (acceptedRide.pickupLocation != null) {
          try {
            await _apiClient.updateDriverLocation(
              driverId,
              acceptedRide.pickupLocation!.latitude,
              acceptedRide.pickupLocation!.longitude,
            );
          } catch (e) {
            debugPrint('⚠️ Failed to update driver location after rescue accept: $e');
          }
        }

        return true;
      }

      final code = response['code'] as String?;
      String errorMessage;

      if (code == 'ALREADY_ACCEPTED') {
        errorMessage = response['message']?.toString() ??
            'This rescue has already been fully assigned';
        removeRide(offer.id);
      } else if (code == 'FORBIDDEN') {
        errorMessage = response['message']?.toString() ??
            'You are not authorized to accept rescue requests';
      } else {
        errorMessage =
            response['message']?.toString() ?? 'Failed to accept rescue';
      }

      state = state.copyWith(isLoading: false, error: errorMessage);
      return false;
    } catch (e) {
      debugPrint('❌ Error accepting rescue: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to accept rescue: $e',
      );
      return false;
    }
  }

  /// Refresh active rescue job from GET /api/rescue/:id (polling while waiting).
  Future<bool> refreshAcceptedRescue({required String driverId}) async {
    final current = state.acceptedRide;
    if (current == null || !current.isRescue) return false;

    try {
      final response = await _apiClient.getRescueRequest(current.id);
      if (response['success'] != true) return false;
      final rescueRaw = response['data'];
      if (rescueRaw is! Map) return false;

      final updated = mergeRescuePayloadIntoOffer(
        current,
        Map<String, dynamic>.from(rescueRaw as Map),
        driverId: driverId,
      );
      state = state.copyWith(acceptedRide: updated);
      return true;
    } catch (e) {
      debugPrint('⚠️ Rescue refresh failed: $e');
      return false;
    }
  }

  /// Update accepted rescue after a driver action (en route, arrived, OTP).
  void updateAcceptedRescue(RideOffer updated) {
    if (state.acceptedRide?.id != updated.id) return;
    state = state.copyWith(acceptedRide: updated);
  }

  /// Transition from rescue pre-OTP job to linked active ride after OTP verify.
  void promoteRescueToLinkedRide(RideOffer rescueOffer) {
    final linkedId = rescueOffer.linkedActiveRideId;
    if (linkedId == null || linkedId.isEmpty) return;

    final promoted = rescueOffer.copyWith(
      id: linkedId,
      status: 'ride_started',
    );
    state = state.copyWith(acceptedRide: promoted);
  }

  /// Merge backend ride payload onto the accepted offer (e.g. after GET /api/rides/:id).
  void patchAcceptedRide(RideOffer updated) {
    if (state.acceptedRide?.id != updated.id) return;
    state = state.copyWith(acceptedRide: updated);
  }

  /// Accept a ride as a driver
  /// 
  /// Flow:
  /// 1. Call backend accept API
  /// 2. Clear activeOffer
  /// 3. Clear pendingOffers (important to avoid stale offers)
  /// 4. Set acceptedRide
  Future<bool> acceptRide(String rideId, {required String driverId}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.acceptRide(rideId);

      if (response['success'] == true) {
        RideOffer? acceptedRide;
        if (state.activeOffer?.id == rideId) {
          acceptedRide = state.activeOffer;
        } else {
          for (final o in state.pendingOffers) {
            if (o.id == rideId) {
              acceptedRide = o;
              break;
            }
          }
        }

        final responseData = response['data'];
        if (responseData is Map) {
          final merged = Map<String, dynamic>.from(responseData);
          final prior = acceptedRide;
          if (prior != null) {
            merged.putIfAbsent('rideId', () => prior.id);
            merged.putIfAbsent('id', () => prior.id);
            merged.putIfAbsent('pickupAddress', () => prior.pickupAddress);
            merged.putIfAbsent('dropAddress', () => prior.dropAddress);
            if (prior.stops.isNotEmpty && !merged.containsKey('stops')) {
              merged['stops'] = prior.stops.map((s) => s.toApiJson()).toList();
            }
          }
          try {
            acceptedRide = RideOffer.fromJson(merged);
          } catch (e) {
            debugPrint('⚠️ Could not merge accept response into offer: $e');
          }
        }

        if (acceptedRide == null) {
          state = state.copyWith(
            isLoading: false,
            error: 'Ride accepted but offer details were lost',
          );
          return false;
        }

        debugPrint('✅ Ride $rideId accepted');
        if (acceptedRide.stops.isNotEmpty) {
          debugPrint('   Multi-stop trip: ${acceptedRide.stopCount} stop(s)');
        }

        // Clear all offers on accept
        state = DriverRidesState(
          activeOffer: null,
          pendingOffers: Queue<RideOffer>(),
          dismissedOfferIds: state.dismissedOfferIds,
          seenOfferIds: state.seenOfferIds,
          isLoading: false,
          error: null,
          acceptedRide: acceptedRide,
        );

        // Update driver location to pickup
        if (acceptedRide.pickupLocation != null) {
          try {
            await _apiClient.updateDriverLocation(
              driverId,
              acceptedRide.pickupLocation!.latitude,
              acceptedRide.pickupLocation!.longitude,
            );
            debugPrint('📍 Driver location updated to pickup');
          } catch (e) {
            debugPrint('⚠️ Failed to update driver location: $e');
          }
        }

        return true;
      } else {
        final code = response['code'] as String?;
        String errorMessage;

        if (code == 'RIDE_ALREADY_TAKEN') {
          errorMessage = 'This ride has already been accepted by another driver';
          // Remove the ride since it's taken
          removeRide(rideId);
        } else if (code == 'FORBIDDEN') {
          errorMessage = response['message'] ?? 'You are not authorized to accept rides';
        } else {
          errorMessage = response['message'] ?? 'Failed to accept ride';
        }

        state = state.copyWith(isLoading: false, error: errorMessage);
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

  /// Clear the accepted ride (after ride completion or cancellation)
  void clearAcceptedRide() {
    state = state.copyWith(clearAcceptedRide: true);
  }

  /// Set accepted ride from external source (e.g., notification action)
  void setAcceptedRide(RideOffer ride) {
    // Clear all offers when setting accepted ride
    state = DriverRidesState(
      activeOffer: null,
      pendingOffers: Queue<RideOffer>(),
      dismissedOfferIds: state.dismissedOfferIds,
      seenOfferIds: state.seenOfferIds,
      isLoading: false,
      error: null,
      acceptedRide: ride,
    );
  }

  /// Clear all offers (used when going offline)
  void clearAllOffers() {
    state = state.copyWith(
      clearActiveOffer: true,
      pendingOffers: Queue<RideOffer>(),
    );
  }

  /// Full reset for fresh login/session or when explicitly discarding all driver-ride memory.
  ///
  /// When [preserveAcceptedRide] is true, only offer-queue / seen / loading state is cleared
  /// so a driver returning to [DriverHomeScreen] can still resume an in-progress trip card.
  /// Callers that must wipe everything (logout) pass [preserveAcceptedRide]: false (default).
  void resetForNewSession({bool preserveAcceptedRide = false}) {
    if (preserveAcceptedRide) {
      final ride = state.acceptedRide;
      state = DriverRidesState(acceptedRide: ride);
      debugPrint(
        '🧼 Driver offer state reset (preserved accepted ride id=${ride?.id})',
      );
    } else {
      state = DriverRidesState();
      debugPrint('🧼 Driver offer state reset for new session');
    }
  }

  /// Reset dismissed IDs (used when going online fresh)
  void resetDismissedOffers() {
    state = state.copyWith(
      dismissedOfferIds: <String>{},
      seenOfferIds: <String>{},
    );
  }

  /// Marks an offer as rejected without changing active card selection.
  void markOfferRejected(String rideId) {
    final dismissed = Set<String>.from(state.dismissedOfferIds)..add(rideId);
    state = state.copyWith(dismissedOfferIds: dismissed);
  }

  /// Removes stale/invalid offers from active and pending queues.
  void cleanupStaleOffers({Duration? maxAge}) {
    final ageLimit = maxAge ?? _offerFreshnessWindow;
    final active = state.activeOffer;
    final pending = Queue<RideOffer>.from(state.pendingOffers);
    final dismissed = Set<String>.from(state.dismissedOfferIds);

    RideOffer? nextActive = active;
    if (active != null && !_isOfferValid(active, maxAge: ageLimit)) {
      dismissed.add(active.id);
      nextActive = null;
    }

    pending.removeWhere((offer) {
      final invalid = !_isOfferValid(offer, maxAge: ageLimit);
      if (invalid) dismissed.add(offer.id);
      return invalid;
    });

    if (nextActive == null && pending.isNotEmpty) {
      nextActive = pending.removeFirst();
    }

    state = state.copyWith(
      activeOffer: nextActive,
      pendingOffers: pending,
      dismissedOfferIds: dismissed,
      clearActiveOffer: nextActive == null,
    );
  }
}

// Provider
final driverRidesProvider =
    StateNotifierProvider<DriverRidesNotifier, DriverRidesState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DriverRidesNotifier(apiClient);
});
