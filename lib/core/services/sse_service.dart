import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

/// SSE (Server-Sent Events) client for real-time server→client push.
///
/// The backend realtime-service exposes:
///   GET /api/realtime/sse/ride/:rideId   — ride events
///   GET /api/realtime/sse/driver/:driverId?lat=X&lng=Y — driver events
///
/// SSE event names match the backend EventBus:
///   ride-status-update, driver-location, driver-assigned,
///   ride-cancelled, ride-chat-message, new-ride-request, ride-taken, connected
class SSEService {
  HttpClient? _httpClient;
  final Map<String, _SSEConnection> _connections = {};
  String? _authToken;

  void setAuthToken(String? token) => _authToken = token;

  /// Base URL for SSE endpoints (via gateway).
  /// e.g. http://139.59.34.68/api/realtime/sse
  String get _sseBaseUrl {
    final api = AppConfig.apiUrl; // e.g. http://139.59.34.68/api
    // Strip /api suffix and add /api/realtime/sse
    final base = api.endsWith('/api') ? api.substring(0, api.length - 4) : api;
    return '$base/api/realtime/sse';
  }

  HttpClient get _client {
    _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 25)
      ..idleTimeout = const Duration(minutes: 5);
    return _httpClient!;
  }

  // ─── RIDE SSE STREAM ─────────────────────────────

  /// Connect to ride event stream.
  /// Receives: ride-status-update, driver-location, driver-assigned,
  ///           ride-cancelled, ride-chat-message, connected
  SSESubscription connectToRide(String rideId, {
    required void Function(String event, Map<String, dynamic> data) onEvent,
    void Function(Object error)? onError,
    void Function()? onDone,
  }) {
    final url = '$_sseBaseUrl/ride/$rideId';
    debugPrint('📡 SSE: Connecting to ride stream: $url');
    return _connect('ride:$rideId', url, onEvent: onEvent, onError: onError, onDone: onDone);
  }

  // ─── DRIVER SSE STREAM ───────────────────────────

  /// Connect to driver event stream.
  /// lat/lng are used for H3 cell subscription on the backend.
  /// Receives: new-ride-request, driver-assigned, ride-cancelled, ride-taken, connected
  SSESubscription connectToDriver(String driverId, {
    double? lat,
    double? lng,
    required void Function(String event, Map<String, dynamic> data) onEvent,
    void Function(Object error)? onError,
    void Function()? onDone,
  }) {
    var url = '$_sseBaseUrl/driver/$driverId';
    final params = <String>[];
    if (lat != null) params.add('lat=$lat');
    if (lng != null) params.add('lng=$lng');
    if (params.isNotEmpty) url += '?${params.join('&')}';

    debugPrint('📡 SSE: Connecting to driver stream: $url');
    return _connect('driver:$driverId', url, onEvent: onEvent, onError: onError, onDone: onDone);
  }

  /// Update driver H3 cell when they move (keeps SSE subscriptions in sync).
  /// PATCH /api/realtime/sse/driver/:driverId/location
  Future<String?> updateDriverH3(String driverId, double lat, double lng) async {
    try {
      final url = '$_sseBaseUrl/driver/$driverId/location';
      final uri = Uri.parse(url);
      final request = await _client.patchUrl(uri);
      _setHeaders(request);
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({'lat': lat, 'lng': lng}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        return json['h3Index'] as String?;
      }
      debugPrint('📡 SSE: H3 update failed: ${response.statusCode} $body');
      return null;
    } catch (e) {
      debugPrint('📡 SSE: H3 update error: $e');
      return null;
    }
  }

  // ─── CORE SSE CONNECTION ─────────────────────────

  SSESubscription _connect(
    String key,
    String url, {
    required void Function(String event, Map<String, dynamic> data) onEvent,
    void Function(Object error)? onError,
    void Function()? onDone,
  }) {
    // Close existing connection for this key
    _connections[key]?.close();

    final conn = _SSEConnection(
      key: key,
      url: url,
      authToken: _authToken,
      client: _client,
      onEvent: onEvent,
      onError: onError,
      onDone: onDone,
    );
    _connections[key] = conn;
    conn.connect();

    return SSESubscription._(
      close: () {
        conn.close();
        _connections.remove(key);
      },
    );
  }

  void _setHeaders(HttpClientRequest request) {
    if (_authToken != null) {
      request.headers.set('Authorization', 'Bearer $_authToken');
    }
  }

  /// Disconnect a specific stream.
  void disconnect(String key) {
    _connections[key]?.close();
    _connections.remove(key);
  }

  /// Disconnect all streams.
  void disconnectAll() {
    for (final conn in _connections.values) {
      conn.close();
    }
    _connections.clear();
  }

  /// Check if a specific stream is connected.
  bool isConnected(String key) => _connections[key]?.isActive ?? false;

  void dispose() {
    disconnectAll();
    _httpClient?.close(force: true);
    _httpClient = null;
  }
}

/// Handle returned when subscribing to an SSE stream.
class SSESubscription {
  final void Function() _close;
  SSESubscription._({required void Function() close}) : _close = close;

  void cancel() => _close();
}

/// Internal class managing a single SSE connection with auto-reconnect.
class _SSEConnection {
  final String key;
  final String url;
  final String? authToken;
  final HttpClient client;
  final void Function(String event, Map<String, dynamic> data) onEvent;
  final void Function(Object error)? onError;
  final void Function()? onDone;

  StreamSubscription<String>? _subscription;
  bool _closed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  String? _lastEventId;

  bool get isActive => !_closed && _subscription != null;

  _SSEConnection({
    required this.key,
    required this.url,
    required this.authToken,
    required this.client,
    required this.onEvent,
    this.onError,
    this.onDone,
  });

  Future<void> connect() async {
    if (_closed) return;

    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);

      // SSE headers
      request.headers.set('Accept', 'text/event-stream');
      request.headers.set('Cache-Control', 'no-cache');
      if (authToken != null) {
        request.headers.set('Authorization', 'Bearer $authToken');
      }
      if (_lastEventId != null) {
        request.headers.set('Last-Event-ID', _lastEventId!);
      }

      final response = await request.close();

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        debugPrint('📡 SSE [$key]: HTTP ${response.statusCode}: $body');
        _scheduleReconnect();
        return;
      }

      debugPrint('📡 SSE [$key]: Connected');
      _reconnectAttempts = 0;

      // Parse SSE stream
      String eventType = 'message';
      StringBuffer dataBuffer = StringBuffer();

      _subscription = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (_closed) return;

          if (line.startsWith('event:')) {
            eventType = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            dataBuffer.write(line.substring(5).trim());
          } else if (line.startsWith('id:')) {
            _lastEventId = line.substring(3).trim();
          } else if (line.isEmpty && dataBuffer.isNotEmpty) {
            // End of event — dispatch
            _dispatchEvent(eventType, dataBuffer.toString());
            eventType = 'message';
            dataBuffer = StringBuffer();
          }
        },
        onError: (error) {
          debugPrint('📡 SSE [$key]: Stream error: $error');
          onError?.call(error);
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('📡 SSE [$key]: Stream ended');
          if (!_closed) {
            _scheduleReconnect();
          }
          onDone?.call();
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('📡 SSE [$key]: Connect error: $e');
      onError?.call(e);
      _scheduleReconnect();
    }
  }

  void _dispatchEvent(String event, String rawData) {
    try {
      final data = rawData.isNotEmpty ? jsonDecode(rawData) as Map<String, dynamic> : <String, dynamic>{};
      onEvent(event, data);
    } catch (e) {
      // Non-JSON data — wrap it
      onEvent(event, {'raw': rawData});
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _subscription?.cancel();
    _subscription = null;

    _reconnectAttempts++;
    // Exponential backoff: 1s, 2s, 4s, 8s, max 30s
    final delay = Duration(seconds: (1 << _reconnectAttempts.clamp(0, 5)).clamp(1, 30));
    debugPrint('📡 SSE [$key]: Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');

    _reconnectTimer = Timer(delay, () {
      if (!_closed) connect();
    });
  }

  void close() {
    _closed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    debugPrint('📡 SSE [$key]: Closed');
  }
}

/// Singleton instance
final sseService = SSEService();
