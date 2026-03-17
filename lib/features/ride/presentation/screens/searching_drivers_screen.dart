import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/sse_service.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/models/location.dart';
import '../../../auth/providers/auth_provider.dart';

class SearchingDriversScreen extends ConsumerStatefulWidget {
  const SearchingDriversScreen({super.key});

  @override
  ConsumerState<SearchingDriversScreen> createState() => _SearchingDriversScreenState();
}

class _SearchingDriversScreenState extends ConsumerState<SearchingDriversScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  Timer? _pollTimer;
  
  // Google Maps
  final Completer<GoogleMapController> _mapController = Completer();
  
  // Location from provider
  late LatLng _pickupLocation;
  late String _pickupAddress;
  String? _rideId;
  
  // SSE + Socket.io subscription
  SSESubscription? _sseSubscription;
  VoidCallback? _unsubscribeRide;
  bool _driverFound = false;
  
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};

  @override
  void initState() {
    super.initState();
    
    // Get location and ride ID from provider
    final bookingState = ref.read(rideBookingProvider);
    _pickupLocation = bookingState.pickupLocation ?? const LatLng(12.9716, 77.5946);
    _pickupAddress = (bookingState.pickupAddress?.isNotEmpty ?? false)
        ? bookingState.pickupAddress! 
        : 'Your Location';
    _rideId = bookingState.rideId;
    
    debugPrint('🔍 Searching drivers near: $_pickupAddress');
    debugPrint('🔍 Pickup LatLng: ${_pickupLocation.latitude}, ${_pickupLocation.longitude}');
    debugPrint('🔍 Ride ID: $_rideId');
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _setupMapElements();
    _listenForDriverAcceptance();
  }

  void _setupMapElements() {
    _markers = {
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickupLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: _pickupAddress),
      ),
    };
    
    _circles = {
      Circle(
        circleId: const CircleId('searchRadius'),
        center: _pickupLocation,
        radius: 2000,
        fillColor: const Color(0xFFD4956A).withAlpha(25),
        strokeColor: const Color(0xFFD4956A).withAlpha(76),
        strokeWidth: 2,
      ),
    };
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
    debugPrint('🔑 Got auth token for SSE: ${authToken != null ? "yes" : "no"}');

    // Subscribe to Socket.io events for this ride
    _unsubscribeRide = webSocketService.subscribe('ride-status-update', (message) {
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
          debugPrint('⏳ Still waiting... Status: $status');
        }
      } catch (e, stack) {
        debugPrint('❌ Poll error: $e');
        debugPrint('❌ Poll stack: $stack');
      }
    });
  }

  void _onDriverAccepted() {
    if (_driverFound || !mounted) return;
    _driverFound = true;
    
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
        title: const Text('Ride Cancelled'),
        content: Text(reason ?? 'No drivers are available at the moment. Please try again.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.go(AppRoutes.findTrip);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF252525),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Go to home with banner instead of showing cancel dialog
        _goToHomeWithBanner();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: _buildSearchingContent(),
              ),
            ],
          ),
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

  Widget _buildSearchingContent() {
    return Column(
      children: [
        // Map with searching animation
        Expanded(
          flex: 3,
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _pickupLocation,
                      zoom: 14,
                    ),
                    markers: _markers,
                    circles: _circles,
                    onMapCreated: (GoogleMapController controller) {
                      _mapController.complete(controller);
                    },
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                  ),
                ),
                
                // Searching pulse animation overlay
                Center(
                  child: AnimatedBuilder(
                    animation: _animationController,
                    builder: (context, child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // Outer pulse
                          Transform.scale(
                            scale: 1 + (_animationController.value * 0.5),
                            child: Opacity(
                              opacity: 1 - _animationController.value,
                              child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFD4956A),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Inner circle with vehicle image
                          Container(
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
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Status text
        Expanded(
          flex: 1,
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
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
                  _rideId != null ? 'Waiting for a driver to accept...' : 'Connecting...',
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
          ),
        ),
      ],
    );
  }

  void _showCancelDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel Ride?'),
        content: const Text('Are you sure you want to cancel the ride search?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('No, Continue'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Cancel via real-time service + API if we have a ride ID
              if (_rideId != null) {
                realtimeService.cancelRide(_rideId!, reason: 'Cancelled by rider');
                apiClient.cancelRide(_rideId!, reason: 'Cancelled by rider').catchError((_) => <String, dynamic>{});
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
