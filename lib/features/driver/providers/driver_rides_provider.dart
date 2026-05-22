import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../core/services/api_client.dart';

const Duration _offerFreshnessWindow = Duration(seconds: 90);
const Set<String> _allowedIncomingStatuses = {'searching', 'pending'};
const Set<String> _terminalStatuses = {'cancelled', 'completed', 'expired'};

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
  final String status;

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
    this.status = 'pending',
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

    final status = (json['status'] ??
            json['rideStatus'] ??
            json['ride_status'] ??
            json['requestStatus'] ??
            'pending')
        .toString()
        .toLowerCase();
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
      status: status,
    );
  }
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

  DriverRidesNotifier(this._apiClient) : super(DriverRidesState());

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
  void _processIncomingOffer(RideOffer offer) {
    if (!_isOfferValid(offer)) {
      debugPrint(
          '🧹 Ignoring stale/invalid offer ${offer.id} (status=${offer.status}, age=${DateTime.now().difference(offer.createdAt).inSeconds}s)');
      return;
    }

    // Skip if already dismissed
    if (state.dismissedOfferIds.contains(offer.id)) {
      debugPrint('🚫 Offer ${offer.id} was dismissed, ignoring');
      return;
    }
    
    // Skip if already seen (duplicate prevention)
    if (state.seenOfferIds.contains(offer.id)) {
      debugPrint('🔄 Offer ${offer.id} already seen, ignoring duplicate');
      return;
    }
    
    // Skip if this is the current active offer
    if (state.activeOffer?.id == offer.id) {
      debugPrint('🔄 Offer ${offer.id} is already active, ignoring');
      return;
    }
    
    // Skip if already in pending queue
    if (state.pendingOffers.any((o) => o.id == offer.id)) {
      debugPrint('🔄 Offer ${offer.id} already in queue, ignoring');
      return;
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
  }

  /// Add a new ride offer (from socket/SSE/push event)
  /// Public API for external callers
  void addRideOffer(RideOffer offer) {
    cleanupStaleOffers();
    _processIncomingOffer(offer);
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
      );
    } else {
      // Remove from pending queue
      final newQueue = Queue<RideOffer>.from(state.pendingOffers)
        ..removeWhere((o) => o.id == rideId);
      
      state = state.copyWith(
        pendingOffers: newQueue,
        dismissedOfferIds: newDismissedIds,
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
        // Get the accepted ride (should be the active offer)
        final acceptedRide = state.activeOffer?.id == rideId 
            ? state.activeOffer 
            : state.pendingOffers.firstWhere(
                (o) => o.id == rideId,
                orElse: () => state.activeOffer!,
              );

        debugPrint('✅ Ride $rideId accepted');

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
        if (acceptedRide?.pickupLocation != null) {
          try {
            await _apiClient.updateDriverLocation(
              driverId,
              acceptedRide!.pickupLocation!.latitude,
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

  /// Full reset for fresh login/session.
  /// Clears active/pending/offer history so old offers are never replayed.
  void resetForNewSession() {
    state = DriverRidesState();
    debugPrint('🧼 Driver offer state reset for new session');
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
  void cleanupStaleOffers({Duration maxAge = const Duration(seconds: 30)}) {
    final active = state.activeOffer;
    final pending = Queue<RideOffer>.from(state.pendingOffers);
    final dismissed = Set<String>.from(state.dismissedOfferIds);

    RideOffer? nextActive = active;
    if (active != null && !_isOfferValid(active, maxAge: maxAge)) {
      dismissed.add(active.id);
      nextActive = null;
    }

    pending.removeWhere((offer) {
      final invalid = !_isOfferValid(offer, maxAge: maxAge);
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
