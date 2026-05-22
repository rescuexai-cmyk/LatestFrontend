import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Model for a saved/recent location
class SavedLocation {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String? placeId;
  final LocationType type;
  final DateTime savedAt;

  const SavedLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.placeId,
    required this.type,
    required this.savedAt,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'latitude': latitude,
    'longitude': longitude,
    'placeId': placeId,
    'type': type.name,
    'savedAt': savedAt.toIso8601String(),
  };

  factory SavedLocation.fromJson(Map<String, dynamic> json) => SavedLocation(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    placeId: json['placeId'] as String?,
    type: LocationType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => LocationType.recent,
    ),
    savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
  );

  /// Create from address and coordinates
  factory SavedLocation.create({
    required String name,
    required String address,
    required LatLng location,
    String? placeId,
    LocationType type = LocationType.recent,
  }) => SavedLocation(
    id: '${DateTime.now().millisecondsSinceEpoch}_${location.latitude.toStringAsFixed(4)}',
    name: name,
    address: address,
    latitude: location.latitude,
    longitude: location.longitude,
    placeId: placeId,
    type: type,
    savedAt: DateTime.now(),
  );

  SavedLocation copyWith({
    String? id,
    String? name,
    String? address,
    double? latitude,
    double? longitude,
    String? placeId,
    LocationType? type,
    DateTime? savedAt,
  }) => SavedLocation(
    id: id ?? this.id,
    name: name ?? this.name,
    address: address ?? this.address,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    placeId: placeId ?? this.placeId,
    type: type ?? this.type,
    savedAt: savedAt ?? this.savedAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedLocation &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum LocationType {
  home,
  work,
  favorite,
  recent,
}

/// State for saved locations
class SavedLocationsState {
  final List<SavedLocation> recentLocations;
  final SavedLocation? homeLocation;
  final SavedLocation? workLocation;
  final List<SavedLocation> favorites;
  final bool isLoading;

  const SavedLocationsState({
    this.recentLocations = const [],
    this.homeLocation,
    this.workLocation,
    this.favorites = const [],
    this.isLoading = false,
  });

  SavedLocationsState copyWith({
    List<SavedLocation>? recentLocations,
    SavedLocation? homeLocation,
    SavedLocation? workLocation,
    List<SavedLocation>? favorites,
    bool? isLoading,
  }) => SavedLocationsState(
    recentLocations: recentLocations ?? this.recentLocations,
    homeLocation: homeLocation ?? this.homeLocation,
    workLocation: workLocation ?? this.workLocation,
    favorites: favorites ?? this.favorites,
    isLoading: isLoading ?? this.isLoading,
  );

  /// Get all saved places (Home, Work, Favorites) for quick access
  List<SavedLocation> get savedPlaces {
    final places = <SavedLocation>[];
    if (homeLocation != null) places.add(homeLocation!);
    if (workLocation != null) places.add(workLocation!);
    places.addAll(favorites);
    return places;
  }

  /// Get combined list: saved places first, then recent
  List<SavedLocation> get allLocations {
    final all = <SavedLocation>[];
    all.addAll(savedPlaces);
    all.addAll(recentLocations.where((r) => 
      !savedPlaces.any((s) => _isSameLocation(s, r))
    ));
    return all;
  }

  static bool _isSameLocation(SavedLocation a, SavedLocation b) {
    // Consider same if within ~100 meters
    final latDiff = (a.latitude - b.latitude).abs();
    final lngDiff = (a.longitude - b.longitude).abs();
    return latDiff < 0.001 && lngDiff < 0.001;
  }
}

/// Notifier for saved locations with persistence
class SavedLocationsNotifier extends StateNotifier<SavedLocationsState> {
  static const String _recentKey = 'recent_locations';
  static const String _homeKey = 'home_location';
  static const String _workKey = 'work_location';
  static const String _favoritesKey = 'favorite_locations';
  static const int _maxRecentLocations = 10;

  SavedLocationsNotifier() : super(const SavedLocationsState(isLoading: true)) {
    // Defer loading to next microtask to avoid blocking constructor
    Future.microtask(() => _loadFromStorage());
  }

  Future<void> _loadFromStorage() async {
    try {
      // Add timeout to prevent blocking
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException('SharedPreferences timeout'),
      );

      // Load recent locations
      final recentJson = prefs.getString(_recentKey);
      List<SavedLocation> recent = [];
      if (recentJson != null) {
        final List<dynamic> decoded = json.decode(recentJson);
        recent = decoded.map((e) => SavedLocation.fromJson(e)).toList();
      }

      // Load home
      SavedLocation? home;
      final homeJson = prefs.getString(_homeKey);
      if (homeJson != null) {
        home = SavedLocation.fromJson(json.decode(homeJson));
      }

      // Load work
      SavedLocation? work;
      final workJson = prefs.getString(_workKey);
      if (workJson != null) {
        work = SavedLocation.fromJson(json.decode(workJson));
      }

      // Load favorites
      List<SavedLocation> favorites = [];
      final favoritesJson = prefs.getString(_favoritesKey);
      if (favoritesJson != null) {
        final List<dynamic> decoded = json.decode(favoritesJson);
        favorites = decoded.map((e) => SavedLocation.fromJson(e)).toList();
      }

      state = SavedLocationsState(
        recentLocations: recent,
        homeLocation: home,
        workLocation: work,
        favorites: favorites,
        isLoading: false,
      );
    } catch (e) {
      state = const SavedLocationsState(isLoading: false);
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Save recent
      await prefs.setString(
        _recentKey,
        json.encode(state.recentLocations.map((e) => e.toJson()).toList()),
      );

      // Save home
      if (state.homeLocation != null) {
        await prefs.setString(_homeKey, json.encode(state.homeLocation!.toJson()));
      } else {
        await prefs.remove(_homeKey);
      }

      // Save work
      if (state.workLocation != null) {
        await prefs.setString(_workKey, json.encode(state.workLocation!.toJson()));
      } else {
        await prefs.remove(_workKey);
      }

      // Save favorites
      await prefs.setString(
        _favoritesKey,
        json.encode(state.favorites.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      // Ignore storage errors
    }
  }

  /// Add a location to recent history (called when user completes a ride or selects a destination)
  Future<void> addRecentLocation({
    required String name,
    required String address,
    required LatLng location,
    String? placeId,
  }) async {
    final newLocation = SavedLocation.create(
      name: name,
      address: address,
      location: location,
      placeId: placeId,
      type: LocationType.recent,
    );

    // Remove duplicates (same coordinates within ~100m)
    final filtered = state.recentLocations.where((existing) {
      final latDiff = (existing.latitude - location.latitude).abs();
      final lngDiff = (existing.longitude - location.longitude).abs();
      return latDiff > 0.001 || lngDiff > 0.001;
    }).toList();

    // Add to front, limit to max
    final updated = [newLocation, ...filtered].take(_maxRecentLocations).toList();

    state = state.copyWith(recentLocations: updated);
    await _saveToStorage();
  }

  /// Set home location
  Future<void> setHomeLocation({
    required String name,
    required String address,
    required LatLng location,
    String? placeId,
  }) async {
    final home = SavedLocation.create(
      name: name.isNotEmpty ? name : 'Home',
      address: address,
      location: location,
      placeId: placeId,
      type: LocationType.home,
    );

    state = state.copyWith(homeLocation: home);
    await _saveToStorage();
  }

  /// Set work location
  Future<void> setWorkLocation({
    required String name,
    required String address,
    required LatLng location,
    String? placeId,
  }) async {
    final work = SavedLocation.create(
      name: name.isNotEmpty ? name : 'Work',
      address: address,
      location: location,
      placeId: placeId,
      type: LocationType.work,
    );

    state = state.copyWith(workLocation: work);
    await _saveToStorage();
  }

  /// Add a favorite location
  Future<void> addFavorite({
    required String name,
    required String address,
    required LatLng location,
    String? placeId,
  }) async {
    final favorite = SavedLocation.create(
      name: name,
      address: address,
      location: location,
      placeId: placeId,
      type: LocationType.favorite,
    );

    // Check for duplicates
    final exists = state.favorites.any((f) {
      final latDiff = (f.latitude - location.latitude).abs();
      final lngDiff = (f.longitude - location.longitude).abs();
      return latDiff < 0.001 && lngDiff < 0.001;
    });

    if (!exists) {
      state = state.copyWith(favorites: [...state.favorites, favorite]);
      await _saveToStorage();
    }
  }

  /// Remove a favorite
  Future<void> removeFavorite(String id) async {
    state = state.copyWith(
      favorites: state.favorites.where((f) => f.id != id).toList(),
    );
    await _saveToStorage();
  }

  /// Remove home location
  Future<void> removeHome() async {
    state = SavedLocationsState(
      recentLocations: state.recentLocations,
      homeLocation: null,
      workLocation: state.workLocation,
      favorites: state.favorites,
      isLoading: false,
    );
    await _saveToStorage();
  }

  /// Remove work location
  Future<void> removeWork() async {
    state = SavedLocationsState(
      recentLocations: state.recentLocations,
      homeLocation: state.homeLocation,
      workLocation: null,
      favorites: state.favorites,
      isLoading: false,
    );
    await _saveToStorage();
  }

  /// Clear recent locations
  Future<void> clearRecent() async {
    state = state.copyWith(recentLocations: []);
    await _saveToStorage();
  }

  /// Clear all saved data
  Future<void> clearAll() async {
    state = const SavedLocationsState(isLoading: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentKey);
    await prefs.remove(_homeKey);
    await prefs.remove(_workKey);
    await prefs.remove(_favoritesKey);
  }
}

/// Provider for saved locations
final savedLocationsProvider = StateNotifierProvider<SavedLocationsNotifier, SavedLocationsState>(
  (ref) => SavedLocationsNotifier(),
);

/// Quick access providers
final recentLocationsProvider = Provider<List<SavedLocation>>((ref) {
  return ref.watch(savedLocationsProvider).recentLocations;
});

final homeLocationProvider = Provider<SavedLocation?>((ref) {
  return ref.watch(savedLocationsProvider).homeLocation;
});

final workLocationProvider = Provider<SavedLocation?>((ref) {
  return ref.watch(savedLocationsProvider).workLocation;
});

final savedPlacesProvider = Provider<List<SavedLocation>>((ref) {
  return ref.watch(savedLocationsProvider).savedPlaces;
});
