import 'package:equatable/equatable.dart';
import 'location.dart';
import 'driver.dart';
import 'vehicle.dart';

enum RideStatus {
  requested,
  accepted,
  arriving,
  driverArriving,
  inProgress,
  completed,
  cancelled,
}

enum PaymentMethod { cash, card, upi, wallet, digitalWallet }

class Ride extends Equatable {
  final String id;
  final String riderId;
  final String? driverId;
  final AddressLocation pickupLocation;
  final AddressLocation destinationLocation;
  final RideStatus status;
  final double fare;
  final double distance;
  final int estimatedDuration;
  final String rideType;
  final PaymentMethod paymentMethod;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final double? rating;
  final String? notes;
  final Driver? driver;
  final Map<String, dynamic>? fareBreakdown;

  const Ride({
    required this.id,
    required this.riderId,
    this.driverId,
    required this.pickupLocation,
    required this.destinationLocation,
    required this.status,
    required this.fare,
    required this.distance,
    required this.estimatedDuration,
    required this.rideType,
    required this.paymentMethod,
    required this.createdAt,
    this.acceptedAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.rating,
    this.notes,
    this.driver,
    this.fareBreakdown,
  });

  /// Parse ride from backend response.
  /// Backend returns camelCase fields:
  /// { id, passengerId, driverId, pickupLat, pickupLng, dropLat, dropLng,
  ///   pickupAddress, dropAddress, distance, duration, baseFare, distanceFare,
  ///   timeFare, surgeMultiplier, totalFare, status, paymentMethod, paymentStatus,
  ///   scheduledAt, startedAt, completedAt, cancelledAt, cancellationReason,
  ///   createdAt, updatedAt, driver? }
  factory Ride.fromJson(Map<String, dynamic> json) {
    // Parse pickup location - handle both formats
    AddressLocation pickupLoc;
    if (json['pickup_location'] is Map<String, dynamic>) {
      pickupLoc = AddressLocation.fromJson(json['pickup_location'] as Map<String, dynamic>);
    } else {
      pickupLoc = AddressLocation(
        latitude: _toDouble(json['pickupLat'] ?? json['pickupLatitude'] ?? 0),
        longitude: _toDouble(json['pickupLng'] ?? json['pickupLongitude'] ?? 0),
        address: json['pickupAddress'] as String? ?? json['pickup_address'] as String? ?? 'Unknown pickup',
      );
    }

    // Parse destination location - handle both formats
    AddressLocation destLoc;
    if (json['destination_location'] is Map<String, dynamic>) {
      destLoc = AddressLocation.fromJson(json['destination_location'] as Map<String, dynamic>);
    } else if (json['dropoff_location'] is Map<String, dynamic>) {
      destLoc = AddressLocation.fromJson(json['dropoff_location'] as Map<String, dynamic>);
    } else {
      destLoc = AddressLocation(
        latitude: _toDouble(json['dropLat'] ?? json['dropLatitude'] ?? 0),
        longitude: _toDouble(json['dropLng'] ?? json['dropLongitude'] ?? 0),
        address: json['dropAddress'] as String? ?? json['destination_address'] as String? ?? 'Unknown destination',
      );
    }

    // Parse driver from backend format
    Driver? driver;
    if (json['driver'] is Map<String, dynamic>) {
      final driverJson = json['driver'] as Map<String, dynamic>;
      
      // Parse driver's current location
      LocationCoordinate? driverCurrentLocation;
      if (driverJson['current_location'] is Map<String, dynamic>) {
        final locJson = driverJson['current_location'] as Map<String, dynamic>;
        final lat = (locJson['lat'] as num?)?.toDouble() ?? (locJson['latitude'] as num?)?.toDouble();
        final lng = (locJson['lng'] as num?)?.toDouble() ?? (locJson['longitude'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          driverCurrentLocation = LocationCoordinate(lat: lat, lng: lng);
        }
      }
      
      driver = Driver(
        id: driverJson['id'] as String? ?? '',
        name: _buildDriverName(driverJson),
        phone: _extractDriverPhone(driverJson),
        rating: _toDouble(driverJson['rating'] ?? 4.0),
        vehicleInfo: driverJson['vehicleNumber'] != null || driverJson['vehicleModel'] != null
            ? VehicleInfo(
                make: driverJson['vehicleModel']?.toString().split(' ').first,
                model: driverJson['vehicleModel'] as String?,
                plateNumber: driverJson['vehicleNumber'] as String? ?? '',
                color: driverJson['vehicleColor'] as String? ?? 'Unknown',
                type: 'economy',
              )
            : null,
        avatar: driverJson['profileImage'] as String?,
        currentLocation: driverCurrentLocation,
        heading: (driverJson['current_location']?['heading'] as num?)?.toDouble(),
      );
    }

    // Parse dates safely
    DateTime createdAt;
    try {
      final raw = json['createdAt'] ?? json['created_at'];
      createdAt = raw != null ? DateTime.parse(raw.toString()) : DateTime.now();
    } catch (_) {
      createdAt = DateTime.now();
    }

    // Parse fare breakdown from backend
    Map<String, dynamic>? fareBreakdown;
    if (json['breakdown'] is Map<String, dynamic>) {
      fareBreakdown = json['breakdown'] as Map<String, dynamic>;
    } else if (json['fareBreakdown'] is Map<String, dynamic>) {
      fareBreakdown = json['fareBreakdown'] as Map<String, dynamic>;
    } else {
      fareBreakdown = {
        'startingFee': _toDouble(json['baseFare'] ?? 30),
        'ratePerKm': 12.0,
        'ratePerMin': 1.5,
        'distanceFare': _toDouble(json['distanceFare'] ?? 0),
        'timeFare': _toDouble(json['timeFare'] ?? 0),
        'dynamicMultiplier': _toDouble(json['surgeMultiplier'] ?? 1.0),
        'tolls': _toDouble(json['tolls'] ?? 0),
        'airportCharge': _toDouble(json['airportCharge'] ?? 0),
        'waitingCharge': _toDouble(json['waitingCharge'] ?? 0),
        'parkingFees': _toDouble(json['parkingFees'] ?? 0),
        'extraStopsCharge': _toDouble(json['extraStopsCharge'] ?? 0),
        'discount': _toDouble(json['discount'] ?? 0),
        'gstPercent': 5.0,
        'gstAmount': _toDouble(json['gstAmount'] ?? 0),
        'minimumFareApplied': json['minimumFareApplied'] ?? false,
      };
    }

    return Ride(
      id: json['id']?.toString() ?? '',
      riderId: (json['passengerId'] ?? json['rider_id'] ?? '').toString(),
      driverId: (json['driverId'] ?? json['driver_id'])?.toString(),
      pickupLocation: pickupLoc,
      destinationLocation: destLoc,
      status: _parseStatus(json['status']?.toString() ?? 'PENDING'),
      fare: _toDouble(json['totalFare'] ?? json['fare'] ?? 0),
      distance: _toDouble(json['distance'] ?? 0),
      estimatedDuration: _toInt(json['duration'] ?? json['estimated_duration'] ?? 0),
      rideType: json['rideType'] ?? json['ride_type'] ?? json['vehicleType'] ?? 'standard',
      paymentMethod: _parsePaymentMethod(json['paymentMethod']?.toString() ?? json['payment_method']?.toString() ?? 'CASH'),
      createdAt: createdAt,
      acceptedAt: _parseDate(json['acceptedAt'] ?? json['accepted_at']),
      startedAt: _parseDate(json['startedAt'] ?? json['started_at']),
      completedAt: _parseDate(json['completedAt'] ?? json['completed_at']),
      cancelledAt: _parseDate(json['cancelledAt'] ?? json['cancelled_at']),
      rating: (json['rating'] as num?)?.toDouble(),
      notes: (json['cancellationReason'] ?? json['notes']) as String?,
      driver: driver,
      fareBreakdown: fareBreakdown,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'passengerId': riderId,
      'driverId': driverId,
      'pickupAddress': pickupLocation.address,
      'pickupLat': pickupLocation.latitude,
      'pickupLng': pickupLocation.longitude,
      'dropAddress': destinationLocation.address,
      'dropLat': destinationLocation.latitude,
      'dropLng': destinationLocation.longitude,
      'status': _statusToBackend(status),
      'totalFare': fare,
      'distance': distance,
      'duration': estimatedDuration,
      'paymentMethod': _paymentToBackend(paymentMethod),
      'createdAt': createdAt.toIso8601String(),
      'startedAt': startedAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'cancelledAt': cancelledAt?.toIso8601String(),
      'rating': rating,
    };
  }

  static String _buildDriverName(Map<String, dynamic> json) {
    final firstName = json['firstName'] as String? ?? '';
    final lastName = json['lastName'] as String? ?? '';
    final name = json['name'] as String?;
    if (name != null && name.isNotEmpty) return name;
    return '$firstName${lastName.isNotEmpty ? ' $lastName' : ''}'.trim();
  }

  static String? _extractDriverPhone(Map<String, dynamic> json) {
    final userJson = json['user'] is Map<String, dynamic>
        ? json['user'] as Map<String, dynamic>
        : null;
    final nested = userJson?['phone']?.toString() ?? userJson?['phoneNumber']?.toString();
    final top = json['phone']?.toString() ?? json['phoneNumber']?.toString();
    return _pickPreferredPhone(nested, top);
  }

  static String? _pickPreferredPhone(String? primary, String? secondary) {
    final a = primary?.trim();
    final b = secondary?.trim();
    if (a != null && a.isNotEmpty && !_isLikelyPlaceholderPhone(a)) return a;
    if (b != null && b.isNotEmpty && !_isLikelyPlaceholderPhone(b)) return b;
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    return null;
  }

  static bool _isLikelyPlaceholderPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return false;
    final core = digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
    return core == '9999999999' || core == '9876543210' || RegExp(r'^(\d)\1{9}$').hasMatch(core);
  }

  static double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.parse(value.toString());
    } catch (_) {
      return null;
    }
  }

  /// Parse status from backend (UPPERCASE) or frontend (lowercase) format.
  static RideStatus _parseStatus(String status) {
    switch (status.toUpperCase()) {
      case 'PENDING':
      case 'REQUESTED':
      case 'SEARCHING_DRIVER':
        return RideStatus.requested;
      case 'CONFIRMED':
      case 'ACCEPTED':
        return RideStatus.accepted;
      case 'DRIVER_ASSIGNED':
        return RideStatus.accepted;
      case 'DRIVER_ARRIVED':
      case 'ARRIVING':
      case 'DRIVER_ARRIVING':
        return RideStatus.driverArriving;
      case 'RIDE_STARTED':
      case 'IN_PROGRESS':
      case 'STARTED':
        return RideStatus.inProgress;
      case 'RIDE_COMPLETED':
      case 'COMPLETED':
      case 'FINISHED':
        return RideStatus.completed;
      case 'CANCELLED':
      case 'CANCELED':
        return RideStatus.cancelled;
      default:
        return RideStatus.requested;
    }
  }

  static String _statusToBackend(RideStatus status) {
    switch (status) {
      case RideStatus.requested:
        return 'PENDING';
      case RideStatus.accepted:
        return 'CONFIRMED';
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return 'DRIVER_ARRIVED';
      case RideStatus.inProgress:
        return 'RIDE_STARTED';
      case RideStatus.completed:
        return 'RIDE_COMPLETED';
      case RideStatus.cancelled:
        return 'CANCELLED';
    }
  }

  static PaymentMethod _parsePaymentMethod(String method) {
    switch (method.toUpperCase()) {
      case 'CARD':
        return PaymentMethod.card;
      case 'UPI':
        return PaymentMethod.upi;
      case 'WALLET':
      case 'DIGITAL_WALLET':
        return PaymentMethod.wallet;
      default:
        return PaymentMethod.cash;
    }
  }

  static String _paymentToBackend(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.cash:
        return 'CASH';
      case PaymentMethod.card:
        return 'CARD';
      case PaymentMethod.upi:
        return 'UPI';
      case PaymentMethod.wallet:
      case PaymentMethod.digitalWallet:
        return 'WALLET';
    }
  }

  Ride copyWith({
    String? id,
    String? riderId,
    String? driverId,
    AddressLocation? pickupLocation,
    AddressLocation? destinationLocation,
    RideStatus? status,
    double? fare,
    double? distance,
    int? estimatedDuration,
    String? rideType,
    PaymentMethod? paymentMethod,
    DateTime? createdAt,
    DateTime? acceptedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? cancelledAt,
    double? rating,
    String? notes,
    Driver? driver,
    Map<String, dynamic>? fareBreakdown,
  }) {
    return Ride(
      id: id ?? this.id,
      riderId: riderId ?? this.riderId,
      driverId: driverId ?? this.driverId,
      pickupLocation: pickupLocation ?? this.pickupLocation,
      destinationLocation: destinationLocation ?? this.destinationLocation,
      status: status ?? this.status,
      fare: fare ?? this.fare,
      distance: distance ?? this.distance,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      rideType: rideType ?? this.rideType,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      createdAt: createdAt ?? this.createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      rating: rating ?? this.rating,
      notes: notes ?? this.notes,
      driver: driver ?? this.driver,
      fareBreakdown: fareBreakdown ?? this.fareBreakdown,
    );
  }

  @override
  List<Object?> get props => [id, riderId, driverId, status, fare];
}

class FareEstimate extends Equatable {
  final String rideType;
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double subtotal;
  final double taxes;
  final double total;
  final String currency;
  final double estimatedDistance;
  final double estimatedDuration;
  final double? distance;
  final double? estimatedTime;

  const FareEstimate({
    required this.rideType,
    required this.baseFare,
    required this.distanceFare,
    required this.timeFare,
    required this.subtotal,
    required this.taxes,
    required this.total,
    required this.currency,
    required this.estimatedDistance,
    required this.estimatedDuration,
    this.distance,
    this.estimatedTime,
  });

  /// Parse from backend pricing response.
  /// Backend returns: { baseFare, distanceFare, timeFare, surgeMultiplier,
  ///   peakHourMultiplier, totalFare, distance, estimatedDuration, breakdown }
  factory FareEstimate.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'] as Map<String, dynamic>?;
    return FareEstimate(
      rideType: json['rideType'] as String? ?? 'standard',
      baseFare: (json['baseFare'] as num?)?.toDouble() ?? 0,
      distanceFare: (json['distanceFare'] as num?)?.toDouble() ?? 0,
      timeFare: (json['timeFare'] as num?)?.toDouble() ?? 0,
      subtotal: (breakdown?['subtotal'] as num?)?.toDouble() ??
          ((json['baseFare'] as num?)?.toDouble() ?? 0) +
              ((json['distanceFare'] as num?)?.toDouble() ?? 0) +
              ((json['timeFare'] as num?)?.toDouble() ?? 0),
      taxes: 0, // Backend doesn't have separate taxes
      total: (json['totalFare'] as num?)?.toDouble() ?? (json['total'] as num?)?.toDouble() ?? 0,
      currency: json['currency'] as String? ?? 'INR',
      estimatedDistance: (json['distance'] as num?)?.toDouble() ?? 0,
      estimatedDuration: (json['estimatedDuration'] as num?)?.toDouble() ?? 0,
      distance: (json['distance'] as num?)?.toDouble(),
      estimatedTime: (json['estimatedDuration'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'rideType': rideType,
      'baseFare': baseFare,
      'distanceFare': distanceFare,
      'timeFare': timeFare,
      'subtotal': subtotal,
      'taxes': taxes,
      'total': total,
      'currency': currency,
      'estimatedDistance': estimatedDistance,
      'estimatedDuration': estimatedDuration,
      'distance': distance,
      'estimatedTime': estimatedTime,
    };
  }

  @override
  List<Object?> get props => [rideType, total, estimatedDistance];
}
