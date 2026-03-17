import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/places_service.dart';
import '../services/maps_service.dart';

/// A nearby place with name, estimated travel time, coordinates, and photo
class NearbyPlace {
  final String name;
  final String address;
  final String timeText;
  final LatLng latLng;
  final String placeId;
  final double distanceKm;
  final String? photoUrl;

  const NearbyPlace({
    required this.name,
    required this.address,
    required this.timeText,
    required this.latLng,
    required this.placeId,
    required this.distanceKm,
    this.photoUrl,
  });
}

/// State for nearby places
class NearbyPlacesState {
  final List<NearbyPlace> places;
  final bool isLoading;
  final String? error;
  final LatLng? lastLocation;

  const NearbyPlacesState({
    this.places = const [],
    this.isLoading = false,
    this.error,
    this.lastLocation,
  });

  NearbyPlacesState copyWith({
    List<NearbyPlace>? places,
    bool? isLoading,
    String? error,
    LatLng? lastLocation,
  }) =>
      NearbyPlacesState(
        places: places ?? this.places,
        isLoading: isLoading ?? this.isLoading,
        error: error,
        lastLocation: lastLocation ?? this.lastLocation,
      );
}

/// Provider that fetches nearby places based on current device location (realtime)
final nearbyPlacesProvider =
    StateNotifierProvider<NearbyPlacesNotifier, NearbyPlacesState>((ref) {
  return NearbyPlacesNotifier();
});

class NearbyPlacesNotifier extends StateNotifier<NearbyPlacesState> {
  NearbyPlacesNotifier() : super(const NearbyPlacesState());

  /// Estimate travel time (min) from distance: ~25 km/h average in city
  static String _estimateTime(double distanceKm) {
    final minutes = (distanceKm / 25 * 60).ceil().clamp(1, 120);
    if (minutes >= 60) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      return m > 0 ? '${h}h ${m}min' : '${h}h';
    }
    return '$minutes min';
  }

  /// Refresh nearby places using current device location
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 5),
      );
      final location = LatLng(position.latitude, position.longitude);

      final results = await placesService.getNearbyPlaces(
        location: location,
        radiusMeters: 5000,
      );

      if (results.isEmpty) {
        state = state.copyWith(
          places: [],
          isLoading: false,
          lastLocation: location,
        );
        return;
      }

      final maps = mapsService;
      final places = <NearbyPlace>[];

      for (final r in results) {
        if (r.latLng == null) continue;
        final distKm = maps.calculateDistance(
          location.latitude,
          location.longitude,
          r.latLng!.latitude,
          r.latLng!.longitude,
        );
        places.add(NearbyPlace(
          name: r.name,
          address: r.address,
          timeText: _estimateTime(distKm),
          latLng: r.latLng!,
          placeId: r.placeId,
          distanceKm: distKm,
          photoUrl: r.getPhotoUrl(maxWidth: 400),
        ));
      }

      // Sort by distance
      places.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

      state = state.copyWith(
        places: places.take(6).toList(),
        isLoading: false,
        lastLocation: location,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}
