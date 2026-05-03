import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dio/dio.dart';
import '../config/app_config.dart';

/// Service for getting directions and routes between locations
class DirectionsService {
  static final DirectionsService _instance = DirectionsService._internal();
  factory DirectionsService() => _instance;
  DirectionsService._internal();

  final Dio _dio = Dio();

  /// Get route from Google Directions API
  Future<RouteResult> getRoute({
    required LatLng origin,
    required LatLng destination,
    List<LatLng>? waypoints,
    TravelMode mode = TravelMode.driving,
  }) async {
    try {
      final String apiKey = AppConfig.googleMapsApiKey;
      
      debugPrint('🗺️ Getting route via Directions API...');
      debugPrint('   Origin: ${origin.latitude}, ${origin.longitude}');
      debugPrint('   Destination: ${destination.latitude}, ${destination.longitude}');
      debugPrint('   API Key present: ${apiKey.isNotEmpty && apiKey != 'YOUR_API_KEY_HERE'}');
      
      if (apiKey.isEmpty || apiKey == 'YOUR_API_KEY_HERE') {
        // Fallback to Dijkstra-based local routing
        debugPrint('📍 Using local Dijkstra routing (no API key)');
        return _getLocalRoute(origin, destination, waypoints);
      }

      final String url = 'https://maps.googleapis.com/maps/api/directions/json';
      
      String waypointsParam = '';
      if (waypoints != null && waypoints.isNotEmpty) {
        waypointsParam = waypoints
            .map((wp) => '${wp.latitude},${wp.longitude}')
            .join('|');
      }

      debugPrint('🌐 Calling Directions API...');
      
      final response = await _dio.get(
        url, 
        queryParameters: {
          'origin': '${origin.latitude},${origin.longitude}',
          'destination': '${destination.latitude},${destination.longitude}',
          'mode': mode.name,
          if (waypointsParam.isNotEmpty) 'waypoints': waypointsParam,
          'key': apiKey,
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );

      debugPrint('📡 API Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = response.data;
        
        debugPrint('📡 API Response data status: ${data['status']}');
        
        if (data['status'] == 'OK' && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final legs = route['legs'] as List;
          
          // Sum distance and duration across all legs (multi-stop routes)
          double totalDistance = 0;
          double totalDuration = 0;
          for (final leg in legs) {
            totalDistance += (leg['distance']['value'] as num).toDouble();
            totalDuration += (leg['duration']['value'] as num).toDouble();
          }
          
          final firstLeg = legs.first;
          final lastLeg = legs.last;
          
          // Decode polyline (overview covers full route including waypoints)
          final encodedPolyline = route['overview_polyline']['points'] as String;
          final polylinePoints = _decodePolyline(encodedPolyline);
          
          debugPrint('✅ Directions API success!');
          debugPrint('   Polyline points: ${polylinePoints.length}');
          debugPrint('   Legs: ${legs.length}, Distance: ${totalDistance}m, Duration: ${totalDuration}s');
          
          final firstLegDur =
              (firstLeg['duration']['value'] as num).toDouble();

          return RouteResult(
            points: polylinePoints,
            distance: totalDistance,
            duration: totalDuration,
            firstLegDurationSeconds: firstLegDur,
            legCount: legs.length,
            distanceText: _formatDistance(totalDistance),
            durationText: _formatDuration(totalDuration),
            startAddress: firstLeg['start_address'] ?? 'Pickup',
            endAddress: lastLeg['end_address'] ?? 'Destination',
            bounds: LatLngBounds(
              southwest: LatLng(
                route['bounds']['southwest']['lat'].toDouble(),
                route['bounds']['southwest']['lng'].toDouble(),
              ),
              northeast: LatLng(
                route['bounds']['northeast']['lat'].toDouble(),
                route['bounds']['northeast']['lng'].toDouble(),
              ),
            ),
          );
        } else {
          debugPrint('⚠️ Directions API returned status: ${data['status']}');
          debugPrint('   Error: ${data['error_message'] ?? 'No error message'}');
          debugPrint('   Note: Enable Directions API in Google Cloud Console and ensure billing is active');
        }
      }
      
      // Fallback to local routing if API fails
      debugPrint('⚠️ Directions API failed, using local routing');
      return _getLocalRoute(origin, destination, waypoints);
      
    } catch (e) {
      debugPrint('❌ Directions API error: $e');
      debugPrint('📍 Falling back to local Dijkstra routing');
      return _getLocalRoute(origin, destination, waypoints);
    }
  }

  /// Local route calculation using Dijkstra's algorithm on a simulated road network.
  /// This is a fallback when the Google Directions API is unavailable.
  /// Distances are multiplied by a road-factor (1.4×) to approximate real road distance.
  RouteResult _getLocalRoute(LatLng origin, LatLng destination, List<LatLng>? waypoints) {
    debugPrint('⚠️ Using local fallback routing (Directions API unavailable)');

    final graph = RoadGraph();
    
    // Build a simple road network around the origin and destination
    graph.buildNetworkAround(origin, destination);
    
    // Find shortest path using Dijkstra
    final path = graph.dijkstraShortestPath(origin, destination);
    
    // Calculate total distance along the path
    double totalDistance = 0;
    for (int i = 0; i < path.length - 1; i++) {
      totalDistance += _calculateDistance(path[i], path[i + 1]);
    }

    // Apply road-factor: real roads are typically 1.3–1.5× straight-line distance
    totalDistance *= 1.4;
    
    // Estimate duration (assuming average speed of 25 km/h in city with traffic)
    final duration = (totalDistance / 1000) / 25 * 3600; // seconds
    
    return RouteResult(
      points: path,
      distance: totalDistance,
      duration: duration,
      firstLegDurationSeconds: duration,
      legCount: 1,
      distanceText: '~${_formatDistance(totalDistance)}',
      durationText: '~${_formatDuration(duration)}',
      startAddress: 'Pickup Location',
      endAddress: 'Destination',
      bounds: _calculateBounds(path),
    );
  }

  /// Decode Google's encoded polyline format
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int shift = 0;
      int result = 0;
      int byte;
      
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1F) << shift;
        shift += 5;
      } while (byte >= 0x20);
      
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1F) << shift;
        shift += 5;
      } while (byte >= 0x20);
      
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    
    return points;
  }

  double _calculateDistance(LatLng p1, LatLng p2) {
    const double earthRadius = 6371000; // meters
    final double dLat = _toRadians(p2.latitude - p1.latitude);
    final double dLng = _toRadians(p2.longitude - p1.longitude);
    
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(p1.latitude)) * math.cos(_toRadians(p2.latitude)) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    }
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatDuration(double seconds) {
    if (seconds < 60) {
      return '${seconds.round()} sec';
    }
    final minutes = (seconds / 60).round();
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '$hours h $mins min';
  }

  LatLngBounds _calculateBounds(List<LatLng> points) {
    if (points.isEmpty) {
      return LatLngBounds(
        southwest: const LatLng(0, 0),
        northeast: const LatLng(0, 0),
      );
    }
    
    double minLat = points[0].latitude;
    double maxLat = points[0].latitude;
    double minLng = points[0].longitude;
    double maxLng = points[0].longitude;
    
    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }
    
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }
}

/// Road graph for Dijkstra's algorithm
class RoadGraph {
  final Map<String, List<RoadEdge>> _adjacencyList = {};
  final Map<String, LatLng> _nodes = {};

  /// Build a road network around origin and destination
  void buildNetworkAround(LatLng origin, LatLng destination) {
    // Create a grid-like road network between origin and destination
    final double latDiff = destination.latitude - origin.latitude;
    final double lngDiff = destination.longitude - origin.longitude;
    
    // Increased grid resolution for smoother paths
    const int gridSize = 12;
    
    // Add nodes in a grid pattern
    for (int i = 0; i <= gridSize; i++) {
      for (int j = 0; j <= gridSize; j++) {
        final lat = origin.latitude + (latDiff * i / gridSize);
        final lng = origin.longitude + (lngDiff * j / gridSize);
        
        // Add some randomness to simulate real road network
        final random = math.Random(i * 100 + j);
        final latOffset = (random.nextDouble() - 0.5) * 0.001;
        final lngOffset = (random.nextDouble() - 0.5) * 0.001;
        
        final node = LatLng(lat + latOffset, lng + lngOffset);
        _addNode(node);
      }
    }
    
    // Ensure origin and destination are in the graph
    _addNode(origin);
    _addNode(destination);
    
    // Connect adjacent nodes (simulating roads)
    final nodeList = _nodes.values.toList();
    for (int i = 0; i < nodeList.length; i++) {
      for (int j = i + 1; j < nodeList.length; j++) {
        final distance = _calculateHaversineDistance(nodeList[i], nodeList[j]);
        
        // Connect nodes that are close enough (simulating road segments)
        // Average road segment length ~200-500 meters
        if (distance < 800) {
          // Add some roads with different weights (traffic, road type)
          final random = math.Random((nodeList[i].latitude * 1000000).toInt());
          final weight = distance * (1 + random.nextDouble() * 0.3); // 0-30% traffic factor
          
          _addEdge(nodeList[i], nodeList[j], weight);
        }
      }
    }
    
    // Connect origin and destination to nearest nodes
    _connectToNearestNodes(origin, 3);
    _connectToNearestNodes(destination, 3);
  }

  void _addNode(LatLng node) {
    final key = _nodeKey(node);
    if (!_nodes.containsKey(key)) {
      _nodes[key] = node;
      _adjacencyList[key] = [];
    }
  }

  void _addEdge(LatLng from, LatLng to, double weight) {
    final fromKey = _nodeKey(from);
    final toKey = _nodeKey(to);
    
    _adjacencyList[fromKey]?.add(RoadEdge(to: to, weight: weight));
    _adjacencyList[toKey]?.add(RoadEdge(to: from, weight: weight));
  }

  void _connectToNearestNodes(LatLng point, int count) {
    final distances = _nodes.entries
        .where((e) => _nodeKey(point) != e.key)
        .map((e) => MapEntry(e.value, _calculateHaversineDistance(point, e.value)))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    
    for (int i = 0; i < math.min(count, distances.length); i++) {
      _addEdge(point, distances[i].key, distances[i].value);
    }
  }

  String _nodeKey(LatLng node) => '${node.latitude.toStringAsFixed(6)},${node.longitude.toStringAsFixed(6)}';

  double _calculateHaversineDistance(LatLng p1, LatLng p2) {
    const double earthRadius = 6371000;
    final double dLat = _toRadians(p2.latitude - p1.latitude);
    final double dLng = _toRadians(p2.longitude - p1.longitude);
    
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(p1.latitude)) * math.cos(_toRadians(p2.latitude)) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;

  /// Dijkstra's shortest path algorithm
  List<LatLng> dijkstraShortestPath(LatLng start, LatLng end) {
    final startKey = _nodeKey(start);
    final endKey = _nodeKey(end);
    
    // Priority queue entries: (distance, nodeKey)
    final pq = <_PQEntry>[];
    final distances = <String, double>{};
    final previous = <String, String?>{};
    final visited = <String>{};
    
    // Initialize distances
    for (final key in _nodes.keys) {
      distances[key] = double.infinity;
    }
    distances[startKey] = 0;
    
    pq.add(_PQEntry(0, startKey));
    
    while (pq.isNotEmpty) {
      // Get node with minimum distance
      pq.sort((a, b) => a.distance.compareTo(b.distance));
      final current = pq.removeAt(0);
      
      if (visited.contains(current.nodeKey)) continue;
      visited.add(current.nodeKey);
      
      if (current.nodeKey == endKey) break;
      
      // Check all neighbors
      final neighbors = _adjacencyList[current.nodeKey] ?? [];
      for (final edge in neighbors) {
        final neighborKey = _nodeKey(edge.to);
        if (visited.contains(neighborKey)) continue;
        
        final newDistance = distances[current.nodeKey]! + edge.weight;
        if (newDistance < distances[neighborKey]!) {
          distances[neighborKey] = newDistance;
          previous[neighborKey] = current.nodeKey;
          pq.add(_PQEntry(newDistance, neighborKey));
        }
      }
    }
    
    // Reconstruct path
    final path = <LatLng>[];
    String? current = endKey;
    
    while (current != null) {
      final node = _nodes[current];
      if (node != null) {
        path.insert(0, node);
      }
      current = previous[current];
    }
    
    // If no path found, return direct line with intermediate points
    if (path.isEmpty || path.length < 2) {
      return _generateSmoothPath(start, end);
    }
    
    // Smooth the path
    return _smoothPath(path);
  }

  /// Generate a smooth path when no road path exists
  List<LatLng> _generateSmoothPath(LatLng start, LatLng end) {
    final points = <LatLng>[start];
    
    // Add more intermediate points to simulate a road
    const int segments = 25;
    final latDiff = end.latitude - start.latitude;
    final lngDiff = end.longitude - start.longitude;
    
    final random = math.Random(42); // Fixed seed for consistency
    
    // Generate a curved path that looks more like a road
    for (int i = 1; i < segments; i++) {
      final t = i / segments;
      
      // Create natural-looking curves using sine waves
      final curveOffset = math.sin(t * math.pi * 2) * 0.0015;
      final secondaryCurve = math.sin(t * math.pi * 4) * 0.0008;
      
      // Add slight randomness
      final noise = (random.nextDouble() - 0.5) * 0.0005;
      
      points.add(LatLng(
        start.latitude + latDiff * t + curveOffset + noise,
        start.longitude + lngDiff * t + secondaryCurve + noise,
      ));
    }
    
    points.add(end);
    debugPrint('📍 Generated fallback smooth path with ${points.length} points');
    return points;
  }

  /// Smooth the path using Catmull-Rom spline interpolation
  List<LatLng> _smoothPath(List<LatLng> path) {
    if (path.length <= 2) return path;
    
    final smoothed = <LatLng>[];
    
    for (int i = 0; i < path.length - 1; i++) {
      final p0 = i > 0 ? path[i - 1] : path[i];
      final p1 = path[i];
      final p2 = path[i + 1];
      final p3 = i < path.length - 2 ? path[i + 2] : path[i + 1];
      
      // Add more interpolated points for smoother curves (0.1 step instead of 0.2)
      for (double t = 0; t < 1; t += 0.1) {
        final point = _catmullRom(p0, p1, p2, p3, t);
        smoothed.add(point);
      }
    }
    
    smoothed.add(path.last);
    debugPrint('📍 Local routing generated ${smoothed.length} smooth points');
    return smoothed;
  }

  LatLng _catmullRom(LatLng p0, LatLng p1, LatLng p2, LatLng p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    
    final lat = 0.5 * ((2 * p1.latitude) +
        (-p0.latitude + p2.latitude) * t +
        (2 * p0.latitude - 5 * p1.latitude + 4 * p2.latitude - p3.latitude) * t2 +
        (-p0.latitude + 3 * p1.latitude - 3 * p2.latitude + p3.latitude) * t3);
    
    final lng = 0.5 * ((2 * p1.longitude) +
        (-p0.longitude + p2.longitude) * t +
        (2 * p0.longitude - 5 * p1.longitude + 4 * p2.longitude - p3.longitude) * t2 +
        (-p0.longitude + 3 * p1.longitude - 3 * p2.longitude + p3.longitude) * t3);
    
    return LatLng(lat, lng);
  }
}

class _PQEntry {
  final double distance;
  final String nodeKey;
  
  _PQEntry(this.distance, this.nodeKey);
}

class RoadEdge {
  final LatLng to;
  final double weight;
  
  RoadEdge({required this.to, required this.weight});
}

/// Result of route calculation
class RouteResult {
  final List<LatLng> points;
  final double distance; // in meters
  final double duration; // in seconds (total route)
  /// First Directions leg duration (pickup → first waypoint or drop).
  final double firstLegDurationSeconds;
  /// Number of legs in the route (1 = direct pickup→drop).
  final int legCount;
  final String distanceText;
  final String durationText;
  final String startAddress;
  final String endAddress;
  final LatLngBounds bounds;

  RouteResult({
    required this.points,
    required this.distance,
    required this.duration,
    this.firstLegDurationSeconds = 0,
    this.legCount = 1,
    required this.distanceText,
    required this.durationText,
    required this.startAddress,
    required this.endAddress,
    required this.bounds,
  });
}

enum TravelMode {
  driving,
  walking,
  bicycling,
  transit,
}
