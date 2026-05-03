import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/directions_service.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/sse_service.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/auto_map_icon.dart';
import '../../../../core/utils/bike_map_icon.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../chat/providers/chat_provider.dart';
import '../../../chat/presentation/screens/ride_chat_screen.dart';

// Ride phase enum
enum _RidePhase { driverEnRoute, rideInProgress, completed }

/// Result of projecting a point onto a polyline segment
class _PolylineSnapResult {
  final LatLng point;
  final double distance;
  final int segmentIndex;

  _PolylineSnapResult({
    required this.point,
    required this.distance,
    required this.segmentIndex,
  });
}

class DriverAssignedScreen extends ConsumerStatefulWidget {
  final String? initialRideId;
  final bool autoOpenChat;

  const DriverAssignedScreen({
    super.key,
    this.initialRideId,
    this.autoOpenChat = false,
  });

  @override
  ConsumerState<DriverAssignedScreen> createState() =>
      _DriverAssignedScreenState();
}

class _DriverAssignedScreenState extends ConsumerState<DriverAssignedScreen>
    with WidgetsBindingObserver {
  // Driver data
  String _driverName = 'Driver';
  String _vehicleNumber = '';
  String _vehicleModel = '';
  final double _driverRating = 4.9;
  late String _otp;
  int _eta = 2;
  DateTime? _lastSharedEtaAt;
  double _fareAmount = 0;
  String _driverPhone = '';

  // Locations from provider
  late String _pickupAddress;
  late String _dropAddress;
  late LatLng _pickupLocation;
  late LatLng _destinationLocation;
  late LatLng _driverLocation;
  String? _rideId;

  // Message state
  final TextEditingController _messageController = TextEditingController();
  final List<_ChatMessage> _messages = [];
  final Set<String> _messageIds = {}; // For deduplication
  final ScrollController _scrollController = ScrollController();
  bool _showChat = false;
  bool _chatSheetOpen = false;
  Timer? _chatPollTimer;

  // Google Maps
  final Completer<GoogleMapController> _mapController = Completer();
  final DirectionsService _directionsService = DirectionsService();
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  bool _isLoadingRoutes = true;
  bool _isCalculatingRoute = false;
  DateTime? _lastRouteRecalculationAt;
  LatLng? _lastRouteRecalculationFrom;
  Timer? _driverMarkerAnimationTimer;
  int _routeRevision = 0;
  static const Duration _driverMarkerAnimationDuration =
      Duration(milliseconds: 1000);
  static const Duration _routeRecalculationCooldown = Duration(seconds: 4);
  static const double _routeRecalculationMinDriverMoveMeters = 15.0;

  // Vehicle-specific marker icon
  BitmapDescriptor? _vehicleIcon;
  String? _vehicleType;

  // Map style for dark mode
  String? _mapStyle;
  bool _lastDarkMode = false;
  GoogleMapController? _mapControllerInstance;

  // Route points for smart deviation handling
  List<LatLng> _currentRoutePoints = [];
  static const double _snapThreshold = 30.0; // meters - snap to route if within
  static const double _deviationThreshold =
      50.0; // meters - recalculate if beyond

  // SSE + Socket.io
  SSESubscription? _sseSubscription;
  VoidCallback? _unsubscribeRide;
  VoidCallback? _unsubscribeChat;
  VoidCallback? _unsubscribeChatHistory;
  StreamSubscription<Map<String, dynamic>>? _chatOpenSubscription;
  bool _autoChatHandled = false;

  // Ride phase — drives the UI
  _RidePhase _phase = _RidePhase.driverEnRoute;

  // Rating state
  bool _isSubmittingRating = false;
  bool _completionHandled = false;
  bool _ratingSheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final bookingState = ref.read(rideBookingProvider);

    _pickupAddress = (bookingState.pickupAddress?.isNotEmpty ?? false)
        ? bookingState.pickupAddress!
        : '562/11-A, Kaikondrahalli, Bengaluru, Karnataka';
    _dropAddress = (bookingState.destinationAddress?.isNotEmpty ?? false)
        ? bookingState.destinationAddress!
        : 'Third Wave Coffee, HSR Layout, Bengaluru';
    _otp = bookingState.rideOtp ?? '----';
    _fareAmount = bookingState.fare;
    _rideId = widget.initialRideId ?? bookingState.rideId;

    // CRITICAL: Locations should ALWAYS be set from GPS/user selection before reaching this screen
    if (bookingState.pickupLocation == null) {
      debugPrint('⚠️ WARNING: pickupLocation is null in driver_assigned_screen!');
    }
    if (bookingState.destinationLocation == null) {
      debugPrint('⚠️ WARNING: destinationLocation is null in driver_assigned_screen!');
    }
    
    _pickupLocation =
        bookingState.pickupLocation ?? const LatLng(28.4595, 77.0266); // Fallback only for safety
    _destinationLocation =
        bookingState.destinationLocation ?? const LatLng(28.4949, 77.0887); // Fallback only for safety
    _driverLocation = LatLng(
      _pickupLocation.latitude + 0.003,
      _pickupLocation.longitude + 0.002,
    );

    debugPrint(
        '📍 DriverAssigned — rideId=$_rideId, pickup=$_pickupAddress, drop=$_dropAddress');
    debugPrint(
        '🔐 OTP from booking state: $_otp (raw: ${bookingState.rideOtp})');

    // Get vehicle type from booking state
    _vehicleType = bookingState.selectedCabTypeId;

    _loadVehicleIcon();
    _loadMapStyle();
    _setupMapElements();
    _calculateRoutes();
    _initializeChatProvider();
    _subscribeToNotificationChatOpens();
    _subscribeToRideUpdates();

    // Always fetch ride details from backend to get OTP and driver info
    if (_rideId != null) {
      _fetchOtpFromBackend();
    }
  }

  void _initializeChatProvider() {
    if (_rideId == null) return;
    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';
    if (currentUserId.isEmpty) return;
    ref.read(chatProvider(_rideId!).notifier).initialize(
          currentUserId: currentUserId,
          passengerId: currentUserId,
          isDriver: false,
        );
    ref.read(chatProvider(_rideId!).notifier).closeChat();
  }

  /// Fetch OTP and driver details from backend, and sync phase with current status
  Future<void> _fetchOtpFromBackend() async {
    if (_rideId == null) return;

    try {
      debugPrint('🔐 Fetching ride details from backend for ride: $_rideId');
      final response = await apiClient.getRide(_rideId!);

      debugPrint('🔐 getRide response: $response');

      // Backend returns { success: true, data: { rideOtp: "1234", driver: {...}, status, ... } }
      final rideData = response['data'] as Map<String, dynamic>? ?? response;

      // Sync phase from backend status — handles cases where driver already started/completed before we connected
      _syncPhaseFromStatus(rideData);
      final backendFare = _extractRideFare(rideData);
      if (backendFare > 0 && mounted) {
        setState(() {
          _fareAmount = backendFare;
        });
      }

      // Fetch OTP
      final fetchedOtp =
          rideData['rideOtp']?.toString() ?? rideData['otp']?.toString();

      if (fetchedOtp != null &&
          fetchedOtp.isNotEmpty &&
          fetchedOtp.length == 4) {
        debugPrint('🔐 OTP fetched from backend: $fetchedOtp');
        if (mounted) {
          setState(() {
            _otp = fetchedOtp;
          });
          // Also update the provider state
          ref.read(rideBookingProvider.notifier).setRideOtp(fetchedOtp);
        }
      } else {
        debugPrint(
            '⚠️ Backend did not return OTP for ride $_rideId (got: $fetchedOtp)');
      }

      // Fetch driver details if available
      final driverData = rideData['driver'] as Map<String, dynamic>?;
      final vehicleData = rideData['vehicle'] as Map<String, dynamic>? ??
          (driverData?['vehicle'] as Map<String, dynamic>?);
      if (driverData != null && mounted) {
        final driverName = driverData['name']?.toString() ??
            driverData['fullName']?.toString() ??
            '${driverData['firstName'] ?? ''} ${driverData['lastName'] ?? ''}'
                .trim();
        final vehicleNumber = _firstNonEmptyString([
          driverData['vehicleNumber'],
          driverData['vehicle_number'],
          vehicleData?['plateNumber'],
          vehicleData?['vehicleNumber'],
          vehicleData?['vehicle_number'],
          vehicleData?['registrationNumber'],
          vehicleData?['registration_number'],
        ]);
        final vehicleModel = _firstNonEmptyString([
          driverData['vehicleModel'],
          driverData['vehicle_model'],
          vehicleData?['model'],
          vehicleData?['vehicleModel'],
          vehicleData?['vehicle_model'],
          vehicleData?['name'],
        ]);
        final driverPhone = _normalizePhone(
          driverData['phone']?.toString() ??
              driverData['phoneNumber']?.toString() ??
              (driverData['user'] is Map<String, dynamic>
                  ? (driverData['user']['phone']?.toString() ??
                      driverData['user']['phoneNumber']?.toString())
                  : null),
        );

        debugPrint('🚗 Driver info: $driverName, $driverPhone');

        if (driverName.isNotEmpty) {
          setState(() {
            _driverName = driverName;
            if (driverPhone.isNotEmpty) {
              _driverPhone = driverPhone;
            }
            if (vehicleNumber.isNotEmpty) {
              _vehicleNumber = vehicleNumber;
            }
            if (vehicleModel.isNotEmpty) {
              _vehicleModel = vehicleModel;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to fetch ride details from backend: $e');
    } finally {
      _maybeAutoOpenChat();
    }
  }

  double _extractRideFare(Map<String, dynamic> rideData) {
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

  void _maybeAutoOpenChat() {
    if (!widget.autoOpenChat || _autoChatHandled || _rideId == null || !mounted)
      return;
    _autoChatHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openChatBottomSheet();
      }
    });
  }

  /// Sync _phase from backend status (handles missed real-time events)
  void _syncPhaseFromStatus(Map<String, dynamic> rideData) {
    if (!mounted) return;
    final status = (rideData['status']?.toString() ??
            rideData['rideStatus']?.toString() ??
            '')
        .toLowerCase();
    if (status.isEmpty) return;
    final startedStatuses = ['in_progress', 'started', 'ride_started'];
    final completedStatuses = ['completed', 'ride_completed'];
    if (startedStatuses.any((s) => status.contains(s)) &&
        _phase == _RidePhase.driverEnRoute) {
      debugPrint(
          '📡 Syncing phase to rideInProgress from backend status: $status');
      _transitionToInProgress();
    } else if (completedStatuses.any((s) => status.contains(s)) &&
        _phase != _RidePhase.completed) {
      debugPrint('📡 Syncing phase to completed from backend status: $status');
      _transitionToCompleted();
    } else if (status == 'cancelled' || status == 'canceled') {
      _handleRideCancelled(
          {'reason': rideData['cancelReason'] ?? 'Ride was cancelled'});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    _driverMarkerAnimationTimer?.cancel();
    _chatPollTimer?.cancel();
    _pollTimer?.cancel();
    _sseSubscription?.cancel();
    _unsubscribeRide?.call();
    _unsubscribeChat?.call();
    _unsubscribeChatHistory?.call();
    _chatOpenSubscription?.cancel();
    if (_rideId != null) {
      webSocketService.leaveRideTracking(_rideId!);
      realtimeService.disconnectRide(_rideId!);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Refresh status to handle missed completion while app was backgrounded.
      unawaited(_fetchOtpFromBackend());
    }
  }

  void _subscribeToNotificationChatOpens() {
    _chatOpenSubscription =
        pushNotificationService.chatOpenStream.listen((payload) {
      final targetRideId = payload['rideId']?.toString() ?? '';
      if (_rideId == null || targetRideId.isEmpty || targetRideId != _rideId)
        return;
      if (!mounted) return;
      _openChatBottomSheet();
    });
  }

  // ─── SSE + Socket.io subscription ──────────────────────────

  Future<void> _subscribeToRideUpdates() async {
    if (_rideId == null || _rideId!.isEmpty) return;

    // Get auth token for SSE connection
    String? authToken;
    try {
      final secureStorage = ref.read(secureStorageProvider);
      authToken = await secureStorage.read(key: 'auth_token');
      debugPrint(
          '📡 Rider: Got auth token for SSE: ${authToken != null ? 'yes' : 'no'}');
    } catch (e) {
      debugPrint('⚠️ Rider: Failed to get auth token: $e');
    }

    // Primary: SSE ride stream
    _sseSubscription = realtimeService.connectRide(
      _rideId!,
      token: authToken,
      onEvent: (type, data) {
        debugPrint('📡 Ride SSE event: $type, data: $data');
        if (type == 'status_update') {
          _handleStatusUpdate(data);
        } else if (type == 'location_update') {
          _handleLocationUpdate(data);
        } else if (type == 'message') {
          _handleChatMessage(data);
        } else if (type == 'chat_history') {
          // Chat history is owned by chatProvider
        } else if (type == 'cancelled') {
          _handleRideCancelled(data);
        } else if (type == 'driver_assigned') {
          _handleStatusUpdate({'status': 'accepted', ...data});
        } else if (type == 'ride_started') {
          // Handle ride_started event directly
          _handleStatusUpdate({'status': 'ride_started', ...data});
        } else if (type == 'ride_completed') {
          _handleStatusUpdate({'status': 'ride_completed', ...data});
        }
      },
    );

    // Join the Socket.io ride room so we actually receive ride-specific events
    final rideId = _rideId!;
    webSocketService.joinRideTracking(rideId);

    // Chat subscription is centralized in chatProvider.
    // This screen only handles ride status/location updates.

    // REAL-TIME FIRST: Poll as fallback. Run first poll immediately to catch any missed SSE.
    _startPolling();
    Future.microtask(() => _pollRideStatus()); // Immediate sync on load
  }

  Future<void> _pollRideStatus() async {
    if (_rideId == null || !mounted) return;
    if (_phase == _RidePhase.completed) return;
    try {
      final response = await apiClient.getRide(_rideId!);
      if (!mounted) return;
      final data = response['data'] as Map<String, dynamic>? ?? response;
      final status = (data['status'] ?? '').toString().toLowerCase();
      if ((status == 'in_progress' || status.contains('ride_started')) &&
          _phase == _RidePhase.driverEnRoute) {
        ref
            .read(activeRideProvider.notifier)
            .updateActiveRideStatus(RideStatus.inProgress);
        _transitionToInProgress();
      } else if ((status == 'completed' || status.contains('ride_completed')) &&
          _phase != _RidePhase.completed) {
        _transitionToCompleted();
      } else if (status == 'cancelled' || status == 'canceled') {
        _handleRideCancelled(
            {'reason': data['cancelReason'] ?? 'Ride was cancelled'});
      }
    } catch (_) {}
  }

  Timer? _pollTimer;
  void _startPolling() {
    _pollTimer?.cancel();
    if (_rideId == null) return;
    // Fallback poll every 5 seconds - real-time handles most updates
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) {
        _pollTimer?.cancel();
        return;
      }
      if (_phase == _RidePhase.completed) {
        _pollTimer?.cancel();
        return;
      }
      await _pollRideStatus();
    });
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    if (!mounted) return;
    // Status can be at top-level or in payload (depending on backend event format)
    final status = ((data['status'] ?? data['payload']?['status']) as String?)
            ?.toLowerCase() ??
        '';
    debugPrint(
        '📡 Rider: Status update received: $status (current phase: $_phase)');

    // Update driver info if available
    if (data['driver'] != null && data['driver'] is Map<String, dynamic>) {
      final d = data['driver'] as Map<String, dynamic>;
      final statusVehicle = data['vehicle'] is Map<String, dynamic>
          ? data['vehicle'] as Map<String, dynamic>
          : (d['vehicle'] is Map<String, dynamic>
              ? d['vehicle'] as Map<String, dynamic>
              : null);
      final statusVehicleNumber = _firstNonEmptyString([
        d['vehicleNumber'],
        d['vehicle_number'],
        statusVehicle?['plateNumber'],
        statusVehicle?['vehicleNumber'],
        statusVehicle?['vehicle_number'],
        statusVehicle?['registrationNumber'],
      ]);
      final statusVehicleModel = _firstNonEmptyString([
        d['vehicleModel'],
        d['vehicle_model'],
        statusVehicle?['model'],
        statusVehicle?['vehicleModel'],
        statusVehicle?['name'],
      ]);
      setState(() {
        _driverName = d['name'] as String? ?? _driverName;
        if (statusVehicleNumber.isNotEmpty) {
          _vehicleNumber = statusVehicleNumber;
        }
        if (statusVehicleModel.isNotEmpty) {
          _vehicleModel = statusVehicleModel;
        }
      });
    }

    // Handle ride started - backend sends RIDE_STARTED, in_progress, or started
    final startedStatuses = [
      'in_progress',
      'started',
      'ride_started',
      'RIDE_STARTED',
      'IN_PROGRESS'
    ];
    if (startedStatuses.contains(status) &&
        _phase == _RidePhase.driverEnRoute) {
      debugPrint('📡 Rider: Transitioning to rideInProgress');
      // Sync activeRideProvider so the banner hides OTP
      ref
          .read(activeRideProvider.notifier)
          .updateActiveRideStatus(RideStatus.inProgress);
      _transitionToInProgress();
    } else if ((status == 'completed' || status.contains('ride_completed')) &&
        _phase != _RidePhase.completed) {
      debugPrint('📡 Rider: Transitioning to completed');
      _transitionToCompleted();
    } else if (status == 'cancelled' || status == 'canceled') {
      // Handle ride cancelled via status update
      _handleRideCancelled({'reason': data['reason'] ?? 'Ride was cancelled'});
    } else if (status == 'accepted' ||
        status == 'arriving' ||
        status == 'driver_arriving' ||
        status == 'driver_assigned' ||
        status == 'confirmed' ||
        status == 'driver_arrived') {
      // Driver is still coming or just arrived — keep current phase
      debugPrint('📡 Rider: Driver en route status: $status');
    }
  }

  void _handleLocationUpdate(Map<String, dynamic> data) {
    final loc = data['driverLocation'] as Map<String, dynamic>?;
    if (loc != null && mounted) {
      final newDriverLocation = LatLng(
        (loc['latitude'] as num).toDouble(),
        (loc['longitude'] as num).toDouble(),
      );

      _animateDriverMarkerTo(newDriverLocation);
      _followDriverOnMap(newDriverLocation);

      // Use shared ETA from driver if provided (ensures consistency)
      final driverEta = _extractSharedEtaMinutes(data);
      if (driverEta != null && driverEta > 0) {
        if (_eta != driverEta && mounted) {
          setState(() {
            _eta = driverEta;
            _lastSharedEtaAt = DateTime.now();
          });
          debugPrint('📍 [ETA] Using driver ETA: ${driverEta}min');
        } else {
          _lastSharedEtaAt = DateTime.now();
        }
      } else {
        // Fallback only when shared ETA is unavailable/stale
        if (_shouldUseLocalEtaFallback()) {
          _updateRealtimeEtaEstimate(newDriverLocation);
        }
      }

      _recalculateRouteIfNeeded(newDriverLocation);
    }
  }

  int? _extractSharedEtaMinutes(Map<String, dynamic> data) {
    final direct = _parseEtaValue(data['etaMinutes'] ?? data['eta_minutes']);
    if (direct != null) return direct;
    final payload = data['payload'];
    if (payload is Map) {
      final fromPayload =
          _parseEtaValue(payload['etaMinutes'] ?? payload['eta_minutes']);
      if (fromPayload != null) return fromPayload;
    }
    return null;
  }

  int? _parseEtaValue(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.ceil();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool _shouldUseLocalEtaFallback() {
    if (_lastSharedEtaAt == null) return true;
    return DateTime.now().difference(_lastSharedEtaAt!) >
        const Duration(seconds: 12);
  }

  void _handleChatMessage(Map<String, dynamic> data) {
    if (_rideId == null) return;
    try {
      ref.read(chatProvider(_rideId!).notifier).handleExternalChatMessage(data);
    } catch (_) {}
  }

  void _handleRideCancelled(Map<String, dynamic> data) {
    if (!mounted) return;

    // CRITICAL: Clear ride state immediately when cancelled
    ref.read(activeRideProvider.notifier).clearActiveRide();

    final reason = (data['reason'] as String? ?? '').toLowerCase();
    // Driver cancel: reason contains "driver", or we're pre-OTP and it's not rider-initiated
    final isDriverCancel = reason.contains('driver') ||
        reason.contains('by driver') ||
        (_phase == _RidePhase.driverEnRoute && !reason.contains('rider'));

    if (isDriverCancel && _phase == _RidePhase.driverEnRoute) {
      // Driver cancelled before OTP — Uber/Rapido style: keep booking, search again automatically
      ref.read(rideBookingProvider.notifier).clearRideOnly();
      _createRideAndSearchAgain();
    } else {
      // Rider cancelled or ride cancelled after OTP — clear all, go home
      ref.read(rideBookingProvider.notifier).reset();
      _showGenericCancelledDialog(
          data['reason'] as String? ?? 'Your ride has been cancelled.');
    }
  }

  void _showGenericCancelledDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('ride_cancelled')),
        content: Text(message),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (mounted) context.go(AppRoutes.home);
            },
            child: Text(ref.tr('ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _createRideAndSearchAgain() async {
    final booking = ref.read(rideBookingProvider);
    final pickup = booking.pickupLocation;
    final drop = booking.destinationLocation;
    final pickupAddr = booking.pickupAddress ?? 'Unknown pickup';
    final dropAddr = booking.destinationAddress ?? 'Unknown destination';

    if (pickup == null || drop == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(ref.tr('unable_find_driver')),
              backgroundColor: Colors.orange),
        );
        context.go(AppRoutes.home);
      }
      return;
    }

    try {
      final waypoints = booking.stops.isNotEmpty
          ? booking.stops
              .map((s) => {
                    'lat': s.location.latitude,
                    'lng': s.location.longitude,
                    'address': s.address,
                  })
              .toList()
          : null;
      final response = await apiClient.createRide(
        pickupLat: pickup.latitude,
        pickupLng: pickup.longitude,
        dropLat: drop.latitude,
        dropLng: drop.longitude,
        pickupAddress: pickupAddr,
        dropAddress: dropAddr,
        paymentMethod: 'CASH',
        waypoints: waypoints,
        vehicleType: booking.selectedCabTypeId,
      );

      if (!mounted) return;
      if (response['success'] == true) {
        final rideData = response['data'] as Map<String, dynamic>?;
        final rideId = rideData?['id']?.toString();
        final rideOtp =
            rideData?['rideOtp']?.toString() ?? rideData?['otp']?.toString();
        if (rideId != null && rideId.isNotEmpty) {
          ref
              .read(rideBookingProvider.notifier)
              .setRideDetails(rideId: rideId, otp: rideOtp);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.tr('finding_another_driver')),
              backgroundColor: Color(0xFFD4956A),
              behavior: SnackBarBehavior.floating,
            ),
          );
          context.pushReplacement(AppRoutes.searchingDrivers);
        } else {
          _navigateHomeOnError('Invalid ride data');
        }
      } else {
        _navigateHomeOnError(response['error']?.toString() ??
            response['message']?.toString() ??
            'Failed to create ride');
      }
    } catch (e) {
      if (mounted) _navigateHomeOnError('Unable to connect. Please try again.');
    }
  }

  void _navigateHomeOnError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.orange),
    );
    context.go(AppRoutes.home);
  }

  // ─── Phase transitions ───────────────────────────────────────

  void _transitionToInProgress() {
    if (!mounted) return;
    setState(() {
      _phase = _RidePhase.rideInProgress;
      // Rebuild markers immediately so pickup/passenger pin is removed at ride start.
      _setupMapElements();
    });
    // Recalculate route from live driver position -> destination.
    _calculateRoutes();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ref.tr('ride_started_heading')),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _transitionToCompleted() {
    if (!mounted) return;
    if (_completionHandled) return;
    _completionHandled = true;
    _pollTimer?.cancel();
    // Hide persistent "active ride" banner immediately on completion.
    ref.read(activeRideProvider.notifier).clearActiveRide();
    ref.read(rideBookingProvider.notifier).clearRideOnly();
    setState(() => _phase = _RidePhase.completed);
    // Show rating after a brief delay
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _showRatingSheet();
    });
  }

  // ─── Map & route calculation ─────────────────────────────────

  Future<void> _loadVehicleIcon() async {
    final normalizedType = _normalizeVehicleType(_vehicleType);
    try {
      // Use existing PNG assets from assets/map_icons/
      String assetPath;
      switch (normalizedType) {
        case 'bike':
          assetPath = 'assets/map_icons/icon_bike.png';
          break;
        case 'bike-rescue':
          assetPath = 'assets/map_icons/icon_bike_rescue.png';
          break;
        case 'auto':
          assetPath = 'assets/map_icons/icon_auto.png';
          break;
        case 'cab-premium':
        case 'cab-xl':
        case 'cab':
        case 'cab-mini':
        default:
          assetPath = 'assets/map_icons/icon_cab.png';
          break;
      }

      const imageConfig =
          ImageConfiguration(size: Size(44, 44), devicePixelRatio: 2.5);
      // Bike: flood-remove black plate connected to edges.
      if (normalizedType == 'bike' || normalizedType == 'bike-rescue') {
        _vehicleIcon = await loadBikeMapIconProcessed(assetPath,
                debugLabel: normalizedType) ??
            await BitmapDescriptor.asset(imageConfig, assetPath);
      } else if (normalizedType == 'auto') {
        _vehicleIcon = await loadAutoMapIconProcessed(debugLabel: 'auto') ??
            await BitmapDescriptor.asset(imageConfig, assetPath);
      } else {
        _vehicleIcon = await BitmapDescriptor.asset(imageConfig, assetPath);
      }
      debugPrint('🚗 Vehicle icon loaded from asset: $assetPath');
      if (mounted) _updateDriverMarker();
    } catch (e) {
      debugPrint('Failed to load vehicle icon asset: $e');
      _vehicleIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }
  }

  String _normalizeVehicleType(String? type) {
    if (type == null || type.isEmpty) return 'cab';
    final lower = type.toLowerCase().trim();
    if (lower.contains('rescue') || lower == 'bike_rescue')
      return 'bike-rescue';
    if (lower.contains('bike') || lower.contains('moto')) return 'bike';
    if (lower.contains('auto') || lower.contains('rickshaw')) return 'auto';
    if (lower.contains('premium') || lower.contains('suv'))
      return 'cab-premium';
    if (lower.contains('xl')) return 'cab-xl';
    if (lower.contains('mini') || lower.contains('hatch')) return 'cab-mini';
    return 'cab';
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
          '🗺️ Driver assigned map style loaded: ${isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  void _updateDriverMarker() {
    if (!mounted) return;
    setState(() {
      _markers = _markers.map((m) {
        if (m.markerId.value == 'driver') {
          return m.copyWith(
            iconParam: _vehicleIcon ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueOrange),
          );
        }
        return m;
      }).toSet();
    });
  }

  void _setupMapElements() {
    final nextMarkers = <Marker>{
      Marker(
        markerId: const MarkerId('driver'),
        position: _driverLocation,
        icon: _vehicleIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        anchor: const Offset(0.5, 0.5),
        flat: true,
        infoWindow: InfoWindow(title: _driverName, snippet: _vehicleNumber),
      ),
    };

    // Before OTP/ride-start: show pickup passenger pin.
    if (_phase == _RidePhase.driverEnRoute) {
      nextMarkers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLocation,
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          infoWindow: const InfoWindow(title: 'Pickup'),
        ),
      );
    }

    // Do not add pickup marker in rideInProgress/completed.
    // This mirrors real ride behavior where passenger is already in the vehicle.
    _markers = nextMarkers;
  }

  Future<void> _calculateRoutes() async {
    if (_isCalculatingRoute) return;

    final origin = _driverLocation;
    final destination = _phase == _RidePhase.rideInProgress
        ? _destinationLocation
        : _pickupLocation;
    final isDriverArriving = _phase == _RidePhase.driverEnRoute;
    final routeRevision = ++_routeRevision;
    final routeType = isDriverArriving ? 'PICKUP' : 'DROPOFF';

    debugPrint(
      '🗺️ [Route] Calculating route '
      'rideId=$_rideId '
      'phase=$_phase '
      'type=$routeType '
      'driver=(${origin.latitude.toStringAsFixed(5)}, ${origin.longitude.toStringAsFixed(5)}) '
      'target=(${destination.latitude.toStringAsFixed(5)}, ${destination.longitude.toStringAsFixed(5)})',
    );

    _isCalculatingRoute = true;
    try {
      final route = await _directionsService.getRoute(
        origin: origin,
        destination: destination,
        mode: TravelMode.driving,
      );

      if (!mounted) return;
      setState(() {
        if (routeRevision != _routeRevision) return;
        _eta = (route.duration / 60).ceil();
        _currentRoutePoints =
            List.from(route.points); // Store for deviation check

        // Premium Uber-style polyline rendering with multiple layers
        final Color mainColor;
        final Color borderColor;
        final Color glowColor;

        if (isDriverArriving) {
          mainColor = const Color(0xFF34A853); // Google green
          borderColor = const Color(0xFF1E7E34);
          glowColor = const Color(0xFF34A853).withOpacity(0.20);
        } else {
          mainColor = const Color(0xFF4285F4); // Google blue
          borderColor = const Color(0xFF1A56DB);
          glowColor = const Color(0xFF4285F4).withOpacity(0.20);
        }

        // Uber/Rapido-style: thin, clean polylines
        _polylines = {
          // Layer 1: Border
          Polyline(
            polylineId: const PolylineId('route_border'),
            points: route.points,
            color: borderColor,
            width: 6,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            patterns: isDriverArriving
                ? [PatternItem.dash(12), PatternItem.gap(8)]
                : const <PatternItem>[],
          ),
          // Layer 2: Main route
          Polyline(
            polylineId: const PolylineId('route_main'),
            points: route.points,
            color: mainColor,
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
            patterns: isDriverArriving
                ? [PatternItem.dash(12), PatternItem.gap(8)]
                : const <PatternItem>[],
          ),
        };
        _isLoadingRoutes = false;
      });
      _lastRouteRecalculationAt = DateTime.now();
      _lastRouteRecalculationFrom = _driverLocation;

      debugPrint(
        '🗺️ [Route] Route calculated SUCCESS '
        'type=$routeType '
        'points=${route.points.length} '
        'distance=${(route.distance / 1000).toStringAsFixed(2)}km '
        'eta=${_eta}min',
      );
    } catch (e) {
      debugPrint('🗺️ [Route] Route calculation ERROR: $e');
      if (!mounted) return;
      setState(() {
        // Fallback to straight line - thin style
        _polylines = {
          Polyline(
            polylineId: const PolylineId('route_fallback'),
            points: [origin, destination],
            color: isDriverArriving
                ? const Color(0xFF34A853)
                : const Color(0xFF4285F4),
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            patterns: isDriverArriving
                ? [PatternItem.dash(12), PatternItem.gap(8)]
                : const <PatternItem>[],
          ),
        };
        _isLoadingRoutes = false;
      });
    } finally {
      _isCalculatingRoute = false;
    }
  }

  Future<void> _fitMapToBounds() async {
    if (!_mapController.isCompleted) return;
    final controller = await _mapController.future;
    final points = <LatLng>[
      _driverLocation,
      _phase == _RidePhase.rideInProgress
          ? _destinationLocation
          : _pickupLocation,
    ];
    final sw = LatLng(
      points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
      points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
    );
    final ne = LatLng(
      points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
      points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
    );
    controller.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: sw, northeast: ne), 80));
  }

  void _animateDriverMarkerTo(LatLng target) {
    final start = _driverLocation;
    _driverMarkerAnimationTimer?.cancel();

    // Calculate distance for variable animation duration
    final distance = _distanceMeters(start, target);
    int durationMs;
    if (distance < 5) {
      durationMs = 400;
    } else if (distance < 15) {
      durationMs = (400 + (distance - 5) * 40).round();
    } else if (distance < 50) {
      durationMs = (800 + (distance - 15) * 45).round();
    } else {
      durationMs = math.min(2500, (1600 + (distance - 50) * 20).round());
    }

    const steps = 20; // More steps for smoother animation
    final stepMs = (durationMs / steps).round();
    int currentStep = 0;

    // Calculate bearing for marker rotation
    final bearing = _calculateBearing(start, target);

    _driverMarkerAnimationTimer =
        Timer.periodic(Duration(milliseconds: stepMs), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      currentStep++;
      // Apply cubic ease-in-out for natural movement
      final rawT = currentStep / steps;
      final t = rawT < 0.5
          ? 4 * rawT * rawT * rawT
          : 1 - math.pow(-2 * rawT + 2, 3) / 2;

      final lat = start.latitude + (target.latitude - start.latitude) * t;
      final lng = start.longitude + (target.longitude - start.longitude) * t;
      final interpolated = LatLng(lat, lng);

      setState(() {
        _driverLocation = interpolated;
        _markers = _markers.map((m) {
          if (m.markerId.value == 'driver') {
            return m.copyWith(
              positionParam: interpolated,
              rotationParam: bearing,
              flatParam: true,
              iconParam: _vehicleIcon ??
                  BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueOrange),
            );
          }
          return m;
        }).toSet();
      });
      if (_shouldUseLocalEtaFallback()) {
        _updateRealtimeEtaEstimate(interpolated);
      }

      if (currentStep >= steps) {
        timer.cancel();
      }
    });

    debugPrint(
      '🚕 [Marker] Animating driver '
      'rideId=$_rideId '
      'distance=${distance.toStringAsFixed(1)}m '
      'duration=${durationMs}ms '
      'bearing=${bearing.toStringAsFixed(0)}°',
    );
  }

  double _calculateBearing(LatLng start, LatLng end) {
    final lat1 = start.latitude * math.pi / 180;
    final lat2 = end.latitude * math.pi / 180;
    final dLng = (end.longitude - start.longitude) * math.pi / 180;

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    double bearing = math.atan2(y, x) * 180 / math.pi;
    return (bearing + 360) % 360;
  }

  void _followDriverOnMap(LatLng driverLocation) async {
    if (!_mapController.isCompleted) return;
    final controller = await _mapController.future;

    // Calculate distance to target for dynamic zoom
    final target = _phase == _RidePhase.rideInProgress
        ? _destinationLocation
        : _pickupLocation;
    final distance = _distanceMeters(driverLocation, target);

    // Dynamic zoom based on distance
    double zoom;
    if (distance < 100) {
      zoom = 17.5;
    } else if (distance < 300) {
      zoom = 17.0;
    } else if (distance < 500) {
      zoom = 16.5;
    } else if (distance < 1000) {
      zoom = 16.0;
    } else if (distance < 2000) {
      zoom = 15.5;
    } else {
      zoom = 15.0;
    }

    // Dynamic tilt based on phase
    final tilt = _phase == _RidePhase.rideInProgress ? 50.0 : 35.0;

    // Calculate bearing to target for navigation feel
    final bearing = _calculateBearing(driverLocation, target);

    // Project camera ahead of driver in driving direction
    final metersAhead = _phase == _RidePhase.rideInProgress ? 50.0 : 35.0;
    final leadTarget = _projectPointAhead(driverLocation, bearing, metersAhead);

    controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: leadTarget,
          zoom: zoom,
          tilt: tilt,
          bearing: bearing,
        ),
      ),
    );

    debugPrint(
      '📷 [Camera] Following driver '
      'phase=$_phase '
      'zoom=${zoom.toStringAsFixed(1)} '
      'tilt=${tilt.toStringAsFixed(0)}° '
      'bearing=${bearing.toStringAsFixed(0)}°',
    );
  }

  LatLng _projectPointAhead(
      LatLng from, double bearingDeg, double metersAhead) {
    const earthRadius = 6378137.0;
    final bearing = bearingDeg * math.pi / 180;
    final lat1 = from.latitude * math.pi / 180;
    final lon1 = from.longitude * math.pi / 180;
    final angularDistance = metersAhead / earthRadius;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) * math.sin(angularDistance) * math.cos(bearing),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(bearing) * math.sin(angularDistance) * math.cos(lat1),
          math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
        );

    return LatLng(lat2 * 180 / math.pi, lon2 * 180 / math.pi);
  }

  void _recalculateRouteIfNeeded(LatLng latestDriverLocation) {
    if (_currentRoutePoints.isEmpty || _currentRoutePoints.length < 2) {
      // No route to check against - calculate fresh route
      _calculateRoutes();
      return;
    }

    // Find nearest point on the route polyline (segment projection)
    final snapResult =
        _findNearestPointOnPolyline(latestDriverLocation, _currentRoutePoints);
    final distanceFromRoute = snapResult.distance;

    debugPrint(
      '📍 [Deviation] '
      'rideId=$_rideId '
      'phase=$_phase '
      'driverLat=${latestDriverLocation.latitude.toStringAsFixed(5)} '
      'driverLng=${latestDriverLocation.longitude.toStringAsFixed(5)} '
      'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
      'segmentIndex=${snapResult.segmentIndex}',
    );

    if (distanceFromRoute <= _snapThreshold) {
      // Driver is close to route - apply snapping for visual alignment
      _applyRouteSnapping(snapResult.point, snapResult.segmentIndex);
      debugPrint(
        '✅ [Snap] Snapped to route '
        'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
        'snappedToRoute=true',
      );
      return;
    }

    if (distanceFromRoute > _deviationThreshold) {
      // Driver significantly deviated - check cooldown before recalculating
      final now = DateTime.now();
      final lastAt = _lastRouteRecalculationAt;
      final cooledDown = lastAt == null ||
          now.difference(lastAt) >= _routeRecalculationCooldown;

      if (cooledDown) {
        debugPrint(
          '🔄 [Deviation] Route recalculation triggered '
          'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
          'routeRecalculated=true',
        );
        _calculateRoutes();
      } else {
        final cooldownRemaining = _routeRecalculationCooldown.inSeconds -
            now.difference(lastAt!).inSeconds;
        debugPrint(
          '⏳ [Deviation] Recalculation skipped (cooldown) '
          'cooldownRemaining=${cooldownRemaining}s',
        );
      }
    }
  }

  /// Result of projecting a point onto a polyline segment
  _PolylineSnapResult _findNearestPointOnPolyline(
      LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) {
      return _PolylineSnapResult(
          point: point, distance: double.infinity, segmentIndex: -1);
    }
    if (polyline.length == 1) {
      return _PolylineSnapResult(
        point: polyline[0],
        distance: _distanceMeters(point, polyline[0]),
        segmentIndex: 0,
      );
    }

    double minDistance = double.infinity;
    LatLng nearestPoint = polyline[0];
    int nearestSegmentIndex = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final projected =
          _projectPointOntoSegment(point, polyline[i], polyline[i + 1]);
      final distance = _distanceMeters(point, projected);

      if (distance < minDistance) {
        minDistance = distance;
        nearestPoint = projected;
        nearestSegmentIndex = i;
      }
    }

    return _PolylineSnapResult(
      point: nearestPoint,
      distance: minDistance,
      segmentIndex: nearestSegmentIndex,
    );
  }

  /// Project a point onto a line segment
  LatLng _projectPointOntoSegment(
      LatLng point, LatLng segmentStart, LatLng segmentEnd) {
    final px = point.longitude;
    final py = point.latitude;
    final ax = segmentStart.longitude;
    final ay = segmentStart.latitude;
    final bx = segmentEnd.longitude;
    final by = segmentEnd.latitude;

    final dx = bx - ax;
    final dy = by - ay;

    if (dx == 0 && dy == 0) return segmentStart;

    final t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    final clampedT = t.clamp(0.0, 1.0);

    return LatLng(ay + clampedT * dy, ax + clampedT * dx);
  }

  /// Apply route snapping - trim route and optionally update marker
  void _applyRouteSnapping(LatLng snappedPosition, int segmentIndex) {
    if (segmentIndex > 0 && segmentIndex < _currentRoutePoints.length) {
      // Trim route to start from snapped position
      final newRoutePoints = <LatLng>[snappedPosition];
      if (segmentIndex + 1 < _currentRoutePoints.length) {
        newRoutePoints.addAll(_currentRoutePoints.sublist(segmentIndex + 1));
      }

      if (newRoutePoints.length != _currentRoutePoints.length) {
        setState(() {
          _currentRoutePoints = newRoutePoints;
          // Update polylines with trimmed route
          _updatePolylinesWithPoints(newRoutePoints);
        });
      }
    }
  }

  /// Update polylines with new route points (preserves styling)
  void _updatePolylinesWithPoints(List<LatLng> points) {
    final isDriverArriving = _phase == _RidePhase.driverEnRoute;

    final Color mainColor;
    final Color borderColor;
    final Color glowColor;

    if (isDriverArriving) {
      mainColor = const Color(0xFF34A853);
      borderColor = const Color(0xFF1E7E34);
      glowColor = const Color(0xFF34A853).withOpacity(0.20);
    } else {
      mainColor = const Color(0xFF4285F4);
      borderColor = const Color(0xFF1A56DB);
      glowColor = const Color(0xFF4285F4).withOpacity(0.20);
    }

    // Uber/Rapido-style: thin, clean polylines
    _polylines = {
      Polyline(
        polylineId: const PolylineId('route_border'),
        points: points,
        color: borderColor,
        width: 6,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        patterns: isDriverArriving
            ? [PatternItem.dash(12), PatternItem.gap(8)]
            : const <PatternItem>[],
      ),
      Polyline(
        polylineId: const PolylineId('route_main'),
        points: points,
        color: mainColor,
        width: 4,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        patterns: isDriverArriving
            ? [PatternItem.dash(12), PatternItem.gap(8)]
            : const <PatternItem>[],
      ),
    };
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h =
        sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLng * sinLng;
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadius * c;
  }

  void _updateRealtimeEtaEstimate(LatLng driverPosition) {
    if (!_shouldUseLocalEtaFallback()) return;
    final target = _phase == _RidePhase.rideInProgress
        ? _destinationLocation
        : _pickupLocation;
    final distanceMeters = _distanceMeters(driverPosition, target);

    // Lightweight realtime ETA estimate between route refreshes.
    final avgKmph = _phase == _RidePhase.rideInProgress ? 24.0 : 20.0;
    final nextEta =
        ((distanceMeters / 1000) / avgKmph * 60).ceil().clamp(1, 180);

    if (nextEta != _eta && mounted) {
      setState(() {
        _eta = nextEta;
      });
    }
  }

  // ─── Rating ──────────────────────────────────────────────────

  void _showRatingSheet() {
    if (_ratingSheetOpen) return;
    _ratingSheetOpen = true;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RatingSheet(
        fare: _fareAmount,
        driverName: _driverName,
        onSubmit: (rating, feedback) async {
          Navigator.pop(ctx);
          await _submitRating(rating, feedback);
          _clearRideStateAndNavigate();
        },
        onSkip: () {
          Navigator.pop(ctx);
          _clearRideStateAndNavigate();
        },
      ),
    ).whenComplete(() {
      _ratingSheetOpen = false;
    });
  }

  /// Clear all ride-related state and navigate to the services / vehicle selection screen.
  void _clearRideStateAndNavigate() {
    ref.read(activeRideProvider.notifier).clearActiveRide();
    ref.read(rideBookingProvider.notifier).reset();
    if (mounted) context.go(AppRoutes.home);
  }

  Future<void> _submitRating(double rating, String? feedback) async {
    if (_rideId == null || _isSubmittingRating) return;
    _isSubmittingRating = true;
    try {
      await apiClient.submitRideRating(_rideId!, rating, feedback: feedback);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(ref.tr('thanks_feedback')),
              backgroundColor: AppColors.success,
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      debugPrint('Rating error: $e');
    }
    _isSubmittingRating = false;
  }

  // ─── Helpers ─────────────────────────────────────────────────

  Future<void> _callDriver() async {
    final phone = _normalizePhone(_driverPhone);
    if (phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('driver_phone_unavailable'))),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  String _normalizePhone(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    var p = raw.trim().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (p.startsWith('+')) return p;
    if (p.startsWith('91') && p.length == 12) return '+$p';
    if (p.length == 10) return '+91$p';
    return p;
  }

  String _firstNonEmptyString(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String get _vehicleSummaryLine {
    final number = _vehicleNumber.trim();
    final model = _vehicleModel.trim();
    if (model.isNotEmpty && number.isNotEmpty) return '$model • $number';
    if (model.isNotEmpty) return model;
    if (number.isNotEmpty) return number;
    return 'Vehicle details unavailable';
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    // Show in UI immediately (optimistic)
    setState(() {
      _messageController.clear();
      _messages.add(_ChatMessage(
        text: text,
        isFromDriver: false,
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom();

    if (_rideId != null) {
      webSocketService.sendRideMessage(_rideId!, text, sender: 'rider');
      apiClient.sendChatMessage(_rideId!, text);
    }
  }

  void _handleIncomingMessage(Map<String, dynamic> data) {
    final msgId = data['id'] as String? ?? '';
    final msgText = data['message'] as String? ?? data['text'] as String? ?? '';
    final sender = data['sender'] as String? ?? '';
    if (msgText.isEmpty) return;

    if (sender == 'rider' || sender == 'passenger') return;

    if (msgId.isNotEmpty && _messageIds.contains(msgId)) return;
    if (msgId.isNotEmpty) _messageIds.add(msgId);

    if (msgId.isEmpty) {
      final isDupe = _messages.any((m) =>
          m.text == msgText &&
          m.isFromDriver &&
          DateTime.now().difference(m.timestamp).inSeconds < 30);
      if (isDupe) return;
    }

    if (mounted) {
      setState(() {
        _messages.add(_ChatMessage(
          id: msgId,
          text: msgText,
          isFromDriver: true,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
    }
  }

  /// Handle chat_history event (all stored messages for this ride)
  void _handleChatHistory(Map<String, dynamic> data) {
    final serverMessages = data['messages'] as List<dynamic>? ?? [];
    if (serverMessages.isEmpty) return;

    if (mounted) {
      setState(() {
        // Remove optimistic (id-less) messages that now exist on the server
        _messages.removeWhere((local) {
          if (local.id.isNotEmpty) return false;
          return serverMessages.any((srv) {
            if (srv is! Map<String, dynamic>) return false;
            return (srv['message'] as String? ?? '') == local.text &&
                ((srv['sender'] as String? ?? '') == 'rider') ==
                    !local.isFromDriver;
          });
        });

        // Add any server messages we don't already have
        for (final srv in serverMessages) {
          if (srv is! Map<String, dynamic>) continue;
          final msgId = srv['id'] as String? ?? '';
          if (msgId.isNotEmpty && _messageIds.contains(msgId)) continue;
          if (msgId.isNotEmpty) _messageIds.add(msgId);

          _messages.add(_ChatMessage(
            id: msgId,
            text: srv['message'] as String? ?? '',
            isFromDriver: (srv['sender'] as String? ?? '') != 'rider',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
                srv['timestamp'] as int? ?? 0),
          ));
        }
        _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      });
      _scrollToBottom();
    }
  }

  /// Load chat history from REST API — clean merge with local messages
  Future<void> _loadChatHistory() async {
    if (_rideId == null) return;
    final serverMessages = await apiClient.getChatMessages(_rideId!);
    if (serverMessages.isEmpty || !mounted) return;

    setState(() {
      // Remove optimistic (id-less) messages that now exist on the server
      // Match by: same text + same sender role
      _messages.removeWhere((local) {
        if (local.id.isNotEmpty) return false; // Not an optimistic message
        return serverMessages.any((srv) =>
            (srv['message'] as String? ?? '') == local.text &&
            ((srv['sender'] as String? ?? '') == 'rider') ==
                !local.isFromDriver);
      });

      // Add any server messages we don't already have
      for (final msg in serverMessages) {
        final msgId = msg['id'] as String? ?? '';
        if (msgId.isNotEmpty && _messageIds.contains(msgId)) continue;
        if (msgId.isNotEmpty) _messageIds.add(msgId);

        _messages.add(_ChatMessage(
          id: msgId,
          text: msg['message'] as String? ?? '',
          isFromDriver: (msg['sender'] as String? ?? '') != 'rider',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
              msg['timestamp'] as int? ?? 0),
        ));
      }
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    });
    _scrollToBottom();
  }

  void _startChatPolling() {
    _chatPollTimer?.cancel();
    _chatPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadChatHistory();
    });
  }

  void _stopChatPolling() {
    _chatPollTimer?.cancel();
    _chatPollTimer = null;
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _fitBounds(GoogleMapController controller) async {
    final lats = [
      _pickupLocation.latitude,
      _destinationLocation.latitude,
      _driverLocation.latitude
    ];
    final lngs = [
      _pickupLocation.longitude,
      _destinationLocation.longitude,
      _driverLocation.longitude
    ];
    final bounds = LatLngBounds(
      southwest: LatLng(lats.reduce((a, b) => a < b ? a : b),
          lngs.reduce((a, b) => a < b ? a : b)),
      northeast: LatLng(lats.reduce((a, b) => a > b ? a : b),
          lngs.reduce((a, b) => a > b ? a : b)),
    );
    await Future.delayed(const Duration(milliseconds: 100));
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  void _cancelRide() {
    if (_rideId != null) {
      realtimeService.cancelRide(_rideId!, reason: 'Cancelled by rider');
      apiClient
          .cancelRide(_rideId!, reason: 'Cancelled by rider')
          .catchError((_) => <String, dynamic>{});
    }
    _clearRideStateAndNavigate();
  }

  // ─── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          // Navigate to services screen instead of popping — keeps ride state alive
          // so the ActiveRideBanner can show on the services screen.
          context.go(AppRoutes.services);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(),
                  Expanded(
                      child: _phase == _RidePhase.rideInProgress
                          ? _buildRideInProgressUI()
                          : _buildDriverEnRouteUI()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Phase 1: Driver en-route (original UI + Uber-style OTP) ─

  Widget _buildDriverEnRouteUI() {
    return Column(
      children: [
        Expanded(flex: 2, child: _buildMapSection('$_driverName is arriving')),
        Expanded(flex: 3, child: _buildBottomSheet()),
      ],
    );
  }

  /// OTP PIN banner inside the bottom sheet
  Widget _buildOtpPinBanner() {
    final hasValidOtp = _otp.isNotEmpty && _otp != '----' && _otp.length == 4;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F4EF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8DFD3)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFD4956A).withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.lock_outline,
                color: Color(0xFFD4956A), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'RIDE PIN',
                  style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasValidOtp
                      ? 'Share with driver to start ride'
                      : 'Loading...',
                  style:
                      const TextStyle(color: Color(0xFF888888), fontSize: 11),
                ),
              ],
            ),
          ),
          if (hasValidOtp)
            Row(
              children: _otp.split('').map((digit) {
                return Container(
                  margin: const EdgeInsets.only(left: 4),
                  width: 34,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      digit,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                );
              }).toList(),
            )
          else
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFFD4956A)),
            ),
        ],
      ),
    );
  }

  // ─── Phase 2: Ride in progress — navigation to drop ─────────

  Widget _buildRideInProgressUI() {
    // Passenger has boarded - no chat/call needed, only Safety button
    return Stack(
      children: [
        // Full-screen map
        _buildFullScreenMap(),
        // Bottom info card
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withAlpha(30),
                    blurRadius: 20,
                    offset: const Offset(0, -4))
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 16),
                // Status
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.info.withAlpha(25),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          const Icon(Icons.navigation, color: AppColors.info),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Heading to',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                          Text(
                            _dropAddress.split(',').first,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                          color: AppColors.inputBackground,
                          borderRadius: BorderRadius.circular(8)),
                      child: Text('$_eta min',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Fare + driver info row
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: const Color(0xFFD4956A),
                      child: Text(_driverName.isNotEmpty ? _driverName[0] : 'D',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _driverName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _vehicleNumber.isNotEmpty
                                ? _vehicleNumber
                                : 'Vehicle details unavailable',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '\u20B9${_fareAmount.round()}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Safety button only - passenger has boarded, no need for chat/call
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _openSafetyOptions,
                    icon: const Icon(Icons.shield_outlined,
                        size: 20, color: Colors.white),
                    label: Text(ref.tr('safety'),
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4956A),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 14),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullScreenMap() {
    // Watch dark mode changes
    final isDarkMode = ref.watch(settingsProvider).isDarkMode;
    if (isDarkMode != _lastDarkMode) {
      _lastDarkMode = isDarkMode;
      _loadMapStyle();
    }

    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(
          (_pickupLocation.latitude + _destinationLocation.latitude) / 2,
          (_pickupLocation.longitude + _destinationLocation.longitude) / 2,
        ),
        zoom: 14,
      ),
      markers: _markers,
      polylines: _polylines,
      onMapCreated: (controller) {
        if (!_mapController.isCompleted) _mapController.complete(controller);
        _mapControllerInstance = controller;
        // Apply map style
        if (_mapStyle != null) {
          controller.setMapStyle(_mapStyle);
        }
        _fitMapToBounds();
      },
      myLocationEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
    );
  }

  // ─── Header ──────────────────────────────────────────────────

  Widget _buildHeader() {
    final bool canCancel = _phase !=
        _RidePhase
            .rideInProgress; // No cancel once ride has started (OTP verified)
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Hide close/cancel entirely when ride has started - no cancel option
          if (canCancel)
            GestureDetector(
              onTap: () => _showCancelDialog(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(20)),
                child:
                    const Icon(Icons.close, color: Color(0xFF1A1A1A), size: 20),
              ),
            )
          else
            const SizedBox(width: 44),
          // Phase indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: _phase == _RidePhase.rideInProgress
                  ? AppColors.info
                  : const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              _phase == _RidePhase.rideInProgress
                  ? 'En Route'
                  : 'Driver Arriving',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (canCancel)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Color(0xFF1A1A1A)),
              onSelected: (v) {
                if (v == 'cancel') _showCancelDialog();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'cancel',
                    child: Row(children: [
                      Icon(Icons.cancel_outlined, color: Colors.red, size: 20),
                      SizedBox(width: 12),
                      Text(ref.tr('cancel_ride'),
                          style: TextStyle(color: Colors.red))
                    ])),
              ],
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  void _showCancelDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('cancel_ride_question')),
        content: Text(ref.tr('cancel_ride_sure')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ref.tr('keep_ride'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _cancelRide();
            },
            child: Text(ref.tr('cancel_ride'),
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ─── Map section (for driver-en-route phase) ─────────────────

  Widget _buildMapSection(String label) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  (_pickupLocation.latitude + _driverLocation.latitude) / 2,
                  (_pickupLocation.longitude + _driverLocation.longitude) / 2,
                ),
                zoom: 15,
              ),
              markers: _markers,
              polylines: _polylines,
              onMapCreated: (controller) {
                if (!_mapController.isCompleted)
                  _mapController.complete(controller);
                _fitBounds(controller);
              },
              myLocationEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withAlpha(25), blurRadius: 4)
                  ]),
              child: Column(children: [
                Text('$_eta',
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700)),
                const Text('min',
                    style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
              ]),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 80,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withAlpha(25), blurRadius: 4)
                  ]),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom sheet (driver-en-route phase) ────────────────────

  Widget _buildBottomSheet() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(30),
              blurRadius: 10,
              offset: const Offset(0, -2))
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE0E0E0),
                      borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          _buildDriverInfoCard(),
          const SizedBox(height: 12),
          _buildOtpPinBanner(),
          const SizedBox(height: 12),
          _buildMessageAndOTP(),
          const SizedBox(height: 16),
          _buildActionButtons(),
          const SizedBox(height: 16),
          _buildTripLocations(),
        ]),
      ),
    );
  }

  Widget _buildDriverInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
              color: const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(12)),
          child: Center(
              child: Text(_driverName.isNotEmpty ? _driverName[0] : 'D',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 24))),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _vehicleNumber.isNotEmpty
                ? _vehicleNumber
                : 'Vehicle details unavailable',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (_vehicleModel.isNotEmpty)
            Text(_vehicleModel,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_driverName,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          Row(children: [
            const Icon(Icons.star, size: 14, color: Color(0xFFFFD700)),
            const SizedBox(width: 2),
            Text(_driverRating.toString(),
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
          ]),
        ]),
      ]),
    );
  }

  Widget _buildMessageAndOTP() {
    final unreadCount = _rideId == null
        ? 0
        : ref.watch(chatProvider(_rideId!).select((s) => s.unreadCount));
    return Row(
      children: [
        // Message box - expanded to take remaining space
        Expanded(
          child: GestureDetector(
            onTap: _openChatBottomSheet,
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(24)),
              child: Row(children: [
                const Expanded(
                    child: Text('Send a message...',
                        style:
                            TextStyle(color: Color(0xFFBDBDBD), fontSize: 14))),
                _chatIconWithBadge(
                  unreadCount,
                  baseIcon: Icons.chat_bubble_outline,
                  iconSize: 20,
                  iconColor: const Color(0xFF888888),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Call button - beside message box
        GestureDetector(
          onTap: _callDriver,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.phone, color: Colors.white, size: 22),
          ),
        ),
      ],
    );
  }

  Future<void> _openChatBottomSheet() async {
    if (_rideId == null || _chatSheetOpen) return;
    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';
    if (currentUserId.isEmpty) return;

    _chatSheetOpen = true;
    try {
      await RideChatBottomSheet.show(
        context,
        rideId: _rideId!,
        currentUserId: currentUserId,
        passengerId: authState.user?.id,
        otherUserName: _driverName.isNotEmpty ? _driverName : 'Driver',
        otherUserPhoto: null,
        isDriver: false,
      );
    } finally {
      _chatSheetOpen = false;
    }
  }

  Widget _chatIconWithBadge(
    int count, {
    required IconData baseIcon,
    double iconSize = 20,
    Color iconColor = const Color(0xFF1A1A1A),
  }) {
    if (count > 0) {
      return Text(
        count > 99 ? '99+' : count.toString(),
        style: TextStyle(
          color: iconColor,
          fontSize: iconSize * 0.7,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    return Icon(baseIcon, color: iconColor, size: iconSize);
  }

  Widget _buildActionButtons() {
    // Pre-ride: hide action buttons since Call is now beside message box
    if (_phase == _RidePhase.driverEnRoute) {
      return const SizedBox.shrink();
    }

    // Ride in progress: show Safety and Share (Call is already beside message box)
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      _actionBtn(Icons.shield_outlined, 'Safety', _openSafetyOptions),
      _actionBtn(Icons.share_outlined, 'Share trip', _shareTripDetails),
    ]);
  }

  Future<void> _openSafetyOptions() async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: Text(ref.tr('safety_tools')),
                subtitle: Text(ref.tr('quick_actions')),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text(ref.tr('share_trip')),
                onTap: () {
                  Navigator.pop(context);
                  _shareTripDetails();
                },
              ),
              ListTile(
                leading: const Icon(Icons.report_problem_outlined),
                title: Text(ref.tr('report_issue_btn')),
                onTap: () {
                  Navigator.pop(context);
                  _openReportIssueSheet();
                },
              ),
              ListTile(
                leading: const Icon(Icons.sos_outlined, color: Colors.red),
                title: Text(ref.tr('sos_alert')),
                onTap: () async {
                  Navigator.pop(context);
                  await _callEmergencyNumber('112');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _callEmergencyNumber(String number) async {
    final uri = Uri.parse('tel:$number');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('unable_open_dialer'))),
      );
    }
  }

  Future<void> _shareTripDetails() async {
    try {
      final rideId = _rideId ?? 'N/A';
      final text = '''
Raahi Trip Safety Details
Ride ID: $rideId
Driver: ${_driverName.isNotEmpty ? _driverName : 'Driver'}
Vehicle: ${_vehicleNumber.isNotEmpty ? _vehicleNumber : 'N/A'}
Pickup: ${_pickupAddress.split(',').first}
Drop: ${_dropAddress.split(',').first}
Status: ${_phase == _RidePhase.rideInProgress ? 'IN_PROGRESS' : 'DRIVER_ARRIVING'}
''';
      await Share.share(text.trim(), subject: 'Raahi Trip Safety');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('unable_share_trip'))),
      );
    }
  }

  Future<void> _openReportIssueSheet() async {
    if (!mounted) return;
    final parentContext = context;
    // Capture translations before entering builder
    final trReportIssue = ref.tr('report_issue');
    final trSelectIssue = ref.tr('select_issue');
    final trIssueReportedMsg = ref.tr('issue_reported_msg');
    await showModalBottomSheet(
      context: parentContext,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final issues = <String>[
          'Driver behavior issue',
          'Route/safety concern',
          'Vehicle issue',
          'Other emergency concern',
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.report_problem_outlined),
                title: Text(trReportIssue),
                subtitle: Text(trSelectIssue),
              ),
              ...issues.map(
                (issue) => ListTile(
                  title: Text(issue),
                  onTap: () {
                    Navigator.pop(context);
                    if (!mounted) return;
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      SnackBar(
                          content: Text(
                              trIssueReportedMsg.replaceAll('{issue}', issue))),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap,
      {bool isPrimary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
              color:
                  isPrimary ? const Color(0xFFD4956A) : const Color(0xFFF5F5F5),
              shape: BoxShape.circle),
          child: Icon(icon,
              color: isPrimary ? Colors.white : const Color(0xFF1A1A1A),
              size: 24),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
      ]),
    );
  }

  Widget _buildTripLocations() {
    return Column(children: [
      _locationRow(_pickupAddress, const Color(0xFF1A1A1A)),
      Container(
          margin: const EdgeInsets.only(left: 3),
          width: 2,
          height: 24,
          color: const Color(0xFFE0E0E0)),
      _locationRow(_dropAddress, const Color(0xFFD4956A)),
    ]);
  }

  Widget _locationRow(String address, Color dotColor) {
    final parts = address.contains(',')
        ? [
            address.split(',').first,
            address.substring(address.indexOf(',') + 2)
          ]
        : [address, ''];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
      const SizedBox(width: 12),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(parts[0],
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (parts[1].isNotEmpty)
          Text(parts[1],
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
      ])),
    ]);
  }

  // ─── Chat overlay ────────────────────────────────────────────

  Widget _buildChatOverlay() {
    return Container(
      color: Colors.black54,
      child: Column(children: [
        Container(
          padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              bottom: 16),
          decoration: const BoxDecoration(color: Colors.white, boxShadow: [
            BoxShadow(
                color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
          ]),
          child: Row(children: [
            GestureDetector(
                onTap: () {
                  _stopChatPolling();
                  setState(() => _showChat = false);
                },
                child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Icon(Icons.close, size: 20))),
            const SizedBox(width: 12),
            Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: const Color(0xFFD4956A),
                    borderRadius: BorderRadius.circular(20)),
                child: Center(
                    child: Text(_driverName.isNotEmpty ? _driverName[0] : 'D',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16)))),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(_driverName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                  Text(
                    _vehicleSummaryLine,
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF888888)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ])),
            GestureDetector(
                onTap: _callDriver,
                child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: const Color(0xFFD4956A),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Icon(Icons.phone,
                        color: Colors.white, size: 20))),
          ]),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFF5F5F5),
            child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _buildBubble(_messages[i])),
          ),
        ),
        Container(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12),
          decoration: const BoxDecoration(color: Colors.white, boxShadow: [
            BoxShadow(
                color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
          ]),
          child: Row(children: [
            Expanded(
                child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(24)),
                    child: TextField(
                        controller: _messageController,
                        decoration: const InputDecoration(
                            hintText: 'Type a message...',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 12)),
                        onSubmitted: (_) => _sendMessage()))),
            const SizedBox(width: 12),
            GestureDetector(
                onTap: _sendMessage,
                child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: const Color(0xFFD4956A),
                        borderRadius: BorderRadius.circular(24)),
                    child:
                        const Icon(Icons.send, color: Colors.white, size: 20))),
          ]),
        ),
      ]),
    );
  }

  Widget _buildBubble(_ChatMessage msg) {
    final time =
        '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            msg.isFromDriver ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (msg.isFromDriver) ...[
            CircleAvatar(
                radius: 14,
                backgroundColor: const Color(0xFFD4956A),
                child: Text(_driverName.isNotEmpty ? _driverName[0] : 'D',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color:
                    msg.isFromDriver ? Colors.white : const Color(0xFFD4956A),
                borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(msg.isFromDriver ? 4 : 16),
                    bottomRight: Radius.circular(msg.isFromDriver ? 16 : 4)),
              ),
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(msg.text,
                    style: TextStyle(
                        color: msg.isFromDriver
                            ? const Color(0xFF1A1A1A)
                            : Colors.white,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(time,
                    style: TextStyle(
                        color: msg.isFromDriver
                            ? const Color(0xFFBDBDBD)
                            : Colors.white70,
                        fontSize: 10)),
              ]),
            ),
          ),
          if (!msg.isFromDriver) const SizedBox(width: 36),
        ],
      ),
    );
  }
}

// ─── Models ──────────────────────────────────────────────────

class _ChatMessage {
  final String id;
  final String text;
  final bool isFromDriver;
  final DateTime timestamp;
  _ChatMessage(
      {this.id = '',
      required this.text,
      required this.isFromDriver,
      required this.timestamp});
}

// ─── Rating sheet ────────────────────────────────────────────

class _RatingSheet extends StatefulWidget {
  final double fare;
  final String driverName;
  final Future<void> Function(double rating, String? feedback) onSubmit;
  final VoidCallback onSkip;

  const _RatingSheet(
      {required this.fare,
      required this.driverName,
      required this.onSubmit,
      required this.onSkip});

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet>
    with SingleTickerProviderStateMixin {
  int _stars = 0;
  final _fc = TextEditingController();
  bool _submitting = false;
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..forward();
  }

  @override
  void dispose() {
    _fc.dispose();
    _anim.dispose();
    super.dispose();
  }

  String _label() =>
      ['', 'Poor', 'Below Average', 'Average', 'Good', 'Excellent!'][_stars];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 24),
              ScaleTransition(
                scale: CurvedAnimation(parent: _anim, curve: Curves.elasticOut),
                child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                        color: AppColors.success.withAlpha(25),
                        shape: BoxShape.circle),
                    child: const Icon(Icons.check_circle,
                        color: AppColors.success, size: 40)),
              ),
              const SizedBox(height: 16),
              const Text('Ride Completed!',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Thank you for riding with us',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600])),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: AppColors.inputBackground,
                    borderRadius: BorderRadius.circular(16)),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.receipt_long,
                      color: AppColors.textSecondary, size: 20),
                  const SizedBox(width: 8),
                  const Text('Total Fare:',
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(width: 8),
                  Text('\u20B9${widget.fare.round()}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 22)),
                ]),
              ),
              const SizedBox(height: 24),
              Text('Rate your ride with ${widget.driverName}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    final idx = i + 1;
                    final sel = idx <= _stars;
                    return GestureDetector(
                      onTap: () => setState(() => _stars = idx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                            sel
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            size: sel ? 48 : 44,
                            color:
                                sel ? AppColors.starYellow : Colors.grey[350]),
                      ),
                    );
                  })),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(_stars > 0 ? _label() : 'Tap a star to rate',
                      key: ValueKey(_stars),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _stars > 0
                              ? AppColors.textPrimary
                              : Colors.grey[500]))),
              if (_stars > 0) ...[
                const SizedBox(height: 20),
                TextField(
                    controller: _fc,
                    maxLines: 3,
                    decoration: InputDecoration(
                        hintText: 'Share your experience (optional)',
                        filled: true,
                        fillColor: AppColors.inputBackground,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none))),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _stars > 0 && !_submitting
                      ? () async {
                          setState(() => _submitting = true);
                          await widget.onSubmit(_stars.toDouble(),
                              _fc.text.trim().isEmpty ? null : _fc.text.trim());
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey[300],
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Submit Rating',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: _submitting ? null : widget.onSkip,
                  child:
                      Text('Skip', style: TextStyle(color: Colors.grey[500]))),
            ]),
          ),
        ),
      ),
    );
  }
}
