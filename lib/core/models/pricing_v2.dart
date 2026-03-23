/// Raahi Pricing Policy v2 Models
/// Supports Launch Mode (liquidity-first) and Scale Mode (efficiency-first)

/// Marketplace operating mode
enum MarketplaceMode {
  launch, // Phase 0-1: Liquidity first, aggressive subsidies
  scale,  // Phase 2: Efficiency first, margin optimization
}

/// Vehicle category for pricing
enum VehicleCategory {
  bike,
  auto,
  mini,
  xl,
  premium,
}

/// Zone health status based on liquidity metrics
enum ZoneHealthStatus {
  critical,  // < 0.6 - needs immediate intervention
  moderate,  // 0.6-0.8 - maintain current state
  healthy,   // > 0.8 - can reduce incentives
}

/// Rider subsidy configuration for launch mode
class RiderSubsidy {
  final double subsidyPct;      // 0.20 - 0.35 (20-35%)
  final double maxSubsidyCap;   // ₹80 per ride
  final bool isActive;
  
  const RiderSubsidy({
    this.subsidyPct = 0.25,
    this.maxSubsidyCap = 80.0,
    this.isActive = false,
  });
  
  /// Calculate effective rider fare after subsidy
  double calculateEffectiveFare(double originalFare) {
    if (!isActive) return originalFare;
    final discount = originalFare * subsidyPct;
    final cappedDiscount = discount > maxSubsidyCap ? maxSubsidyCap : discount;
    return originalFare - cappedDiscount;
  }
  
  factory RiderSubsidy.fromJson(Map<String, dynamic> json) {
    return RiderSubsidy(
      subsidyPct: (json['subsidy_pct'] ?? json['subsidyPct'] ?? 0.25).toDouble(),
      maxSubsidyCap: (json['max_subsidy_cap'] ?? json['maxSubsidyCap'] ?? 80.0).toDouble(),
      isActive: json['is_active'] ?? json['isActive'] ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'subsidyPct': subsidyPct,
    'maxSubsidyCap': maxSubsidyCap,
    'isActive': isActive,
  };
}

/// Driver boost configuration (replaces static hourly guarantee)
class DriverBoost {
  final double boostAmount;     // ₹15-30 per ride based on category
  final double supplyThreshold; // Activate when supply below this
  final bool isActive;
  final VehicleCategory category;
  
  const DriverBoost({
    required this.boostAmount,
    this.supplyThreshold = 0.7,
    this.isActive = false,
    this.category = VehicleCategory.mini,
  });
  
  /// Get default boost amount by vehicle category
  static double getDefaultBoost(VehicleCategory category) {
    switch (category) {
      case VehicleCategory.bike:
        return 15.0;
      case VehicleCategory.auto:
        return 20.0;
      case VehicleCategory.mini:
      case VehicleCategory.xl:
      case VehicleCategory.premium:
        return 30.0;
    }
  }
  
  factory DriverBoost.fromJson(Map<String, dynamic> json) {
    return DriverBoost(
      boostAmount: (json['boost_amount'] ?? json['boostAmount'] ?? 20.0).toDouble(),
      supplyThreshold: (json['supply_threshold'] ?? json['supplyThreshold'] ?? 0.7).toDouble(),
      isActive: json['is_active'] ?? json['isActive'] ?? false,
      category: VehicleCategory.values.firstWhere(
        (c) => c.name == (json['category'] ?? 'mini'),
        orElse: () => VehicleCategory.mini,
      ),
    );
  }
  
  Map<String, dynamic> toJson() => {
    'boostAmount': boostAmount,
    'supplyThreshold': supplyThreshold,
    'isActive': isActive,
    'category': category.name,
  };
}

/// Driver quest (daily challenges for bonus earnings)
class DriverQuest {
  final String id;
  final String title;
  final String description;
  final int targetRides;
  final int completedRides;
  final double rewardAmount;
  final bool isPeakHour;
  final double minAcceptanceRate;  // 65%
  final double maxCancellationRate; // 15%
  final DateTime? expiresAt;
  final bool isCompleted;
  
  const DriverQuest({
    required this.id,
    required this.title,
    required this.description,
    required this.targetRides,
    this.completedRides = 0,
    required this.rewardAmount,
    this.isPeakHour = false,
    this.minAcceptanceRate = 0.65,
    this.maxCancellationRate = 0.15,
    this.expiresAt,
    this.isCompleted = false,
  });
  
  double get progress => targetRides > 0 ? completedRides / targetRides : 0;
  int get remainingRides => targetRides - completedRides;
  bool get isEligible => true; // Backend validates acceptance/cancellation rates
  
  /// Default daily quests
  static List<DriverQuest> getDefaultQuests() {
    return [
      DriverQuest(
        id: 'daily_6',
        title: 'Daily Starter',
        description: 'Complete 6 rides today',
        targetRides: 6,
        rewardAmount: 80.0,
      ),
      DriverQuest(
        id: 'daily_10',
        title: 'Power Driver',
        description: 'Complete 10 rides today',
        targetRides: 10,
        rewardAmount: 180.0,
      ),
      DriverQuest(
        id: 'peak_hour',
        title: 'Peak Hour Hero',
        description: 'Complete rides during 5-9 PM',
        targetRides: 1,
        rewardAmount: 20.0, // Per ride bonus
        isPeakHour: true,
      ),
    ];
  }
  
  factory DriverQuest.fromJson(Map<String, dynamic> json) {
    return DriverQuest(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      targetRides: json['target_rides'] ?? json['targetRides'] ?? 0,
      completedRides: json['completed_rides'] ?? json['completedRides'] ?? 0,
      rewardAmount: (json['reward_amount'] ?? json['rewardAmount'] ?? 0).toDouble(),
      isPeakHour: json['is_peak_hour'] ?? json['isPeakHour'] ?? false,
      minAcceptanceRate: (json['min_acceptance_rate'] ?? 0.65).toDouble(),
      maxCancellationRate: (json['max_cancellation_rate'] ?? 0.15).toDouble(),
      expiresAt: json['expires_at'] != null ? DateTime.parse(json['expires_at']) : null,
      isCompleted: json['is_completed'] ?? json['isCompleted'] ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'targetRides': targetRides,
    'completedRides': completedRides,
    'rewardAmount': rewardAmount,
    'isPeakHour': isPeakHour,
    'minAcceptanceRate': minAcceptanceRate,
    'maxCancellationRate': maxCancellationRate,
    'expiresAt': expiresAt?.toIso8601String(),
    'isCompleted': isCompleted,
  };
}

/// Eco Pickup option (walk a bit, save money)
class EcoPickup {
  final double walkDistanceMeters; // 100-250m
  final double discountPct;        // 10-18%
  final String suggestedPickupAddress;
  final double suggestedLat;
  final double suggestedLng;
  final bool isAvailable;
  
  const EcoPickup({
    this.walkDistanceMeters = 150.0,
    this.discountPct = 0.12,
    this.suggestedPickupAddress = '',
    this.suggestedLat = 0,
    this.suggestedLng = 0,
    this.isAvailable = false,
  });
  
  double calculateSavings(double originalFare) {
    return originalFare * discountPct;
  }
  
  factory EcoPickup.fromJson(Map<String, dynamic> json) {
    return EcoPickup(
      walkDistanceMeters: (json['walk_distance_meters'] ?? json['walkDistanceMeters'] ?? 150.0).toDouble(),
      discountPct: (json['discount_pct'] ?? json['discountPct'] ?? 0.12).toDouble(),
      suggestedPickupAddress: json['suggested_pickup_address'] ?? json['suggestedPickupAddress'] ?? '',
      suggestedLat: (json['suggested_lat'] ?? json['suggestedLat'] ?? 0).toDouble(),
      suggestedLng: (json['suggested_lng'] ?? json['suggestedLng'] ?? 0).toDouble(),
      isAvailable: json['is_available'] ?? json['isAvailable'] ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'walkDistanceMeters': walkDistanceMeters,
    'discountPct': discountPct,
    'suggestedPickupAddress': suggestedPickupAddress,
    'suggestedLat': suggestedLat,
    'suggestedLng': suggestedLng,
    'isAvailable': isAvailable,
  };
}

/// Zone health metrics for liquidity management
class ZoneHealth {
  final String zoneId;
  final String cityCode;
  final double fulfillmentRate;  // % of ride requests fulfilled
  final double etaP90;           // 90th percentile ETA in minutes
  final double acceptRate;       // Driver acceptance rate
  final double healthScore;      // Calculated: 0.5*fulfillment + 0.3*acceptRate + 0.2*(1/etaP90)
  final ZoneHealthStatus status;
  
  const ZoneHealth({
    required this.zoneId,
    required this.cityCode,
    this.fulfillmentRate = 0.85,
    this.etaP90 = 5.0,
    this.acceptRate = 0.75,
    this.healthScore = 0.8,
    this.status = ZoneHealthStatus.healthy,
  });
  
  /// Calculate health score from metrics
  static double calculateHealthScore(double fulfillment, double acceptRate, double etaP90) {
    final etaFactor = etaP90 > 0 ? 1 / etaP90 : 0;
    return 0.5 * fulfillment + 0.3 * acceptRate + 0.2 * etaFactor.clamp(0, 1);
  }
  
  /// Determine status from health score
  static ZoneHealthStatus getStatus(double healthScore) {
    if (healthScore < 0.6) return ZoneHealthStatus.critical;
    if (healthScore < 0.8) return ZoneHealthStatus.moderate;
    return ZoneHealthStatus.healthy;
  }
  
  factory ZoneHealth.fromJson(Map<String, dynamic> json) {
    final fulfillment = (json['fulfillment_rate'] ?? json['fulfillmentRate'] ?? 0.85).toDouble();
    final accept = (json['accept_rate'] ?? json['acceptRate'] ?? 0.75).toDouble();
    final eta = (json['eta_p90'] ?? json['etaP90'] ?? 5.0).toDouble();
    final score = (json['health_score'] ?? json['healthScore'] ?? calculateHealthScore(fulfillment, accept, eta)).toDouble();
    
    return ZoneHealth(
      zoneId: json['zone_id'] ?? json['zoneId'] ?? '',
      cityCode: json['city_code'] ?? json['cityCode'] ?? '',
      fulfillmentRate: fulfillment,
      etaP90: eta,
      acceptRate: accept,
      healthScore: score,
      status: getStatus(score),
    );
  }
  
  Map<String, dynamic> toJson() => {
    'zoneId': zoneId,
    'cityCode': cityCode,
    'fulfillmentRate': fulfillmentRate,
    'etaP90': etaP90,
    'acceptRate': acceptRate,
    'healthScore': healthScore,
    'status': status.name,
  };
}

/// Burn metrics for cost control
class BurnMetrics {
  final String cityCode;
  final DateTime date;
  final double gmv;           // Gross Merchandise Value
  final double subsidy;       // Total subsidies paid
  final double incentives;    // Total driver incentives
  final double burnRate;      // (subsidy + incentives) / GMV
  final bool isOverBudget;    // burnRate > 0.22
  
  const BurnMetrics({
    required this.cityCode,
    required this.date,
    this.gmv = 0,
    this.subsidy = 0,
    this.incentives = 0,
    this.burnRate = 0,
    this.isOverBudget = false,
  });
  
  static const double maxBurnRate = 0.22; // 22% cap
  
  factory BurnMetrics.fromJson(Map<String, dynamic> json) {
    final gmv = (json['gmv'] ?? 0).toDouble();
    final subsidy = (json['subsidy'] ?? 0).toDouble();
    final incentives = (json['incentives'] ?? 0).toDouble();
    final burnRate = gmv > 0 ? (subsidy + incentives) / gmv : 0;
    
    return BurnMetrics(
      cityCode: json['city_code'] ?? json['cityCode'] ?? '',
      date: json['date'] != null ? DateTime.parse(json['date']) : DateTime.now(),
      gmv: gmv,
      subsidy: subsidy,
      incentives: incentives,
      burnRate: burnRate.toDouble(),
      isOverBudget: burnRate > maxBurnRate,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'cityCode': cityCode,
    'date': date.toIso8601String(),
    'gmv': gmv,
    'subsidy': subsidy,
    'incentives': incentives,
    'burnRate': burnRate,
    'isOverBudget': isOverBudget,
  };
}

/// Complete pricing response from backend (v2)
class PricingResponseV2 {
  // Base pricing
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double totalFare;
  
  // Surge
  final double surgeMultiplier;
  final bool isSurgeActive;
  
  // Launch mode features
  final RiderSubsidy? riderSubsidy;
  final EcoPickup? ecoPickup;
  final double effectiveFare;  // After subsidy
  final double savings;        // Original - Effective
  
  // Zone info
  final ZoneHealth? zoneHealth;
  final MarketplaceMode marketplaceMode;
  
  // Trip details
  final double distanceKm;
  final int durationMin;
  
  const PricingResponseV2({
    required this.baseFare,
    required this.distanceFare,
    required this.timeFare,
    required this.totalFare,
    this.surgeMultiplier = 1.0,
    this.isSurgeActive = false,
    this.riderSubsidy,
    this.ecoPickup,
    required this.effectiveFare,
    this.savings = 0,
    this.zoneHealth,
    this.marketplaceMode = MarketplaceMode.scale,
    required this.distanceKm,
    required this.durationMin,
  });
  
  factory PricingResponseV2.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    
    final baseFare = (data['baseFare'] ?? data['base_fare'] ?? 0).toDouble();
    final distanceFare = (data['distanceFare'] ?? data['distance_fare'] ?? 0).toDouble();
    final timeFare = (data['timeFare'] ?? data['time_fare'] ?? 0).toDouble();
    final totalFare = (data['totalFare'] ?? data['total_fare'] ?? baseFare + distanceFare + timeFare).toDouble();
    
    final subsidy = data['rider_subsidy'] != null || data['riderSubsidy'] != null
        ? RiderSubsidy.fromJson(data['rider_subsidy'] ?? data['riderSubsidy'])
        : null;
    
    final eco = data['eco_pickup'] != null || data['ecoPickup'] != null
        ? EcoPickup.fromJson(data['eco_pickup'] ?? data['ecoPickup'])
        : null;
    
    final zone = data['zone_health'] != null || data['zoneHealth'] != null
        ? ZoneHealth.fromJson(data['zone_health'] ?? data['zoneHealth'])
        : null;
    
    double effectiveFare = totalFare;
    if (subsidy != null && subsidy.isActive) {
      effectiveFare = subsidy.calculateEffectiveFare(totalFare);
    }
    
    return PricingResponseV2(
      baseFare: baseFare,
      distanceFare: distanceFare,
      timeFare: timeFare,
      totalFare: totalFare,
      surgeMultiplier: (data['surge_multiplier'] ?? data['surgeMultiplier'] ?? 1.0).toDouble(),
      isSurgeActive: data['surge_active'] ?? data['surgeActive'] ?? data['is_surge'] ?? false,
      riderSubsidy: subsidy,
      ecoPickup: eco,
      effectiveFare: effectiveFare,
      savings: totalFare - effectiveFare,
      zoneHealth: zone,
      marketplaceMode: data['marketplace_mode'] == 'launch' 
          ? MarketplaceMode.launch 
          : MarketplaceMode.scale,
      distanceKm: (data['distance_km'] ?? data['distanceKm'] ?? data['distance'] ?? 0).toDouble(),
      durationMin: (data['duration_min'] ?? data['durationMin'] ?? data['estimatedDuration'] ?? 0).toInt(),
    );
  }
  
  Map<String, dynamic> toJson() => {
    'baseFare': baseFare,
    'distanceFare': distanceFare,
    'timeFare': timeFare,
    'totalFare': totalFare,
    'surgeMultiplier': surgeMultiplier,
    'isSurgeActive': isSurgeActive,
    'riderSubsidy': riderSubsidy?.toJson(),
    'ecoPickup': ecoPickup?.toJson(),
    'effectiveFare': effectiveFare,
    'savings': savings,
    'zoneHealth': zoneHealth?.toJson(),
    'marketplaceMode': marketplaceMode.name,
    'distanceKm': distanceKm,
    'durationMin': durationMin,
  };
}

/// Driver payout calculation (ensures floor protection)
class DriverPayout {
  final double basePayout;
  final double boostAmount;
  final double questBonus;
  final double totalPayout;
  final double tripFloor;     // Minimum guaranteed
  final bool isFloorApplied;
  
  const DriverPayout({
    required this.basePayout,
    this.boostAmount = 0,
    this.questBonus = 0,
    required this.totalPayout,
    required this.tripFloor,
    this.isFloorApplied = false,
  });
  
  /// Calculate payout with floor protection
  static DriverPayout calculate({
    required double basePayout,
    double boostAmount = 0,
    double questBonus = 0,
    required double tripFloor,
  }) {
    final rawTotal = basePayout + boostAmount + questBonus;
    final isFloorApplied = rawTotal < tripFloor;
    final total = isFloorApplied ? tripFloor : rawTotal;
    
    return DriverPayout(
      basePayout: basePayout,
      boostAmount: boostAmount,
      questBonus: questBonus,
      totalPayout: total,
      tripFloor: tripFloor,
      isFloorApplied: isFloorApplied,
    );
  }
  
  factory DriverPayout.fromJson(Map<String, dynamic> json) {
    return DriverPayout(
      basePayout: (json['base_payout'] ?? json['basePayout'] ?? 0).toDouble(),
      boostAmount: (json['boost_amount'] ?? json['boostAmount'] ?? 0).toDouble(),
      questBonus: (json['quest_bonus'] ?? json['questBonus'] ?? 0).toDouble(),
      totalPayout: (json['total_payout'] ?? json['totalPayout'] ?? 0).toDouble(),
      tripFloor: (json['trip_floor'] ?? json['tripFloor'] ?? 0).toDouble(),
      isFloorApplied: json['is_floor_applied'] ?? json['isFloorApplied'] ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'basePayout': basePayout,
    'boostAmount': boostAmount,
    'questBonus': questBonus,
    'totalPayout': totalPayout,
    'tripFloor': tripFloor,
    'isFloorApplied': isFloorApplied,
  };
}
