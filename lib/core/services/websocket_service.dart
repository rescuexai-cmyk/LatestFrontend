import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../config/app_config.dart';

typedef WebSocketListener = void Function(WebSocketMessage message);
typedef VoidCallback = void Function();

class WebSocketMessage {
  final String type;
  final dynamic data;
  final int timestamp;

  const WebSocketMessage({
    required this.type,
    required this.data,
    required this.timestamp,
  });

  factory WebSocketMessage.fromJson(Map<String, dynamic> json) {
    return WebSocketMessage(
      type: json['type'] as String? ?? '',
      data: json['data'],
      timestamp:
          json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'data': data,
      'timestamp': timestamp,
    };
  }
}

class RideLocationUpdate {
  final String rideId;
  final double latitude;
  final double longitude;
  final double? speed;
  final double? heading;
  final int? etaMinutes; // Driver's calculated ETA for passenger sync
  final double? distanceMeters; // Distance to target for passenger sync

  const RideLocationUpdate({
    required this.rideId,
    required this.latitude,
    required this.longitude,
    this.speed,
    this.heading,
    this.etaMinutes,
    this.distanceMeters,
  });

  Map<String, dynamic> toJson() {
    return {
      'rideId': rideId,
      'driverLocation': {
        'latitude': latitude,
        'longitude': longitude,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
      },
      if (heading != null) 'heading': heading,
      if (speed != null) 'speed': speed,
      if (etaMinutes != null) 'etaMinutes': etaMinutes,
      if (distanceMeters != null) 'distanceMeters': distanceMeters,
    };
  }
}

/// WebSocket service using Socket.io client to match the backend's Socket.io server.
/// The backend realtime-service uses Socket.io v4 on port 5007, proxied through
/// the gateway on port 3000 at /socket.io.
class WebSocketService {
  IO.Socket? _socket;
  final Map<String, List<WebSocketListener>> _listeners = {};
  bool _intentionalDisconnect = false;
  String? _authToken;

  // Track rooms to rejoin on reconnect (CRITICAL for real device reliability)
  String? _pendingDriverId;
  final Set<String> _joinedRideRooms = {};

  // CRITICAL: Track registration state for guaranteed delivery
  bool _isRegistered = false;
  Completer<bool>? _registrationCompleter;

  /// Last error message from backend 'registration-error' (cleared when read).
  String? _lastRegistrationErrorMessage;

  // Connection status stream
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;

  // Registration status stream for UI blocking
  final _registrationStatusController = StreamController<bool>.broadcast();
  Stream<bool> get registrationStatus => _registrationStatusController.stream;

  bool get isConnected => _socket?.connected ?? false;
  bool get isRegistered => _isRegistered;

  /// Returns and clears the last registration-error message from the backend, if any.
  String? takeLastRegistrationError() {
    final msg = _lastRegistrationErrorMessage;
    _lastRegistrationErrorMessage = null;
    return msg;
  }

  /// Called on connect/reconnect to rejoin rooms
  void _onReconnect() {
    debugPrint('🔄 Socket reconnected - rejoining rooms...');

    // Rejoin driver room if we were online
    if (_pendingDriverId != null && _pendingDriverId!.isNotEmpty) {
      debugPrint('🔄 Rejoining driver room for: $_pendingDriverId');
      _socket?.emit('join-driver', _pendingDriverId);
      _socket?.emit('driver-online', _pendingDriverId);
    }

    // Rejoin any ride tracking rooms
    for (final rideId in _joinedRideRooms) {
      debugPrint('🔄 Rejoining ride room: $rideId');
      _socket?.emit('join-ride', rideId);
    }
  }

  /// Connect to the Socket.io server through the API gateway (nginx).
  /// On DigitalOcean, nginx proxies /socket.io to the realtime service (port 5007).
  Future<void> connect({String? token}) async {
    if (_socket?.connected == true) return; // Already connected
    _intentionalDisconnect = false;
    if (token != null) _authToken = token;

    try {
      final wsUrl = AppConfig.wsUrl;
      final apiUrl = AppConfig.apiUrl;
      debugPrint('═══════════════════════════════════════════');
      debugPrint('🔌 SOCKET CONNECTION ATTEMPT');
      debugPrint('   API URL: $apiUrl');
      debugPrint('   Socket.io URL: $wsUrl');
      debugPrint('   Expected: https://api.raahionrescue.com/realtime');
      debugPrint('   (socket_io_client uses HTTP, not ws://)');
      debugPrint('═══════════════════════════════════════════');

      // Use polling first as it's more reliable, then upgrade to websocket
      // This helps with firewalls and proxies that might block websocket

      // Determine socket.io path based on URL structure
      // If URL ends with /realtime, use /realtime/socket.io/ as path
      String socketPath = '/socket.io/';
      String baseUrl = wsUrl;
      if (wsUrl.contains('/realtime')) {
        socketPath = '/realtime/socket.io/';
        // Remove /realtime from base URL since it's now in the path
        baseUrl = wsUrl.replaceAll('/realtime', '');
      }

      debugPrint('   Socket.io base URL: $baseUrl');
      debugPrint('   Socket.io path: $socketPath');

      _socket = IO.io(
        baseUrl,
        IO.OptionBuilder()
            .setTransports(
                ['polling', 'websocket']) // Polling first: mobile-friendly
            .setPath(socketPath)
            .disableAutoConnect()
            .enableReconnection()
            .setReconnectionDelay(2000)
            .setReconnectionDelayMax(15000)
            .setReconnectionAttempts(20)
            .setExtraHeaders(
              _authToken != null ? {'Authorization': 'Bearer $_authToken'} : {},
            )
            .build(),
      );

      _socket!.onConnect((_) {
        debugPrint('✅ Socket.io connected successfully');
        _connectionStatusController.add(true);
        // Notify any pending room joins that connection is ready
        _onReconnect();
      });

      _socket!.onDisconnect((reason) {
        debugPrint('❌ Socket.io disconnected: $reason');
        _connectionStatusController.add(false);
      });

      _socket!.on('reconnect', (_) {
        debugPrint('🔄 Socket.io reconnected');
        _connectionStatusController.add(true);
        _onReconnect();
      });

      _socket!.onConnectError((error) {
        debugPrint('═══════════════════════════════════════════');
        debugPrint('❌ SOCKET CONNECTION ERROR');
        debugPrint('   Error: $error');
        debugPrint('   Error type: ${error.runtimeType}');
        debugPrint('   Socket.io URL was: $wsUrl');
        debugPrint('═══════════════════════════════════════════');
        _connectionStatusController.add(false);
      });

      _socket!.onError((error) {
        debugPrint('❌ Socket.io error: $error');
      });

      // Listen for registration confirmation from backend - CRITICAL for guaranteed delivery
      _socket!.on('registration-success', (data) {
        debugPrint('✅ Driver registration confirmed: $data');
        _isRegistered = true;
        _registrationStatusController.add(true);
        _registrationCompleter?.complete(true);
        _registrationCompleter = null;
      });

      _socket!.on('registration-error', (data) {
        debugPrint('❌ Driver registration FAILED: $data');
        String? errorMessage;
        if (data is Map && data['message'] != null) {
          errorMessage = data['message'] as String?;
        } else {
          errorMessage = 'Registration rejected by server';
        }

        _lastRegistrationErrorMessage = errorMessage;
        _isRegistered = false;
        _registrationStatusController.add(false);
        _registrationCompleter?.complete(false);
        _registrationCompleter = null;
      });

      // Listen for state warnings from backend
      _socket!.on('state-warning', (data) {
        debugPrint('⚠️ Backend state warning: $data');
      });

      // Register all Socket.io event listeners that the backend emits
      _registerBackendEvents();

      debugPrint('🔌 Initiating socket connection...');
      _socket!.connect();

      // Wait a bit for connection to establish
      await Future.delayed(const Duration(milliseconds: 500));
      debugPrint(
          '🔌 Socket.io connection status after 500ms: ${_socket?.connected}');
    } catch (e) {
      debugPrint('❌ Socket.io connect failed: $e');
      _connectionStatusController.add(false);
    }
  }

  /// Register listeners for all events the backend Socket.io server emits.
  void _registerBackendEvents() {
    if (_socket == null) return;

    // Events emitted by the backend realtime-service:
    final events = [
      'new-ride-request', // New ride offer for drivers
      'ride-status-update', // Ride status changed
      'driver-location-update', // Driver location updated
      'driver-assigned', // Driver was assigned to ride
      'ride-cancelled', // Ride was cancelled
      'ride-accepted', // Ride was accepted by a driver
      'ride-taken', // Ride was taken (broadcast to other drivers)
      'driver-arrived', // Driver has arrived at pickup
      'ride-message', // Chat message (single)
      'ride-chat-message', // Alternative chat event name
      'chat-history', // Chat history (bulk)
      'message-delivered', // Message delivered receipt
      'message-read', // Message read receipt
      'chat-read', // Conversation-level read cursor update
      'typing-start', // Typing start
      'typing-stop', // Typing stop
    ];

    for (final event in events) {
      _socket!.on(event, (data) {
        _handleIncomingEvent(event, data);
      });
    }
  }

  /// Translate Socket.io events into the internal listener system.
  void _handleIncomingEvent(String event, dynamic data) {
    // Normalize event names from Socket.io format (kebab-case)
    // to our internal format (snake_case)
    final normalizedType = _normalizeEventName(event);

    final message = WebSocketMessage(
      type: normalizedType,
      data: data is Map ? Map<String, dynamic>.from(data) : data,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    // Notify type-specific listeners
    final listeners = _listeners[normalizedType];
    if (listeners != null) {
      for (final listener in List<WebSocketListener>.from(listeners)) {
        listener(message);
      }
    }

    // Also try the original event name (for backward compatibility)
    if (normalizedType != event) {
      final origListeners = _listeners[event];
      if (origListeners != null) {
        for (final listener in List<WebSocketListener>.from(origListeners)) {
          listener(message);
        }
      }
    }

    // Notify global listeners
    final globalListeners = _listeners['*'];
    if (globalListeners != null) {
      for (final listener in List<WebSocketListener>.from(globalListeners)) {
        listener(message);
      }
    }
  }

  /// Convert kebab-case event names to snake_case for internal use.
  String _normalizeEventName(String event) {
    switch (event) {
      case 'new-ride-request':
        return 'new_ride_offer';
      case 'ride-status-update':
        return 'ride_status_update';
      case 'driver-location-update':
        return 'driver_location_update';
      case 'driver-assigned':
        return 'driver_assigned';
      case 'ride-cancelled':
        return 'ride_cancelled';
      case 'ride-accepted':
        return 'ride_accepted';
      case 'ride-taken':
        return 'ride_taken';
      case 'driver-arrived':
        return 'driver_arrived';
      case 'ride-message':
      case 'ride-chat-message':
        return 'ride_message';
      case 'chat-history':
        return 'chat_history';
      case 'message-delivered':
        return 'message_delivered';
      case 'message-read':
        return 'message_read';
      case 'chat-read':
        return 'chat_read';
      case 'typing-start':
        return 'typing_start';
      case 'typing-stop':
        return 'typing_stop';
      default:
        return event.replaceAll('-', '_');
    }
  }

  /// Disconnect from Socket.io (intentional).
  void disconnect() {
    _intentionalDisconnect = true;
    _pendingDriverId = null;
    _joinedRideRooms.clear();
    _isRegistered = false;
    _registrationCompleter?.complete(false);
    _registrationCompleter = null;
    _socket?.dispose();
    _socket = null;
    _listeners.clear();
    _connectionStatusController.add(false);
    _registrationStatusController.add(false);
    debugPrint('🔌 Socket.io disconnected (intentional)');
  }

  /// Ensure Socket.io is connected. Call this before entering real-time screens.
  Future<void> ensureConnected() async {
    if (_socket?.connected == true) return;
    debugPrint('Ensuring Socket.io is connected...');
    _intentionalDisconnect = false;
    await connect(token: _authToken);
  }

  /// CRITICAL: Wait for socket connection with timeout.
  /// Returns true if connected, false if timeout or error.
  Future<bool> waitForConnection(
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (_socket?.connected == true) return true;

    debugPrint(
        '⏳ Waiting for socket connection (timeout: ${timeout.inSeconds}s)...');

    final completer = Completer<bool>();
    Timer? timeoutTimer;
    StreamSubscription<bool>? subscription;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        debugPrint('═══════════════════════════════════════════');
        debugPrint('❌ SOCKET CONNECTION TIMEOUT');
        debugPrint('   Timeout: ${timeout.inSeconds}s');
        debugPrint('   Socket connected: ${_socket?.connected}');
        debugPrint('═══════════════════════════════════════════');
        completer.complete(false);
      }
    });

    subscription = connectionStatus.listen((connected) {
      if (connected && !completer.isCompleted) {
        debugPrint('✅ Socket connected within timeout');
        completer.complete(true);
      }
    });

    // Check if already connected
    if (_socket?.connected == true) {
      completer.complete(true);
    }

    final result = await completer.future;
    timeoutTimer.cancel();
    subscription.cancel();
    return result;
  }

  /// CRITICAL: Connect and register driver for ride offers.
  /// Returns true if connected and registered successfully, false otherwise.
  ///
  /// NOTE: Backend may or may not send 'registration-success' event.
  /// We consider registration successful if:
  /// 1. Socket is connected, AND
  /// 2. Events were emitted successfully
  ///
  /// If backend sends 'registration-success', we use it. Otherwise, we
  /// assume success after a short delay to allow the events to be processed.
  Future<bool> connectAndRegister(String driverId,
      {String? token, Duration timeout = const Duration(seconds: 15)}) async {
    debugPrint('🔐 connectAndRegister: Starting for driver $driverId');

    if (driverId.isEmpty || driverId == 'unknown') {
      debugPrint('❌ connectAndRegister: Invalid driver ID');
      return false;
    }

    // Step 1: Connect if not connected
    _lastRegistrationErrorMessage = null;
    if (_socket?.connected != true) {
      await connect(token: token);
      final connected = await waitForConnection(timeout: timeout);
      if (!connected) {
        debugPrint('❌ connectAndRegister: Failed to connect socket');
        return false;
      }
    }

    // Verify socket is actually connected
    if (_socket?.connected != true) {
      debugPrint('❌ connectAndRegister: Socket not connected after wait');
      return false;
    }

    // Step 2: Set up registration completer BEFORE emitting
    _registrationCompleter = Completer<bool>();
    _pendingDriverId = driverId;
    _isRegistered = false;

    // Step 3: Emit join events
    debugPrint('📤 connectAndRegister: Emitting join-driver and driver-online');
    _socket?.emit('join-driver', driverId);
    _socket?.emit('driver-online', driverId);

    // Step 4: Wait for registration confirmation OR timeout with success
    // Backend may not send 'registration-success', so we have two paths:
    // - If backend confirms within 3s, use that
    // - Otherwise, assume success if socket is still connected

    bool registered = false;

    // Timeout to wait for backend confirmation (5s for mobile)
    Timer? confirmTimer;
    confirmTimer = Timer(const Duration(seconds: 5), () {
      if (_registrationCompleter != null &&
          !_registrationCompleter!.isCompleted) {
        // Backend didn't confirm, but if socket is connected, consider it success
        if (_socket?.connected == true) {
          debugPrint(
              '⚠️ connectAndRegister: No backend confirmation, but socket connected - assuming success');
          _isRegistered = true;
          _registrationStatusController.add(true);
          _registrationCompleter!.complete(true);
        } else {
          debugPrint(
              '❌ connectAndRegister: No confirmation and socket disconnected');
          _registrationCompleter!.complete(false);
        }
      }
    });

    registered = await _registrationCompleter!.future;
    confirmTimer.cancel();

    if (registered) {
      debugPrint(
          '✅ connectAndRegister: Driver $driverId registered successfully');
    } else {
      debugPrint('❌ connectAndRegister: Driver $driverId registration failed');
      _pendingDriverId = null;
    }

    return registered;
  }

  // ─────────────────────────────────────────────
  // EMIT EVENTS (client → server)
  // ─────────────────────────────────────────────

  /// Join a ride tracking room (receive ride-specific events).
  void joinRideTracking(String rideId) {
    if (rideId.isEmpty) return;
    _joinedRideRooms.add(rideId);
    _socket?.emit('join-ride', rideId);
    debugPrint('✅ Joined ride tracking room: ride-$rideId');
  }

  /// Leave a ride tracking room.
  void leaveRideTracking(String rideId) {
    if (rideId.isEmpty) return;
    _joinedRideRooms.remove(rideId);
    _socket?.emit('leave-ride', rideId);
    debugPrint('Left ride tracking room: ride-$rideId');
  }

  /// Join driver-specific room (receive ride offers).
  /// CRITICAL: This must be called with valid driverId for socket events to work.
  void joinDriverRoom(String driverId) {
    if (driverId.isEmpty || driverId == 'unknown') {
      debugPrint('⚠️ Cannot join driver room - invalid driverId: $driverId');
      return;
    }
    _pendingDriverId = driverId;
    if (_socket?.connected != true) {
      debugPrint('⚠️ Socket not connected - will join driver room on connect');
      return;
    }
    _socket?.emit('join-driver', driverId);
    debugPrint('✅ Joined driver room: driver-$driverId');
  }

  /// Leave driver-specific room.
  void leaveDriverRoom(String driverId) {
    if (driverId.isEmpty || driverId == 'unknown') return;
    _pendingDriverId = null;
    _socket?.emit('leave-driver', driverId);
    debugPrint('Left driver room: driver-$driverId');
  }

  /// Join available-drivers room to receive new ride requests.
  /// Must be called when driver goes online.
  /// CRITICAL: Backend requires driverId/userId to join the room.
  void joinAvailableDriversRoom(String driverId) {
    if (_socket?.connected != true) {
      debugPrint(
          '⚠️ Cannot join available-drivers room - socket not connected');
      return;
    }
    if (driverId.isEmpty || driverId == 'unknown') {
      debugPrint(
          '⚠️ Cannot join available-drivers room - invalid driverId: $driverId');
      return;
    }
    _socket?.emit('driver-online', driverId);
    debugPrint('✅ Emitted driver-online with driverId: $driverId');
  }

  /// Leave available-drivers room when driver goes offline.
  void leaveAvailableDriversRoom(String driverId) {
    if (driverId.isEmpty || driverId == 'unknown') {
      debugPrint('⚠️ Cannot leave available-drivers room - invalid driverId');
      return;
    }
    _socket?.emit('driver-offline', driverId);
    debugPrint('Left available-drivers room for driver: $driverId');
  }

  /// Accept a ride request (driver).
  void acceptRideRequest(String rideId, String driverId) {
    _socket?.emit('accept-ride-request', {
      'rideId': rideId,
      'driverId': driverId,
    });
  }

  /// Notify that driver has arrived at pickup.
  void notifyDriverArrived(String rideId, String driverId) {
    _socket?.emit('driver-arrived', {
      'rideId': rideId,
      'driverId': driverId,
    });
  }

  /// Send driver location update via Socket.io.
  void updateDriverLocation(RideLocationUpdate update) {
    _socket?.emit('driver-location-update', update.toJson());
  }

  /// Send ride status update via Socket.io.
  void updateRideStatus(String rideId, String status,
      {String? driverId, int? estimatedArrival}) {
    _socket?.emit('ride-status-update', {
      'rideId': rideId,
      'status': status,
      if (driverId != null) 'driverId': driverId,
      if (estimatedArrival != null) 'estimatedArrival': estimatedArrival,
    });
  }

  /// Cancel ride via Socket.io.
  void cancelRide(String rideId, {String? reason}) {
    _socket?.emit('ride-cancel', {
      'rideId': rideId,
      if (reason != null) 'reason': reason,
    });
  }

  /// Send chat message via Socket.io.
  void sendRideMessage(String rideId, String message,
      {required String sender, String? senderName}) {
    _socket?.emit('ride-message', {
      'rideId': rideId,
      'message': message,
      'sender': sender,
      'senderName': senderName ?? sender,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Send chat message with server acknowledgment.
  Future<Map<String, dynamic>?> sendRideMessageWithAck(
    String rideId,
    String message, {
    required String sender,
    String? senderName,
    String? clientMessageId,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_socket?.connected != true) return null;

    final payload = {
      'rideId': rideId,
      'message': message,
      'sender': sender,
      'senderName': senderName ?? sender,
      if (clientMessageId != null && clientMessageId.isNotEmpty)
        'clientMessageId': clientMessageId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final completer = Completer<Map<String, dynamic>?>();
    Timer? timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      _socket?.emitWithAck('ride-message', payload, ack: (dynamic response) {
        timer?.cancel();
        if (response is Map) {
          completer.complete(Map<String, dynamic>.from(response));
        } else {
          completer.complete(null);
        }
      });
    } catch (_) {
      timer.cancel();
      return null;
    }

    return completer.future;
  }

  /// Send delivered receipt for a chat message.
  void sendMessageDelivered({
    required String messageId,
    required String rideId,
    required String receiverId,
  }) {
    _socket?.emit('message-delivered', {
      'messageId': messageId,
      'rideId': rideId,
      'receiverId': receiverId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Send read receipt for a chat message.
  void sendMessageRead({
    required String messageId,
    required String rideId,
    required String readerId,
  }) {
    _socket?.emit('message-read', {
      'messageId': messageId,
      'rideId': rideId,
      'readerId': readerId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void sendTypingStart({
    required String rideId,
    required String userId,
  }) {
    _socket?.emit('typing-start', {
      'rideId': rideId,
      'userId': userId,
      'senderId': userId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendTypingStop({
    required String rideId,
    required String userId,
  }) {
    _socket?.emit('typing-stop', {
      'rideId': rideId,
      'userId': userId,
      'senderId': userId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendChatOpen({
    required String rideId,
    required String userId,
  }) {
    _socket?.emit('chat-open', {
      'rideId': rideId,
      'userId': userId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendChatClose({
    required String rideId,
    required String userId,
  }) {
    _socket?.emit('chat-close', {
      'rideId': rideId,
      'userId': userId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Send a generic event via Socket.io.
  void sendMessage(String type, dynamic data) {
    if (_socket?.connected != true) {
      debugPrint('Socket.io not connected, cannot send [$type]');
      return;
    }
    _socket?.emit(type, data);
  }

  // ─────────────────────────────────────────────
  // SUBSCRIBE TO EVENTS
  // ─────────────────────────────────────────────

  /// Subscribe to a specific message type.
  VoidCallback subscribe(String messageType, WebSocketListener listener) {
    _listeners.putIfAbsent(messageType, () => []);
    _listeners[messageType]!.add(listener);

    return () {
      _listeners[messageType]?.remove(listener);
    };
  }

  /// Subscribe to all messages.
  VoidCallback subscribeToAll(WebSocketListener listener) {
    return subscribe('*', listener);
  }

  /// Subscribe to ride-specific events (status updates, location, messages, cancellation).
  VoidCallback subscribeToRideUpdates(
      String rideId, void Function(Map<String, dynamic> data) callback) {
    final unsubscribers = <VoidCallback>[];

    unsubscribers.add(subscribe('ride_status_update', (message) {
      final msgData = message.data;
      if (msgData is Map && msgData['rideId'] == rideId) {
        callback(
            {'type': 'status_update', ...Map<String, dynamic>.from(msgData)});
      }
    }));

    unsubscribers.add(subscribe('driver_location_update', (message) {
      final msgData = message.data;
      if (msgData is Map) {
        callback(
            {'type': 'location_update', ...Map<String, dynamic>.from(msgData)});
      }
    }));

    unsubscribers.add(subscribe('driver_assigned', (message) {
      final msgData = message.data;
      if (msgData is Map && msgData['rideId'] == rideId) {
        callback(
            {'type': 'driver_assigned', ...Map<String, dynamic>.from(msgData)});
      }
    }));

    unsubscribers.add(subscribe('ride_cancelled', (message) {
      final msgData = message.data;
      if (msgData is Map && msgData['rideId'] == rideId) {
        callback({'type': 'cancelled', ...Map<String, dynamic>.from(msgData)});
      }
    }));

    unsubscribers.add(subscribe('driver_arrived', (message) {
      final msgData = message.data;
      if (msgData is Map && msgData['rideId'] == rideId) {
        callback(
            {'type': 'driver_arrived', ...Map<String, dynamic>.from(msgData)});
      }
    }));

    return () {
      for (final unsubscribe in unsubscribers) {
        unsubscribe();
      }
    };
  }

  /// Subscribe to driver-specific events (new ride offers, ride taken).
  VoidCallback subscribeToDriverEvents(
      void Function(Map<String, dynamic> data) callback) {
    final unsubscribers = <VoidCallback>[];

    unsubscribers.add(subscribe('new_ride_offer', (message) {
      debugPrint('New ride offer received via Socket.io');
      final msgData = message.data;
      callback({
        'type': 'new_ride_offer',
        'ride': msgData is Map ? Map<String, dynamic>.from(msgData) : msgData,
      });
    }));

    unsubscribers.add(subscribe('ride_taken', (message) {
      final msgData = message.data;
      callback({
        'type': 'ride_taken',
        ...msgData is Map ? Map<String, dynamic>.from(msgData) : {},
      });
    }));

    unsubscribers.add(subscribe('ride_cancelled', (message) {
      final msgData = message.data;
      callback({
        'type': 'ride_cancelled',
        ...msgData is Map ? Map<String, dynamic>.from(msgData) : {},
      });
    }));

    return () {
      for (final unsubscribe in unsubscribers) {
        unsubscribe();
      }
    };
  }

  void dispose() {
    disconnect();
    _connectionStatusController.close();
    _registrationStatusController.close();
  }
}

// Singleton instance
final webSocketService = WebSocketService();
