import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/location.dart';
import '../models/ride.dart';

class MapsService {
  final String _apiKey = AppConfig.googleMapsApiKey;
  final String _baseUrl = 'https://maps.googleapis.com/maps/api';

  // Geocoding: Convert address to coordinates
  Future<GeocodingResult?> geocodeAddress(String address) async {
    try {
      final encodedAddress = Uri.encodeComponent(address);
      final url = '$_baseUrl/geocode/json?address=$encodedAddress&key=$_apiKey';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
        final result = (data['results'] as List).first as Map<String, dynamic>;
        final geometry = result['geometry'] as Map<String, dynamic>;
        final location = geometry['location'] as Map<String, dynamic>;
        
        return GeocodingResult(
          lat: (location['lat'] as num).toDouble(),
          lng: (location['lng'] as num).toDouble(),
          formattedAddress: result['formatted_address'] as String,
          placeId: result['place_id'] as String,
          types: List<String>.from(result['types'] as List),
          addressComponents: result['address_components'] as List<dynamic>,
        );
      }
      return null;
    } catch (e) {
      print('Geocoding error: $e');
      return null;
    }
  }

  // Reverse Geocoding: Convert coordinates to address
  Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final url = '$_baseUrl/geocode/json?latlng=$lat,$lng&key=$_apiKey';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['status'] == 'OK' && (data['results'] as List).isNotEmpty) {
        final result = (data['results'] as List).first as Map<String, dynamic>;
        return result['formatted_address'] as String;
      }
      return null;
    } catch (e) {
      print('Reverse geocoding error: $e');
      return null;
    }
  }

  // Get directions between two points
  Future<DirectionsResult?> getDirections(
    LocationCoordinate origin,
    LocationCoordinate destination, {
    List<LocationCoordinate>? waypoints,
    String mode = 'driving',
  }) async {
    try {
      final originStr = '${origin.lat},${origin.lng}';
      final destinationStr = '${destination.lat},${destination.lng}';
      
      var url = '$_baseUrl/directions/json?origin=$originStr&destination=$destinationStr&mode=$mode&key=$_apiKey';
      
      if (waypoints != null && waypoints.isNotEmpty) {
        final waypointsStr = waypoints.map((wp) => '${wp.lat},${wp.lng}').join('|');
        url += '&waypoints=$waypointsStr';
      }
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
        final route = (data['routes'] as List).first as Map<String, dynamic>;
        final leg = (route['legs'] as List).first as Map<String, dynamic>;
        final distance = leg['distance'] as Map<String, dynamic>;
        final duration = leg['duration'] as Map<String, dynamic>;
        
        return DirectionsResult(
          distanceText: distance['text'] as String,
          distanceValue: distance['value'] as int,
          durationText: duration['text'] as String,
          durationValue: duration['value'] as int,
          startAddress: leg['start_address'] as String,
          endAddress: leg['end_address'] as String,
          polyline: (route['overview_polyline'] as Map<String, dynamic>)['points'] as String,
          steps: leg['steps'] as List<dynamic>,
        );
      }
      return null;
    } catch (e) {
      print('Directions error: $e');
      return null;
    }
  }

  // Places Autocomplete for address suggestions
  Future<List<PlaceSuggestion>> getPlacesSuggestions(
    String input, {
    LocationCoordinate? location,
    int? radius,
  }) async {
    try {
      var url = '$_baseUrl/place/autocomplete/json?input=${Uri.encodeComponent(input)}&key=$_apiKey';
      
      if (location != null) {
        url += '&location=${location.lat},${location.lng}';
      }
      if (radius != null) {
        url += '&radius=$radius';
      }
      url += '&types=address|establishment';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['status'] == 'OK') {
        return (data['predictions'] as List)
            .map((p) => PlaceSuggestion.fromJson(p as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('Places suggestions error: $e');
      return [];
    }
  }

  // Get place details from place ID
  Future<PlaceDetails?> getPlaceDetails(String placeId) async {
    try {
      final url = '$_baseUrl/place/details/json?place_id=$placeId&fields=geometry,formatted_address,name,types&key=$_apiKey';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['status'] == 'OK') {
        final result = data['result'] as Map<String, dynamic>;
        final geometry = result['geometry'] as Map<String, dynamic>;
        final location = geometry['location'] as Map<String, dynamic>;
        
        return PlaceDetails(
          placeId: placeId,
          name: result['name'] as String? ?? '',
          formattedAddress: result['formatted_address'] as String? ?? '',
          lat: (location['lat'] as num).toDouble(),
          lng: (location['lng'] as num).toDouble(),
          types: List<String>.from(result['types'] as List? ?? []),
        );
      }
      return null;
    } catch (e) {
      print('Place details error: $e');
      return null;
    }
  }

  // Decode polyline string to coordinates array
  List<LocationCoordinate> decodePolyline(String polyline) {
    final coordinates = <LocationCoordinate>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < polyline.length) {
      int b;
      int shift = 0;
      int result = 0;
      
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      
      final deltaLat = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lat += deltaLat;

      shift = 0;
      result = 0;
      
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      
      final deltaLng = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lng += deltaLng;

      coordinates.add(LocationCoordinate(
        lat: lat * 1e-5,
        lng: lng * 1e-5,
      ));
    }

    return coordinates;
  }

  // Calculate distance between two coordinates using Haversine formula
  double calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371; // Radius of the Earth in km
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) * math.cos(_deg2rad(lat2)) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c; // Distance in km
  }

  double _deg2rad(double deg) {
    return deg * (math.pi / 180);
  }

  // Snap GPS coordinates to nearest road using Roads API
  // This improves accuracy for driver tracking
  Future<SnapToRoadResult?> snapToRoad(double lat, double lng) async {
    try {
      final url = '$_baseUrl/../roads/v1/snapToRoads'
          '?path=$lat,$lng'
          '&interpolate=false'
          '&key=$_apiKey';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['snappedPoints'] != null && (data['snappedPoints'] as List).isNotEmpty) {
        final point = (data['snappedPoints'] as List).first as Map<String, dynamic>;
        final location = point['location'] as Map<String, dynamic>;
        
        return SnapToRoadResult(
          lat: (location['latitude'] as num).toDouble(),
          lng: (location['longitude'] as num).toDouble(),
          placeId: point['placeId'] as String?,
        );
      }
      return null;
    } catch (e) {
      print('Snap to road error: $e');
      return null;
    }
  }

  // Snap multiple points to roads (for route smoothing)
  Future<List<SnapToRoadResult>> snapPathToRoads(List<LocationCoordinate> points) async {
    if (points.isEmpty) return [];
    
    try {
      // Roads API supports up to 100 points per request
      final pathString = points
          .take(100)
          .map((p) => '${p.lat},${p.lng}')
          .join('|');
      
      final url = '$_baseUrl/../roads/v1/snapToRoads'
          '?path=$pathString'
          '&interpolate=true'
          '&key=$_apiKey';
      
      final response = await http.get(Uri.parse(url));
      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (data['snappedPoints'] != null) {
        return (data['snappedPoints'] as List).map((point) {
          final location = point['location'] as Map<String, dynamic>;
          return SnapToRoadResult(
            lat: (location['latitude'] as num).toDouble(),
            lng: (location['longitude'] as num).toDouble(),
            placeId: point['placeId'] as String?,
            originalIndex: point['originalIndex'] as int?,
          );
        }).toList();
      }
      return [];
    } catch (e) {
      print('Snap path to roads error: $e');
      return [];
    }
  }

  // Calculate fare estimate based on distance and time
  FareEstimate calculateFareEstimate(double distance, double duration, {String rideType = 'economy'}) {
    // Base fare rates (per km and per minute)
    final rates = {
      'bike': {'baseRate': 5, 'perKm': 5, 'perMinute': 0.5},
      'economy': {'baseRate': 10, 'perKm': 8, 'perMinute': 1},
      'comfort': {'baseRate': 15, 'perKm': 12, 'perMinute': 1.5},
      'premium': {'baseRate': 25, 'perKm': 18, 'perMinute': 2},
      'xl': {'baseRate': 20, 'perKm': 15, 'perMinute': 1.8},
    };

    final rate = rates[rideType] ?? rates['economy']!;
    final distanceKm = distance / 1000;
    final durationMinutes = duration / 60;

    final baseFare = rate['baseRate']!.toDouble();
    final distanceFare = distanceKm * rate['perKm']!.toDouble();
    final timeFare = durationMinutes * rate['perMinute']!.toDouble();
    
    final subtotal = baseFare + distanceFare + timeFare;
    final taxes = subtotal * 0.05; // 5% tax
    final total = subtotal + taxes;

    return FareEstimate(
      rideType: rideType,
      baseFare: baseFare,
      distanceFare: distanceFare,
      timeFare: timeFare,
      subtotal: subtotal,
      taxes: taxes,
      total: total,
      currency: 'INR',
      estimatedDistance: distanceKm,
      estimatedDuration: durationMinutes,
      distance: distanceKm,
      estimatedTime: duration,
    );
  }
}

class DirectionsResult {
  final String distanceText;
  final int distanceValue;
  final String durationText;
  final int durationValue;
  final String startAddress;
  final String endAddress;
  final String polyline;
  final List<dynamic> steps;

  const DirectionsResult({
    required this.distanceText,
    required this.distanceValue,
    required this.durationText,
    required this.durationValue,
    required this.startAddress,
    required this.endAddress,
    required this.polyline,
    required this.steps,
  });
}

/// Result from Snap to Roads API
class SnapToRoadResult {
  final double lat;
  final double lng;
  final String? placeId;
  final int? originalIndex;

  const SnapToRoadResult({
    required this.lat,
    required this.lng,
    this.placeId,
    this.originalIndex,
  });

  LocationCoordinate toCoordinate() => LocationCoordinate(lat: lat, lng: lng);
}

// Singleton instance
final mapsService = MapsService();


