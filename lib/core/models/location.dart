import 'package:equatable/equatable.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class LocationCoordinate extends Equatable {
  final double lat;
  final double lng;

  const LocationCoordinate({
    required this.lat,
    required this.lng,
  });

  factory LocationCoordinate.fromJson(Map<String, dynamic> json) {
    return LocationCoordinate(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
    );
  }

  factory LocationCoordinate.fromLatLng(LatLng latLng) {
    return LocationCoordinate(
      lat: latLng.latitude,
      lng: latLng.longitude,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lat': lat,
      'lng': lng,
    };
  }

  LatLng toLatLng() {
    return LatLng(lat, lng);
  }

  @override
  List<Object?> get props => [lat, lng];
}

class AddressLocation extends Equatable {
  final double latitude;
  final double longitude;
  final String? address;
  final String? name;
  final String? placeId;

  const AddressLocation({
    required this.latitude,
    required this.longitude,
    this.address,
    this.name,
    this.placeId,
  });

  factory AddressLocation.fromJson(Map<String, dynamic> json) {
    // Handle both {latitude, longitude} and {lat, lng} formats
    final lat = json['latitude'] ?? json['lat'];
    final lng = json['longitude'] ?? json['lng'];
    return AddressLocation(
      latitude: (lat as num?)?.toDouble() ?? 0.0,
      longitude: (lng as num?)?.toDouble() ?? 0.0,
      address: json['address'] as String?,
      name: json['name'] as String?,
      placeId: json['place_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'name': name,
      'place_id': placeId,
    };
  }

  LocationCoordinate toLocationCoordinate() {
    return LocationCoordinate(lat: latitude, lng: longitude);
  }

  LatLng toLatLng() {
    return LatLng(latitude, longitude);
  }

  @override
  List<Object?> get props => [latitude, longitude, address, name, placeId];
}

class GeocodingResult {
  final double lat;
  final double lng;
  final String formattedAddress;
  final String placeId;
  final List<String> types;
  final List<dynamic> addressComponents;

  const GeocodingResult({
    required this.lat,
    required this.lng,
    required this.formattedAddress,
    required this.placeId,
    required this.types,
    required this.addressComponents,
  });

  factory GeocodingResult.fromJson(Map<String, dynamic> json) {
    return GeocodingResult(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      formattedAddress: json['formattedAddress'] as String,
      placeId: json['placeId'] as String,
      types: List<String>.from(json['types'] as List),
      addressComponents: json['addressComponents'] as List<dynamic>,
    );
  }
}

class PlaceSuggestion {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;
  final List<String> types;

  const PlaceSuggestion({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
    required this.types,
  });

  factory PlaceSuggestion.fromJson(Map<String, dynamic> json) {
    final structuredFormatting = json['structured_formatting'] as Map<String, dynamic>?;
    return PlaceSuggestion(
      placeId: json['place_id'] as String,
      description: json['description'] as String,
      mainText: structuredFormatting?['main_text'] as String? ?? '',
      secondaryText: structuredFormatting?['secondary_text'] as String? ?? '',
      types: List<String>.from(json['types'] as List? ?? []),
    );
  }
}

class PlaceDetails {
  final String placeId;
  final String name;
  final String formattedAddress;
  final double lat;
  final double lng;
  final List<String> types;

  const PlaceDetails({
    required this.placeId,
    required this.name,
    required this.formattedAddress,
    required this.lat,
    required this.lng,
    required this.types,
  });

  factory PlaceDetails.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry'] as Map<String, dynamic>?;
    final location = geometry?['location'] as Map<String, dynamic>?;
    return PlaceDetails(
      placeId: json['place_id'] as String,
      name: json['name'] as String? ?? '',
      formattedAddress: json['formatted_address'] as String? ?? '',
      lat: (location?['lat'] as num?)?.toDouble() ?? 0,
      lng: (location?['lng'] as num?)?.toDouble() ?? 0,
      types: List<String>.from(json['types'] as List? ?? []),
    );
  }

  LocationCoordinate toLocationCoordinate() {
    return LocationCoordinate(lat: lat, lng: lng);
  }
}


