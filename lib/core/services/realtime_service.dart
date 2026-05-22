import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';
import 'sse_service.dart';
import 'websocket_service.dart';

enum RealtimeStopReason { logout, manual, appBackground, authExpired }

/// Unified real-time service for the Raahi backend.
///
/// Architecture matches the backend's hybrid transport system:
///   1. SSE (primary)  — server→client push (ride events, driver events)
///   2. HTTP           — client→server actions (location updates, status changes)
///   3. Socket.io      — fallback bidirectional transport
///
/// Usage:
///   // Driver going online
///   realtimeService.connectDriver(driverId, lat, lng, onEvent: ...);
///
///   // Rider tracking a ride
///   realtimeService.connectRide(rideId, onEvent: ...);
///
///   // Driver sending location
///   realtimeService.updateDriverLocation(driverId, lat, lng, heading, speed);
class RealtimeService {
  String? _authToken;
  HttpClient? _httpClient;

  // Active SSE subscriptions
  SSESubscription? _driverSSE;
  SSESubscription? _rideSSE;

  // Socket.io fallback subscriptions
  VoidCallback? _driverSocketSub;
  VoidCallback? _rideSocketSub;

  // Current state
  String? _currentDriverId;
  String? _currentRideId;
  bool _isDriverOnline = false;

  // Connection status
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  bool get isDriverOnline => _isDriverOnline;

  /// Base URL for realtime HTTP endpoints
  String get _realtimeBaseUrl {
    final api = AppConfig.apiUrl;
    final base = api.endsWith('/api') ? api.substring(0, api.length - 4) : api;
    return '$base/api/realtime';
  }

  HttpClient get _client {
    _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30);
    return _httpClient!;
  }

  void setAuthToken(String? token) {
    _authToken = token;
    sseService.setAuthToken(token);
  }

  // ═══════════════════════════════════════════════════
  // DRIVER REAL-TIME (going online, receiving ride offers)
  // ═══════════════════════════════════════════════════

  /// Connect driver to receive ride offers and events.
  /// Uses SSE as primary with Socket.io as fallback.
  /// Returns true only when at least one transport is confirmed connected.
  ///
  /// [onEvent] receives normalized events:
  ///   - type='new_ride_offer', data={ride details}
  ///   - type='ride_taken', data={rideId}
  ///   - type='ride_cancelled', data={rideId, reason}
  ///   - type='driver_assigned', data={rideId, driver}
  ///   - type='connected', data={}
  Future<bool> connectDriver(
    String driverId, {
    double? lat,
    double? lng,
    String? token,
    required void Function(String type, Map<String, dynamic> data) onEvent,
    void Function(Object error)? onError,
  }) async {
    if (token != null) setAuthToken(token);
    _currentDriverId = driverId;

    debugPrint('🚗 Realtime: Connecting driver $driverId (SSE + Socket.io)...');

    final completer = Completer<bool>();
    var completed = false;
    void tryComplete(bool success) {
      if (completed) return;
      completed = true;
      if (!completer.isCompleted) completer.complete(success);
    }

    // 25s timeout for mobile networks (higher latency, carrier restrictions)
    Timer? timeoutTimer;
    timeoutTimer = Timer(const Duration(seconds: 25), () {
      if (!completed) {
        debugPrint('🚗 Realtime: Connection timeout (25s)');
        tryComplete(false);
      }
    });

    void onConnected() {
      timeoutTimer?.cancel();
      _isDriverOnline = true;
      _isConnected = true;
      _connectionStatusController.add(true);
      tryComplete(true);
    }

    try {
      // Primary: SSE
      _driverSSE = sseService.connectToDriver(
        driverId,
        lat: lat,
        lng: lng,
        onEvent: (event, data) {
          _dispatchDriverEvent(event, data, onEvent);
          if (!completed) onConnected(); // Any event = SSE connected
        },
        onError: (error) async {
          debugPrint('🚗 Realtime: SSE error, trying Socket.io: $error');
          _connectionStatusController.add(false);
          onError?.call(error);
          final ok = await _connectDriverSocketFallback(driverId, token: token, onEvent: onEvent);
          if (ok) onConnected();
        },
        onDone: () {
          if (_isDriverOnline) {
            debugPrint('🚗 Realtime: SSE stream ended');
          }
        },
      );

      // Socket.io in parallel (backup transport + bidirectional)
      unawaited(_connectDriverSocket(driverId, token: token, onEvent: onEvent).then((ok) {
        if (ok && !completed) onConnected();
      }));

      final success = await completer.future;
      timeoutTimer?.cancel();

      if (!success) {
        _isConnected = false;
        _isDriverOnline = false;
        _connectionStatusController.add(false);
        disconnectDriver();
      }
      return success;
    } catch (e) {
      debugPrint('🚗 Realtime: Connect failed: $e');
      timeoutTimer?.cancel();
      _connectionStatusController.add(false);
      return _connectDriverSocketFallback(driverId, token: token, onEvent: onEvent);
    }
  }

  /// Connect Socket.io for bidirectional communication (emit events).
  /// Returns true if connected and registered.
  Future<bool> _connectDriverSocket(
    String driverId, {
    String? token,
    required void Function(String type, Map<String, dynamic> data) onEvent,
  }) async {
    try {
      return await webSocketService.connectAndRegister(
        driverId,
        token: token,
        timeout: const Duration(seconds: 25),
      );
    } catch (e) {
      debugPrint('🚗 Realtime: Socket.io connect failed: $e');
      return false;
    }
  }

  /// Fallback: use Socket.io as sole transport when SSE fails.
  Future<bool> _connectDriverSocketFallback(
    String driverId, {
    String? token,
    required void Function(String type, Map<String, dynamic> data) onEvent,
  }) async {
    debugPrint('🚗 Realtime: Using Socket.io as primary transport');
    try {
      final success = await webSocketService.connectAndRegister(
        driverId,
        token: token,
        timeout: const Duration(seconds: 25),
      );
      if (success) {
        _driverSocketSub = webSocketService.subscribeToDriverEvents((data) {
          final type = data['type'] as String? ?? '';
          onEvent(type, data);
        });
      }
      return success;
    } catch (e) {
      debugPrint('🚗 Realtime: Socket.io fallback failed: $e');
      return false;
    }
  }

  /// Normalize SSE event names → internal event types.
  void _dispatchDriverEvent(
    String sseEvent,
    Map<String, dynamic> data,
    void Function(String type, Map<String, dynamic> data) onEvent,
  ) {
    switch (sseEvent) {
      case 'new-ride-request':
        // SSE sends full event { type, rideId, targetDriverIds, payload }; ride details are in payload
        final ridePayload = data['payload'] ?? data;
        onEvent('new_ride_offer', {'ride': ridePayload});
        break;
      case 'ride-taken':
        onEvent('ride_taken', data);
        break;
      case 'ride-cancelled':
        onEvent('ride_cancelled', data);
        break;
      case 'ride-completed':
        onEvent('ride_completed', data);
        break;
      case 'driver-assigned':
        onEvent('driver_assigned', data);
        break;
      case 'connected':
        debugPrint('📡 SSE: Driver stream connected');
        onEvent('connected', data);
        break;
      default:
        onEvent(sseEvent.replaceAll('-', '_'), data);
    }
  }

  /// Disconnect driver from all real-time streams.
  void disconnectDriver({bool silent = false}) {
    debugPrint('🚗 Realtime: Disconnecting driver');
    _driverSSE?.cancel();
    _driverSSE = null;
    _driverSocketSub?.call();
    _driverSocketSub = null;
    _isDriverOnline = false;
    _currentDriverId = null;

    if (_currentRideId == null) {
      webSocketService.disconnect();
      sseService.disconnectAll();
      _isConnected = false;
      if (!silent) {
        _connectionStatusController.add(false);
      }
    }
  }

  // ═══════════════════════════════════════════════════
  // RIDE REAL-TIME (tracking ride status, driver location)
  // ═══════════════════════════════════════════════════

  /// Connect to ride event stream (for riders tracking a ride).
  ///
  /// [onEvent] receives normalized events:
  ///   - type='status_update', data={rideId, status, ...}
  ///   - type='location_update', data={driverLocation: {latitude, longitude}}
  ///   - type='driver_assigned', data={rideId, driver}
  ///   - type='cancelled', data={rideId, reason}
  ///   - type='driver_arrived', data={rideId}
  ///   - type='message', data={rideId, message, sender}
  SSESubscription? connectRide(
    String rideId, {
    String? token,
    required void Function(String type, Map<String, dynamic> data) onEvent,
    void Function(Object error)? onError,
  }) {
    _currentRideId = rideId;
    
    // CRITICAL: Set auth token for SSE connection
    if (token != null) {
      setAuthToken(token);
      debugPrint('🚕 Realtime: Auth token set for ride SSE');
    }
    
    debugPrint('🚕 Realtime: Connecting to ride $rideId via SSE...');

    _rideSSE = sseService.connectToRide(
      rideId,
      onEvent: (event, data) {
        _dispatchRideEvent(event, data, onEvent);
      },
      onError: (error) {
        debugPrint('🚕 Realtime: SSE ride error, using Socket.io: $error');
        onError?.call(error);
        _connectRideSocketFallback(rideId, onEvent: onEvent);
      },
    );

    // Also join Socket.io room as backup
    webSocketService.joinRideTracking(rideId);

    return _rideSSE;
  }

  /// Fallback: use Socket.io for ride tracking.
  void _connectRideSocketFallback(
    String rideId, {
    required void Function(String type, Map<String, dynamic> data) onEvent,
  }) {
    _rideSocketSub = webSocketService.subscribeToRideUpdates(rideId, (data) {
      final type = data['type'] as String? ?? '';
      onEvent(type, data);
    });
  }

  /// Normalize SSE ride events → internal types.
  void _dispatchRideEvent(
    String sseEvent,
    Map<String, dynamic> data,
    void Function(String type, Map<String, dynamic> data) onEvent,
  ) {
    switch (sseEvent) {
      case 'ride-status-update':
        onEvent('status_update', data);
        break;
      case 'driver-location':
        // Preserve heading and speed from the event data
        final locationData = data['location'] as Map<String, dynamic>? ?? data;
        onEvent('location_update', {
          'driverLocation': {
            'latitude': locationData['lat'] ?? locationData['latitude'],
            'longitude': locationData['lng'] ?? locationData['longitude'],
            'heading': locationData['heading'] ?? data['heading'],
            'speed': locationData['speed'] ?? data['speed'],
          },
          'heading': locationData['heading'] ?? data['heading'],
          'speed': locationData['speed'] ?? data['speed'],
        });
        break;
      case 'driver-assigned':
        onEvent('driver_assigned', data);
        break;
      case 'ride-cancelled':
        onEvent('cancelled', data);
        break;
      case 'ride-chat-message':
        onEvent('message', data);
        break;
      case 'connected':
        debugPrint('📡 SSE: Ride stream connected');
        break;
      default:
        onEvent(sseEvent.replaceAll('-', '_'), data);
    }
  }

  /// Disconnect from ride stream.
  void disconnectRide(String rideId) {
    debugPrint('🚕 Realtime: Disconnecting ride $rideId');
    _rideSSE?.cancel();
    _rideSSE = null;
    _rideSocketSub?.call();
    _rideSocketSub = null;
    webSocketService.leaveRideTracking(rideId);
    _currentRideId = null;
  }

  // ═══════════════════════════════════════════════════
  // HTTP ACTIONS (client → server)
  // ═══════════════════════════════════════════════════

  /// Update driver location via HTTP (more reliable than Socket.io).
  /// POST /api/realtime/update-driver-location
  /// If snapToRoad is true, location will be snapped to nearest road (improves accuracy)
  Future<bool> updateDriverLocation(
    String driverId,
    double lat,
    double lng, {
    double? heading,
    double? speed,
    bool snapToRoad = false,
  }) async {
    try {
      // Final coordinates to send
      double finalLat = lat;
      double finalLng = lng;
      
      // Snap to road if requested (improves accuracy for driver tracking)
      if (snapToRoad) {
        try {
          final snapped = await _snapToRoad(lat, lng);
          if (snapped != null) {
            finalLat = snapped['lat']!;
            finalLng = snapped['lng']!;
            debugPrint('📍 Snapped to road: ($lat,$lng) → ($finalLat,$finalLng)');
          }
        } catch (e) {
          debugPrint('📍 Snap to road failed, using raw coordinates: $e');
        }
      }
      
      final url = Uri.parse('$_realtimeBaseUrl/update-driver-location');
      final request = await _client.postUrl(url);
      _setHeaders(request);
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'driverId': driverId,
        'lat': finalLat,
        'lng': finalLng,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
      }));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('📍 Location update failed: $e');
      // Fallback to Socket.io
      webSocketService.updateDriverLocation(RideLocationUpdate(
        rideId: '',
        latitude: lat,
        longitude: lng,
        heading: heading,
        speed: speed,
      ));
      return false;
    }
  }
  
  /// Snap GPS coordinates to nearest road using Roads API
  Future<Map<String, double>?> _snapToRoad(double lat, double lng) async {
    try {
      // Use the Roads API endpoint
      final apiKey = AppConfig.googleMapsApiKey;
      final url = Uri.parse(
        'https://roads.googleapis.com/v1/snapToRoads?path=$lat,$lng&key=$apiKey'
      );
      
      final request = await _client.getUrl(url);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      
      if (data['snappedPoints'] != null && (data['snappedPoints'] as List).isNotEmpty) {
        final point = (data['snappedPoints'] as List).first;
        final location = point['location'] as Map<String, dynamic>;
        return {
          'lat': (location['latitude'] as num).toDouble(),
          'lng': (location['longitude'] as num).toDouble(),
        };
      }
      return null;
    } catch (e) {
      debugPrint('Snap to road error: $e');
      return null;
    }
  }

  /// Update driver location via binary protocol (~80% smaller payload).
  /// POST /api/realtime/location/binary
  Future<bool> updateDriverLocationBinary(
    double lat,
    double lng, {
    double heading = 0,
    double speed = 0,
  }) async {
    try {
      final url = Uri.parse('$_realtimeBaseUrl/location/binary');
      final request = await _client.postUrl(url);
      _setHeaders(request);
      request.headers.set('Content-Type', 'application/octet-stream');

      // Encode 24-byte binary message
      final buffer = ByteData(24);
      buffer.setFloat32(0, lat, Endian.little);
      buffer.setFloat32(4, lng, Endian.little);
      buffer.setUint16(8, (heading * 100).round().clamp(0, 65535), Endian.little);
      buffer.setUint16(10, (speed * 100).round().clamp(0, 65535), Endian.little);
      buffer.setUint32(12, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.little);
      // Bytes 16-23: H3 index (left as zeros — server calculates)

      request.add(buffer.buffer.asUint8List());
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('📍 Binary location update failed: $e');
      return false;
    }
  }

  /// Update driver H3 cell for SSE subscription routing.
  /// PATCH /api/realtime/sse/driver/:driverId/location
  Future<String?> updateDriverH3(String driverId, double lat, double lng) {
    return sseService.updateDriverH3(driverId, lat, lng);
  }

  /// Update ride status via Socket.io (backend handles state transition).
  void updateRideStatus(String rideId, String status, {String? driverId}) {
    webSocketService.updateRideStatus(rideId, status, driverId: driverId);
  }

  /// Cancel ride via Socket.io.
  void cancelRide(String rideId, {String? reason}) {
    webSocketService.cancelRide(rideId, reason: reason);
  }

  /// Accept ride request via Socket.io.
  void acceptRideRequest(String rideId, String driverId) {
    webSocketService.acceptRideRequest(rideId, driverId);
  }

  /// Notify driver arrived at pickup via Socket.io.
  void notifyDriverArrived(String rideId, String driverId) {
    webSocketService.notifyDriverArrived(rideId, driverId);
  }

  /// Send chat message via Socket.io.
  void sendRideMessage(String rideId, String message, {required String sender, String? senderName}) {
    webSocketService.sendRideMessage(rideId, message, sender: sender, senderName: senderName);
  }

  // ═══════════════════════════════════════════════════
  // PROTOCOL DISCOVERY
  // ═══════════════════════════════════════════════════

  /// Fetch available protocols from server.
  /// GET /api/realtime/protocols
  Future<Map<String, dynamic>?> getProtocols() async {
    try {
      final url = Uri.parse('$_realtimeBaseUrl/protocols');
      final request = await _client.getUrl(url);
      _setHeaders(request);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('📡 Protocol discovery failed: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════

  void _setHeaders(HttpClientRequest request) {
    if (_authToken != null) {
      request.headers.set('Authorization', 'Bearer $_authToken');
    }
  }

  /// Get last registration error from Socket.io (for diagnostics).
  String? takeLastRegistrationError() => webSocketService.takeLastRegistrationError();

  /// Disconnect everything.
  void disconnectAll({bool silent = false}) {
    disconnectDriver(silent: silent);
    if (_currentRideId != null) disconnectRide(_currentRideId!);
    webSocketService.disconnect();
    sseService.disconnectAll();
    _isConnected = false;
    if (!silent) {
      _connectionStatusController.add(false);
    }
  }

  /// Intentional stop path used during logout/navigation transitions.
  Future<void> stop({RealtimeStopReason reason = RealtimeStopReason.manual}) async {
    debugPrint('🛑 Realtime: stop requested, reason=$reason');
    disconnectAll(silent: true);
    _isDriverOnline = false;
    _currentDriverId = null;
    _currentRideId = null;
  }

  /// Placeholder for API parity with UI layer reconnect manager.
  void cancelReconnectTimer() {}

  /// Reset local connection state without broadcasting disconnect events/snackbars.
  void resetConnectionStateSilently() {
    _isConnected = false;
    _isDriverOnline = false;
  }

  void dispose() {
    disconnectAll();
    _connectionStatusController.close();
    sseService.dispose();
    _httpClient?.close(force: true);
    _httpClient = null;
  }
}

/// Singleton instance
final realtimeService = RealtimeService();
