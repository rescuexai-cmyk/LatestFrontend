import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Intermediate stop between pickup and final drop (multi-stop trips).
class RideStop {
  const RideStop({required this.address, this.location});

  final String address;
  final LatLng? location;

  bool get hasLocation => location != null;

  RideStop copyWith({String? address, LatLng? location}) {
    return RideStop(
      address: address ?? this.address,
      location: location ?? this.location,
    );
  }

  Map<String, dynamic> toApiJson() {
    return {
      if (location != null) 'lat': location!.latitude,
      if (location != null) 'lng': location!.longitude,
      'address': address,
    };
  }
}

/// Parses rider/backend stop arrays for driver offers and active ride screens.
List<RideStop> parseRideStopsFromJson(dynamic raw) {
  if (raw == null) return const [];

  final List<dynamic> items;
  if (raw is List) {
    items = raw;
  } else if (raw is Map) {
    final nested = raw['stops'] ?? raw['waypoints'] ?? raw['intermediateStops'];
    if (nested is! List) return const [];
    items = nested;
  } else {
    return const [];
  }

  final stops = <RideStop>[];
  for (final item in items) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item as Map);
    final address = (map['address'] ??
            map['name'] ??
            map['label'] ??
            map['placeName'] ??
            '')
        .toString()
        .trim();

    final lat = _toDouble(map['lat'] ?? map['latitude']);
    final lng = _toDouble(map['lng'] ?? map['longitude'] ?? map['lon']);
    LatLng? location;
    if (lat != null && lng != null && (lat != 0 || lng != 0)) {
      location = LatLng(lat, lng);
    }

    if (address.isEmpty && location == null) continue;
    stops.add(RideStop(address: address.isEmpty ? 'Stop' : address, location: location));
  }
  return stops;
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

/// Waypoint coordinates for Google Directions (ordered, location required).
List<LatLng> rideStopWaypoints(Iterable<RideStop> stops) {
  return stops
      .where((s) => s.location != null)
      .map((s) => s.location!)
      .toList(growable: false);
}

/// Rejects null island and out-of-range coordinates from bad API payloads.
bool isValidRideCoordinate(double lat, double lng) {
  if (lat.abs() < 0.0001 && lng.abs() < 0.0001) return false;
  if (lat.abs() > 90 || lng.abs() > 180) return false;
  return true;
}

bool isValidLatLng(LatLng? point) {
  if (point == null) return false;
  return isValidRideCoordinate(point.latitude, point.longitude);
}

LatLng? parsePickupLatLngFromJson(Map<String, dynamic> json) {
  final pickupLoc = json['pickupLocation'] ?? json['pickup_location'];
  if (pickupLoc is Map) {
    final lat = _toDouble(pickupLoc['lat'] ?? pickupLoc['latitude']);
    final lng = _toDouble(
      pickupLoc['lng'] ?? pickupLoc['longitude'] ?? pickupLoc['lon'],
    );
    if (lat != null &&
        lng != null &&
        isValidRideCoordinate(lat, lng)) {
      return LatLng(lat, lng);
    }
  }

  final lat = _toDouble(
    json['pickupLat'] ??
        json['pickupLatitude'] ??
        json['pickup_lat'],
  );
  final lng = _toDouble(
    json['pickupLng'] ??
        json['pickupLongitude'] ??
        json['pickup_lng'],
  );
  if (lat != null &&
      lng != null &&
      isValidRideCoordinate(lat, lng)) {
    return LatLng(lat, lng);
  }
  return null;
}

LatLng? parseDropLatLngFromJson(Map<String, dynamic> json) {
  final dropLoc = json['dropLocation'] ??
      json['destination_location'] ??
      json['drop_location'] ??
      json['dropoff_location'];
  if (dropLoc is Map) {
    final lat = _toDouble(dropLoc['lat'] ?? dropLoc['latitude']);
    final lng = _toDouble(
      dropLoc['lng'] ?? dropLoc['longitude'] ?? dropLoc['lon'],
    );
    if (lat != null &&
        lng != null &&
        isValidRideCoordinate(lat, lng)) {
      return LatLng(lat, lng);
    }
  }

  final lat = _toDouble(
    json['dropLat'] ??
        json['dropLatitude'] ??
        json['destinationLat'] ??
        json['drop_lat'],
  );
  final lng = _toDouble(
    json['dropLng'] ??
        json['dropLongitude'] ??
        json['destinationLng'] ??
        json['drop_lng'],
  );
  if (lat != null &&
      lng != null &&
      isValidRideCoordinate(lat, lng)) {
    return LatLng(lat, lng);
  }
  return null;
}
