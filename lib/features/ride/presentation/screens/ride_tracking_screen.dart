import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/models/driver.dart';
import '../../../../core/models/location.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/sse_service.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/app_routes.dart';
import '../../../home/presentation/widgets/custom_map_view.dart'
    show CustomMapView, RidePhase;
import '../../../chat/presentation/screens/ride_chat_screen.dart';
import '../../../chat/providers/chat_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/widgets/upi_app_icon.dart';
import '../../providers/ride_provider.dart';
import '../../providers/ride_booking_provider.dart';

class RideTrackingScreen extends ConsumerStatefulWidget {
  final String rideId;
  final bool autoOpenChat;

  const RideTrackingScreen({
    super.key,
    required this.rideId,
    this.autoOpenChat = false,
  });

  @override
  ConsumerState<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends ConsumerState<RideTrackingScreen>
    with WidgetsBindingObserver {
  Ride? _ride;
  Driver? _driver;
  LocationCoordinate? _driverLocation;
  double? _driverHeading;
  bool _isLoading = true;
  bool _isSubmittingRating = false;
  String _statusMessage = 'Finding your driver...';
  SSESubscription? _sseSubscription;
  VoidCallback? _unsubscribeRide;
  VoidCallback? _unsubscribeSocketLocation;
  bool _showBottomCard = true;
  bool _chatSheetOpen = false;
  bool _autoChatHandled = false;
  bool _pendingPushChatOpen = false;
  StreamSubscription<Map<String, dynamic>>? _chatOpenSubscription;

  // Driver distance/ETA tracking
  double _driverDistanceMeters = 0;
  int _driverEtaMinutes = 0;
  DateTime? _lastSharedEtaAt;

  // Periodic driver location polling
  Timer? _locationPollTimer;
  bool _completionHandled = false;
  bool _ratingSheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeChatProvider();
    _loadRideDetails();
    _subscribeToUpdates();
    _subscribeToSocketLocationUpdates();
    _startLocationPolling();
    _subscribeToNotificationChatOpens();
  }

  void _initializeChatProvider() {
    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';
    if (currentUserId.isEmpty) return;
    ref.read(chatProvider(widget.rideId).notifier).initialize(
          currentUserId: currentUserId,
          passengerId: currentUserId,
          isDriver: false,
        );
    ref.read(chatProvider(widget.rideId).notifier).closeChat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationPollTimer?.cancel();
    _sseSubscription?.cancel();
    _chatOpenSubscription?.cancel();
    _unsubscribeRide?.call();
    _unsubscribeSocketLocation?.call();
    webSocketService.leaveRideTracking(widget.rideId);
    realtimeService.disconnectRide(widget.rideId);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Ensure completion transition is not missed after background/resume.
      unawaited(_syncRideStateFromBackend());
    }
  }

  void _subscribeToNotificationChatOpens() {
    _chatOpenSubscription =
        pushNotificationService.chatOpenStream.listen((payload) {
      final targetRideId = payload['rideId']?.toString() ?? '';
      if (targetRideId.isEmpty || targetRideId != widget.rideId) return;
      if (!mounted || _chatSheetOpen) return;

      if (_ride == null || _driver == null) {
        _pendingPushChatOpen = true;
        return;
      }
      _messageDriver();
    });
  }

  /// Subscribe directly to Socket.io driver location events
  void _subscribeToSocketLocationUpdates() {
    _unsubscribeSocketLocation =
        webSocketService.subscribe('driver_location_update', (message) {
      final data = message.data;
      if (data is Map) {
        final mapData = Map<String, dynamic>.from(data);
        // Only process if it's for our ride
        final msgRideId = mapData['rideId'] as String?;
        if (msgRideId == null || msgRideId == widget.rideId) {
          _handleLocationUpdate(mapData);
        }
      }
    });
  }

  /// Poll for driver location every 5 seconds as backup
  void _startLocationPolling() {
    _locationPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_ride != null &&
          _ride!.status != RideStatus.completed &&
          _ride!.status != RideStatus.cancelled) {
        _pollDriverLocation();
      }
    });
  }

  Future<void> _pollDriverLocation() async {
    try {
      final rideData = await apiClient.getRide(widget.rideId);
      final ride = Ride.fromJson(_extractRidePayload(rideData));

      // Update driver location if available
      if (ride.driver?.currentLocation != null) {
        final newLoc = ride.driver!.currentLocation!;
        if (_driverLocation == null ||
            _driverLocation!.lat != newLoc.lat ||
            _driverLocation!.lng != newLoc.lng) {
          setState(() {
            _driverLocation = newLoc;
            _driverHeading = ride.driver?.heading;
            _driver = ride.driver;
          });
          _updateRealtimeEtaFromDriverLocation(newLoc);
        }
      }

      // Also update ride status if changed
      if (ride.status != _ride?.status) {
        setState(() {
          _ride = ride;
          _statusMessage = _getStatusMessage(ride.status);
        });
      }

      if (ride.status == RideStatus.completed) {
        _handleCompletionTransition();
      } else if (ride.status == RideStatus.cancelled) {
        _handleRideCancelled({'reason': 'Ride was cancelled'});
      }
    } catch (e) {
      // Silently ignore polling errors
    }
  }

  Future<void> _syncRideStateFromBackend() async {
    if (!mounted) return;
    try {
      final rideData = await apiClient.getRide(widget.rideId);
      final ride = Ride.fromJson(_extractRidePayload(rideData));
      if (!mounted) return;
      setState(() {
        _ride = ride;
        _statusMessage = _getStatusMessage(ride.status);
      });
      if (ride.status == RideStatus.completed) {
        _handleCompletionTransition();
      } else if (ride.status == RideStatus.cancelled) {
        _handleRideCancelled({'reason': 'Ride was cancelled'});
      }
    } catch (_) {
      // Best-effort sync only.
    }
  }

  Future<void> _loadRideDetails() async {
    try {
      final rideData = await apiClient.getRide(widget.rideId);
      final ride = Ride.fromJson(_extractRidePayload(rideData));

      // Preserve the original rider UX:
      // pre-pickup phases must stay on DriverAssignedScreen.
      if (_isPrePickupPhase(ride.status)) {
        if (mounted) {
          context.go(
              '${AppRoutes.driverAssigned}?rideId=${widget.rideId}&openChat=${widget.autoOpenChat ? 'true' : 'false'}');
        }
        return;
      }

      setState(() {
        _ride = ride;
        _driver = ride.driver;
        _isLoading = false;
        _statusMessage = _getStatusMessage(ride.status);

        // Set initial driver location from ride.driver if available
        if (ride.driver?.currentLocation != null) {
          _driverLocation = ride.driver!.currentLocation;
          _driverHeading = ride.driver?.heading;
        }
      });
      if (_driverLocation != null) {
        _updateRealtimeEtaFromDriverLocation(_driverLocation!);
      }

      // If ride is already completed when loaded, show the rating dialog
      if (ride.status == RideStatus.completed) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _showRatingBottomSheet();
        });
      }
      if (_pendingPushChatOpen && mounted) {
        _pendingPushChatOpen = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_chatSheetOpen) {
            _messageDriver();
          }
        });
      }
      _maybeAutoOpenChat();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error loading ride details';
      });
    }
  }

  bool _isPrePickupPhase(RideStatus status) {
    return status == RideStatus.requested ||
        status == RideStatus.accepted ||
        status == RideStatus.arriving ||
        status == RideStatus.driverArriving;
  }

  void _maybeAutoOpenChat() {
    if (!widget.autoOpenChat || _autoChatHandled || _chatSheetOpen) return;
    if (_ride == null || _driver == null) return;
    _autoChatHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _messageDriver();
      }
    });
  }

  void _subscribeToUpdates() {
    webSocketService.joinRideTracking(widget.rideId);

    // Primary: SSE ride stream
    _sseSubscription = realtimeService.connectRide(
      widget.rideId,
      onEvent: (type, data) {
        switch (type) {
          case 'status_update':
            _handleStatusUpdate(data);
            break;
          case 'location_update':
            _handleLocationUpdate(data);
            break;
          case 'cancelled':
            _handleRideCancelled(data);
            break;
          case 'driver_assigned':
            _handleStatusUpdate({'status': 'accepted', ...data});
            break;
          case 'message':
          case 'ride-chat-message':
          case 'chat_message':
          case 'ride_chat_message':
            _handleChatMessage(data);
            break;
        }
      },
    );
  }

  void _handleChatMessage(Map<String, dynamic> data) {
    // Forward chat message to the chat provider if it exists
    try {
      ref
          .read(chatProvider(widget.rideId).notifier)
          .handleExternalChatMessage(data);
    } catch (e) {
      debugPrint(
          'Chat provider not initialized, message will be loaded on chat open: $e');
    }
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    final statusStr = data['status'] as String?;
    if (statusStr != null && _ride != null) {
      final status = _parseStatus(statusStr);

      // If driver info is in the update, parse it
      Driver? updatedDriver = _driver;
      if (data['driver'] != null && data['driver'] is Map<String, dynamic>) {
        try {
          updatedDriver =
              Driver.fromJson(data['driver'] as Map<String, dynamic>);
        } catch (_) {}
      }

      setState(() {
        _ride = _ride!.copyWith(status: status);
        _statusMessage = _getStatusMessage(status);
        if (updatedDriver != null) _driver = updatedDriver;
      });
      if (_driverLocation != null) {
        _updateRealtimeEtaFromDriverLocation(_driverLocation!);
      }

      // If ride completed, enter completion flow once.
      if (status == RideStatus.completed) {
        _handleCompletionTransition();
      }
      _maybeAutoOpenChat();
    }
  }

  void _handleCompletionTransition() {
    if (!mounted || _completionHandled) return;
    _completionHandled = true;
    _showRatingBottomSheet();
  }

  void _handleLocationUpdate(Map<String, dynamic> data) {
    // Use shared ETA from driver if provided (ensures consistency)
    final driverEta = _extractSharedEtaMinutes(data);

    final location = data['driverLocation'] as Map<String, dynamic>?;
    if (location != null) {
      final lat = (location['latitude'] as num?)?.toDouble();
      final lng = (location['longitude'] as num?)?.toDouble();
      final heading = (location['heading'] as num?)?.toDouble() ??
          (data['heading'] as num?)?.toDouble();

      if (lat != null && lng != null) {
        final nextLoc = LocationCoordinate(lat: lat, lng: lng);
        setState(() {
          _driverLocation = nextLoc;
          _driverHeading = heading;
          // Use driver's ETA if available for consistency
          if (driverEta != null && driverEta > 0) {
            _driverEtaMinutes = driverEta;
            _lastSharedEtaAt = DateTime.now();
            debugPrint('📍 [ETA] Using driver ETA: ${driverEta}min');
          }
        });
        // Only calculate locally if driver didn't provide ETA
        if ((driverEta == null || driverEta <= 0) &&
            _shouldUseLocalEtaFallback()) {
          _updateRealtimeEtaFromDriverLocation(nextLoc);
        }
      }
    } else {
      // Try alternate data structure (direct lat/lng in data)
      final lat = (data['lat'] as num?)?.toDouble() ??
          (data['latitude'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble() ??
          (data['longitude'] as num?)?.toDouble();
      final heading = (data['heading'] as num?)?.toDouble();

      if (lat != null && lng != null) {
        final nextLoc = LocationCoordinate(lat: lat, lng: lng);
        setState(() {
          _driverLocation = nextLoc;
          _driverHeading = heading;
          // Use driver's ETA if available for consistency
          if (driverEta != null && driverEta > 0) {
            _driverEtaMinutes = driverEta;
            _lastSharedEtaAt = DateTime.now();
            debugPrint('📍 [ETA] Using driver ETA: ${driverEta}min');
          }
        });
        // Only calculate locally if driver didn't provide ETA
        if ((driverEta == null || driverEta <= 0) &&
            _shouldUseLocalEtaFallback()) {
          _updateRealtimeEtaFromDriverLocation(nextLoc);
        }
      }
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

  void _updateRealtimeEtaFromDriverLocation(LocationCoordinate driverLoc) {
    if (_ride == null) return;
    if (!_shouldUseLocalEtaFallback()) return;

    final bool inProgress = _ride!.status == RideStatus.inProgress;
    final target = inProgress
        ? _ride!.destinationLocation.toLocationCoordinate()
        : _ride!.pickupLocation.toLocationCoordinate();

    final distanceMeters = _distanceMeters(
      driverLoc.lat,
      driverLoc.lng,
      target.lat,
      target.lng,
    );
    final avgKmph = inProgress ? 24.0 : 20.0;
    final etaMinutes =
        ((distanceMeters / 1000) / avgKmph * 60).ceil().clamp(1, 180);

    if (!mounted) return;
    setState(() {
      _driverDistanceMeters = distanceMeters;
      _driverEtaMinutes = etaMinutes;
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

  void _handleRideCancelled(Map<String, dynamic> data) {
    // Clear all ride state so the banner disappears
    ref.read(activeRideProvider.notifier).clearActiveRide();
    ref.read(rideBookingProvider.notifier).reset();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('ride_cancelled')),
        content:
            Text(data['reason'] as String? ?? 'Your ride has been cancelled.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Navigate to services screen (ride booking), not findTrip or home
              if (mounted) context.go(AppRoutes.services);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(ref.tr('ok')),
          ),
        ],
      ),
    );
  }

  /// Show a beautiful rating bottom sheet with interactive stars and feedback
  void _showRatingBottomSheet() {
    if (!mounted || _ride == null || _ratingSheetOpen) return;
    _ratingSheetOpen = true;

    // Hide bottom card to make it immersive
    setState(() => _showBottomCard = false);

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _RatingBottomSheet(
        ride: _ride!,
        driver: _driver,
        onSubmit: (rating, feedback) async {
          final nav = GoRouter.of(context);
          Navigator.pop(context);
          await _submitRating(rating, feedback);
          // Clear ride state so banner disappears
          ref.read(activeRideProvider.notifier).clearActiveRide();
          ref.read(rideBookingProvider.notifier).reset();
          _ratingSheetOpen = false;
          // Navigate to services screen (ride booking) for easy rebooking
          nav.go(AppRoutes.services);
        },
        onSkip: () {
          final nav = GoRouter.of(context);
          Navigator.pop(context);
          // Clear ride state so banner disappears
          ref.read(activeRideProvider.notifier).clearActiveRide();
          ref.read(rideBookingProvider.notifier).reset();
          _ratingSheetOpen = false;
          // Navigate to services screen (ride booking) for easy rebooking
          nav.go(AppRoutes.services);
        },
      ),
    ).whenComplete(() {
      _ratingSheetOpen = false;
    });
  }

  Future<void> _submitRating(double rating, String? feedback) async {
    if (_ride == null || _isSubmittingRating) return;

    setState(() => _isSubmittingRating = true);
    try {
      await apiClient.submitRideRating(_ride!.id, rating, feedback: feedback);
      setState(() {
        _ride = _ride!.copyWith(rating: rating);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.tr('thanks_feedback')),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error submitting rating: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.tr('failed_submit_rating')),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmittingRating = false);
      }
    }
  }

  Future<void> _callDriver() async {
    final phone = _resolveDriverPhone();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('driver_phone_unavailable'))),
      );
      return;
    }

    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(ref.tr('could_not_launch_dialer')),
              backgroundColor: AppColors.error),
        );
      }
    }
  }

  String _resolveDriverPhone() {
    final candidates = <String?>[
      _driver?.phone,
      _ride?.driver?.phone,
    ];

    for (final raw in candidates) {
      final normalized = _normalizePhone(raw);
      if (normalized.isNotEmpty) return normalized;
    }
    return '';
  }

  String _normalizePhone(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    var phone = raw.trim().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (phone.startsWith('+')) return phone;
    if (phone.startsWith('91') && phone.length == 12) return '+$phone';
    if (phone.length == 10) return '+91$phone';
    return phone;
  }

  Map<String, dynamic> _extractRidePayload(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map<String, dynamic>) return data;
    return response;
  }

  Future<void> _messageDriver() async {
    if (_chatSheetOpen) return;
    if (_ride == null || _driver == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('driver_info_unavailable'))),
      );
      return;
    }

    final authState = ref.read(authStateProvider);
    final currentUserId = authState.user?.id ?? '';

    if (currentUserId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('login_to_message'))),
      );
      return;
    }

    final driverName = _driver!.name;

    _chatSheetOpen = true;
    try {
      await RideChatBottomSheet.show(
        context,
        rideId: widget.rideId,
        currentUserId: currentUserId,
        passengerId: _ride!.riderId,
        otherUserName: driverName.isNotEmpty ? driverName : 'Driver',
        otherUserPhoto: _driver!.avatar,
        isDriver: false,
      );
    } finally {
      _chatSheetOpen = false;
    }
  }

  Future<void> _cancelRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('cancel_ride')),
        content: Text(ref.tr('cancel_ride_sure')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ref.tr('no'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: Text(ref.tr('yes_cancel')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Notify driver via real-time service
        realtimeService.cancelRide(widget.rideId, reason: 'Cancelled by rider');
        // Cancel via REST API (this also triggers server-side events to driver)
        await apiClient.cancelRide(widget.rideId, reason: 'Cancelled by rider');
        if (mounted) {
          // Clear ride state before navigation
          ref.read(activeRideProvider.notifier).clearActiveRide();
          ref.read(rideBookingProvider.notifier).reset();
          // Navigate to services screen (ride booking), not findTrip or home
          context.go(AppRoutes.services);
        }
      } catch (e) {
        debugPrint('Error cancelling ride: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(ref.tr('failed_cancel_ride')),
                backgroundColor: AppColors.error),
          );
        }
      }
    }
  }

  String _getStatusMessage(RideStatus status) {
    switch (status) {
      case RideStatus.requested:
        return 'Finding your driver...';
      case RideStatus.accepted:
        return 'Driver is on the way!';
      case RideStatus.arriving:
        return 'Driver has arrived!';
      case RideStatus.driverArriving:
        return 'Driver is arriving...';
      case RideStatus.inProgress:
        return 'Enjoy your ride!';
      case RideStatus.completed:
        return 'Ride completed';
      case RideStatus.cancelled:
        return 'Ride cancelled';
    }
  }

  /// Convert ride status to RidePhase for map display
  RidePhase _getRidePhase() {
    if (_ride == null) return RidePhase.searching;

    switch (_ride!.status) {
      case RideStatus.requested:
        return RidePhase.searching;
      case RideStatus.accepted:
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return RidePhase.driverArriving;
      case RideStatus.inProgress:
        return RidePhase.rideInProgress;
      case RideStatus.completed:
        return RidePhase.completed;
      case RideStatus.cancelled:
        return RidePhase.completed;
    }
  }

  /// Format distance in meters to human readable string
  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m away';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km away';
    }
  }

  RideStatus _parseStatus(String status) {
    final s = status.toLowerCase();
    switch (s) {
      case 'driver_assigned':
      case 'driver_accepted':
      case 'accepted':
      case 'confirmed':
        return RideStatus.accepted;
      case 'driver_arrived':
      case 'arrived':
        return RideStatus.arriving;
      case 'arriving':
      case 'driver_arriving':
        return RideStatus.driverArriving;
      case 'in_progress':
      case 'ride_started':
      case 'started':
        return RideStatus.inProgress;
      case 'completed':
      case 'ride_completed':
        return RideStatus.completed;
      case 'cancelled':
      case 'canceled':
        return RideStatus.cancelled;
      default:
        return RideStatus.requested;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Full-screen map with route polylines and driver tracking
          if (_ride != null)
            CustomMapView(
              rideId: _ride?.id,
              pickupLocation: _ride!.pickupLocation.toLocationCoordinate(),
              dropoffLocation:
                  _ride!.destinationLocation.toLocationCoordinate(),
              rideInProgress: true,
              ridePhase: _getRidePhase(),
              driverLocation: _driverLocation,
              driverHeading: _driverHeading,
              followDriverLocation: true,
              animateDriver: true,
              vehicleType: _ride?.rideType ?? _driver?.vehicleInfo?.type,
              isDarkMode: ref.watch(settingsProvider).isDarkMode,
              onDriverDistanceUpdate: (distance, eta) {
                if (mounted) {
                  setState(() {
                    _driverDistanceMeters = distance;
                    _driverEtaMinutes = eta;
                  });
                }
              },
            )
          else
            Container(color: AppColors.inputBackground),

          // Top bar with back button and status chip
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Back button
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withAlpha(25), blurRadius: 8)
                        ],
                      ),
                      child: const Icon(Icons.arrow_back, size: 20),
                    ),
                  ),
                  const Spacer(),
                  // Status chip
                  if (_ride != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: _getStatusColor(_ride!.status),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withAlpha(25), blurRadius: 8)
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _getStatusIcon(_ride!.status),
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _statusMessage,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  const SizedBox(width: 44), // Balance the back button
                ],
              ),
            ),
          ),

          // Bottom card with ride info
          if (_showBottomCard)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(20),
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
                child: _isLoading ? _buildLoadingState() : _buildRideInfo(),
              ),
            ),
        ],
      ),
    );
  }

  Color _getStatusColor(RideStatus status) {
    switch (status) {
      case RideStatus.requested:
        return AppColors.info;
      case RideStatus.accepted:
        return AppColors.success;
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return AppColors.warningOrange;
      case RideStatus.inProgress:
        return AppColors.info;
      case RideStatus.completed:
        return AppColors.success;
      case RideStatus.cancelled:
        return AppColors.error;
    }
  }

  IconData _getStatusIcon(RideStatus status) {
    switch (status) {
      case RideStatus.requested:
        return Icons.search;
      case RideStatus.accepted:
        return Icons.check_circle;
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return Icons.navigation;
      case RideStatus.inProgress:
        return Icons.directions_car;
      case RideStatus.completed:
        return Icons.flag;
      case RideStatus.cancelled:
        return Icons.cancel;
    }
  }

  Widget _buildLoadingState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(ref.tr('loading_ride_details')),
      ],
    );
  }

  Widget _buildRideInfo() {
    final isDriverArriving = _ride?.status == RideStatus.accepted ||
        _ride?.status == RideStatus.arriving ||
        _ride?.status == RideStatus.driverArriving;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Driver arriving info (show when driver is on the way)
        if (isDriverArriving && _driverLocation != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.green.withAlpha(20),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.withAlpha(60)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.directions_car,
                      color: Colors.green, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Driver arriving',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _ride!.pickupLocation.address ?? 'Pickup Location',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$_driverEtaMinutes min',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                    Text(
                      _formatDistance(_driverDistanceMeters),
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],

        // Destination info
        if (_ride != null) ...[
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.dropoffMarker.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.location_on,
                    color: AppColors.dropoffMarker, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isDriverArriving ? 'Then heading to' : 'Heading to',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                    Text(
                      _ride!.destinationLocation.address ?? 'Drop-off Location',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // ETA
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.inputBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_ride!.estimatedDuration} min',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
        ],

        // Driver info
        if (_driver != null) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.secondary.withAlpha(76),
                child: Text(
                  _driver!.name.isNotEmpty
                      ? _driver!.name[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: AppColors.textPrimary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(_driver!.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                        if (_driver!.isVerified) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.verified,
                              size: 16, color: AppColors.info),
                        ],
                      ],
                    ),
                    if (_driver!.vehicleInfo != null)
                      Text(
                        '${_driver!.vehicleInfo!.color} ${_driver!.vehicleInfo!.type} - ${_driver!.vehicleInfo!.plateNumber}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ),
              // Rating badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.starYellow.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star,
                        size: 14, color: AppColors.starYellow),
                    const SizedBox(width: 2),
                    Text(
                      _driver!.rating.toStringAsFixed(1),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 16),

        // Action buttons (Cancel hidden once ride has started - driver entered OTP)
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                icon: Icons.phone,
                label: 'Call',
                onTap: _callDriver,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                icon: Icons.message,
                label: 'Message',
                onTap: _messageDriver,
                color: AppColors.info,
                badgeCount: ref.watch(
                    chatProvider(widget.rideId).select((s) => s.unreadCount)),
              ),
            ),
            if (_ride?.status != RideStatus.inProgress) ...[
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionButton(
                  icon: Icons.close,
                  label: 'Cancel',
                  onTap: _cancelRide,
                  color: AppColors.error,
                ),
              ),
            ],
          ],
        ),

        // Fare info
        if (_ride != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.inputBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Estimated Fare',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
                Text(
                  '\u20B9${_ride!.fare.round()}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
    int badgeCount = 0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Column(
          children: [
            badgeCount > 0
                ? Text(
                    badgeCount > 99 ? '99+' : badgeCount.toString(),
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------
// Rating Bottom Sheet Widget
// -------------------------------------------------------------------

class _RatingBottomSheet extends StatefulWidget {
  final Ride ride;
  final Driver? driver;
  final Future<void> Function(double rating, String? feedback) onSubmit;
  final VoidCallback onSkip;

  const _RatingBottomSheet({
    required this.ride,
    required this.driver,
    required this.onSubmit,
    required this.onSkip,
  });

  @override
  State<_RatingBottomSheet> createState() => _RatingBottomSheetState();
}

class _RatingBottomSheetState extends State<_RatingBottomSheet>
    with SingleTickerProviderStateMixin {
  int _selectedStars = 0;
  final _feedbackController = TextEditingController();
  bool _isSubmitting = false;
  bool _paymentCompleted = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  // UPI Payment Apps configuration
  static const List<Map<String, dynamic>> _upiApps = [
    {
      'name': 'Google Pay',
      'package': 'com.google.android.apps.nbu.paisa.user',
      'scheme': 'gpay',
      'icon': Icons.g_mobiledata,
      'color': Color(0xFF4285F4),
    },
    {
      'name': 'PhonePe',
      'package': 'com.phonepe.app',
      'scheme': 'phonepe',
      'icon': Icons.phone_android,
      'color': Color(0xFF5F259F),
    },
    {
      'name': 'Paytm',
      'package': 'net.one97.paytm',
      'scheme': 'paytmmp',
      'icon': Icons.payment,
      'color': Color(0xFF00BAF2),
    },
    {
      'name': 'CRED',
      'package': 'com.dreamplug.androidapp',
      'scheme': 'credpay',
      'icon': Icons.credit_score,
      'color': Color(0xFF1A1A1A),
    },
  ];

  /// Launch UPI payment intent with the specified app
  Future<void> _launchUpiPayment(Map<String, dynamic> app) async {
    final amount = widget.ride.fare.toStringAsFixed(2);
    final transactionNote = 'Raahi Ride Payment - ${widget.ride.id}';
    // Use company UPI ID for all ride payments
    final payeeVpa = AppConfig.companyUpiId;
    final payeeName = AppConfig.companyDisplayName;

    // Construct UPI URL
    // Format: upi://pay?pa=<payee_vpa>&pn=<payee_name>&am=<amount>&cu=INR&tn=<note>
    final upiUrl = Uri.parse(
        'upi://pay?pa=$payeeVpa&pn=$payeeName&am=$amount&cu=INR&tn=${Uri.encodeComponent(transactionNote)}');

    try {
      // Try to launch with the specific app scheme first
      final appScheme = app['scheme'] as String;
      final appSpecificUrl = Uri.parse(
          '$appScheme://pay?pa=$payeeVpa&pn=$payeeName&am=$amount&cu=INR&tn=${Uri.encodeComponent(transactionNote)}');

      if (await canLaunchUrl(appSpecificUrl)) {
        await launchUrl(appSpecificUrl, mode: LaunchMode.externalApplication);
        // Mark payment as initiated (user will confirm manually)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Opening ${app['name']}...'),
              backgroundColor: app['color'] as Color,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (await canLaunchUrl(upiUrl)) {
        // Fallback to generic UPI intent
        await launchUrl(upiUrl, mode: LaunchMode.externalApplication);
      } else {
        // App not installed
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${app['name']} is not installed'),
              backgroundColor: Colors.orange,
              action: SnackBarAction(
                label: 'Install',
                textColor: Colors.white,
                onPressed: () {
                  // Open Play Store
                  final playStoreUrl = Uri.parse(
                      'https://play.google.com/store/apps/details?id=${app['package']}');
                  launchUrl(playStoreUrl, mode: LaunchMode.externalApplication);
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open ${app['name']}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _markPaymentComplete() {
    setState(() => _paymentCompleted = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Payment marked as complete'),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
  }

  Widget _buildUpiAppButton(Map<String, dynamic> app) {
    return GestureDetector(
      onTap: () => _launchUpiPayment(app),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: (app['color'] as Color).withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: (app['color'] as Color).withOpacity(0.3),
                width: 1.5,
              ),
            ),
            child: Center(
              child: UpiAppIcon(
                appName: app['name'] as String,
                size: 28,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            app['name'] as String,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnim =
        CurvedAnimation(parent: _animController, curve: Curves.elasticOut);
    _animController.forward();
  }

  @override
  void dispose() {
    _feedbackController.dispose();
    _animController.dispose();
    super.dispose();
  }

  String _getRatingLabel() {
    switch (_selectedStars) {
      case 1:
        return 'Poor';
      case 2:
        return 'Below Average';
      case 3:
        return 'Average';
      case 4:
        return 'Good';
      case 5:
        return 'Excellent!';
      default:
        return 'Tap a star to rate';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),

                // Success icon
                ScaleTransition(
                  scale: _scaleAnim,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(25),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle,
                      color: AppColors.success,
                      size: 40,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Title
                const Text(
                  'Ride Completed!',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Thank you for riding with us',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 20),

                // Fare summary card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.inputBackground,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.receipt_long,
                          color: AppColors.textSecondary, size: 20),
                      const SizedBox(width: 8),
                      const Text('Total Fare:',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 14)),
                      const SizedBox(width: 8),
                      Text(
                        '\u20B9${widget.ride.fare.round()}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Pay Now Section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE8E8E8)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _paymentCompleted
                                ? Icons.check_circle
                                : Icons.payment,
                            color: _paymentCompleted
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFD4956A),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _paymentCompleted ? 'Payment Complete' : 'Pay Now',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _paymentCompleted
                                  ? const Color(0xFF4CAF50)
                                  : AppColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          if (!_paymentCompleted)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD4956A).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '\u20B9${widget.ride.fare.round()}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFD4956A),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (!_paymentCompleted) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Choose your preferred payment app',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // UPI App Grid
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: _upiApps
                              .map((app) => _buildUpiAppButton(app))
                              .toList(),
                        ),
                        const SizedBox(height: 16),
                        // Mark as Paid button (for cash payments)
                        Center(
                          child: TextButton.icon(
                            onPressed: _markPaymentComplete,
                            icon: const Icon(Icons.money, size: 18),
                            label: const Text('Paid in Cash'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.grey[600],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Driver info
                if (widget.driver != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.secondary.withAlpha(76),
                        child: Text(
                          widget.driver!.name.isNotEmpty
                              ? widget.driver!.name[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: AppColors.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Rate your ride with ${widget.driver!.name}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  const Text(
                    'Rate your ride',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Interactive star rating
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final starIndex = index + 1;
                    final isSelected = starIndex <= _selectedStars;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _selectedStars = starIndex);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          isSelected
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: isSelected ? 48 : 44,
                          color: isSelected
                              ? AppColors.starYellow
                              : Colors.grey[350],
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),

                // Rating label
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _getRatingLabel(),
                    key: ValueKey(_selectedStars),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _selectedStars > 0
                          ? AppColors.textPrimary
                          : Colors.grey[500],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Feedback text field (shown after selecting stars)
                if (_selectedStars > 0) ...[
                  TextField(
                    controller: _feedbackController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Share your experience (optional)',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: AppColors.inputBackground,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _selectedStars > 0 && !_isSubmitting
                        ? () async {
                            setState(() => _isSubmitting = true);
                            final feedback = _feedbackController.text.trim();
                            await widget.onSubmit(
                              _selectedStars.toDouble(),
                              feedback.isNotEmpty ? feedback : null,
                            );
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey[300],
                      disabledForegroundColor: Colors.grey[500],
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Submit Rating',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
                const SizedBox(height: 12),

                // Skip button
                TextButton(
                  onPressed: _isSubmitting ? null : widget.onSkip,
                  child: Text(
                    'Skip',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 14,
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
}
