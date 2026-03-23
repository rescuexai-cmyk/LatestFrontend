import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/directions_service.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/widgets/slide_to_action_button.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../chat/presentation/screens/ride_chat_screen.dart';
import '../../../chat/providers/chat_provider.dart';
import '../../providers/driver_rides_provider.dart';
import '../../../../core/providers/settings_provider.dart';

class DriverActiveRideScreen extends ConsumerStatefulWidget {
  final String? initialRideId;
  final bool autoOpenChat;

  const DriverActiveRideScreen({
    super.key,
    this.initialRideId,
    this.autoOpenChat = false,
  });

  @override
  ConsumerState<DriverActiveRideScreen> createState() =>
      _DriverActiveRideScreenState();
}

class _DriverActiveRideScreenState
    extends ConsumerState<DriverActiveRideScreen> {
  // Google Maps
  final Completer<GoogleMapController> _mapController = Completer();
  final DirectionsService _directionsService = DirectionsService();

  // Earnings - fetched from API, 0 until real data loads
  double _todayEarnings = 0.0;
  final String _todayDate = '26.07.2025';

  // Ride data - will be populated from provider
  late String _rideId;
  late LatLng _pickupLocation;
  late LatLng _dropLocation;
  late LatLng _driverLocation;
  late String _riderName;
  late String _riderPhone;
  late String _pickupAddress;
  late String _dropAddress;
  // OTP is now verified via backend API - driver enters OTP, backend validates
  late double _earning;
  late String _paymentMethod; // 'cash' or 'prepaid'
  String _passengerId = ''; // For chat functionality

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  bool _isLoadingRoute = true;
  String _distanceText = '';
  String _durationText = '';

  // Separate tracking for driver ETA and trip distance
  String _driverEtaText = ''; // Time for driver to reach pickup
  String _driverDistanceText = ''; // Distance from driver to pickup
  String _tripDistanceText = ''; // Distance from pickup to destination
  String _tripDurationText = ''; // Duration from pickup to destination

  // Numeric ETA/distance for syncing with passenger
  int _currentEtaMinutes = 0;
  double _currentDistanceMeters = 0;

  // OTP Entry
  final TextEditingController _otpController = TextEditingController();
  bool _otpVerified = false;
  String _otpError = '';
  bool _otpLoading = false;

  // Ride state
  bool _hasArrivedAtPickup = false; // Driver has arrived at pickup location
  bool _pickupConfirmed = false; // Driver confirmed pickup before OTP prompt
  bool _isPickedUp = false; // false = going to pickup, true = going to drop
  String _rideStatus = 'DRIVER_ASSIGNED';

  // Fare adjustments (driver input at ride completion)
  final TextEditingController _tollsController = TextEditingController();
  final TextEditingController _parkingController = TextEditingController();
  final TextEditingController _extraStopsController = TextEditingController();

  // Chat state
  final List<Map<String, dynamic>> _chatMessages = [];
  final Set<String> _chatMessageIds = {}; // For deduplication
  final ValueNotifier<int> _chatUpdateNotifier =
      ValueNotifier(0); // Triggers sheet rebuild on new message
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  VoidCallback? _unsubscribeChat;
  VoidCallback? _unsubscribeHistory;
  VoidCallback? _unsubscribeRideCancelled;

  // Uber/Rapido-style: vehicle icon + camera follow when ride in progress
  StreamSubscription<Position>? _positionStream;
  BitmapDescriptor? _vehicleIcon;
  double _driverHeading = 0;
  bool _cameraFollowEnabled = true;
  DateTime? _ignoreCameraMoveUntil;
  bool _chatSheetOpen = false;
  bool _autoChatHandled = false;
  bool _pendingPushChatOpen = false;
  String? _activeRideIdForChat;
  StreamSubscription<Map<String, dynamic>>? _chatOpenSubscription;

  // Map style for dark mode
  String? _mapStyle;
  bool _lastDarkMode = false;
  GoogleMapController? _mapControllerInstance;
  String? _driverRecordId;

  @override
  void initState() {
    super.initState();
    _hydrateDriverRecordId();
    _loadRideData();
    _initializeChatProvider();
    _loadVehicleIcon();
    _loadMapStyle();
    _setupMapElements();
    _calculateRoute();
    _subscribeToRideCancellation();
    _initializeDriverLocation();
    _fetchEarnings();
    _startLocationStream();
    _subscribeToNotificationChatOpens();
    // Sync ride status so we show correct UI when returning (OTP already verified)
    _syncRideStatusFromBackend();
  }

  void _initializeChatProvider() {
    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';
    if (currentUserId.isEmpty) return;
    ref.read(chatProvider(_rideId).notifier).initialize(
          currentUserId: currentUserId,
          passengerId: _passengerId,
          isDriver: true,
        );
    ref.read(chatProvider(_rideId).notifier).closeChat();
  }

  /// Load vehicle icon for Uber/Rapido-style map
  Future<void> _loadVehicleIcon() async {
    try {
      // Uber/Rapido style: ~40-50 logical pixels, with device pixel ratio for crisp rendering
      const config =
          ImageConfiguration(size: Size(44, 44), devicePixelRatio: 2.5);
      _vehicleIcon = await BitmapDescriptor.asset(
        config,
        'assets/map_icons/icon_cab.png',
      );
      if (mounted) _setupMapElements();
    } catch (e) {
      debugPrint('Vehicle icon load failed: $e');
      _vehicleIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }
  }

  /// Load map style based on dark mode setting
  Future<void> _loadMapStyle() async {
    try {
      final isDarkMode = ref.read(settingsProvider).isDarkMode;
      _lastDarkMode = isDarkMode;
      final stylePath = isDarkMode
          ? 'assets/map_styles/raahi_dark.json'
          : 'assets/map_styles/raahi_light.json';
      _mapStyle = await rootBundle.loadString(stylePath);
      if (_mapControllerInstance != null && _mapStyle != null) {
        _mapControllerInstance!.setMapStyle(_mapStyle);
      }
      debugPrint(
          '🗺️ Driver active ride map style loaded: ${isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  Future<void> _hydrateDriverRecordId() async {
    if (_driverRecordId != null && _driverRecordId!.isNotEmpty) return;
    try {
      final profile = await apiClient.getDriverProfile();
      final data = profile['data'];
      if (data is Map<String, dynamic>) {
        final resolved =
            (data['driver_id'] ?? data['driverId'] ?? data['id'])?.toString();
        if (resolved != null && resolved.isNotEmpty) {
          if (mounted) {
            setState(() => _driverRecordId = resolved);
          } else {
            _driverRecordId = resolved;
          }
        }
      }
    } catch (_) {
      // Non-fatal: backend now also accepts userId in location endpoint.
    }
  }

  /// Start continuous location stream - vehicle icon follows GPS along route
  void _startLocationStream() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) return;

      _positionStream?.cancel();
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (!mounted) return;
        setState(() {
          _driverLocation = LatLng(position.latitude, position.longitude);
          _driverHeading = position.heading;
        });
        _updateRealtimeEtaTexts();
        _setupMapElements();
        _updateDriverLocationOnBackend(position.latitude, position.longitude,
            heading: position.heading);
        if (_cameraFollowEnabled) _animateCameraToDriver();
      });
    } catch (e) {
      debugPrint('Location stream error: $e');
    }
  }

  void _animateCameraToDriver() async {
    try {
      _ignoreCameraMoveUntil =
          DateTime.now().add(const Duration(milliseconds: 800));
      final controller = await _mapController.future;
      controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _driverLocation,
            zoom: 17,
            bearing: _driverHeading,
            tilt: 30,
          ),
        ),
      );
    } catch (_) {}
  }

  /// Fetch ride status from backend — sync state based on current status
  Future<void> _syncRideStatusFromBackend() async {
    try {
      final response = await apiClient.getRide(_rideId);
      if (!mounted) return;
      final data = response['data'] as Map<String, dynamic>? ?? response;
      final backendRiderPhone = _extractPassengerPhoneFromRidePayload(data);
      final status =
          (data['status'] ?? data['rideStatus'] ?? '').toString().toUpperCase();
      final backendFare = _extractRideFareFromPayload(data);
      final backendPayment = _extractPaymentMethodFromPayload(data);

      if (backendRiderPhone.isNotEmpty &&
          _normalizePhone(_riderPhone).isEmpty) {
        setState(() {
          _riderPhone = backendRiderPhone;
        });
      }
      if (backendFare > 0 || backendPayment.isNotEmpty) {
        setState(() {
          if (backendFare > 0) _earning = backendFare;
          if (backendPayment.isNotEmpty) _paymentMethod = backendPayment;
        });
      }

      // Check if driver has arrived
      final arrivedStatuses = ['DRIVER_ARRIVED', 'ARRIVED'];
      if (arrivedStatuses.any((s) => status.contains(s))) {
        setState(() {
          _rideStatus = status.isNotEmpty ? status : _rideStatus;
          _hasArrivedAtPickup = true;
          _pickupConfirmed = false;
        });
      }

      final startedStatuses = ['RIDE_STARTED', 'IN_PROGRESS', 'STARTED'];
      if (startedStatuses.any((s) => status.contains(s))) {
        setState(() {
          _rideStatus = status.isNotEmpty ? status : _rideStatus;
          _hasArrivedAtPickup = true;
          _pickupConfirmed = true;
          _otpVerified = true;
          _isPickedUp = true;
        });
        _updateRealtimeEtaTexts();
        debugPrint('📡 Ride already started — skipping OTP screen');
        _calculateRoute(); // Recalc route for pickup→drop
      } else if (status.isNotEmpty) {
        setState(() {
          _rideStatus = status;
        });
      }
    } catch (_) {}
  }

  String _extractPassengerPhoneFromRidePayload(Map<String, dynamic> rideData) {
    final passenger = rideData['passenger'] is Map<String, dynamic>
        ? rideData['passenger'] as Map<String, dynamic>
        : null;
    final raw = rideData['rider_phone']?.toString() ??
        rideData['riderPhone']?.toString() ??
        rideData['passenger_phone']?.toString() ??
        rideData['passengerPhone']?.toString() ??
        passenger?['phone']?.toString() ??
        passenger?['phoneNumber']?.toString();
    return _normalizePhone(raw);
  }

  /// Fetch real driver earnings from API (shows 0 until loaded)
  Future<void> _fetchEarnings() async {
    try {
      final data = await apiClient.getDriverEarnings();
      if (!mounted) return;
      if (data['success'] == true) {
        final earnings = data['data'] as Map<String, dynamic>? ?? {};
        setState(() {
          _todayEarnings = (earnings['today']?['amount'] ?? 0).toDouble();
        });
      }
    } catch (_) {
      // Keep 0 on error
    }
  }

  /// Initialize driver's actual location using GPS and update backend
  Future<void> _initializeDriverLocation() async {
    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint(
            '⚠️ Location permission denied, using pickup-based location');
        return;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      if (mounted) {
        setState(() {
          _driverLocation = LatLng(position.latitude, position.longitude);
        });

        // Update markers with new driver location
        _setupMapElements();

        // Recalculate route from actual driver location
        _calculateRoute();

        // Update driver location on backend for rider tracking
        _updateDriverLocationOnBackend(position.latitude, position.longitude,
            heading: position.heading);

        debugPrint(
            '📍 Driver actual location: ${position.latitude}, ${position.longitude}');
      }
    } catch (e) {
      debugPrint('⚠️ Could not get actual location: $e');
    }
  }

  /// Update driver location on backend for rider tracking
  Future<void> _updateDriverLocationOnBackend(double lat, double lng,
      {double? heading}) async {
    try {
      if (_driverRecordId == null || _driverRecordId!.isEmpty) {
        await _hydrateDriverRecordId();
      }
      final user = ref.read(currentUserProvider);
      final driverId = _driverRecordId ?? user?.id ?? '';

      if (driverId.isEmpty) return;

      // Store in database via REST
      apiClient.updateDriverLocation(driverId, lat, lng, heading: heading);

      // Broadcast to rider via Socket.io (ride-specific, rider receives this)
      // Include ETA and distance so passenger shows same values as driver
      webSocketService.updateDriverLocation(RideLocationUpdate(
        rideId: _rideId,
        latitude: lat,
        longitude: lng,
        heading: heading,
        etaMinutes: _currentEtaMinutes > 0 ? _currentEtaMinutes : null,
        distanceMeters:
            _currentDistanceMeters > 0 ? _currentDistanceMeters : null,
      ));
    } catch (e) {
      debugPrint('Failed to update driver location: $e');
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _chatOpenSubscription?.cancel();
    _otpController.dispose();
    _tollsController.dispose();
    _parkingController.dispose();
    _extraStopsController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _unsubscribeChat?.call();
    _unsubscribeHistory?.call();
    _unsubscribeRideCancelled?.call();
    _chatUpdateNotifier.dispose();
    super.dispose();
  }

  void _subscribeToNotificationChatOpens() {
    _chatOpenSubscription =
        pushNotificationService.chatOpenStream.listen((payload) {
      final targetRideId = payload['rideId']?.toString() ?? '';
      final currentRideId = _activeRideIdForChat ?? widget.initialRideId ?? '';
      if (targetRideId.isEmpty ||
          currentRideId.isEmpty ||
          targetRideId != currentRideId) {
        return;
      }
      if (!mounted || _chatSheetOpen) return;

      if (_activeRideIdForChat == null || _activeRideIdForChat!.isEmpty) {
        _pendingPushChatOpen = true;
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_chatSheetOpen) {
          _showChatDialog(context);
        }
      });
    });
  }

  /// Subscribe to ride cancellation events from rider
  void _subscribeToRideCancellation() {
    _unsubscribeRideCancelled =
        webSocketService.subscribe('ride_cancelled', (message) {
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;

      final cancelledRideId = data['rideId'] as String? ?? '';

      // Check if this cancellation is for our current ride
      if (cancelledRideId == _rideId) {
        debugPrint('⚠️ Ride $_rideId was cancelled by rider');
        _handleRideCancelledByRider(data);
      }
    });
  }

  /// Handle when rider cancels the ride
  void _handleRideCancelledByRider(Map<String, dynamic> data) {
    if (!mounted) return;

    final reason = data['reason'] as String? ?? 'Rider cancelled the ride';

    // Clear the accepted ride from provider
    ref.read(driverRidesProvider.notifier).clearAcceptedRide();

    // Show alert dialog to driver
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.cancel, color: Colors.red, size: 28),
            ),
            const SizedBox(width: 12),
            Text(ref.tr('ride_cancelled')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reason,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: Color(0xFFFF9800), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ref.tr('available_new_requests'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF5D4037),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                context.go(AppRoutes.driverHome);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Back to Home',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _subscribeToChatMessages() {
    // Listen for individual chat messages (from server echo or other party)
    _unsubscribeChat = webSocketService.subscribe('ride_message', (message) {
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;
      final msgRideId = data['rideId'] as String? ?? '';
      if (msgRideId != _rideId) return;

      _addChatMessage(data);

      // Also forward to chat provider for the new chat UI
      try {
        ref
            .read(chatProvider(_rideId).notifier)
            .handleExternalChatMessage(data);
      } catch (_) {}
    });

    // Listen for chat history (sent when joining ride room)
    _unsubscribeHistory = webSocketService.subscribe('chat_history', (message) {
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;
      final historyRideId = data['rideId'] as String? ?? '';
      if (historyRideId != _rideId) return;

      final messages = data['messages'] as List<dynamic>? ?? [];
      for (final msg in messages) {
        if (msg is Map<String, dynamic>) {
          _addChatMessage(msg, fromHistory: true);
        }
      }
      // Sort by timestamp
      if (mounted) {
        setState(() {
          _chatMessages.sort(
              (a, b) => (a['ts'] as int? ?? 0).compareTo(b['ts'] as int? ?? 0));
        });
      }
      _chatUpdateNotifier.value++;
    });
  }

  /// Add a chat message from WebSocket (real-time delivery from OTHER party only)
  /// Driver's own messages are ALWAYS skipped here — they're shown optimistically
  /// on send, and reconciled via the REST _loadChatHistory clean merge.
  void _addChatMessage(Map<String, dynamic> data, {bool fromHistory = false}) {
    final msgId = data['id'] as String? ?? '';
    final msgText = data['message'] as String? ?? '';
    final sender = data['sender'] as String? ?? 'unknown';
    if (msgText.isEmpty) return;

    // ALWAYS skip our own messages — optimistic add + REST merge handles them
    if (sender == 'driver') return;

    // Already tracked by server ID — skip
    if (msgId.isNotEmpty && _chatMessageIds.contains(msgId)) return;
    if (msgId.isNotEmpty) _chatMessageIds.add(msgId);

    final ts =
        data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (mounted) {
      setState(() {
        _chatMessages.add({
          'id': msgId,
          'sender': sender,
          'text': msgText,
          'time': _formatTime(DateTime.fromMillisecondsSinceEpoch(ts)),
          'ts': ts,
        });
      });
      _chatUpdateNotifier.value++; // Notify chat sheet to rebuild
    }
  }

  /// Load chat history from REST API — clean merge with local messages
  Future<void> _loadChatHistory() async {
    final serverMessages = await apiClient.getChatMessages(_rideId);
    if (!mounted || serverMessages.isEmpty) return;

    setState(() {
      // Build a set of server message IDs for quick lookup
      final serverIds = <String>{};
      for (final msg in serverMessages) {
        final id = msg['id'] as String? ?? '';
        if (id.isNotEmpty) serverIds.add(id);
      }

      // Remove optimistic (local_) messages that now exist on the server
      // Match by: same text + same sender
      _chatMessages.removeWhere((local) {
        final localId = local['id'] as String? ?? '';
        if (!localId.startsWith('local_')) return false;
        final localText = local['text'] as String? ?? '';
        final localSender = local['sender'] as String? ?? '';
        return serverMessages.any((srv) =>
            (srv['message'] as String? ?? '') == localText &&
            (srv['sender'] as String? ?? '') == localSender);
      });

      // Add any server messages we don't already have
      for (final msg in serverMessages) {
        final msgId = msg['id'] as String? ?? '';
        if (msgId.isNotEmpty && _chatMessageIds.contains(msgId)) continue;
        if (msgId.isNotEmpty) _chatMessageIds.add(msgId);

        final ts =
            msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        _chatMessages.add({
          'id': msgId,
          'sender': msg['sender'] as String? ?? 'unknown',
          'text': msg['message'] as String? ?? '',
          'time': _formatTime(DateTime.fromMillisecondsSinceEpoch(ts)),
          'ts': ts,
        });
      }

      _chatMessages.sort(
          (a, b) => (a['ts'] as int? ?? 0).compareTo(b['ts'] as int? ?? 0));
    });
    _chatUpdateNotifier.value++;
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:${dt.minute.toString().padLeft(2, '0')} $amPm';
  }

  void _loadRideData() {
    final acceptedRide = ref.read(driverRidesProvider).acceptedRide;

    if (acceptedRide != null) {
      _rideId = acceptedRide.id;
      _activeRideIdForChat = _rideId;
      _pickupLocation =
          acceptedRide.pickupLocation ?? const LatLng(28.5245, 77.1855);
      _dropLocation =
          acceptedRide.destinationLocation ?? const LatLng(28.6507, 77.2334);
      _riderName = acceptedRide.riderName ?? 'Rider';
      _riderPhone = _normalizePhone(acceptedRide.riderPhone);
      _passengerId = acceptedRide.riderId ?? '';
      _pickupAddress = acceptedRide.pickupAddress;
      _dropAddress = acceptedRide.dropAddress;
      // OTP is NOT shown to driver - they must ask passenger for it
      // Backend will verify OTP when driver calls POST /api/rides/:id/start
      _earning = acceptedRide.earning;
      _paymentMethod = acceptedRide.paymentMethod;

      debugPrint('📦 Loaded ride data:');
      debugPrint('   Ride ID: $_rideId');
      debugPrint('   Rider: $_riderName');
      debugPrint('   OTP: Driver must ask rider for OTP (backend validates)');
      debugPrint('   Pickup: $_pickupAddress');
      debugPrint('   Drop: $_dropAddress');
      debugPrint('   Payment Method: $_paymentMethod');
      debugPrint(
          '   Pickup LatLng: ${_pickupLocation.latitude}, ${_pickupLocation.longitude}');
      debugPrint(
          '   Drop LatLng: ${_dropLocation.latitude}, ${_dropLocation.longitude}');
    } else if ((widget.initialRideId ?? '').isNotEmpty) {
      _rideId = widget.initialRideId!;
      _activeRideIdForChat = _rideId;
      _pickupLocation = const LatLng(28.5245, 77.1855);
      _dropLocation = const LatLng(28.6507, 77.2334);
      _riderName = 'Rider';
      _riderPhone = '';
      _pickupAddress = 'Pickup';
      _dropAddress = 'Drop';
      _earning = 0.0;
      _paymentMethod = 'cash';
      unawaited(_hydrateRideContextFromBackend());
    } else {
      _rideId = 'demo_ride';
      _activeRideIdForChat = _rideId;
      // Fallback to demo data
      _pickupLocation = const LatLng(28.5245, 77.1855);
      _dropLocation = const LatLng(28.6507, 77.2334);
      _riderName = 'Rohit Kumar';
      _riderPhone = '';
      _pickupAddress = 'Safdarjung Enclave, Gali no.20';
      _dropAddress = 'Chandni Chowk, Metro Station gate 4';
      // Demo mode - OTP verification will fail but that's expected
      _earning = 200.00;
      _paymentMethod = 'cash'; // Default to cash for demo
    }

    // Driver location slightly before pickup
    _driverLocation = LatLng(
      _pickupLocation.latitude + 0.003,
      _pickupLocation.longitude + 0.002,
    );
    _maybeAutoOpenChat();
    if (_pendingPushChatOpen && _rideId != 'demo_ride') {
      _pendingPushChatOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_chatSheetOpen) {
          _showChatDialog(context);
        }
      });
    }
  }

  Future<void> _hydrateRideContextFromBackend() async {
    try {
      final response = await apiClient.getRide(_rideId);
      final data = response['data'] is Map<String, dynamic>
          ? response['data'] as Map<String, dynamic>
          : response;
      final pickupLat = (data['pickupLat'] as num?)?.toDouble() ??
          (data['pickupLatitude'] as num?)?.toDouble();
      final pickupLng = (data['pickupLng'] as num?)?.toDouble() ??
          (data['pickupLongitude'] as num?)?.toDouble();
      final dropLat = (data['dropLat'] as num?)?.toDouble() ??
          (data['dropLatitude'] as num?)?.toDouble();
      final dropLng = (data['dropLng'] as num?)?.toDouble() ??
          (data['dropLongitude'] as num?)?.toDouble();
      final passenger = data['passenger'] is Map<String, dynamic>
          ? data['passenger'] as Map<String, dynamic>
          : null;
      final backendFare = _extractRideFareFromPayload(data);
      final backendPayment = _extractPaymentMethodFromPayload(data);
      if (!mounted) return;
      setState(() {
        _passengerId = (data['passengerId']?.toString() ??
            passenger?['id']?.toString() ??
            _passengerId);
        final firstName = passenger?['firstName']?.toString() ?? '';
        final lastName = passenger?['lastName']?.toString() ?? '';
        final passengerName = '$firstName $lastName'.trim();
        if (passengerName.isNotEmpty) {
          _riderName = passengerName;
        }
        final backendPhone = _normalizePhone(
          passenger?['phone']?.toString() ??
              data['riderPhone']?.toString() ??
              data['passengerPhone']?.toString(),
        );
        if (backendPhone.isNotEmpty) {
          _riderPhone = backendPhone;
        }
        _pickupAddress = data['pickupAddress']?.toString() ?? _pickupAddress;
        _dropAddress = data['dropAddress']?.toString() ?? _dropAddress;
        if (pickupLat != null && pickupLng != null) {
          _pickupLocation = LatLng(pickupLat, pickupLng);
        }
        if (dropLat != null && dropLng != null) {
          _dropLocation = LatLng(dropLat, dropLng);
        }
        if (backendFare > 0) {
          _earning = backendFare;
        }
        if (backendPayment.isNotEmpty) {
          _paymentMethod = backendPayment;
        }
      });
      _setupMapElements();
      unawaited(_calculateRoute());
      _maybeAutoOpenChat();
    } catch (e) {
      debugPrint('Failed to hydrate ride context from backend: $e');
    }
  }

  void _maybeAutoOpenChat() {
    if (!widget.autoOpenChat || _autoChatHandled || _chatSheetOpen) return;
    if (_rideId.isEmpty || _rideId == 'demo_ride') return;
    _autoChatHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showChatDialog(context);
      }
    });
  }

  void _setupMapElements() {
    final driverIcon = _vehicleIcon ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    _markers = {
      Marker(
        markerId: const MarkerId('driver'),
        position: _driverLocation,
        icon: driverIcon,
        rotation: _driverHeading,
        infoWindow: const InfoWindow(title: 'You'),
        flat: true,
      ),
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickupLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: 'Pickup', snippet: _pickupAddress),
      ),
      Marker(
        markerId: const MarkerId('drop'),
        position: _dropLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: 'Drop', snippet: _dropAddress),
      ),
    };
  }

  Future<void> _calculateRoute() async {
    if (!mounted) return;
    setState(() => _isLoadingRoute = true);

    try {
      // Calculate route from pickup to drop (the main ride route)
      final rideRoute = await _directionsService.getRoute(
        origin: _pickupLocation,
        destination: _dropLocation,
        mode: TravelMode.driving,
      );

      // Calculate route from driver to pickup (if not picked up yet)
      RouteResult? driverRoute;
      if (!_isPickedUp) {
        driverRoute = await _directionsService.getRoute(
          origin: _driverLocation,
          destination: _pickupLocation,
          mode: TravelMode.driving,
        );
      }

      if (!mounted) return;
      final tripDistanceText = _resolveDistanceText(
        rideRoute.distanceText,
        _pickupLocation,
        _dropLocation,
      );
      final driverDistanceText = driverRoute != null
          ? _resolveDistanceText(
              driverRoute.distanceText,
              _driverLocation,
              _pickupLocation,
            )
          : tripDistanceText;
      setState(() {
        // Store trip distance (pickup to destination) - this is constant
        _tripDistanceText = tripDistanceText;
        _tripDurationText = _formatEtaMinutes((rideRoute.duration / 60).ceil());

        // Store driver ETA to pickup (cap at 2 hours to avoid confusing "10+ hours" display)
        if (driverRoute != null) {
          _driverEtaText =
              _formatEtaMinutes((driverRoute.duration / 60).ceil());
          _driverDistanceText = driverDistanceText;
        }

        // Show ETA based on current state
        if (_isPickedUp) {
          // After pickup: show distance/time to destination
          _distanceText = tripDistanceText;
          _durationText = _formatEtaMinutes((rideRoute.duration / 60).ceil());
        } else {
          // Before pickup: show driver's ETA to pickup
          _distanceText = driverDistanceText;
          _durationText = driverRoute != null
              ? _formatEtaMinutes((driverRoute.duration / 60).ceil())
              : _formatEtaMinutes((rideRoute.duration / 60).ceil());
        }

        // Uber/Rapido-style: thin, clean polylines
        _polylines = {
          // Main ride route border (pickup → drop)
          Polyline(
            polylineId: const PolylineId('ride_route_border'),
            points: rideRoute.points,
            color: const Color(0xFF1A1A1A),
            width: 5,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
          // Main ride route fill
          Polyline(
            polylineId: const PolylineId('ride_route'),
            points: rideRoute.points,
            color: const Color(0xFF4285F4),
            width: 3,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };

        // Driver → Pickup: dashed orange (before pickup)
        if (!_isPickedUp && driverRoute != null) {
          _polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_route_border'),
              points: driverRoute.points,
              color: const Color(0xFF8B5E3C),
              width: 5,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
              patterns: [PatternItem.dash(12), PatternItem.gap(8)],
            ),
          );
          _polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_route'),
              points: driverRoute.points,
              color: const Color(0xFFD4956A),
              width: 3,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
              patterns: [PatternItem.dash(12), PatternItem.gap(8)],
            ),
          );
        }

        _isLoadingRoute = false;
      });

      // Fit bounds to show all points
      _fitAllBounds();
    } catch (e) {
      debugPrint('Route calculation error: $e');
      setState(() => _isLoadingRoute = false);
    }
  }

  void _updateRealtimeEtaTexts() {
    final target = _isPickedUp ? _dropLocation : _pickupLocation;
    final distanceMeters = _distanceMeters(
      _driverLocation.latitude,
      _driverLocation.longitude,
      target.latitude,
      target.longitude,
    );
    final avgKmph = _isPickedUp ? 24.0 : 20.0;
    final etaMinutes =
        ((distanceMeters / 1000) / avgKmph * 60).ceil().clamp(1, 180);

    final distanceText = _formatDistanceMeters(distanceMeters);
    final etaText = _formatEtaMinutes(etaMinutes);

    if (!mounted) return;
    setState(() {
      // Store numeric values for syncing with passenger
      _currentEtaMinutes = etaMinutes;
      _currentDistanceMeters = distanceMeters;

      if (_isPickedUp) {
        _durationText = etaText;
        _distanceText = distanceText;
      } else {
        _driverEtaText = etaText;
        _driverDistanceText = distanceText;
        _durationText = etaText;
        _distanceText = distanceText;
      }
    });
  }

  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  String _formatDistanceMeters(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatEtaMinutes(int minutes) {
    final clampedMinutes = minutes < 1 ? 1 : minutes;
    if (clampedMinutes >= 120) return '2+ hours';
    if (clampedMinutes >= 60) {
      final h = clampedMinutes ~/ 60;
      final m = clampedMinutes % 60;
      return m == 0 ? '$h hr' : '$h hr $m min';
    }
    return '$clampedMinutes min';
  }

  String _resolveDistanceText(String rawText, LatLng from, LatLng to) {
    final parsedMeters = _parseDistanceTextToMeters(rawText);
    if (parsedMeters != null && parsedMeters >= 50) {
      return _formatDistanceMeters(parsedMeters);
    }

    // Fallback for APIs occasionally returning "0 m" even for valid trips.
    final straightMeters = _distanceMeters(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    final roadMeters = (straightMeters * 1.2).clamp(50.0, 200000.0);
    return _formatDistanceMeters(roadMeters);
  }

  double? _parseDistanceTextToMeters(String rawText) {
    final text = rawText.trim().toLowerCase();
    if (text.isEmpty) return null;
    final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1) ?? '');
    if (value == null) return null;
    if (text.contains('km')) return value * 1000;
    if (text.contains('m')) return value;
    return null;
  }

  double _extractRideFareFromPayload(Map<String, dynamic> rideData) {
    final pricing = rideData['pricing'] is Map<String, dynamic>
        ? rideData['pricing'] as Map<String, dynamic>
        : null;
    final values = <dynamic>[
      rideData['totalFare'],
      rideData['fare'],
      rideData['estimatedFare'],
      rideData['payableAmount'],
      rideData['finalFare'],
      rideData['amount'],
      rideData['price'],
      pricing?['totalFare'],
      pricing?['fare'],
      pricing?['estimatedFare'],
    ];
    for (final value in values) {
      if (value is num && value.toDouble() > 0) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return 0;
  }

  String _extractPaymentMethodFromPayload(Map<String, dynamic> rideData) {
    final value =
        (rideData['paymentMethod'] ?? rideData['payment_method'])?.toString();
    if (value == null || value.trim().isEmpty) return '';
    return value.trim().toLowerCase();
  }

  Future<void> _fitAllBounds() async {
    try {
      final controller = await _mapController.future;

      // Calculate bounds including all points
      List<LatLng> allPoints = [
        _driverLocation,
        _pickupLocation,
        _dropLocation
      ];
      for (final polyline in _polylines) {
        allPoints.addAll(polyline.points);
      }

      double minLat = allPoints.first.latitude;
      double maxLat = allPoints.first.latitude;
      double minLng = allPoints.first.longitude;
      double maxLng = allPoints.first.longitude;

      for (final point in allPoints) {
        if (point.latitude < minLat) minLat = point.latitude;
        if (point.latitude > maxLat) maxLat = point.latitude;
        if (point.longitude < minLng) minLng = point.longitude;
        if (point.longitude > maxLng) maxLng = point.longitude;
      }

      final latPadding = (maxLat - minLat) * 0.15;
      final lngPadding = (maxLng - minLng) * 0.15;

      final bounds = LatLngBounds(
        southwest: LatLng(minLat - latPadding, minLng - lngPadding),
        northeast: LatLng(maxLat + latPadding, maxLng + lngPadding),
      );

      await Future.delayed(const Duration(milliseconds: 200));
      controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    } catch (e) {
      debugPrint('Error fitting bounds: $e');
    }
  }

  Future<void> _fitBounds(LatLngBounds bounds) async {
    final controller = await _mapController.future;
    await Future.delayed(const Duration(milliseconds: 200));
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  /// Verify OTP and start the ride via backend API.
  /// The backend will validate the OTP against what was stored during ride creation.
  Future<void> _verifyOtp() async {
    if (_otpLoading) return;
    final enteredOtp = _otpController.text.trim();

    if (enteredOtp.isEmpty) {
      setState(() => _otpError = 'Please enter the OTP');
      return;
    }

    if (enteredOtp.length != 4) {
      setState(() => _otpError = 'OTP must be 4 digits');
      return;
    }

    // Clear stale error and show loading state
    setState(() {
      _otpError = '';
      _otpLoading = true;
    });

    try {
      debugPrint('🚗 Verifying OTP with backend for ride: $_rideId');

      if (!_hasArrivedAtPickup) {
        setState(() {
          _otpError = 'Please mark "I\'ve Arrived" first.';
          _otpLoading = false;
        });
        return;
      }

      // Now call the startRide endpoint with OTP
      final result = await apiClient.startRide(_rideId, enteredOtp);

      if (!mounted) return;

      if (result['success'] == true) {
        setState(() {
          _otpVerified = true;
          _otpError = '';
          _otpLoading = false;
        });
        debugPrint('✅ OTP verified and ride started via backend');

        // Notify rider that ride has started via realtime service
        debugPrint('📡 Sending RIDE_STARTED notification to rider');
        realtimeService.updateRideStatus(_rideId, 'RIDE_STARTED');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.tr('otp_verified_started')),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final code = result['code'] as String?;
        String errorMessage;

        if (code == 'INVALID_OTP') {
          errorMessage = 'Incorrect OTP. Ask rider for correct OTP.';
        } else if (code == 'FORBIDDEN') {
          errorMessage = result['message'] ?? 'Not authorized';
        } else {
          errorMessage = result['message'] ?? 'Failed to verify OTP';
        }

        if (mounted) {
          setState(() {
            _otpError = errorMessage;
            _otpLoading = false;
          });
        }
        debugPrint('❌ OTP verification failed: $errorMessage');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error verifying OTP: $e');
      setState(() {
        _otpError = 'Network error. Please try again.';
        _otpLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('network_error_retry')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Driver taps "I've Arrived" when they reach the pickup location
  /// This should only update arrival state. OTP comes after "Confirm Pickup".
  Future<void> _markArrivedAtPickup() async {
    try {
      // Update status to DRIVER_ARRIVED
      await apiClient.updateRideStatus(_rideId, 'DRIVER_ARRIVED');
      debugPrint('✅ Status updated to DRIVER_ARRIVED');

      // Notify rider via realtime
      realtimeService.updateRideStatus(_rideId, 'DRIVER_ARRIVED');
      debugPrint('📡 Notified rider: driver has arrived');

      setState(() {
        _rideStatus = 'DRIVER_ARRIVED';
        _hasArrivedAtPickup = true;
        _pickupConfirmed = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Arrival confirmed. Please confirm pickup to continue.'),
          backgroundColor: Color(0xFF2196F3),
        ),
      );
    } catch (e) {
      debugPrint('Error marking arrived: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_extractErrorMessage(
            e,
            fallback:
                'Unable to mark arrival. Move closer to pickup and try again.',
          )),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Show OTP entry dialog for driver to verify rider
  void _showOtpEntryDialog() {
    _otpController.clear();
    setState(() {
      _otpError = '';
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Title
                const Row(
                  children: [
                    Icon(Icons.verified_user,
                        color: Color(0xFF4CAF50), size: 28),
                    SizedBox(width: 12),
                    Text(
                      'Enter Ride PIN',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Ask the rider for their 4-digit PIN to start the trip',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 24),

                // OTP Input Field
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 16,
                    color: Color(0xFF1A1A1A), // Always black for visibility
                  ),
                  decoration: InputDecoration(
                    hintText: '• • • •',
                    hintStyle: TextStyle(
                      fontSize: 32,
                      color: Colors.grey[400],
                      letterSpacing: 16,
                    ),
                    counterText: '',
                    filled: true,
                    fillColor: const Color(0xFFF5F5F5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide:
                          const BorderSide(color: Color(0xFF4CAF50), width: 2),
                    ),
                    errorText: _otpError.isNotEmpty ? _otpError : null,
                    errorStyle: const TextStyle(color: Colors.red),
                  ),
                  onChanged: (value) {
                    if (value.length == 4) {
                      // Auto-verify when 4 digits entered
                      _verifyOtpFromDialog(value, setModalState);
                    }
                  },
                ),
                const SizedBox(height: 24),

                // Verify Button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _otpLoading
                        ? null
                        : () {
                            if (_otpController.text.length == 4) {
                              _verifyOtpFromDialog(
                                  _otpController.text, setModalState);
                            } else {
                              setModalState(() {
                                _otpError = 'Please enter 4-digit PIN';
                              });
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: _otpLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Verify & Start Ride',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),

                // Cancel button
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Verify OTP from dialog and start ride
  Future<void> _verifyOtpFromDialog(
      String otp, StateSetter setModalState) async {
    if (_otpLoading) return;
    setModalState(() {
      _otpError = '';
      _otpLoading = true;
    });
    try {
      debugPrint('🔐 Verifying OTP from dialog: $otp');

      if (!_hasArrivedAtPickup) {
        setModalState(() {
          _otpError = 'Please mark "I\'ve Arrived" first.';
          _otpLoading = false;
        });
        return;
      }

      // Call backend to verify OTP and start ride
      final result = await apiClient.startRide(_rideId, otp);

      if (result['success'] == true) {
        debugPrint('✅ OTP verified successfully!');

        setState(() {
          _otpVerified = true;
          _otpError = '';
          _otpLoading = false;
          _pickupConfirmed = true;
          _rideStatus = 'RIDE_STARTED';
        });

        // Close dialog
        if (mounted) Navigator.pop(context);

        // Auto-confirm pickup and start ride
        setState(() {
          _isPickedUp = true;
          _rideStatus = 'RIDE_STARTED';
        });
        _updateRealtimeEtaTexts();
        _calculateRoute();

        // Notify rider
        realtimeService.updateRideStatus(_rideId, 'RIDE_STARTED');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.tr('ride_started_navigate')),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        setModalState(() {
          _otpError = result['message'] ?? 'Invalid PIN. Please try again.';
          _otpLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ OTP verification error: $e');
      setModalState(() {
        _otpError = 'Invalid PIN. Please try again.';
        _otpLoading = false;
      });
    }
  }

  void _confirmPickup() {
    if (!_hasArrivedAtPickup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please mark "I\'ve Arrived" first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _pickupConfirmed = true;
    });
    _showOtpEntryDialog();
  }

  /// Update ride status through the required sequence.
  /// Backend requires: DRIVER_ASSIGNED -> CONFIRMED -> DRIVER_ARRIVED -> RIDE_STARTED
  Future<void> _updateRideStatusSequence() async {
    try {
      // Step 1: CONFIRMED (driver confirms they're heading to pickup)
      await apiClient.updateRideStatus(_rideId, 'CONFIRMED');
      debugPrint('✅ Status updated to CONFIRMED');

      // Step 2: DRIVER_ARRIVED (driver has arrived at pickup)
      await apiClient.updateRideStatus(_rideId, 'DRIVER_ARRIVED');
      debugPrint('✅ Status updated to DRIVER_ARRIVED');

      // Step 3: RIDE_STARTED (ride begins after OTP verification)
      await apiClient.updateRideStatus(_rideId, 'RIDE_STARTED');
      debugPrint('✅ Status updated to RIDE_STARTED');

      // Notify rider via real-time service that ride is now in progress
      realtimeService.updateRideStatus(_rideId, 'in_progress');
    } catch (e) {
      debugPrint('❌ Error updating ride status: $e');
      realtimeService.updateRideStatus(_rideId, 'in_progress');
    }
  }

  void _completeRide() {
    final trCompleteRide = ref.tr('complete_ride');
    final trDroppedRider = ref.tr('dropped_rider_question');
    final trNotYet = ref.tr('not_yet');
    final trYesComplete = ref.tr('yes_complete');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(trCompleteRide),
        content: Text(trDroppedRider),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(trNotYet),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // Complete on backend first (no adjustments for prepaid)
              if (_paymentMethod.toLowerCase() == 'cash') {
                _showCashPaymentQR(); // Payment sheet has adjustment fields
              } else {
                _completeRideOnBackend(); // Prepaid - complete with no adjustments
                _showRideSummary();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
            ),
            child: Text(trYesComplete,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showCashPaymentQR() {
    debugPrint('💰 Driver: Showing cash payment QR dialog');
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4956A).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.payments_outlined,
                      color: Color(0xFFD4956A),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Collect Cash Payment',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        Text(
                          'Show QR to rider for payment',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Amount to collect
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1A1A1A), Color(0xFF333333)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Amount to Collect: ',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
                    Text(
                      '₹${_earning.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // QR Code
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE8E8E8), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // QR Image - UPI payment QR code
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/images/c__Users_AnuragTripathi_AppData_Roaming_Cursor_User_workspaceStorage_7c681e920c35e6a597e37186e21d741a_images_image-5c6e3067-e898-41a3-bd66-2e24748c77e2.png',
                        width: 200,
                        height: 200,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          // Fallback if image not found - show placeholder
                          return Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.qr_code_2,
                                    size: 100, color: Color(0xFF1A1A1A)),
                                SizedBox(height: 8),
                                Text(
                                  'Scan to Pay',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Color(0xFF888888),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Scan QR code to pay',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Additional charges (optional)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    const Icon(Icons.add_road,
                        size: 20, color: Color(0xFF888888)),
                    const SizedBox(width: 8),
                    Text(ref.tr('add_charges'),
                        style: const TextStyle(
                            fontSize: 14, color: Color(0xFF666666))),
                  ],
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      children: [
                        TextField(
                          controller: _tollsController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Tolls (₹)',
                            hintText: '0',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _parkingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Parking fees (₹)',
                            hintText: '0',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _extraStopsController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Extra stops (count)',
                            hintText: '0',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Cash received option
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 20, color: Color(0xFF888888)),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'You can also collect cash directly from the rider',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Confirm Payment Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    debugPrint('💰 Driver: Payment Received button clicked');
                    Navigator.pop(context);
                    _completeRideWithAdjustments();
                    _showRideSummary();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Payment Received',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _completeRideOnBackend({
    double? tolls,
    int? waitingMinutes,
    double? parkingFees,
    int? extraStopsCount,
    double? discountPercent,
  }) async {
    try {
      debugPrint('🎉 Completing ride $_rideId on backend...');

      // Notify rider via real-time service
      realtimeService.updateRideStatus(_rideId, 'completed');

      // Also update via REST API with optional fare adjustments
      final data = await apiClient.updateRideStatus(
        _rideId,
        'RIDE_COMPLETED',
        tolls: tolls,
        waitingMinutes: waitingMinutes,
        parkingFees: parkingFees,
        extraStopsCount: extraStopsCount,
        discountPercent: discountPercent,
      );
      debugPrint('Ride completed on backend: ${data['message']}');
      unawaited(_refreshDriverFinancialsAfterRide());
    } catch (e) {
      debugPrint('❌ Error completing ride on backend: $e');
    }
  }

  Future<void> _refreshDriverFinancialsAfterRide() async {
    try {
      final walletResp = await apiClient.getDriverWallet();
      final walletData = walletResp['data'] as Map<String, dynamic>? ?? {};
      final balanceData = walletData['balance'] as Map<String, dynamic>? ?? {};
      final available = (balanceData['available'] as num?)?.toDouble();
      if (available != null) {
        debugPrint(
            '💰 Wallet refreshed after ride completion: available=₹${available.toStringAsFixed(2)}');
      }
    } catch (e) {
      debugPrint('⚠️ Wallet refresh after ride completion failed: $e');
    }

    try {
      await _fetchEarnings();
      debugPrint('💰 Earnings refreshed after ride completion');
    } catch (e) {
      debugPrint('⚠️ Earnings refresh after ride completion failed: $e');
    }
  }

  void _completeRideWithAdjustments() {
    final tollsStr = _tollsController.text.trim();
    final parkingStr = _parkingController.text.trim();
    final extraStopsStr = _extraStopsController.text.trim();

    final tolls = tollsStr.isEmpty ? null : double.tryParse(tollsStr);
    final parkingFees = parkingStr.isEmpty ? null : double.tryParse(parkingStr);
    final extraStops =
        extraStopsStr.isEmpty ? null : int.tryParse(extraStopsStr);

    _completeRideOnBackend(
      tolls: tolls,
      parkingFees: parkingFees,
      extraStopsCount: extraStops,
    );
  }

  void _showRideSummary() {
    // Clear the accepted ride from provider
    ref.read(driverRidesProvider.notifier).clearAcceptedRide();

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle,
              color: Color(0xFF4CAF50),
              size: 64,
            ),
            const SizedBox(height: 16),
            const Text(
              'Ride Completed!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Great job! Your earnings have been updated.',
              style: TextStyle(color: Color(0xFF888888)),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Earnings for this ride',
                    style: TextStyle(fontSize: 14),
                  ),
                  Text(
                    '₹${_earning.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF4CAF50),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.go(AppRoutes.driverHome);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: const Text(
                  'Back to Home',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _callRider() async {
    final phone = _normalizePhone(_riderPhone);
    if (phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('phone_unavailable'))),
      );
      return;
    }
    final Uri phoneUri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    }
  }

  String _normalizePhone(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    var p = raw.trim().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (p.startsWith('+')) return p;
    if (p.startsWith('91') && p.length == 12) return '+$p';
    if (p.length == 10) return '+91$p';
    return p;
  }

  Future<void> _openNavigation() async {
    final inProgressStatuses = ['RIDE_STARTED', 'IN_PROGRESS', 'STARTED'];
    final shouldNavigateToDrop =
        _isPickedUp || inProgressStatuses.any((s) => _rideStatus.contains(s));
    final destination = shouldNavigateToDrop ? _dropLocation : _pickupLocation;
    debugPrint(
      '🧭 Launch navigation '
      'rideId=$_rideId status=$_rideStatus '
      'destinationLat=${destination.latitude} destinationLng=${destination.longitude}',
    );
    final url = Uri.parse(
      'google.navigation:q=${destination.latitude},${destination.longitude}&mode=d',
    );

    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      // Fallback to Google Maps URL
      final mapsUrl = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${destination.latitude},${destination.longitude}&travelmode=driving',
      );
      await launchUrl(mapsUrl, mode: LaunchMode.externalApplication);
    }
  }

  void _cancelRide() {
    final trCancelRide = ref.tr('cancel_ride_question');
    final trCancelConfirm = ref.tr('cancel_ride_confirm');
    final trNo = ref.tr('no');
    final trYesCancel = ref.tr('yes_cancel');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trCancelRide),
        content: Text(trCancelConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(trNo),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performCancelRide();
            },
            child: Text(trYesCancel, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _performCancelRide() async {
    debugPrint('🚫 Driver cancelling ride $_rideId');

    try {
      // Notify rider via real-time service (Socket.io)
      realtimeService.cancelRide(_rideId, reason: 'Cancelled by driver');
      // Cancel via REST API (triggers server-side notifications)
      await apiClient.cancelRide(_rideId, reason: 'Cancelled by driver');
      debugPrint('✅ Ride $_rideId cancelled successfully');
    } catch (e) {
      debugPrint('❌ Error cancelling ride: $e');
    }

    // ALWAYS clear and navigate — UI must update even if API fails (network error, etc.)
    ref.read(driverRidesProvider.notifier).clearAcceptedRide();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('ride_cancelled_available')),
          backgroundColor: const Color(0xFFD4956A),
        ),
      );
      context.go(AppRoutes.driverHome);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Stack(
                children: [
                  _buildMap(),

                  // Navigation controls (thumb-zone friendly, always above bottom panel)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _buildNavigationControls(),
                  ),
                ],
              ),
            ),
            _buildBottomSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Menu: Cancel (only before OTP) or Back (after ride started)
          PopupMenuButton<String>(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: const Icon(Icons.menu, color: Color(0xFF1A1A1A)),
            ),
            onSelected: (value) {
              if (value == 'cancel' && !_otpVerified) {
                _cancelRide();
              } else if (value == 'back' && _otpVerified) {
                context.go(AppRoutes.driverHome);
              }
            },
            itemBuilder: (context) => [
              if (!_otpVerified)
                PopupMenuItem(
                  value: 'cancel',
                  child: Row(
                    children: [
                      const Icon(Icons.cancel_outlined,
                          color: Colors.red, size: 20),
                      const SizedBox(width: 12),
                      Text(ref.tr('cancel_ride'),
                          style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              if (_otpVerified)
                PopupMenuItem(
                  value: 'back',
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_back, size: 20),
                      const SizedBox(width: 12),
                      Text(ref.tr('back_to_home')),
                    ],
                  ),
                ),
            ],
          ),

          const Spacer(),

          // Score badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE0E0E0)),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Text(
                      '90',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Earnings badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '₹ ${_todayEarnings.toStringAsFixed(2)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Search
          const Icon(Icons.search, color: Color(0xFF1A1A1A)),
        ],
      ),
    );
  }

  Widget _buildMap() {
    // Watch dark mode changes
    final isDarkMode = ref.watch(settingsProvider).isDarkMode;
    if (isDarkMode != _lastDarkMode) {
      _lastDarkMode = isDarkMode;
      _loadMapStyle();
    }

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: _driverLocation,
            zoom: 16,
            bearing: _driverHeading,
            tilt: 20,
          ),
          markers: _markers,
          polylines: _polylines,
          onMapCreated: (controller) {
            _mapController.complete(controller);
            _mapControllerInstance = controller;
            // Apply map style
            if (_mapStyle != null) {
              controller.setMapStyle(_mapStyle);
            }
          },
          onCameraMove: (_) {
            if (_ignoreCameraMoveUntil == null ||
                DateTime.now().isAfter(_ignoreCameraMoveUntil!)) {
              setState(() => _cameraFollowEnabled = false);
            }
          },
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
        ),

        // Date overlay
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'Today - $_todayDate',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
          ),
        ),

        // Loading overlay
        if (_isLoadingRoute)
          Container(
            color: Colors.black12,
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          ),
      ],
    );
  }

  Widget _buildNavigationControls() {
    final unreadCount =
        ref.watch(chatProvider(_rideId).select((s) => s.unreadCount));
    return Column(
      children: [
        // Follow vehicle button (Uber/Rapido style - recenter on driver)
        GestureDetector(
          onTap: () {
            setState(() => _cameraFollowEnabled = true);
            _animateCameraToDriver();
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color:
                  _cameraFollowEnabled ? const Color(0xFF4285F4) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Icon(
              Icons.my_location,
              color:
                  _cameraFollowEnabled ? Colors.white : const Color(0xFF4285F4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Navigate button
        GestureDetector(
          onTap: _openNavigation,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                ),
              ],
            ),
            child: const Icon(
              Icons.navigation,
              color: Colors.white,
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Message button
        GestureDetector(
          onTap: () {
            _showChatDialog(context);
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Center(
              child: unreadCount > 0
                  ? Text(
                      unreadCount > 99 ? '99+' : unreadCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : const Icon(
                      Icons.message,
                      color: Colors.white,
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showChatDialog(BuildContext context) async {
    if (_chatSheetOpen) return;
    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';
    _chatSheetOpen = true;
    try {
      await RideChatBottomSheet.show(
        context,
        rideId: _rideId,
        currentUserId: currentUserId,
        passengerId: _passengerId,
        otherUserName: _riderName,
        otherUserPhoto: null,
        isDriver: true,
      );
    } finally {
      _chatSheetOpen = false;
    }
  }

  Widget _buildStopRidingButton() {
    // Determine button state based on arrival, OTP verification, and pickup status
    final bool canConfirmPickup =
        _hasArrivedAtPickup && !_pickupConfirmed && !_isPickedUp;
    final bool showArrivedButton = !_hasArrivedAtPickup && !_isPickedUp;

    // Button configuration based on state
    Color buttonColor;
    String buttonText;
    IconData buttonIcon;
    VoidCallback? onTap;

    if (_isPickedUp) {
      // Ride in progress - show Complete Ride
      buttonColor = const Color(0xFF4CAF50);
      buttonText = 'Complete Ride';
      buttonIcon = Icons.check_circle;
      onTap = _completeRide;
    } else if (canConfirmPickup) {
      // Arrived - show Confirm Pickup, then OTP dialog
      buttonColor = const Color(0xFF4CAF50);
      buttonText = 'Confirm Pickup';
      buttonIcon = Icons.person_pin_circle;
      onTap = _confirmPickup;
    } else if (showArrivedButton) {
      // Not arrived yet - show I've Arrived
      buttonColor = const Color(0xFF2196F3);
      buttonText = "I've Arrived";
      buttonIcon = Icons.location_on;
      onTap = _markArrivedAtPickup;
    } else {
      // Arrived but OTP not verified - show Enter OTP prompt
      buttonColor = const Color(0xFFFF9800);
      buttonText = 'Enter Ride PIN';
      buttonIcon = Icons.lock_open;
      onTap = _showOtpEntryDialog;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: buttonColor,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              buttonText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              buttonIcon,
              color: Colors.white,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  String _extractErrorMessage(Object error, {required String fallback}) {
    final raw = error.toString();
    if (raw.contains('ARRIVAL_RADIUS_NOT_REACHED')) {
      return 'Move closer to pickup location (within 120m) before marking arrival.';
    }
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(raw);
    if (match != null && (match.group(1) ?? '').trim().isNotEmpty) {
      return match.group(1)!;
    }
    return fallback;
  }

  Widget _buildBottomSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.tune,
                      color: Color(0xFF1A1A1A), size: 20),
                ),
                const Spacer(),
                Row(
                  children: [
                    const Text(
                      "You're Online",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4CAF50),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                const Icon(Icons.menu, color: Color(0xFF1A1A1A)),
              ],
            ),
          ),

          // Ride info
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Rider info row
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(0xFFD4956A),
                      child: Text(
                        _riderName.isNotEmpty ? _riderName[0] : 'R',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _riderName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _isPickedUp
                                ? 'Drop at destination'
                                : 'Pick up rider',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF888888),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Call button
                    GestureDetector(
                      onTap: _callRider,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4CAF50),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Icon(Icons.call,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Distance and time info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      // Show trip distance (pickup to destination)
                      _buildInfoItem(
                          Icons.straighten,
                          _tripDistanceText.isNotEmpty
                              ? _tripDistanceText
                              : '...',
                          'Trip Distance'),
                      Container(
                          width: 1, height: 40, color: const Color(0xFFE0E0E0)),
                      // Show driver ETA to pickup when not picked up, else trip ETA
                      _buildInfoItem(
                          Icons.access_time,
                          !_isPickedUp
                              ? (_driverEtaText.isNotEmpty
                                  ? _driverEtaText
                                  : '...')
                              : (_durationText.isNotEmpty
                                  ? _durationText
                                  : '...'),
                          !_isPickedUp ? 'Arriving in' : 'ETA'),
                      Container(
                          width: 1, height: 40, color: const Color(0xFFE0E0E0)),
                      _buildInfoItem(Icons.currency_rupee,
                          _earning.toStringAsFixed(0), 'Fare'),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Address info
                Row(
                  children: [
                    Column(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _isPickedUp
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFD4956A),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 30,
                          color: const Color(0xFFE0E0E0),
                        ),
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _isPickedUp
                                ? const Color(0xFFD4956A)
                                : const Color(0xFF4CAF50),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: const Color(0xFFE0E0E0), width: 2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _pickupAddress,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _isPickedUp
                                  ? FontWeight.normal
                                  : FontWeight.w600,
                              color: _isPickedUp
                                  ? const Color(0xFF888888)
                                  : const Color(0xFF1A1A1A),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _dropAddress,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _isPickedUp
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: _isPickedUp
                                  ? const Color(0xFF1A1A1A)
                                  : const Color(0xFF888888),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 20),
                
                // Slideable action button
                _buildSlideableActionButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSlideableActionButton() {
    // Determine button state based on arrival, OTP verification, and pickup status
    final bool canConfirmPickup =
        _hasArrivedAtPickup && !_pickupConfirmed && !_isPickedUp;
    final bool showArrivedButton = !_hasArrivedAtPickup && !_isPickedUp;

    if (_isPickedUp) {
      // Ride in progress - show Complete Ride
      return SlideToActionButton(
        text: 'Slide to Complete Ride',
        icon: Icons.check_circle,
        backgroundColor: const Color(0xFF4CAF50),
        onSlideComplete: _completeRide,
      );
    } else if (canConfirmPickup) {
      // Arrived - show Confirm Pickup
      return SlideToActionButton(
        text: 'Slide to Confirm Pickup',
        icon: Icons.person_pin_circle,
        backgroundColor: const Color(0xFF4CAF50),
        onSlideComplete: _confirmPickup,
      );
    } else if (showArrivedButton) {
      // Not arrived yet - show I've Arrived
      return SlideToActionButton(
        text: "Slide when Arrived",
        icon: Icons.location_on,
        backgroundColor: const Color(0xFF2196F3),
        onSlideComplete: _markArrivedAtPickup,
      );
    } else {
      // Arrived but OTP not verified - show Enter OTP prompt
      return SlideToActionButton(
        text: 'Slide to Enter Ride PIN',
        icon: Icons.lock_open,
        backgroundColor: const Color(0xFFFF9800),
        onSlideComplete: _showOtpEntryDialog,
      );
    }
  }

  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF1A1A1A)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF888888),
          ),
        ),
      ],
    );
  }
}

// ─── Real-time Chat Bottom Sheet for Driver ─────────────────────

class _DriverChatSheet extends StatefulWidget {
  final String riderName;
  final String rideId;
  final List<Map<String, dynamic>> chatMessages;
  final ValueNotifier<int> chatUpdateNotifier;
  final Set<String> chatMessageIds;
  final TextEditingController chatController;
  final ScrollController chatScrollController;
  final void Function(String text) onSend;
  final Future<void> Function() onRefresh;

  const _DriverChatSheet({
    required this.riderName,
    required this.rideId,
    required this.chatMessages,
    required this.chatUpdateNotifier,
    required this.chatMessageIds,
    required this.chatController,
    required this.chatScrollController,
    required this.onSend,
    required this.onRefresh,
  });

  @override
  State<_DriverChatSheet> createState() => _DriverChatSheetState();
}

class _DriverChatSheetState extends State<_DriverChatSheet> {
  Timer? _pollTimer;
  int _lastMsgCount = 0;

  @override
  void initState() {
    super.initState();
    _lastMsgCount = widget.chatMessages.length;
    // Light poll every 15s as safety net (primary delivery is via WebSocket)
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      await widget.onRefresh();
      if (mounted && widget.chatMessages.length != _lastMsgCount) {
        setState(() {
          _lastMsgCount = widget.chatMessages.length;
        });
        _scrollToBottom();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (widget.chatScrollController.hasClients) {
        widget.chatScrollController.animateTo(
          widget.chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.chatUpdateNotifier,
      builder: (context, _, __) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.green[100],
                      child: Text(
                        widget.riderName.isNotEmpty
                            ? widget.riderName[0].toUpperCase()
                            : 'R',
                        style: TextStyle(
                            color: Colors.green[800],
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.riderName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          Text('Rider',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 12)),
                        ],
                      ),
                    ),
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ],
                ),
              ),

              // Messages
              Expanded(
                child: widget.chatMessages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline,
                                size: 48, color: Colors.grey[300]),
                            const SizedBox(height: 8),
                            Text('No messages yet',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 14)),
                            const SizedBox(height: 4),
                            Text('Send a message to the rider',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 12)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: widget.chatScrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: widget.chatMessages.length,
                        itemBuilder: (context, index) {
                          final msg = widget.chatMessages[index];
                          final isDriver = msg['sender'] == 'driver';
                          return Align(
                            alignment: isDriver
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.7),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: isDriver
                                    ? Colors.green[500]
                                    : Colors.grey[200],
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: isDriver
                                      ? const Radius.circular(16)
                                      : Radius.zero,
                                  bottomRight: isDriver
                                      ? Radius.zero
                                      : const Radius.circular(16),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: isDriver
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Text(msg['text'] ?? '',
                                      style: TextStyle(
                                          color: isDriver
                                              ? Colors.white
                                              : Colors.black)),
                                  const SizedBox(height: 4),
                                  Text(msg['time'] ?? '',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: isDriver
                                              ? Colors.white70
                                              : Colors.grey[600])),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // Input
              Container(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                  top: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withAlpha(12),
                        blurRadius: 10,
                        offset: const Offset(0, -5))
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.chatController,
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none),
                          filled: true,
                          fillColor: Colors.grey[100],
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                        ),
                        onSubmitted: (_) => _handleSend(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CircleAvatar(
                      backgroundColor: Colors.green[500],
                      child: IconButton(
                        onPressed: _handleSend,
                        icon: const Icon(Icons.send,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleSend() {
    final text = widget.chatController.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    widget.chatController.clear();
    setState(() {});
    _scrollToBottom();
  }
}
