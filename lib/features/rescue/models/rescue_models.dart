import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Figma rescue landing types.
enum RescueServiceType {
  traffic('Traffic Rescue', 'Stuck in traffic — get moving fast'),
  vehicle('Vehicle Rescue', 'Move your vehicle without you riding'),
  passengerAndVehicle(
    'Passenger + Vehicle Rescue',
    'You and your vehicle reach different places',
  ),
  breakdown('Breakdown Rescue', 'Vehicle won\'t start or is unsafe to drive'),
  emergency('Emergency Assistance', 'Immediate help when you feel unsafe');

  const RescueServiceType(this.label, this.subtitle);
  final String label;
  final String subtitle;

  bool get typicallyHasVehicle =>
      this == RescueServiceType.vehicle ||
      this == RescueServiceType.passengerAndVehicle ||
      this == RescueServiceType.breakdown;
}

enum RescueReason {
  stuckInTraffic('Stuck in traffic'),
  needVehicleDelivered('Need vehicle delivered'),
  feelingUnsafe('Feeling unsafe'),
  driverUnavailable('Driver unavailable'),
  longParkingWalk('Long parking walk'),
  vehicleNotStarting('Vehicle not starting'),
  other('Other (tell us)');

  const RescueReason(this.label);
  final String label;
}

enum RescuePhotoSlot { front, back, left, right }

enum RescueApiVehicleType {
  twoWheeler('TWO_WHEELER'),
  fourWheeler('FOUR_WHEELER');

  const RescueApiVehicleType(this.apiValue);
  final String apiValue;
}

enum RescueVehicleCategory {
  bike('Bike', RescueApiVehicleType.twoWheeler, 'assets/vehicles/bike_rescue.png'),
  scooter('Scooter', RescueApiVehicleType.twoWheeler, 'assets/vehicles/auto.png'),
  hatchback('Hatchback', RescueApiVehicleType.fourWheeler, 'assets/vehicles/cab_mini.png'),
  sedan('Sedan', RescueApiVehicleType.fourWheeler, 'assets/vehicles/cab_premium.png'),
  suv('SUV', RescueApiVehicleType.fourWheeler, 'assets/vehicles/cab_xl.png');

  const RescueVehicleCategory(this.label, this.apiType, this.asset);
  final String label;
  final RescueApiVehicleType apiType;
  final String asset;
}

enum RescueTransmission { manual, automatic }

class RescuePlace {
  const RescuePlace({required this.address, required this.location});

  final String address;
  final LatLng location;

  bool get isValid => address.trim().isNotEmpty;
}

/// Fare estimate from POST /api/rescue/estimate.
class RescueFareEstimate {
  const RescueFareEstimate({
    required this.passengerTransport,
    required this.vehicleDelivery,
    required this.platformFee,
    required this.insurance,
    required this.total,
    this.isStatic = false,
    this.currency = 'INR',
  });

  final double passengerTransport;
  final double vehicleDelivery;
  final double platformFee;
  final double insurance;
  final double total;
  final bool isStatic;
  final String currency;

  /// Parse from /api/rescue/estimate response.
  factory RescueFareEstimate.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'] as Map<String, dynamic>? ?? {};
    
    double readAmount(dynamic item) {
      if (item is Map) return (item['amount'] as num?)?.toDouble() ?? 0;
      if (item is num) return item.toDouble();
      return 0;
    }

    final passenger = readAmount(breakdown['passengerTransport']);
    final vehicle = readAmount(breakdown['vehicleDelivery']);
    final platform = readAmount(breakdown['platformFee']);
    final insuranceFee = readAmount(breakdown['insurance']);
    final total = (json['total'] as num?)?.toDouble() ??
        (passenger + vehicle + platform + insuranceFee);

    return RescueFareEstimate(
      passengerTransport: passenger,
      vehicleDelivery: vehicle,
      platformFee: platform,
      insurance: insuranceFee,
      total: total,
      isStatic: false,
      currency: json['currency'] as String? ?? 'INR',
    );
  }

  /// Legacy: parse from ride pricing maps (fallback).
  factory RescueFareEstimate.fromPricingMaps({
    required Map<String, dynamic>? passengerPricing,
    required Map<String, dynamic>? vehiclePricing,
    required bool hasVehicle,
  }) {
    final passenger = _readFare(passengerPricing);
    final vehicle = hasVehicle ? _readFare(vehiclePricing) : 0.0;
    const platform = 20.0;
    const insurance = 17.0;
    return RescueFareEstimate(
      passengerTransport: passenger > 0 ? passenger : 83,
      vehicleDelivery: hasVehicle ? (vehicle > 0 ? vehicle : 270) : 0,
      platformFee: platform,
      insurance: insurance,
      total: (passenger > 0 ? passenger : 83) +
          (hasVehicle ? (vehicle > 0 ? vehicle : 270) : 0) +
          platform +
          insurance,
      isStatic: passengerPricing == null && vehiclePricing == null,
    );
  }

  factory RescueFareEstimate.staticFallback({required bool hasVehicle}) {
    return RescueFareEstimate(
      passengerTransport: 83,
      vehicleDelivery: hasVehicle ? 270 : 0,
      platformFee: 20,
      insurance: 17,
      total: hasVehicle ? 390 : 120,
      isStatic: true,
    );
  }

  static double _readFare(Map<String, dynamic>? json) {
    if (json == null) return 0;
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final fare = data['totalFare'];
    if (fare is num) return fare.toDouble();
    return 0;
  }
}

class RescueVehicleDetails {
  const RescueVehicleDetails({
    this.category = RescueVehicleCategory.bike,
    this.registrationNumber = '',
    this.transmission = RescueTransmission.manual,
    this.issuesNote = '',
    this.photos = const {},
  });

  final RescueVehicleCategory category;
  final String registrationNumber;
  final RescueTransmission transmission;
  final String issuesNote;
  final Map<RescuePhotoSlot, String> photos;

  RescueVehicleDetails copyWith({
    RescueVehicleCategory? category,
    String? registrationNumber,
    RescueTransmission? transmission,
    String? issuesNote,
    Map<RescuePhotoSlot, String>? photos,
  }) {
    return RescueVehicleDetails(
      category: category ?? this.category,
      registrationNumber: registrationNumber ?? this.registrationNumber,
      transmission: transmission ?? this.transmission,
      issuesNote: issuesNote ?? this.issuesNote,
      photos: photos ?? this.photos,
    );
  }

  bool get isValid => registrationNumber.trim().length >= 4;
}

class RescueRequestSummary {
  const RescueRequestSummary({
    required this.id,
    required this.status,
    required this.rescueStage,
    required this.hasVehicle,
    this.rescueOtp,
    this.pickupAddress,
    this.dropAddress,
    this.vehicleDropAddress,
    this.driver1,
    this.driver2,
    this.driver1Name,
    this.driver2Name,
    this.userRideId,
    this.vehicleRideId,
    this.paymentMethod,
    this.vehicleType,
    this.vehicleSubType,
    this.vehicleRegistrationNumber,
    this.createdAt,
    this.completedAt,
    this.rescueServiceType,
    this.reason,
    this.reasonDetails,
    this.estimatedPassengerFare,
    this.estimatedVehicleFare,
    this.estimatedPlatformFee,
    this.estimatedInsuranceFee,
    this.estimatedTotalFare,
    this.sosTriggered = false,
    this.sosTriggeredAt,
    this.vehicleDeliveryStatus,
    this.vehicleConditionPhotos,
    this.vehicleDeliveryNotes,
  });

  final String id;
  final String status;
  final int rescueStage;
  final bool hasVehicle;
  final String? rescueOtp;
  final String? pickupAddress;
  final String? dropAddress;
  final String? vehicleDropAddress;
  final Map<String, dynamic>? driver1;
  final Map<String, dynamic>? driver2;
  final String? driver1Name;
  final String? driver2Name;
  final String? userRideId;
  final String? vehicleRideId;
  final String? paymentMethod;
  final String? vehicleType;
  final String? vehicleSubType;
  final String? vehicleRegistrationNumber;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final String? rescueServiceType;
  final String? reason;
  final String? reasonDetails;
  final double? estimatedPassengerFare;
  final double? estimatedVehicleFare;
  final double? estimatedPlatformFee;
  final double? estimatedInsuranceFee;
  final double? estimatedTotalFare;
  final bool sosTriggered;
  final DateTime? sosTriggeredAt;
  final String? vehicleDeliveryStatus;
  final List<String>? vehicleConditionPhotos;
  final String? vehicleDeliveryNotes;

  factory RescueRequestSummary.fromJson(Map<String, dynamic> json) {
    String? nameOf(Map<String, dynamic>? d) {
      if (d == null) return null;
      final f = d['firstName'] as String? ?? '';
      final l = d['lastName'] as String? ?? '';
      return '$f $l'.trim();
    }

    final d1 = json['driver1'] as Map<String, dynamic>?;
    final d2 = json['driver2'] as Map<String, dynamic>?;

    List<String>? parsePhotos(dynamic value) {
      if (value == null) return null;
      if (value is List) return value.map((e) => e.toString()).toList();
      return null;
    }

    return RescueRequestSummary(
      id: json['id'] as String? ?? '',
      status: json['status'] as String? ?? 'PENDING',
      rescueStage: json['rescueStage'] as int? ?? 0,
      hasVehicle: json['hasVehicle'] as bool? ?? false,
      rescueOtp: json['rescueOtp'] as String?,
      pickupAddress: json['pickupAddress'] as String?,
      dropAddress: json['dropAddress'] as String?,
      vehicleDropAddress: json['vehicleDropAddress'] as String?,
      driver1: d1,
      driver2: d2,
      driver1Name: nameOf(d1),
      driver2Name: nameOf(d2),
      userRideId: json['userRideId'] as String?,
      vehicleRideId: json['vehicleRideId'] as String?,
      paymentMethod: json['paymentMethod'] as String?,
      vehicleType: json['vehicleType'] as String?,
      vehicleSubType: json['vehicleSubType'] as String?,
      vehicleRegistrationNumber: json['vehicleRegistrationNumber'] as String?,
      createdAt: _parseDate(json['createdAt']),
      completedAt: _parseDate(json['completedAt']),
      rescueServiceType: json['rescueServiceType'] as String?,
      reason: json['reason'] as String?,
      reasonDetails: json['reasonDetails'] as String?,
      estimatedPassengerFare:
          (json['estimatedPassengerFare'] as num?)?.toDouble(),
      estimatedVehicleFare: (json['estimatedVehicleFare'] as num?)?.toDouble(),
      estimatedPlatformFee: (json['estimatedPlatformFee'] as num?)?.toDouble(),
      estimatedInsuranceFee:
          (json['estimatedInsuranceFee'] as num?)?.toDouble(),
      estimatedTotalFare: (json['estimatedTotalFare'] as num?)?.toDouble(),
      sosTriggered: json['sosTriggered'] as bool? ?? false,
      sosTriggeredAt: _parseDate(json['sosTriggeredAt']),
      vehicleDeliveryStatus: json['vehicleDeliveryStatus'] as String?,
      vehicleConditionPhotos: parsePhotos(json['vehicleConditionPhotos']),
      vehicleDeliveryNotes: json['vehicleDeliveryNotes'] as String?,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }

  bool get isSearching => status == 'PENDING' || status == 'DRIVER1_ACCEPTED';

  bool get isLive =>
      status == 'BOTH_ACCEPTED' ||
      status == 'DRIVERS_EN_ROUTE' ||
      status == 'DRIVERS_ARRIVED' ||
      status == 'IN_PROGRESS';

  bool get isCompleted => status == 'COMPLETED';
  bool get isCancelled => status == 'CANCELLED';
  bool get needsHandover =>
      status == 'DRIVERS_ARRIVED' || status == 'IN_PROGRESS';

  bool get vehicleDeliveryAccepted =>
      vehicleDeliveryStatus?.toUpperCase() == 'ACCEPTED';

  bool get vehicleDeliveryIssueReported =>
      vehicleDeliveryStatus?.toUpperCase() == 'ISSUE_REPORTED';

  String? get driver1Phone => driver1?['phone'] as String?;
  String? get driver2Phone => driver2?['phone'] as String?;
  String? get driver1VehicleNumber => driver1?['vehicleNumber'] as String?;
  String? get driver2VehicleNumber => driver2?['vehicleNumber'] as String?;
}

class RescueProgressSnapshot {
  const RescueProgressSnapshot({
    required this.rescue,
    this.userRideStatus,
    this.vehicleRideStatus,
    this.userDriverName,
    this.vehicleDriverName,
    this.userEtaMin,
    this.vehicleEtaMin,
  });

  final RescueRequestSummary rescue;
  final String? userRideStatus;
  final String? vehicleRideStatus;
  final String? userDriverName;
  final String? vehicleDriverName;
  final int? userEtaMin;
  final int? vehicleEtaMin;

  factory RescueProgressSnapshot.fromJson(Map<String, dynamic> json) {
    final rescueJson = json['rescue'] as Map<String, dynamic>? ?? {};
    final userRide = json['userRide'] as Map<String, dynamic>?;
    final vehicleRide = json['vehicleRide'] as Map<String, dynamic>?;

    String? driverName(Map<String, dynamic>? ride) {
      final d = ride?['driver'] as Map<String, dynamic>?;
      if (d == null) return null;
      return '${d['firstName'] ?? ''} ${d['lastName'] ?? ''}'.trim();
    }

    return RescueProgressSnapshot(
      rescue: RescueRequestSummary.fromJson(rescueJson),
      userRideStatus: userRide?['status'] as String?,
      vehicleRideStatus: vehicleRide?['status'] as String?,
      userDriverName: driverName(userRide),
      vehicleDriverName: driverName(vehicleRide),
      userEtaMin: (userRide?['etaMinutes'] as num?)?.toInt(),
      vehicleEtaMin: (vehicleRide?['etaMinutes'] as num?)?.toInt(),
    );
  }
}

class RescueRatingInput {
  const RescueRatingInput({
    this.riderRating = 5,
    this.vehicleDriverRating = 5,
    this.supportRating = 5,
    this.problemSolved = true,
    this.feedback = '',
  });

  final int riderRating;
  final int vehicleDriverRating;
  final int supportRating;
  final bool problemSolved;
  final String feedback;

  /// Convert to API format: array of ratings per target.
  List<Map<String, dynamic>> toApiRatings({required bool hasVehicle}) {
    final ratings = <Map<String, dynamic>>[
      {
        'targetType': 'RIDER_DRIVER',
        'rating': riderRating,
        if (feedback.isNotEmpty) 'feedback': feedback,
      },
    ];
    if (hasVehicle) {
      ratings.add({
        'targetType': 'VEHICLE_DRIVER',
        'rating': vehicleDriverRating,
      });
    }
    ratings.add({
      'targetType': 'SUPPORT',
      'rating': supportRating,
    });
    return ratings;
  }
}

/// Timeline event from GET /api/rescue/:id/timeline.
class RescueTimelineEvent {
  const RescueTimelineEvent({
    required this.id,
    required this.event,
    required this.title,
    this.description,
    this.actor = 'system',
    required this.createdAt,
    this.metadata,
  });

  final String id;
  final String event;
  final String title;
  final String? description;
  final String actor;
  final DateTime createdAt;
  final Map<String, dynamic>? metadata;

  factory RescueTimelineEvent.fromJson(Map<String, dynamic> json) {
    return RescueTimelineEvent(
      id: json['id'] as String? ?? '',
      event: json['event'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String?,
      actor: json['actor'] as String? ?? 'system',
      createdAt: _parseDate(json['createdAt']) ?? DateTime.now(),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }

  bool get isDriverEvent => actor == 'driver';
  bool get isUserEvent => actor == 'user';
  bool get isSystemEvent => actor == 'system';
}

/// Vehicle delivery verification status.
enum VehicleDeliveryStatus {
  pending('PENDING'),
  accepted('ACCEPTED'),
  issueReported('ISSUE_REPORTED');

  const VehicleDeliveryStatus(this.apiValue);
  final String apiValue;

  static VehicleDeliveryStatus fromString(String? value) {
    switch (value?.toUpperCase()) {
      case 'ACCEPTED':
        return VehicleDeliveryStatus.accepted;
      case 'ISSUE_REPORTED':
        return VehicleDeliveryStatus.issueReported;
      default:
        return VehicleDeliveryStatus.pending;
    }
  }
}

/// Issue types for POST /api/rescue/:id/report-issue.
enum RescueIssueType {
  vehicleDamage('VEHICLE_DAMAGE', 'Vehicle Damage'),
  driverBehavior('DRIVER_BEHAVIOR', 'Driver Behavior'),
  pricing('PRICING', 'Pricing Issue'),
  route('ROUTE', 'Route Issue'),
  safety('SAFETY', 'Safety Concern'),
  other('OTHER', 'Other');

  const RescueIssueType(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

/// Timeline milestones for Journey Hub.
enum RescueTimelineStep {
  requestReceived('Rescue request received'),
  bikeRiderOnWay('Bike rider on the way'),
  vehicleDriverOnWay('Vehicle driver on the way'),
  driversArrived('Drivers arrived at pickup'),
  handoverVerified('Vehicle handover verified'),
  journeyStarted('Journey started'),
  vehicleDelivered('Vehicle delivered'),
  rescueCompleted('Rescue completed');

  const RescueTimelineStep(this.label);
  final String label;
}

int rescueTimelineIndexForStatus(String status, {required bool hasVehicle}) {
  switch (status) {
    case 'PENDING':
      return 0;
    case 'DRIVER1_ACCEPTED':
      return 1;
    case 'BOTH_ACCEPTED':
      return hasVehicle ? 2 : 1;
    case 'DRIVERS_EN_ROUTE':
      return hasVehicle ? 2 : 1;
    case 'DRIVERS_ARRIVED':
      return hasVehicle ? 3 : 2;
    case 'IN_PROGRESS':
      return hasVehicle ? 5 : 3;
    case 'COMPLETED':
      return hasVehicle ? 7 : 4;
    default:
      return 0;
  }
}
