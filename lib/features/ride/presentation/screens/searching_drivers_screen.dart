import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/sse_service.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/models/location.dart';
import '../../../auth/providers/auth_provider.dart';

class SearchingDriversScreen extends ConsumerStatefulWidget {
  const SearchingDriversScreen({super.key});

  @override
  ConsumerState<SearchingDriversScreen> createState() =>
      _SearchingDriversScreenState();
}

class _SearchingDriversScreenState extends ConsumerState<SearchingDriversScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _matchFoundController;
  late Animation<double> _driverMarkerScaleAnimation;
  Timer? _pollTimer;

  // Google Maps
  final Completer<GoogleMapController> _mapController = Completer();

  // Location from provider
  late LatLng _pickupLocation;
  late String _pickupAddress;
  String? _rideId;

  // SSE + Socket.io subscription
  SSESubscription? _sseSubscription;

  // Map style for dark mode
  String? _mapStyle;
  bool _lastDarkMode = false;
  GoogleMapController? _mapControllerInstance;
  VoidCallback? _unsubscribeRide;
  bool _driverFound = false;

  // Dynamic search radius (meters) for adaptive map zoom
  double _searchRadiusMeters = 500;
  static const double _minSearchRadiusMeters = 500;
  static const double _maxSearchRadiusMeters = 5000;
  static const double _radiusStepMeters = 500;

  Set<Marker> _markers = {};
  Set<Circle> _circles = {};

  @override
  void initState() {
    super.initState();

    // Get location and ride ID from provider
    final bookingState = ref.read(rideBookingProvider);
    
    // CRITICAL: Pickup should ALWAYS be set from GPS before reaching this screen
    if (bookingState.pickupLocation == null) {
      debugPrint('⚠️ WARNING: pickupLocation is null in searching_drivers_screen!');
      debugPrint('   This should not happen - GPS location should be set earlier');
    }
    
    _pickupLocation = bookingState.pickupLocation ?? const LatLng(28.4595, 77.0266); // Fallback only for safety
    _pickupAddress = (bookingState.pickupAddress?.isNotEmpty ?? false)
        ? bookingState.pickupAddress!
        : 'Your Location';
    _rideId = bookingState.rideId;

    debugPrint('🔍 Searching drivers near: $_pickupAddress');
    debugPrint(
        '🔍 Pickup LatLng: ${_pickupLocation.latitude}, ${_pickupLocation.longitude}');
    debugPrint('🔍 Ride ID: $_rideId');

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _matchFoundController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _driverMarkerScaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _matchFoundController, curve: Curves.easeOutBack),
    );

    _setupMapElements();
    _loadMapStyle();
    _listenForDriverAcceptance();
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
          '🗺️ Searching drivers map style loaded: ${isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  void _setupMapElements() {
    _markers = {}; // Pickup marker removed per design

    _circles = {
      Circle(
        circleId: const CircleId('searchRadius'),
        center: _pickupLocation,
        radius: _searchRadiusMeters,
        fillColor: const Color(0xFFD4956A).withAlpha(25),
        strokeColor: const Color(0xFFD4956A).withAlpha(76),
        strokeWidth: 2,
      ),
    };
  }

  bool _isSameLatLng(LatLng a, LatLng b) {
    const epsilon = 0.000001;
    return (a.latitude - b.latitude).abs() < epsilon &&
        (a.longitude - b.longitude).abs() < epsilon;
  }

  double _getZoomLevel(double radiusMeters) {
    if (radiusMeters <= 0) return 16;
    final zoom = 16 - (math.log(radiusMeters / 500) / math.log(2));
    return zoom.clamp(10.0, 18.0);
  }

  Future<void> _updateCamera({
    LatLng? center,
    double? radiusMeters,
    double? zoomOverride,
  }) async {
    final controller = _mapControllerInstance;
    if (controller == null) return;

    final target = center ?? _pickupLocation;
    final radius = (radiusMeters ?? _searchRadiusMeters)
        .clamp(_minSearchRadiusMeters, _maxSearchRadiusMeters);
    final zoom = (zoomOverride ?? _getZoomLevel(radius)).clamp(10.0, 18.0);

    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: zoom,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Map camera animation failed: $e');
    }
  }

  void _setSearchRadius(
    double radiusMeters, {
    String reason = 'update',
  }) {
    final normalized =
        radiusMeters.clamp(_minSearchRadiusMeters, _maxSearchRadiusMeters);
    if ((normalized - _searchRadiusMeters).abs() < 1) {
      _updateCamera(radiusMeters: normalized);
      return;
    }

    if (!mounted) return;
    setState(() {
      _searchRadiusMeters = normalized;
      _setupMapElements();
    });
    _updateCamera(radiusMeters: normalized);
    debugPrint(
        '🔎 Search radius -> ${normalized.toStringAsFixed(0)}m ($reason)');
  }

  void _expandSearchRadius() {
    final nextRadius = (_searchRadiusMeters + _radiusStepMeters)
        .clamp(_minSearchRadiusMeters, _maxSearchRadiusMeters);
    _setSearchRadius(nextRadius, reason: 'expand');
  }

  double? _extractSearchRadiusFromRideData(Map<String, dynamic> rideData) {
    final dynamic rawRadius = rideData['searchRadius'] ??
        rideData['search_radius'] ??
        rideData['driverSearchRadius'] ??
        rideData['driver_search_radius'];

    if (rawRadius is num) return rawRadius.toDouble();
    if (rawRadius is String) return double.tryParse(rawRadius);
    return null;
  }

  bool _hasNearbyDrivers(Map<String, dynamic> rideData) {
    final dynamic nearby = rideData['nearbyDrivers'] ??
        rideData['nearby_drivers'] ??
        rideData['drivers'];
    if (nearby is List) return nearby.isNotEmpty;
    if (nearby is num) return nearby > 0;
    return false;
  }

  void _handlePickupLocationChange(LatLng newPickup, String? newAddress) {
    if (_isSameLatLng(newPickup, _pickupLocation)) return;
    if (!mounted) return;
    setState(() {
      _pickupLocation = newPickup;
      _pickupAddress =
          (newAddress?.isNotEmpty ?? false) ? newAddress! : _pickupAddress;
      _setupMapElements();
    });
    _updateCamera(center: newPickup, radiusMeters: _searchRadiusMeters);
    debugPrint(
        '📍 Pickup updated during search: ${newPickup.latitude}, ${newPickup.longitude}');
  }

  String _getVehicleImage(String cabTypeId) {
    switch (cabTypeId) {
      case 'bike_rescue':
        return 'assets/vehicles/bike_rescue.png';
      case 'auto':
        return 'assets/vehicles/auto.png';
      case 'cab_mini':
        return 'assets/vehicles/cab_mini.png';
      case 'cab_xl':
        return 'assets/vehicles/cab_xl.png';
      case 'cab_premium':
        return 'assets/vehicles/cab_premium.png';
      default:
        return 'assets/vehicles/cab_mini.png';
    }
  }

  /// Listen for ride acceptance via SSE (primary) + Socket.io + poll API as fallback
  Future<void> _listenForDriverAcceptance() async {
    if (_rideId == null || _rideId!.isEmpty) {
      debugPrint('⚠️ No ride ID found, cannot listen for acceptance');
      return;
    }

    // Get auth token for SSE connection
    final secureStorage = ref.read(secureStorageProvider);
    final authToken = await secureStorage.read(key: 'auth_token');
    debugPrint(
        '🔑 Got auth token for SSE: ${authToken != null ? "yes" : "no"}');

    // Subscribe to Socket.io events for this ride
    _unsubscribeRide =
        webSocketService.subscribe('ride-status-update', (message) {
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;

      final eventRideId = data['rideId']?.toString() ?? '';
      if (eventRideId != _rideId) return;

      final status = (data['status'] ?? '').toString().toUpperCase();
      debugPrint('🔌 Socket ride-status-update: $status for ride $eventRideId');

      if (status == 'DRIVER_ASSIGNED' ||
          status == 'CONFIRMED' ||
          status == 'ACCEPTED') {
        _onDriverAccepted();
      }
    });

    // Also listen for driver_assigned event specifically
    webSocketService.subscribe('driver_assigned', (message) {
      final data = message.data as Map<String, dynamic>?;
      if (data == null) return;

      final eventRideId = data['rideId']?.toString() ?? '';
      if (eventRideId == _rideId) {
        debugPrint('🔌 Socket driver_assigned event for ride $eventRideId');
        _onDriverAccepted();
      }
    });

    // Primary: SSE ride stream - pass auth token
    _sseSubscription = realtimeService.connectRide(
      _rideId!,
      token: authToken,
      onEvent: (type, data) {
        debugPrint('📡 SSE ride event: $type, data: $data');
        switch (type) {
          case 'status_update':
            final status = (data['status'] as String? ?? '').toUpperCase();
            debugPrint('📡 Status update received: $status');
            if (status == 'DRIVER_ASSIGNED' ||
                status == 'CONFIRMED' ||
                status == 'DRIVER_ARRIVED' ||
                status == 'ACCEPTED' ||
                status == 'ARRIVING' ||
                status == 'DRIVER_ARRIVING') {
              _onDriverAccepted();
            }
            break;
          case 'driver_assigned':
            debugPrint('📡 Driver assigned event received!');
            _onDriverAccepted();
            break;
          case 'ride_accepted':
            debugPrint('📡 Ride accepted event received!');
            _onDriverAccepted();
            break;
          case 'cancelled':
            _onRideCancelled(data['reason'] as String?);
            break;
        }
      },
    );

    // REAL-TIME FIRST: Poll REST API every 10 seconds as a fallback ONLY.
    // Primary updates come via SSE/Socket.io events above.
    // This is just for network hiccups or missed events.
    debugPrint('🔄 Starting fallback poll timer (10s) for ride: $_rideId');
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_driverFound) {
        debugPrint('🔄 Poll skipped - driver already found');
        return;
      }
      if (_rideId == null || _rideId!.isEmpty) {
        debugPrint('❌ Poll skipped - no ride ID');
        return;
      }
      try {
        debugPrint('🔄 Polling ride status for: $_rideId');
        final response = await apiClient.getRide(_rideId!);
        debugPrint('🔄 Poll response: $response');

        // Backend returns: { success: true, data: { status: "DRIVER_ASSIGNED", ... } }
        final rideData = response['data'] as Map<String, dynamic>? ?? response;
        final status = (rideData['status'] ?? '').toString().toUpperCase();
        final driverId = rideData['driverId'] ?? rideData['driver_id'];
        final backendRadius = _extractSearchRadiusFromRideData(rideData);
        final hasNearbyDrivers = _hasNearbyDrivers(rideData);
        debugPrint('📡 Poll ride status: $status, driverId: $driverId');

        // Check for driver assigned status (backend uses DRIVER_ASSIGNED)
        if (status == 'DRIVER_ASSIGNED' ||
            status == 'CONFIRMED' ||
            status == 'DRIVER_ARRIVED' ||
            status == 'RIDE_STARTED' ||
            status == 'IN_PROGRESS') {
          debugPrint('✅ Driver found! Status: $status, driverId: $driverId');
          _onDriverAccepted();
        } else if (status == 'CANCELLED' || status == 'CANCELED') {
          debugPrint('❌ Ride cancelled');
          _onRideCancelled(null);
        } else {
          if (backendRadius != null) {
            _setSearchRadius(backendRadius, reason: 'backend');
          } else {
            _expandSearchRadius();
          }
          if (hasNearbyDrivers) {
            _updateCamera(radiusMeters: _searchRadiusMeters);
          }
          debugPrint('⏳ Still waiting... Status: $status');
        }
      } catch (e, stack) {
        debugPrint('❌ Poll error: $e');
        debugPrint('❌ Poll stack: $stack');
      }
    });
  }

  Future<void> _animateMatchFoundMoment() async {
    // Stop radar loop immediately once a driver is matched.
    _animationController.stop();
    await _updateCamera(
      center: _pickupLocation,
      zoomOverride: _getZoomLevel(_searchRadiusMeters) + 0.5,
    );
    if (!mounted) return;
    await _matchFoundController.forward(from: 0);
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  void _onDriverAccepted() async {
    if (_driverFound || !mounted) return;
    setState(() {
      _driverFound = true;
    });

    debugPrint('🎉 Driver accepted! Navigating to driver assigned screen...');

    // Set the active ride so the banner shows the correct phase (driver arriving)
    if (_rideId != null) {
      final booking = ref.read(rideBookingProvider);
      ref.read(activeRideProvider.notifier).setActiveRide(
            Ride(
              id: _rideId!,
              riderId: '',
              status: RideStatus.accepted,
              pickupLocation: AddressLocation(
                latitude: booking.pickupLocation?.latitude ?? 0,
                longitude: booking.pickupLocation?.longitude ?? 0,
                address: booking.pickupAddress ?? 'Pickup',
              ),
              destinationLocation: AddressLocation(
                latitude: booking.destinationLocation?.latitude ?? 0,
                longitude: booking.destinationLocation?.longitude ?? 0,
                address: booking.destinationAddress ?? 'Destination',
              ),
              fare: 0,
              distance: 0,
              estimatedDuration: 0,
              rideType: 'standard',
              paymentMethod: PaymentMethod.cash,
              createdAt: DateTime.now(),
            ),
          );
    }

    await _animateMatchFoundMoment();
    if (!mounted) return;
    context.pushReplacement(AppRoutes.driverAssigned);
  }

  void _onRideCancelled(String? reason) {
    if (!mounted) return;
    // Clear ride state so the banner disappears
    ref.read(activeRideProvider.notifier).clearActiveRide();
    ref.read(rideBookingProvider.notifier).reset();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(ref.tr('ride_cancelled')),
        content: Text(reason ??
            'No drivers are available at the moment. Please try again.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.go(AppRoutes.findTrip);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF252525),
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

  @override
  void dispose() {
    _animationController.dispose();
    _matchFoundController.dispose();
    _pollTimer?.cancel();
    _sseSubscription?.cancel();
    _unsubscribeRide?.call();
    super.dispose();
  }

  /// Navigate to home while keeping the ride search active (banner will show)
  void _goToHomeWithBanner() {
    // Don't cancel the ride - just go to home page
    // The active ride banner will show the searching status
    context.go(AppRoutes.services);
  }

  @override
  Widget build(BuildContext context) {
    final bookingState = ref.watch(rideBookingProvider);
    final providerPickup = bookingState.pickupLocation;
    if (providerPickup != null &&
        !_isSameLatLng(providerPickup, _pickupLocation)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handlePickupLocationChange(providerPickup, bookingState.pickupAddress);
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Go to home with banner instead of showing cancel dialog
        _goToHomeWithBanner();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            Positioned.fill(child: _buildMapLayer()),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: _buildHeader(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _buildStatusPanel(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () {
              // Back arrow goes to home with banner
              _goToHomeWithBanner();
            },
            child: const Icon(Icons.arrow_back, color: Color(0xFF1A1A1A)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'Rescue',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }

  Widget _buildMapLayer() {
    return Stack(
      children: [
        Positioned.fill(
          child: Builder(
            builder: (context) {
              // Watch dark mode changes
              final isDarkMode = ref.watch(settingsProvider).isDarkMode;
              if (isDarkMode != _lastDarkMode) {
                _lastDarkMode = isDarkMode;
                _loadMapStyle();
              }
              return GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: _pickupLocation,
                  zoom: 14,
                ),
                markers: _markers,
                circles: _circles,
                onMapCreated: (GoogleMapController controller) {
                  _mapController.complete(controller);
                  _mapControllerInstance = controller;
                  // Apply map style
                  if (_mapStyle != null) {
                    controller.setMapStyle(_mapStyle);
                  }
                  _updateCamera(
                    center: _pickupLocation,
                    radiusMeters: _searchRadiusMeters,
                  );
                },
                myLocationEnabled: false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                padding: const EdgeInsets.only(top: 90, bottom: 210),
              );
            },
          ),
        ),
        Center(
          child: _driverFound
              ? ScaleTransition(
                  scale: _driverMarkerScaleAnimation,
                  child: _buildRadarDriverIcon(),
                )
              : _buildSearchingRadar(),
        ),
      ],
    );
  }

  Widget _buildSearchingRadar() {
    const basePulseDiameter = 140.0;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _animationController,
        child: _buildRadarDriverIcon(),
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              _buildRadarPulse(basePulseDiameter, 0.0),
              _buildRadarPulse(basePulseDiameter, 0.33),
              _buildRadarPulse(basePulseDiameter, 0.66),
              if (child != null) child,
            ],
          );
        },
      ),
    );
  }

  Widget _buildRadarPulse(double baseDiameter, double phaseShift) {
    final progress = (_animationController.value + phaseShift) % 1.0;
    final eased = Curves.easeOut.transform(progress);
    final scale = 0.5 + eased; // 0.5x -> 1.5x
    final pulseDiameter = baseDiameter * scale;
    final fade = (0.22 * (1 - eased)).clamp(0.0, 0.22);
    final pulseColor = const Color(0xFFD4956A).withAlpha((255 * fade).round());
    final strokeColor =
        const Color(0xFFD4956A).withAlpha((255 * (fade * 1.6)).round());

    return IgnorePointer(
      child: Container(
        width: pulseDiameter,
        height: pulseDiameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pulseColor,
          border: Border.all(color: strokeColor, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildRadarDriverIcon() {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD4956A).withAlpha(76),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipOval(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset(
            _getVehicleImage(ref.read(rideBookingProvider).selectedCabTypeId),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.two_wheeler,
              color: Color(0xFFD4956A),
              size: 32,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPanel() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Looking for nearby drivers',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _rideId != null
                ? 'Waiting for a driver to accept...'
                : 'Connecting...',
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF888888),
            ),
          ),
          const SizedBox(height: 12),
          // Loading dots animation
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (index) {
              return AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  final delay = index * 0.2;
                  final progress = (_animationController.value + delay) % 1.0;
                  final opacity = math.sin(progress * math.pi);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Color.fromRGBO(212, 149, 106, opacity),
                      shape: BoxShape.circle,
                    ),
                  );
                },
              );
            }),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _showCancelDialog,
            child: const Text(
              'Cancel Search',
              style: TextStyle(
                color: Color(0xFF888888),
                fontSize: 14,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
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
        content: Text(ref.tr('cancel_ride_search')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ref.tr('no_continue')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Cancel via real-time service + API if we have a ride ID
              if (_rideId != null) {
                realtimeService.cancelRide(_rideId!,
                    reason: 'Cancelled by rider');
                apiClient
                    .cancelRide(_rideId!, reason: 'Cancelled by rider')
                    .catchError((_) => <String, dynamic>{});
              }
              // Clear ride state so banner disappears
              ref.read(activeRideProvider.notifier).clearActiveRide();
              ref.read(rideBookingProvider.notifier).reset();
              // Navigate directly to home page
              context.go(AppRoutes.services);
            },
            child: const Text(
              'Yes, Cancel',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}
