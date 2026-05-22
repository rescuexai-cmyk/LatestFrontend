import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';

class PlaceSearchResult {
  final String placeId;
  final String name;
  final String address;
  final LatLng? latLng;
  final String? photoReference;

  PlaceSearchResult({
    required this.placeId,
    required this.name,
    required this.address,
    this.latLng,
    this.photoReference,
  });
  
  /// Get Google Places photo URL from photo reference
  String? getPhotoUrl({int maxWidth = 400}) {
    if (photoReference == null || photoReference!.isEmpty) return null;
    return 'https://maps.googleapis.com/maps/api/place/photo'
        '?maxwidth=$maxWidth'
        '&photo_reference=$photoReference'
        '&key=${AppConfig.googleMapsApiKey}';
  }
}

class PlacesService {
  static const String _baseUrl = 'https://maps.googleapis.com/maps/api/place';
  final String _apiKey = AppConfig.googleMapsApiKey;
  
  // Session token for Places Autocomplete - groups requests for billing optimization
  // A session begins when user starts typing and ends when they select a place
  String? _sessionToken;
  DateTime? _sessionStartTime;
  static const Duration _sessionTimeout = Duration(minutes: 3);
  final Uuid _uuid = const Uuid();

  /// Get or create a session token for autocomplete requests
  /// Sessions reduce API costs by grouping multiple autocomplete requests
  String _getSessionToken() {
    final now = DateTime.now();
    
    // Create new session if none exists or if timed out (3 min max per Google docs)
    if (_sessionToken == null || 
        _sessionStartTime == null ||
        now.difference(_sessionStartTime!) > _sessionTimeout) {
      _sessionToken = _uuid.v4();
      _sessionStartTime = now;
      debugPrint('🔑 New Places session token created: ${_sessionToken!.substring(0, 8)}...');
    }
    
    return _sessionToken!;
  }

  /// End the current session (call when user selects a place)
  void endSession() {
    if (_sessionToken != null) {
      debugPrint('🔑 Places session ended: ${_sessionToken!.substring(0, 8)}...');
    }
    _sessionToken = null;
    _sessionStartTime = null;
  }

  /// Search for places using Google Places Autocomplete API
  /// Uses broad search without type restrictions for better results
  /// Session tokens are used to group requests for billing optimization
  Future<List<PlaceSearchResult>> searchPlaces(String query, {LatLng? location}) async {
    if (query.isEmpty) return [];
    
    // Minimum 2 characters for meaningful search
    if (query.length < 2) return [];

    try {
      // Get session token for billing optimization
      final sessionToken = _getSessionToken();
      
      // Build URL with location bias for better results in India
      // Remove type restrictions to get broader results (addresses, establishments, landmarks, etc.)
      String urlString = '$_baseUrl/autocomplete/json'
          '?input=${Uri.encodeComponent(query)}'
          '&key=$_apiKey'
          '&components=country:in'
          '&language=en'
          '&sessiontoken=$sessionToken'; // Session token for billing optimization
      
      // Strict location restriction: only show results near user's city (~50km)
      // `strictbounds` enforces the radius as a hard boundary, not just a preference
      if (location != null) {
        urlString += '&location=${location.latitude},${location.longitude}'
            '&radius=50000'
            '&strictbounds';
      }
      
      final url = Uri.parse(urlString);

      debugPrint('🔍 Places API request: $url');
      
      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Places API timeout'),
      );
      
      if (response.statusCode != 200) {
        debugPrint('❌ Places API error: ${response.statusCode} - ${response.body}');
        return [];
      }

      final data = json.decode(response.body);
      final status = data['status'] as String;

      debugPrint('📍 Places API status: $status, predictions: ${(data['predictions'] as List?)?.length ?? 0}');

      if (status == 'REQUEST_DENIED') {
        debugPrint('❌ Places API REQUEST_DENIED: ${data['error_message'] ?? 'Check API key permissions'}');
        return [];
      }
      
      if (status == 'INVALID_REQUEST') {
        debugPrint('❌ Places API INVALID_REQUEST: ${data['error_message'] ?? ''}');
        return [];
      }

      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('❌ Places API status: $status - ${data['error_message'] ?? ''}');
        return [];
      }

      final predictions = data['predictions'] as List<dynamic>? ?? [];
      
      return predictions.map((prediction) {
        return PlaceSearchResult(
          placeId: prediction['place_id'] as String,
          name: prediction['structured_formatting']?['main_text'] as String? ?? 
                prediction['description'] as String? ?? '',
          address: prediction['structured_formatting']?['secondary_text'] as String? ?? 
                   prediction['description'] as String? ?? '',
        );
      }).toList();

    } catch (e) {
      debugPrint('❌ Places search error: $e');
      return [];
    }
  }

  /// Fallback: Search using Google Places Text Search API
  /// More comprehensive but slightly slower than Autocomplete
  Future<List<PlaceSearchResult>> textSearchPlaces(String query, {LatLng? location}) async {
    if (query.isEmpty || query.length < 2) return [];

    try {
      // Don't append " India" — location restriction handles relevance
      String urlString = '$_baseUrl/textsearch/json'
          '?query=${Uri.encodeComponent(query)}'
          '&key=$_apiKey'
          '&language=en';
      
      // Location bias: prefer results within ~50km of user
      // Note: Text Search API doesn't support strictbounds (Autocomplete does)
      if (location != null) {
        urlString += '&location=${location.latitude},${location.longitude}'
            '&radius=50000';
      }
      
      final url = Uri.parse(urlString);
      debugPrint('🔍 Text Search API request: $url');
      
      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Text Search API timeout'),
      );
      
      if (response.statusCode != 200) {
        debugPrint('❌ Text Search API error: ${response.statusCode}');
        return [];
      }

      final data = json.decode(response.body);
      final status = data['status'] as String;
      
      debugPrint('📍 Text Search API status: $status, results: ${(data['results'] as List?)?.length ?? 0}');

      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('❌ Text Search API status: $status - ${data['error_message'] ?? ''}');
        return [];
      }

      final results = data['results'] as List<dynamic>? ?? [];
      
      return results.take(15).map((result) {
        final geometry = result['geometry']?['location'];
        LatLng? latLng;
        if (geometry != null) {
          latLng = LatLng(
            (geometry['lat'] as num).toDouble(),
            (geometry['lng'] as num).toDouble(),
          );
        }
        
        return PlaceSearchResult(
          placeId: result['place_id'] as String? ?? '',
          name: result['name'] as String? ?? '',
          address: result['formatted_address'] as String? ?? '',
          latLng: latLng,
        );
      }).toList();

    } catch (e) {
      debugPrint('❌ Text Search error: $e');
      return [];
    }
  }

  /// Combined search: runs Autocomplete AND Text Search in parallel, merges for richer suggestions.
  /// 
  /// Text Search finds establishments (PVR, malls, hospitals) better; Autocomplete finds addresses.
  /// Merging both gives users proper "map suggestions" like Rapido/Uber.
  Future<List<PlaceSearchResult>> searchPlacesWithFallback(String query, {LatLng? location}) async {
    debugPrint('🔍 searchPlacesWithFallback called with query: "$query"');
    if (query.trim().isEmpty || query.trim().length < 2) return [];

    // Run both in parallel for richer results
    final results = await Future.wait([
      searchPlaces(query, location: location),
      textSearchPlaces(query, location: location),
    ]);
    final autocompleteResults = results[0] as List<PlaceSearchResult>;
    final textResults = results[1] as List<PlaceSearchResult>;

    debugPrint('📍 Autocomplete: ${autocompleteResults.length}, Text Search: ${textResults.length}');

    // Merge: Text Search first (has latLng, better for establishments like "PVR prayagraj"),
    // then Autocomplete (addresses). Deduplicate by placeId.
    final seenIds = <String>{};
    final merged = <PlaceSearchResult>[];

    for (final r in textResults) {
      if (r.placeId.isNotEmpty && !seenIds.contains(r.placeId)) {
        seenIds.add(r.placeId);
        merged.add(r);
      }
    }
    for (final r in autocompleteResults) {
      if (r.placeId.isNotEmpty && !seenIds.contains(r.placeId)) {
        seenIds.add(r.placeId);
        merged.add(r);
      }
    }

    if (merged.isNotEmpty) {
      debugPrint('✅ Merged ${merged.length} suggestions');
      return merged;
    }

    // Final fallback: Geocoding API
    debugPrint('📍 No Places results, trying Geocoding API...');
    return _geocodeSearch(query);
  }
  
  /// Fallback: Search using Google Geocoding API
  Future<List<PlaceSearchResult>> _geocodeSearch(String query) async {
    if (query.isEmpty || query.length < 2) return [];
    
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=${Uri.encodeComponent(query)}'
        '&key=$_apiKey'
        '&components=country:IN'
        '&language=en'
      );
      
      debugPrint('🔍 Geocoding API request: $url');
      
      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Geocoding API timeout'),
      );
      
      if (response.statusCode != 200) {
        debugPrint('❌ Geocoding API error: ${response.statusCode}');
        return [];
      }
      
      final data = json.decode(response.body);
      final status = data['status'] as String;
      
      debugPrint('📍 Geocoding API status: $status, results: ${(data['results'] as List?)?.length ?? 0}');
      
      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('❌ Geocoding API status: $status - ${data['error_message'] ?? ''}');
        return [];
      }
      
      final results = data['results'] as List<dynamic>? ?? [];
      
      return results.take(5).map((result) {
        final geometry = result['geometry']?['location'];
        LatLng? latLng;
        if (geometry != null) {
          latLng = LatLng(
            (geometry['lat'] as num).toDouble(),
            (geometry['lng'] as num).toDouble(),
          );
        }
        
        // Extract a meaningful name from address components
        final components = result['address_components'] as List<dynamic>? ?? [];
        String name = '';
        for (final comp in components) {
          final types = comp['types'] as List<dynamic>? ?? [];
          if (types.contains('sublocality_level_1') || 
              types.contains('locality') ||
              types.contains('neighborhood') ||
              types.contains('route')) {
            name = comp['long_name'] as String? ?? '';
            break;
          }
        }
        if (name.isEmpty) {
          name = (result['formatted_address'] as String? ?? '').split(',').first;
        }
        
        return PlaceSearchResult(
          placeId: result['place_id'] as String? ?? '',
          name: name,
          address: result['formatted_address'] as String? ?? '',
          latLng: latLng,
        );
      }).toList();
      
    } catch (e) {
      debugPrint('❌ Geocoding search error: $e');
      return [];
    }
  }

  /// Get place details (coordinates) using Google Places Details API
  /// This completes the session - session token is included for billing optimization
  Future<LatLng?> getPlaceDetails(String placeId) async {
    try {
      // Include session token to complete the session (billing optimization)
      final sessionToken = _sessionToken;
      String urlString = '$_baseUrl/details/json?place_id=$placeId&key=$_apiKey&fields=geometry';
      
      if (sessionToken != null) {
        urlString += '&sessiontoken=$sessionToken';
      }
      
      final url = Uri.parse(urlString);

      debugPrint('📍 Getting place details for: $placeId');
      
      final response = await http.get(url);
      
      // End session after place details request (user selected a place)
      endSession();
      
      if (response.statusCode != 200) {
        debugPrint('❌ Place details error: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body);
      final status = data['status'] as String;

      if (status != 'OK') {
        debugPrint('❌ Place details status: $status');
        return null;
      }

      final location = data['result']?['geometry']?['location'];
      if (location == null) return null;

      return LatLng(
        location['lat'] as double,
        location['lng'] as double,
      );

    } catch (e) {
      debugPrint('❌ Place details error: $e');
      return null;
    }
  }

  /// Search and get full place info with coordinates
  Future<List<PlaceSearchResult>> searchPlacesWithCoordinates(String query) async {
    final results = await searchPlaces(query);
    
    // Get coordinates for first few results
    final enrichedResults = <PlaceSearchResult>[];
    
    for (final result in results.take(5)) {
      final latLng = await getPlaceDetails(result.placeId);
      enrichedResults.add(PlaceSearchResult(
        placeId: result.placeId,
        name: result.name,
        address: result.address,
        latLng: latLng,
      ));
    }
    
    return enrichedResults;
  }

  /// Fetch nearby places (realtime) using Google Places Nearby Search API
  /// Returns places within radius of the given location
  Future<List<PlaceSearchResult>> getNearbyPlaces({
    required LatLng location,
    int radiusMeters = 5000,
    String type = '',
  }) async {
    try {
      String urlString = '$_baseUrl/nearbysearch/json'
          '?location=${location.latitude},${location.longitude}'
          '&radius=$radiusMeters'
          '&key=$_apiKey'
          '&language=en';
      if (type.isNotEmpty) {
        urlString += '&type=$type';
      }
      final url = Uri.parse(urlString);
      debugPrint('📍 Nearby Places API request for ${location.latitude},${location.longitude}');

      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Nearby Places API timeout'),
      );

      if (response.statusCode != 200) {
        debugPrint('❌ Nearby Places API error: ${response.statusCode}');
        return [];
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String;

      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('❌ Nearby Places API status: $status');
        return [];
      }

      final results = data['results'] as List<dynamic>? ?? [];
      return results.take(8).map((result) {
        final r = result as Map<String, dynamic>;
        final geometry = r['geometry']?['location'];
        LatLng? latLng;
        if (geometry != null) {
          latLng = LatLng(
            (geometry['lat'] as num).toDouble(),
            (geometry['lng'] as num).toDouble(),
          );
        }
        
        // Extract photo reference if available
        String? photoRef;
        final photos = r['photos'] as List<dynamic>?;
        if (photos != null && photos.isNotEmpty) {
          photoRef = photos[0]['photo_reference'] as String?;
        }
        
        return PlaceSearchResult(
          placeId: r['place_id'] as String? ?? '',
          name: r['name'] as String? ?? 'Unknown',
          address: r['vicinity'] as String? ?? r['formatted_address'] as String? ?? '',
          latLng: latLng,
          photoReference: photoRef,
        );
      }).toList();
    } catch (e) {
      debugPrint('❌ Nearby places error: $e');
      return [];
    }
  }

  /// Search places and return as List<Map> for compatibility
  /// Uses fallback search for better results
  Future<List<Map<String, dynamic>>> searchPlacesAsMap(String query, {LatLng? location}) async {
    final results = await searchPlacesWithFallback(query, location: location);
    return results.map((r) => {
      'place_id': r.placeId,
      'name': r.name,
      'address': r.address,
      'lat': r.latLng?.latitude,
      'lng': r.latLng?.longitude,
    }).toList();
  }

  /// Get place details as Map for compatibility
  Future<Map<String, dynamic>?> getPlaceDetailsAsMap(String placeId) async {
    final latLng = await getPlaceDetails(placeId);
    if (latLng == null) return null;
    return {
      'lat': latLng.latitude,
      'lng': latLng.longitude,
    };
  }
}

// Singleton instance
final placesService = PlacesService();
