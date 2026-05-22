import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/driver_rides_provider.dart';

/// Isolated state provider for the ride request stack UI.
/// 
/// This provider maintains its own queue of ride requests for the stack UI
/// while syncing with the existing driverRidesProvider. It does NOT modify
/// the existing provider - only reads from it and maintains display state.
/// 
/// Key features:
/// - Maintains ordered queue for stack display
/// - Prevents duplicate rideIds
/// - Tracks which ride is currently being swiped
/// - Does NOT touch accept/decline APIs (those stay in driver_home_screen)

class RideQueueState {
  final List<RideOffer> queue;
  final String? swipingRideId;
  final bool isProcessing;

  const RideQueueState({
    this.queue = const [],
    this.swipingRideId,
    this.isProcessing = false,
  });

  RideQueueState copyWith({
    List<RideOffer>? queue,
    String? swipingRideId,
    bool? isProcessing,
    bool clearSwipingId = false,
  }) {
    return RideQueueState(
      queue: queue ?? this.queue,
      swipingRideId: clearSwipingId ? null : (swipingRideId ?? this.swipingRideId),
      isProcessing: isProcessing ?? this.isProcessing,
    );
  }

  bool get isEmpty => queue.isEmpty;
  bool get hasRides => queue.isNotEmpty;
  int get count => queue.length;
  
  RideOffer? get topRide => queue.isNotEmpty ? queue.first : null;
  
  List<RideOffer> get visibleRides => queue.take(3).toList();
}

class RideQueueNotifier extends StateNotifier<RideQueueState> {
  RideQueueNotifier() : super(const RideQueueState());

  void addRide(RideOffer ride) {
    if (state.queue.any((r) => r.id == ride.id)) {
      return;
    }
    
    state = state.copyWith(
      queue: [...state.queue, ride],
    );
  }

  void addRides(List<RideOffer> rides) {
    final existingIds = state.queue.map((r) => r.id).toSet();
    final newRides = rides.where((r) => !existingIds.contains(r.id)).toList();
    
    if (newRides.isEmpty) return;
    
    state = state.copyWith(
      queue: [...state.queue, ...newRides],
    );
  }

  void removeRide(String rideId) {
    final updated = state.queue.where((r) => r.id != rideId).toList();
    state = state.copyWith(
      queue: updated,
      clearSwipingId: state.swipingRideId == rideId,
    );
  }

  void removeTopRide() {
    if (state.queue.isEmpty) return;
    
    final updated = state.queue.sublist(1);
    state = state.copyWith(
      queue: updated,
      clearSwipingId: true,
    );
  }

  void setSwipingRide(String? rideId) {
    state = state.copyWith(
      swipingRideId: rideId,
      clearSwipingId: rideId == null,
    );
  }

  void setProcessing(bool processing) {
    state = state.copyWith(isProcessing: processing);
  }

  void syncWithProvider(List<RideOffer> providerRides) {
    final providerIds = providerRides.map((r) => r.id).toSet();
    
    final retained = state.queue.where((r) => providerIds.contains(r.id)).toList();
    
    final existingIds = retained.map((r) => r.id).toSet();
    final newRides = providerRides.where((r) => !existingIds.contains(r.id)).toList();
    
    state = state.copyWith(
      queue: [...retained, ...newRides],
    );
  }

  void clear() {
    state = const RideQueueState();
  }
}

final rideQueueProvider = StateNotifierProvider<RideQueueNotifier, RideQueueState>((ref) {
  return RideQueueNotifier();
});
