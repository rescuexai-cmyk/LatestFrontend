import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/ride.dart';
import '../../../core/models/location.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/services/realtime_service.dart';
import '../../../core/services/sse_service.dart';

/// Result of a cancel ride operation
class CancelRideResult {
  final bool success;
  final String? error;
  
  const CancelRideResult({required this.success, this.error});
}

// Active ride state
class ActiveRideState {
  final Ride? activeRide;
  final LocationCoordinate? driverLocation;
  final bool isLoading;
  final String? error;

  const ActiveRideState({
    this.activeRide,
    this.driverLocation,
    this.isLoading = false,
    this.error,
  });

  ActiveRideState copyWith({
    Ride? activeRide,
    LocationCoordinate? driverLocation,
    bool? isLoading,
    String? error,
  }) {
    return ActiveRideState(
      activeRide: activeRide ?? this.activeRide,
      driverLocation: driverLocation ?? this.driverLocation,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool get hasActiveRide => activeRide != null && 
      activeRide!.status != RideStatus.completed &&
      activeRide!.status != RideStatus.cancelled;
}

// Active ride notifier
class ActiveRideNotifier extends StateNotifier<ActiveRideState> {
  ActiveRideNotifier() : super(const ActiveRideState());

  SSESubscription? _sseSub;
  VoidCallback? _unsubscribe;

  void setActiveRide(Ride ride) {
    state = state.copyWith(activeRide: ride);
    _subscribeToRideUpdates(ride.id);
  }

  /// Update the active ride's status (e.g. when driver verifies OTP and ride starts).
  /// Use this to sync the banner when status updates come from the driver_assigned screen.
  void updateActiveRideStatus(RideStatus status) {
    if (state.activeRide == null) return;
    state = state.copyWith(
      activeRide: state.activeRide!.copyWith(status: status),
    );
  }

  void _subscribeToRideUpdates(String rideId) {
    _sseSub?.cancel();
    _unsubscribe?.call();
    
    // Primary: SSE ride stream
    _sseSub = realtimeService.connectRide(
      rideId,
      onEvent: (type, data) {
        switch (type) {
          case 'status_update':
            _handleStatusUpdate(data);
            break;
          case 'location_update':
            _handleLocationUpdate(data);
            break;
          case 'driver_assigned':
            _handleDriverAssigned(data);
            break;
          case 'driver_arrived':
            _handleDriverArrived(data);
            break;
          case 'cancelled':
            _handleCancelled();
            break;
      }
    });
  }
  
  void _handleDriverAssigned(Map<String, dynamic> data) {
    if (state.activeRide == null) return;
    
    // Update ride with driver info
    final driverData = data['driver'] as Map<String, dynamic>?;
    if (driverData != null) {
      state = state.copyWith(
        activeRide: state.activeRide!.copyWith(
          status: RideStatus.accepted,
          driverId: driverData['id'] as String?,
        ),
      );
    }
  }
  
  void _handleDriverArrived(Map<String, dynamic> data) {
    if (state.activeRide == null) return;
    
    state = state.copyWith(
      activeRide: state.activeRide!.copyWith(
        status: RideStatus.driverArriving,
      ),
    );
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    if (state.activeRide == null) return;
    
    final statusStr = data['status'] as String;
    final status = _parseStatus(statusStr);
    
    // If ride is completed or cancelled, clear the active ride state
    if (status == RideStatus.completed || status == RideStatus.cancelled) {
      clearActiveRide();
      return;
    }
    
    state = state.copyWith(
      activeRide: state.activeRide!.copyWith(status: status),
    );
  }

  void _handleLocationUpdate(Map<String, dynamic> data) {
    final location = data['driverLocation'] as Map<String, dynamic>?;
    if (location != null) {
      state = state.copyWith(
        driverLocation: LocationCoordinate(
          lat: (location['latitude'] as num).toDouble(),
          lng: (location['longitude'] as num).toDouble(),
        ),
      );
    }
  }

  void _handleCancelled() {
    clearActiveRide();
  }

  void clearActiveRide() {
    if (state.activeRide != null) {
      realtimeService.disconnectRide(state.activeRide!.id);
    }
    _sseSub?.cancel();
    _sseSub = null;
    _unsubscribe?.call();
    _unsubscribe = null;
    state = const ActiveRideState();
  }

  /// Cancel the active ride.
  /// Returns a result with success status and optional error message.
  /// Handles 403 (not authorized to cancel) and 409 (invalid state) errors.
  Future<CancelRideResult> cancelRide({String? reason}) async {
    if (state.activeRide == null) {
      return const CancelRideResult(success: false, error: 'No active ride to cancel');
    }

    state = state.copyWith(isLoading: true);

    try {
      // Backend: POST /api/rides/:id/cancel  body: { reason? }
      final response = await apiClient.cancelRide(state.activeRide!.id, reason: reason);
      
      if (response['success'] == true) {
        clearActiveRide();
        return const CancelRideResult(success: true);
      } else {
        final message = response['message'] as String? ?? 'Failed to cancel ride';
        state = state.copyWith(isLoading: false, error: message);
        return CancelRideResult(success: false, error: message);
      }
    } catch (e) {
      String errorMessage = 'Failed to cancel ride';
      
      // Parse specific error codes
      final errorStr = e.toString();
      if (errorStr.contains('403')) {
        errorMessage = 'You are not authorized to cancel this ride';
      } else if (errorStr.contains('409')) {
        errorMessage = 'This ride cannot be cancelled in its current state';
      } else if (errorStr.contains('404')) {
        errorMessage = 'Ride not found';
        clearActiveRide(); // Clear stale ride
      }
      
      state = state.copyWith(isLoading: false, error: errorMessage);
      return CancelRideResult(success: false, error: errorMessage);
    }
  }

  /// Parse status from backend (UPPERCASE enum) or real-time events.
  RideStatus _parseStatus(String status) {
    switch (status.toUpperCase()) {
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
        return RideStatus.inProgress;
      case 'RIDE_COMPLETED':
      case 'COMPLETED':
        return RideStatus.completed;
      case 'CANCELLED':
      case 'CANCELED':
        return RideStatus.cancelled;
      default:
        return RideStatus.requested;
    }
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    _unsubscribe?.call();
    if (state.activeRide != null) {
      realtimeService.disconnectRide(state.activeRide!.id);
    }
    super.dispose();
  }
}

// Providers
final activeRideProvider = StateNotifierProvider<ActiveRideNotifier, ActiveRideState>((ref) {
  return ActiveRideNotifier();
});

final hasActiveRideProvider = Provider<bool>((ref) {
  return ref.watch(activeRideProvider).hasActiveRide;
});

final activeRideLocationProvider = Provider<LocationCoordinate?>((ref) {
  return ref.watch(activeRideProvider).driverLocation;
});

// Ride history provider - backend: GET /api/rides (authenticated, no userId needed)
final rideHistoryProvider = FutureProvider.family<List<Ride>, String>((ref, userId) async {
  final response = await apiClient.getUserRides();
  // Backend returns: { success, data: { rides: [...], total, page, totalPages } }
  if (response['success'] == true) {
    final data = response['data'] as Map<String, dynamic>?;
    final ridesJson = data?['rides'] as List<dynamic>? ?? [];
    return ridesJson.map((r) => Ride.fromJson(r as Map<String, dynamic>)).toList();
  }
  return [];
});

// Single ride provider - backend: GET /api/rides/:id
final rideDetailsProvider = FutureProvider.family<Ride, String>((ref, rideId) async {
  final response = await apiClient.getRide(rideId);
  // Backend returns: { success, data: { ... ride fields ... } }
  if (response['success'] == true) {
    final rideData = response['data'] as Map<String, dynamic>;
    return Ride.fromJson(rideData);
  }
  throw Exception('Failed to fetch ride details');
});
