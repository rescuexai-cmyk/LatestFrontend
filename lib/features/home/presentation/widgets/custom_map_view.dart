import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/models/driver.dart';
import '../../../../core/models/location.dart';
import '../../../../core/services/maps_service.dart';
import '../../../../core/services/car_animation_service.dart';
import '../../../../core/config/app_config.dart';

/// Ride phase enum for determining route display
enum RidePhase {
  searching,       // Looking for driver
  driverArriving,  // Driver accepted, coming to pickup
  rideInProgress,  // Ride started, going to destination
  completed,       // Ride completed
}

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

class CustomMapView extends StatefulWidget {
  final String? rideId;
  final List<Driver> drivers;
  final LocationCoordinate? pickupLocation;
  final LocationCoordinate? dropoffLocation;
  final LocationCoordinate? currentUserLocation;
  final String userType;
  final bool showUserLocation;
  final bool followUserLocation;
  final bool showTraffic;
  final int searchRadius;
  final Function(Driver)? onDriverPress;
  final Function(LatLng)? onLocationPress;
  final Function(CameraPosition)? onRegionChange;
  final bool rideInProgress;
  final RidePhase ridePhase;
  final LocationCoordinate? driverLocation;
  final double? driverHeading;
  final bool followDriverLocation;
  final bool animateDriver;
  final Function(double distance, int etaMinutes)? onDriverDistanceUpdate;
  final String? vehicleType; // 'bike', 'auto', 'cab', 'cab-mini', 'cab-premium'
  final bool isDarkMode; // Use dark map style

  const CustomMapView({
    super.key,
    this.rideId,
    this.drivers = const [],
    this.pickupLocation,
    this.dropoffLocation,
    this.currentUserLocation,
    this.userType = 'rider',
    this.showUserLocation = true,
    this.followUserLocation = false,
    this.showTraffic = false,
    this.searchRadius = 5000,
    this.onDriverPress,
    this.onLocationPress,
    this.onRegionChange,
    this.rideInProgress = false,
    this.ridePhase = RidePhase.searching,
    this.driverLocation,
    this.driverHeading,
    this.followDriverLocation = false,
    this.animateDriver = true,
    this.onDriverDistanceUpdate,
    this.vehicleType,
    this.isDarkMode = false,
  });

  @override
  State<CustomMapView> createState() => _CustomMapViewState();
}

class _CustomMapViewState extends State<CustomMapView> with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  Set<Circle> _circles = {};
  LocationCoordinate? _userLocation;
  bool _isMapReady = false;
  String? _mapStyle;
  
  // Custom marker icons
  BitmapDescriptor? _vehicleIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropoffIcon;
  String? _loadedVehicleType; // Track which vehicle type icon is loaded
  
  // Uber-style car animation
  CarAnimationService? _carAnimationService;
  LatLng? _animatedDriverPosition;
  double _animatedDriverBearing = 0;
  
  // Route management for progressive polyline
  List<LatLng> _fullRoutePoints = [];
  List<LatLng> _remainingRoutePoints = [];
  List<LatLng> _traveledRoutePoints = [];
  DateTime? _lastRouteRecalculation;
  DateTime? _lastFollowCameraUpdate;
  static const _routeRecalculationThreshold = 50.0; // meters
  static const _routeRecalculationCooldown = Duration(seconds: 10);
  static const _cameraFollowCooldown = Duration(milliseconds: 150);
  
  // Driver distance tracking
  double _driverDistanceMeters = 0;
  int _driverEtaMinutes = 0;
  RidePhase? _lastRidePhase;
  
  // Production-grade camera state
  double _currentCameraZoom = 15.5;
  double _currentCameraTilt = 35.0;
  double _currentCameraBearing = 0;
  bool _isFirstCameraUpdate = true;
  DateTime? _lastCameraTiltUpdate;

  // Raahi brand colors
  static const Color _primaryColor = Color(0xFFD4A574);
  static const Color _accentColor = Color(0xFF1A1A2E);
  static const Color _routeColor = Color(0xFFD4A574);
  static const Color _routeBorderColor = Color(0xFF8B6914);
  static const Color _traveledRouteColor = Color(0xFF9CA3AF);
  static const Color _driverArrivingRouteColor = Color(0xFF4CAF50);

  @override
  void initState() {
    super.initState();
    _loadMapStyle();
    _getCurrentLocation();
    _loadCustomIcons();
    _initCarAnimation();
    
    if (widget.driverLocation != null) {
      _animatedDriverPosition = LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng);
      _animatedDriverBearing = widget.driverHeading ?? 0;
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_carAnimationService != null && widget.driverLocation != null) {
          _carAnimationService!.updateLocation(
            LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng),
            heading: widget.driverHeading,
          );
        }
        // Calculate initial route based on phase
        _calculateRouteForPhase();
      });
    }
  }

  Future<void> _loadMapStyle() async {
    try {
      // Use widget's isDarkMode setting (from app settings) instead of system brightness
      final stylePath = widget.isDarkMode 
          ? 'assets/map_styles/raahi_dark.json'
          : 'assets/map_styles/raahi_light.json';
      _mapStyle = await rootBundle.loadString(stylePath);
      if (_mapController != null && _mapStyle != null) {
        _mapController!.setMapStyle(_mapStyle);
      }
      debugPrint('🗺️ Map style loaded: ${widget.isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  void _initCarAnimation() {
    _carAnimationService = CarAnimationService(
      vsync: this,
      animationDuration: const Duration(milliseconds: 1200),
      onUpdate: (position, bearing) {
        if (mounted) {
          setState(() {
            _animatedDriverPosition = position;
            _animatedDriverBearing = bearing;
          });
          // Update progressive polyline as car animates
          if (_fullRoutePoints.isNotEmpty) {
            _updateProgressivePolyline(position);
          }
          _updateDriverDistance(position);
          _updateMarkers();
          if (widget.followDriverLocation) {
            _smoothFollowDriver(position, bearing: bearing);
          }
        }
      },
    );
    _carAnimationService!.init();
  }

  Future<void> _loadCustomIcons() async {
    await _loadVehicleIcon(widget.vehicleType);
  }
  
  Future<void> _loadVehicleIcon(String? vehicleType) async {
    // Normalize vehicle type
    final normalizedType = _normalizeVehicleType(vehicleType);
    
    // Skip if already loaded for this type
    if (_loadedVehicleType == normalizedType && _vehicleIcon != null) return;
    
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
          assetPath = 'assets/map_icons/icon_cab_premium.png';
          break;
        case 'cab':
        case 'cab-mini':
        default:
          assetPath = 'assets/map_icons/icon_cab.png';
          break;
      }
      
      // Uber/Rapido style: ~40-50 logical pixels, with device pixel ratio for crisp rendering
      // The actual image is larger, Flutter will scale it down appropriately
      _vehicleIcon = await BitmapDescriptor.asset(
        const ImageConfiguration(size: Size(44, 44), devicePixelRatio: 2.5),
        assetPath,
      );
      _loadedVehicleType = normalizedType;
      if (mounted) _updateMarkers();
      debugPrint('🚗 Vehicle icon loaded from asset: $assetPath');
    } catch (e) {
      debugPrint('Failed to load vehicle icon asset: $e, falling back to default');
      // Fallback to programmatically created icon
      try {
        _vehicleIcon = await _createTopViewCarIcon();
        _loadedVehicleType = normalizedType;
        if (mounted) _updateMarkers();
      } catch (e2) {
        debugPrint('Fallback icon creation also failed: $e2');
        _vehicleIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
        if (mounted) _updateMarkers();
      }
    }
  }
  
  String _normalizeVehicleType(String? type) {
    if (type == null || type.isEmpty) return 'cab';
    final lower = type.toLowerCase().trim();
    // Check for bike rescue first (before generic bike check)
    if (lower.contains('rescue') || lower == 'bike_rescue') return 'bike-rescue';
    if (lower.contains('bike') || lower.contains('moto')) return 'bike';
    if (lower.contains('auto') || lower.contains('rickshaw')) return 'auto';
    if (lower.contains('premium') || lower.contains('suv')) return 'cab-premium';
    if (lower.contains('xl')) return 'cab-xl';
    if (lower.contains('mini') || lower.contains('hatch')) return 'cab-mini';
    return 'cab';
  }

  Future<BitmapDescriptor> _createTopViewCarIcon() async {
    const double size = 120;
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    
    // Car body shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2 + 2, size/2 + 3), width: 45, height: 75),
        const Radius.circular(12),
      ),
      shadowPaint,
    );
    
    // Car body - main
    final bodyPaint = Paint()
      ..color = _primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2), width: 44, height: 72),
        const Radius.circular(10),
      ),
      bodyPaint,
    );
    
    // Car body - border/outline
    final borderPaint = Paint()
      ..color = _routeBorderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2), width: 44, height: 72),
        const Radius.circular(10),
      ),
      borderPaint,
    );
    
    // Windshield (front)
    final windshieldPaint = Paint()
      ..color = const Color(0xFF87CEEB).withOpacity(0.8)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2 - 18), width: 32, height: 16),
        const Radius.circular(4),
      ),
      windshieldPaint,
    );
    
    // Rear windshield
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2 + 22), width: 28, height: 12),
        const Radius.circular(3),
      ),
      windshieldPaint,
    );
    
    // Headlights
    final headlightPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size/2 - 12, size/2 - 32), 5, headlightPaint);
    canvas.drawCircle(Offset(size/2 + 12, size/2 - 32), 5, headlightPaint);
    
    // Taillights
    final taillightPaint = Paint()
      ..color = Colors.red.shade700
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2 - 14, size/2 + 33), width: 8, height: 6),
        const Radius.circular(2),
      ),
      taillightPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2 + 14, size/2 + 33), width: 8, height: 6),
        const Radius.circular(2),
      ),
      taillightPaint,
    );
    
    // Roof detail
    final roofPaint = Paint()
      ..color = _primaryColor.withOpacity(0.7)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2 + 2), width: 24, height: 20),
        const Radius.circular(4),
      ),
      roofPaint,
    );
    
    final picture = pictureRecorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  /// Create top-view bike/motorcycle icon
  Future<BitmapDescriptor> _createBikeIcon() async {
    const double size = 100;
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    
    // Shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2 + 2, size/2 + 3), width: 28, height: 60),
      shadowPaint,
    );
    
    // Bike body (elongated oval)
    final bodyPaint = Paint()
      ..color = const Color(0xFF2196F3) // Blue for bike
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2, size/2), width: 24, height: 55),
      bodyPaint,
    );
    
    // Border
    final borderPaint = Paint()
      ..color = const Color(0xFF1565C0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2, size/2), width: 24, height: 55),
      borderPaint,
    );
    
    // Front wheel (top)
    final wheelPaint = Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2, size/2 - 22), width: 18, height: 10),
      wheelPaint,
    );
    
    // Rear wheel (bottom)
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2, size/2 + 22), width: 18, height: 10),
      wheelPaint,
    );
    
    // Headlight
    final headlightPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size/2, size/2 - 26), 4, headlightPaint);
    
    // Taillight
    final taillightPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size/2, size/2 + 26), 3, taillightPaint);
    
    // Handlebar
    final handlePaint = Paint()
      ..color = const Color(0xFF555555)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size/2 - 12, size/2 - 18),
      Offset(size/2 + 12, size/2 - 18),
      handlePaint,
    );
    
    final picture = pictureRecorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  /// Create top-view auto-rickshaw icon
  Future<BitmapDescriptor> _createAutoIcon() async {
    const double size = 110;
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    
    // Shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2 + 2, size/2 + 3), width: 42, height: 58),
        const Radius.circular(8),
      ),
      shadowPaint,
    );
    
    // Auto body - distinctive green/yellow
    final bodyPaint = Paint()
      ..color = const Color(0xFF4CAF50) // Green for auto
      ..style = PaintingStyle.fill;
    
    // Main body (trapezoid-ish shape)
    final bodyPath = Path();
    bodyPath.moveTo(size/2 - 18, size/2 - 25); // Top left
    bodyPath.lineTo(size/2 + 18, size/2 - 25); // Top right
    bodyPath.lineTo(size/2 + 20, size/2 + 25); // Bottom right
    bodyPath.lineTo(size/2 - 20, size/2 + 25); // Bottom left
    bodyPath.close();
    canvas.drawPath(bodyPath, bodyPaint);
    
    // Border
    final borderPaint = Paint()
      ..color = const Color(0xFF2E7D32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(bodyPath, borderPaint);
    
    // Roof/canopy (darker shade)
    final roofPaint = Paint()
      ..color = const Color(0xFF388E3C)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size/2, size/2 - 5), width: 30, height: 28),
        const Radius.circular(4),
      ),
      roofPaint,
    );
    
    // Front wheel (single wheel at top)
    final wheelPaint = Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2, size/2 - 28), width: 14, height: 8),
      wheelPaint,
    );
    
    // Rear wheels (two at bottom)
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2 - 14, size/2 + 22), width: 12, height: 7),
      wheelPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size/2 + 14, size/2 + 22), width: 12, height: 7),
      wheelPaint,
    );
    
    // Headlight
    final headlightPaint = Paint()
      ..color = Colors.yellow.shade200
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size/2, size/2 - 24), 4, headlightPaint);
    
    // Handlebar
    final handlePaint = Paint()
      ..color = const Color(0xFF555555)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size/2 - 10, size/2 - 20),
      Offset(size/2 + 10, size/2 - 20),
      handlePaint,
    );
    
    final picture = pictureRecorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  @override
  void didUpdateWidget(CustomMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    final rideId = widget.rideId ?? 'unknown';
    
    // Check if dark mode changed - reload map style
    if (widget.isDarkMode != oldWidget.isDarkMode) {
      _loadMapStyle();
    }
    
    // Check if vehicle type changed - reload appropriate icon
    if (widget.vehicleType != oldWidget.vehicleType) {
      _loadVehicleIcon(widget.vehicleType);
    }
    
    // CRITICAL: Detect ride phase change - recalculate route immediately
    // This handles the OTP verification -> ride started transition
    if (widget.ridePhase != oldWidget.ridePhase) {
      debugPrint(
        '🔄 [Phase] PHASE CHANGED '
        'rideId=$rideId '
        'from=${oldWidget.ridePhase} '
        'to=${widget.ridePhase}',
      );
      _lastRidePhase = oldWidget.ridePhase;
      
      // Clear existing route before calculating new one
      setState(() {
        _fullRoutePoints = [];
        _remainingRoutePoints = [];
        _traveledRoutePoints = [];
        _polylines = {};
      });
      
      // Calculate new route for the updated phase
      _calculateRouteForPhase();
      
      // Animate camera for new phase with appropriate transition
      if (widget.ridePhase == RidePhase.driverArriving) {
        debugPrint('🔄 [Phase] Animating camera: driver → pickup');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _animateToShowDriverAndPickup();
        });
      } else if (widget.ridePhase == RidePhase.rideInProgress) {
        debugPrint('🔄 [Phase] Animating camera: driver → dropoff (RIDE STARTED)');
        // Reset camera state for new phase
        _isFirstCameraUpdate = false;
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _animateToShowRoute();
        });
      }
    }
    
    // Legacy rideInProgress support
    if (widget.rideInProgress && !oldWidget.rideInProgress) {
      _animateToRideView();
    }
    
    // Pickup or dropoff changed
    if (widget.pickupLocation != oldWidget.pickupLocation ||
        widget.dropoffLocation != oldWidget.dropoffLocation) {
      debugPrint('🗺️ [Location] Pickup/dropoff changed, recalculating route');
      _calculateRouteForPhase();
    }
    
    // First time receiving driver location - calculate route
    if (widget.driverLocation != null && oldWidget.driverLocation == null) {
      debugPrint(
        '🗺️ [Location] First driver location received '
        '(${widget.driverLocation!.lat.toStringAsFixed(5)}, ${widget.driverLocation!.lng.toStringAsFixed(5)})',
      );
      _calculateRouteForPhase();
      if (widget.pickupLocation != null) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) _animateToShowDriverAndPickup();
        });
      }
    }
    
    // Driver location updated - animate marker and camera
    if (widget.driverLocation != oldWidget.driverLocation && widget.driverLocation != null) {
      final newDriverPos = LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng);

      // Trigger smooth animation. The animation service handles interruption safely.
      if (widget.animateDriver && _carAnimationService != null) {
        final previousPos = _animatedDriverPosition ??
            (oldWidget.driverLocation != null
                ? LatLng(oldWidget.driverLocation!.lat, oldWidget.driverLocation!.lng)
                : newDriverPos);
        final distance = CarAnimationService.calculateDistance(previousPos, newDriverPos);
        final calculatedBearing = widget.driverHeading ??
            (distance > 1
                ? CarAnimationService.calculateBearing(previousPos, newDriverPos)
                : _animatedDriverBearing);

        _carAnimationService!.updateLocation(
          newDriverPos,
          heading: widget.driverHeading,
        );

        debugPrint(
          '🚕 [Marker] Driver position update '
          'rideId=$rideId '
          'phase=${widget.ridePhase} '
          'distance=${distance.toStringAsFixed(1)}m '
          'lat=${newDriverPos.latitude.toStringAsFixed(5)} '
          'lng=${newDriverPos.longitude.toStringAsFixed(5)} '
          'bearing=${calculatedBearing.toStringAsFixed(0)}° '
          'animation=${_carAnimationService!.lastAnimationDurationMs}ms',
        );
      } else {
        setState(() {
          _animatedDriverPosition = newDriverPos;
          _animatedDriverBearing = widget.driverHeading ?? _animatedDriverBearing;
        });
        _updateDriverDistance(newDriverPos);
        if (widget.followDriverLocation) {
          _smoothFollowDriver(newDriverPos, bearing: _animatedDriverBearing);
        }
        _updateMarkers();
      }

      // Check if driver deviated from route - recalculate if needed
      if (_fullRoutePoints.isNotEmpty) {
        _checkAndRecalculateRoute(newDriverPos);
      }
    }
    
    if (widget.drivers != oldWidget.drivers ||
        widget.pickupLocation != oldWidget.pickupLocation ||
        widget.dropoffLocation != oldWidget.dropoffLocation ||
        widget.driverLocation != oldWidget.driverLocation ||
        widget.driverHeading != oldWidget.driverHeading) {
      _updateMarkers();
    }
  }
  
  /// Calculate route based on current ride phase
  /// This is the core routing logic that determines which route to display
  Future<void> _calculateRouteForPhase() async {
    final rideId = widget.rideId ?? 'unknown';
    debugPrint('🗺️ [Route] Calculating route for phase: ${widget.ridePhase}, rideId=$rideId');
    
    switch (widget.ridePhase) {
      case RidePhase.searching:
        // Show route from pickup to destination (preview)
        if (widget.pickupLocation != null && widget.dropoffLocation != null) {
          debugPrint('🗺️ [Route] SEARCHING: pickup → destination (preview)');
          await _calculateRouteBetween(
            widget.pickupLocation!,
            widget.dropoffLocation!,
            isDriverArriving: false,
          );
        }
        break;
        
      case RidePhase.driverArriving:
        // Show route from driver to pickup
        if (widget.driverLocation != null && widget.pickupLocation != null) {
          debugPrint(
            '🗺️ [Route] DRIVER_ARRIVING: driver → pickup '
            '(driver: ${widget.driverLocation!.lat.toStringAsFixed(5)}, ${widget.driverLocation!.lng.toStringAsFixed(5)}) '
            '(pickup: ${widget.pickupLocation!.lat.toStringAsFixed(5)}, ${widget.pickupLocation!.lng.toStringAsFixed(5)})',
          );
          await _calculateRouteBetween(
            widget.driverLocation!,
            widget.pickupLocation!,
            isDriverArriving: true,
          );
        } else {
          debugPrint('🗺️ [Route] DRIVER_ARRIVING: Missing driver or pickup location');
        }
        break;
        
      case RidePhase.rideInProgress:
        // Show route from driver to destination (CRITICAL: Route switches after OTP)
        if (widget.driverLocation != null && widget.dropoffLocation != null) {
          debugPrint(
            '🗺️ [Route] RIDE_IN_PROGRESS: driver → destination '
            '(driver: ${widget.driverLocation!.lat.toStringAsFixed(5)}, ${widget.driverLocation!.lng.toStringAsFixed(5)}) '
            '(drop: ${widget.dropoffLocation!.lat.toStringAsFixed(5)}, ${widget.dropoffLocation!.lng.toStringAsFixed(5)})',
          );
          await _calculateRouteBetween(
            widget.driverLocation!,
            widget.dropoffLocation!,
            isDriverArriving: false,
          );
        } else if (widget.pickupLocation != null && widget.dropoffLocation != null) {
          debugPrint('🗺️ [Route] RIDE_IN_PROGRESS: fallback pickup → destination');
          await _calculateRouteBetween(
            widget.pickupLocation!,
            widget.dropoffLocation!,
            isDriverArriving: false,
          );
        } else {
          debugPrint('🗺️ [Route] RIDE_IN_PROGRESS: Missing required locations');
        }
        break;
        
      case RidePhase.completed:
        // Clear route
        debugPrint('🗺️ [Route] COMPLETED: Clearing all routes');
        setState(() {
          _polylines = {};
          _fullRoutePoints = [];
          _remainingRoutePoints = [];
          _traveledRoutePoints = [];
        });
        break;
    }
  }
  
  /// Calculate route between two points using Google Directions API
  /// Returns polyline points and updates distance/ETA
  Future<void> _calculateRouteBetween(
    LocationCoordinate origin,
    LocationCoordinate destination, {
    bool isDriverArriving = false,
  }) async {
    final rideId = widget.rideId ?? 'unknown';
    final routeType = isDriverArriving ? 'PICKUP' : 'DROPOFF';
    
    debugPrint(
      '🗺️ [API] Requesting route '
      'rideId=$rideId '
      'type=$routeType '
      'origin=(${origin.lat.toStringAsFixed(5)}, ${origin.lng.toStringAsFixed(5)}) '
      'destination=(${destination.lat.toStringAsFixed(5)}, ${destination.lng.toStringAsFixed(5)})',
    );
    
    try {
      final directions = await mapsService.getDirections(origin, destination);
      
      if (directions != null) {
        final coordinates = mapsService.decodePolyline(directions.polyline);
        final polylineCoords = coordinates.map((c) => LatLng(c.lat, c.lng)).toList();
        
        setState(() {
          _fullRoutePoints = polylineCoords;
          _remainingRoutePoints = List.from(polylineCoords);
          _traveledRoutePoints = [];
          _driverDistanceMeters = directions.distanceValue.toDouble();
          _driverEtaMinutes = (directions.durationValue / 60).ceil();
        });
        
        // Notify parent of distance update
        widget.onDriverDistanceUpdate?.call(_driverDistanceMeters, _driverEtaMinutes);
        
        // Update polylines with premium styling
        _updatePolylines(isDriverArriving: isDriverArriving);
        
        debugPrint(
          '🗺️ [API] Route calculated SUCCESS '
          'rideId=$rideId '
          'type=$routeType '
          'points=${polylineCoords.length} '
          'distance=${(_driverDistanceMeters / 1000).toStringAsFixed(2)}km '
          'eta=${_driverEtaMinutes}min',
        );
        
        // Only fit bounds on initial route calculation or phase change
        // During live tracking, camera follows driver instead
        if (_isFirstCameraUpdate && _mapController != null && polylineCoords.isNotEmpty) {
          _isFirstCameraUpdate = false;
          final bounds = _getBoundsFromPoints(polylineCoords);
          _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 100));
        }
      } else {
        debugPrint('🗺️ [API] Route calculation returned null');
      }
    } catch (e) {
      debugPrint('🗺️ [API] Route calculation ERROR: $e');
    }
  }
  
  /// Update driver distance to target (pickup or destination)
  void _updateDriverDistance(LatLng driverPos) {
    LatLng? target;
    
    if (widget.ridePhase == RidePhase.driverArriving && widget.pickupLocation != null) {
      target = LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng);
    } else if (widget.ridePhase == RidePhase.rideInProgress && widget.dropoffLocation != null) {
      target = LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng);
    }
    
    if (target != null) {
      final distance = _calculateDistance(driverPos, target);
      // Rough ETA: assume 20 km/h average speed in city
      final eta = (distance / 1000 / 20 * 60).ceil();
      
      setState(() {
        _driverDistanceMeters = distance;
        _driverEtaMinutes = eta.clamp(1, 999);
      });
      
      widget.onDriverDistanceUpdate?.call(_driverDistanceMeters, _driverEtaMinutes);
    }
  }
  
  /// Check if driver deviated from route and recalculate if needed
  // Smart route snapping thresholds
  static const double _snapThreshold = 30.0; // meters - snap to route if within this distance
  static const double _deviationThreshold = 50.0; // meters - recalculate if beyond this distance
  
  /// Smart route deviation handling with segment snapping
  /// Returns the snapped position if driver is close to route, or raw position if deviated
  void _checkAndRecalculateRoute(LatLng driverPos) {
    if (_remainingRoutePoints.isEmpty || _remainingRoutePoints.length < 2) return;
    
    final rideId = widget.rideId ?? 'unknown';
    
    // Find nearest point on the polyline (segment projection, not just vertices)
    final snapResult = _findNearestPointOnPolyline(driverPos, _remainingRoutePoints);
    final distanceFromRoute = snapResult.distance;
    final snappedPosition = snapResult.point;
    final segmentIndex = snapResult.segmentIndex;
    
    // Log deviation status
    debugPrint(
      '📍 [Deviation] '
      'rideId=$rideId '
      'driverLat=${driverPos.latitude.toStringAsFixed(5)} '
      'driverLng=${driverPos.longitude.toStringAsFixed(5)} '
      'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
      'segmentIndex=$segmentIndex '
      'routePoints=${_remainingRoutePoints.length}',
    );
    
    if (distanceFromRoute <= _snapThreshold) {
      // Driver is close to route - snap marker to route for visual alignment
      _applyRouteSnapping(snappedPosition, segmentIndex);
      debugPrint(
        '✅ [Snap] Snapped to route '
        'rideId=$rideId '
        'snappedLat=${snappedPosition.latitude.toStringAsFixed(5)} '
        'snappedLng=${snappedPosition.longitude.toStringAsFixed(5)} '
        'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
        'snappedToRoute=true '
        'routeRecalculated=false',
      );
    } else if (distanceFromRoute > _deviationThreshold) {
      // Driver has significantly deviated - recalculate route
      final now = DateTime.now();
      if (_lastRouteRecalculation == null || 
          now.difference(_lastRouteRecalculation!) > _routeRecalculationCooldown) {
        _lastRouteRecalculation = now;
        debugPrint(
          '🔄 [Deviation] Route recalculation triggered '
          'rideId=$rideId '
          'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
          'snappedToRoute=false '
          'routeRecalculated=true',
        );
        _recalculateRouteFromDriver(driverPos);
      } else {
        final cooldownRemaining = _routeRecalculationCooldown.inSeconds - 
            now.difference(_lastRouteRecalculation!).inSeconds;
        debugPrint(
          '⏳ [Deviation] Recalculation skipped (cooldown) '
          'rideId=$rideId '
          'cooldownRemaining=${cooldownRemaining}s '
          'snappedToRoute=false '
          'routeRecalculated=false',
        );
      }
    } else {
      // Driver is moderately off-route (between snap and deviation thresholds)
      // Don't snap but don't recalculate either - just update progressive polyline
      debugPrint(
        '📍 [Deviation] Moderate deviation (no action) '
        'rideId=$rideId '
        'distanceFromRoute=${distanceFromRoute.toStringAsFixed(1)}m '
        'snappedToRoute=false '
        'routeRecalculated=false',
      );
    }
    
    // Always update progressive polyline to remove traveled segments
    _updateProgressivePolyline(driverPos);
  }
  
  /// Result of finding nearest point on polyline
  _PolylineSnapResult _findNearestPointOnPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) {
      return _PolylineSnapResult(point: point, distance: double.infinity, segmentIndex: -1);
    }
    if (polyline.length == 1) {
      return _PolylineSnapResult(
        point: polyline[0],
        distance: _calculateDistance(point, polyline[0]),
        segmentIndex: 0,
      );
    }
    
    double minDistance = double.infinity;
    LatLng nearestPoint = polyline[0];
    int nearestSegmentIndex = 0;
    
    // Check each segment of the polyline
    for (int i = 0; i < polyline.length - 1; i++) {
      final segmentStart = polyline[i];
      final segmentEnd = polyline[i + 1];
      
      // Project point onto the line segment
      final projected = _projectPointOntoSegment(point, segmentStart, segmentEnd);
      final distance = _calculateDistance(point, projected);
      
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
  
  /// Project a point onto a line segment, returning the nearest point on the segment
  LatLng _projectPointOntoSegment(LatLng point, LatLng segmentStart, LatLng segmentEnd) {
    final px = point.longitude;
    final py = point.latitude;
    final ax = segmentStart.longitude;
    final ay = segmentStart.latitude;
    final bx = segmentEnd.longitude;
    final by = segmentEnd.latitude;
    
    final dx = bx - ax;
    final dy = by - ay;
    
    // Handle degenerate case (zero-length segment)
    if (dx == 0 && dy == 0) {
      return segmentStart;
    }
    
    // Calculate projection parameter t
    // t = 0 means projection is at segmentStart
    // t = 1 means projection is at segmentEnd
    // t between 0 and 1 means projection is on the segment
    final t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    
    // Clamp t to [0, 1] to stay on the segment
    final clampedT = t.clamp(0.0, 1.0);
    
    // Calculate the projected point
    final projectedLng = ax + clampedT * dx;
    final projectedLat = ay + clampedT * dy;
    
    return LatLng(projectedLat, projectedLng);
  }
  
  /// Apply route snapping - update the animated driver position to the snapped location
  void _applyRouteSnapping(LatLng snappedPosition, int segmentIndex) {
    // Update the animated position to the snapped position for visual alignment
    // This keeps the marker on the road without jumping
    if (_animatedDriverPosition != null) {
      // Calculate the bearing from the current segment for proper marker rotation
      if (segmentIndex >= 0 && segmentIndex < _remainingRoutePoints.length - 1) {
        final segmentStart = _remainingRoutePoints[segmentIndex];
        final segmentEnd = _remainingRoutePoints[segmentIndex + 1];
        final routeBearing = CarAnimationService.calculateBearing(segmentStart, segmentEnd);
        
        // Smoothly blend the snapped position (only for visual, don't overwrite raw GPS)
        // The car animation service handles the actual interpolation
        if (_carAnimationService != null) {
          _carAnimationService!.updateLocation(snappedPosition, heading: routeBearing);
        }
      }
    }
    
    // Trim the route polyline to start from the segment after the snapped position
    if (segmentIndex > 0 && segmentIndex < _remainingRoutePoints.length) {
      setState(() {
        // Keep the snapped position as the new start of remaining route
        _remainingRoutePoints = [snappedPosition, ..._remainingRoutePoints.sublist(segmentIndex + 1)];
      });
      _updatePolylines(isDriverArriving: widget.ridePhase == RidePhase.driverArriving);
    }
  }
  
  /// Recalculate route from driver's current position
  /// Called when driver deviates significantly from the planned route
  Future<void> _recalculateRouteFromDriver(LatLng driverPos) async {
    final rideId = widget.rideId ?? 'unknown';
    
    final LocationCoordinate destination;
    final bool isDriverArriving;
    final String routeType;
    
    if (widget.ridePhase == RidePhase.driverArriving && widget.pickupLocation != null) {
      destination = widget.pickupLocation!;
      isDriverArriving = true;
      routeType = 'PICKUP';
    } else if (widget.ridePhase == RidePhase.rideInProgress && widget.dropoffLocation != null) {
      destination = widget.dropoffLocation!;
      isDriverArriving = false;
      routeType = 'DROPOFF';
    } else {
      debugPrint('⚠️ [Route] Cannot recalculate - no valid destination for phase ${widget.ridePhase}');
      return;
    }
    
    debugPrint(
      '🔄 [Route] Recalculating route '
      'rideId=$rideId '
      'phase=${widget.ridePhase} '
      'routeType=$routeType '
      'driverLat=${driverPos.latitude.toStringAsFixed(5)} '
      'driverLng=${driverPos.longitude.toStringAsFixed(5)} '
      'destLat=${destination.lat.toStringAsFixed(5)} '
      'destLng=${destination.lng.toStringAsFixed(5)}',
    );
    
    try {
      final directions = await mapsService.getDirections(
        LocationCoordinate(lat: driverPos.latitude, lng: driverPos.longitude),
        destination,
      );
      
      if (directions != null && mounted) {
        final coordinates = mapsService.decodePolyline(directions.polyline);
        final newRoutePoints = coordinates.map((c) => LatLng(c.lat, c.lng)).toList();
        
        setState(() {
          _fullRoutePoints = newRoutePoints;
          _remainingRoutePoints = List.from(newRoutePoints);
          _traveledRoutePoints = [driverPos];
          _driverDistanceMeters = directions.distanceValue.toDouble();
          _driverEtaMinutes = (directions.durationValue / 60).ceil();
        });
        
        widget.onDriverDistanceUpdate?.call(_driverDistanceMeters, _driverEtaMinutes);
        _updatePolylines(isDriverArriving: isDriverArriving);
        
        debugPrint(
          '✅ [Route] Route recalculated successfully '
          'rideId=$rideId '
          'routeType=$routeType '
          'points=${newRoutePoints.length} '
          'distance=${_driverDistanceMeters.toStringAsFixed(0)}m '
          'eta=${_driverEtaMinutes}min',
        );
      }
    } catch (e) {
      debugPrint(
        '❌ [Route] Route recalculation failed '
        'rideId=$rideId '
        'error=$e',
      );
    }
  }
  
  /// Update progressive polyline as driver moves (removes traveled portion like Uber)
  /// Uses segment projection for accurate position determination
  void _updateProgressivePolyline(LatLng driverPos) {
    if (_remainingRoutePoints.isEmpty || _remainingRoutePoints.length < 2) return;
    
    // Use segment projection to find the exact position on the route
    final snapResult = _findNearestPointOnPolyline(driverPos, _remainingRoutePoints);
    final segmentIndex = snapResult.segmentIndex;
    
    // Only trim if driver is close enough to the route (within snap threshold)
    // and has moved past at least one segment
    if (snapResult.distance <= _deviationThreshold && segmentIndex > 0) {
      // Keep the projected point as the new start, followed by remaining segments
      final snappedPoint = snapResult.point;
      
      // Build new remaining route starting from the snapped position
      final newRemaining = <LatLng>[snappedPoint];
      if (segmentIndex + 1 < _remainingRoutePoints.length) {
        newRemaining.addAll(_remainingRoutePoints.sublist(segmentIndex + 1));
      }
      
      if (newRemaining.length != _remainingRoutePoints.length) {
        setState(() {
          _remainingRoutePoints = newRemaining;
        });
        _updatePolylines(isDriverArriving: widget.ridePhase == RidePhase.driverArriving);
      }
    }
  }
  
  double _calculateDistance(LatLng p1, LatLng p2) {
    const earthRadius = 6371000.0;
    final lat1 = p1.latitude * math.pi / 180;
    final lat2 = p2.latitude * math.pi / 180;
    final dLat = (p2.latitude - p1.latitude) * math.pi / 180;
    final dLng = (p2.longitude - p1.longitude) * math.pi / 180;
    
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    
    return earthRadius * c;
  }
  
  void _animateToRideView() {
    if (_mapController == null) return;
    
    Future.delayed(const Duration(milliseconds: 300), () {
      if (widget.driverLocation != null && widget.pickupLocation != null) {
        _animateToShowDriverAndPickup();
      } else if (widget.pickupLocation != null && widget.dropoffLocation != null) {
        _animateToShowRoute();
      }
    });
  }
  
  void _animateToShowDriverAndPickup() {
    if (_mapController == null || widget.driverLocation == null || widget.pickupLocation == null) return;
    
    final driverPos = LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng);
    final pickupPos = LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng);
    final points = [driverPos, pickupPos];
    
    // Calculate distance for appropriate zoom
    final distance = _calculateDistance(driverPos, pickupPos);
    
    if (distance < 500 && widget.followDriverLocation) {
      // Close enough - switch to navigation camera mode
      final bearing = _carAnimationService?.smoothedBearing ?? 
          CarAnimationService.calculateBearing(driverPos, pickupPos);
      final leadTarget = _projectPointAhead(driverPos, bearing, metersAhead: 40);
      
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: leadTarget,
            zoom: CarAnimationService.calculateDynamicZoom(distance),
            tilt: 40.0,
            bearing: bearing,
          ),
        ),
      );
    } else {
      // Far away - show overview
      final bounds = _getBoundsFromPoints(points);
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 120));
    }
    
    debugPrint('📷 Animate to show driver→pickup, distance=${distance.toStringAsFixed(0)}m');
  }
  
  void _animateToShowRoute() {
    if (_mapController == null || widget.dropoffLocation == null) return;
    
    final driverPos = _animatedDriverPosition ?? 
        (widget.driverLocation != null 
            ? LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng)
            : (widget.pickupLocation != null 
                ? LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng)
                : null));
    final dropPos = LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng);
    
    if (driverPos == null) return;
    
    final points = [driverPos, dropPos];
    final distance = _calculateDistance(driverPos, dropPos);
    
    if (distance < 1000 && widget.followDriverLocation) {
      // Within 1km - use navigation camera
      final bearing = _carAnimationService?.smoothedBearing ?? 
          CarAnimationService.calculateBearing(driverPos, dropPos);
      final leadTarget = _projectPointAhead(driverPos, bearing, metersAhead: 55);
      
      _currentCameraZoom = CarAnimationService.calculateDynamicZoom(distance);
      _currentCameraTilt = 50.0;
      _currentCameraBearing = bearing;
      
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: leadTarget,
            zoom: _currentCameraZoom,
            tilt: _currentCameraTilt,
            bearing: bearing,
          ),
        ),
      );
    } else {
      // Show full route overview
      final bounds = _getBoundsFromPoints(points);
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 100));
    }
    
    debugPrint('📷 Animate to show driver→dropoff, distance=${distance.toStringAsFixed(0)}m');
  }
  
  void _smoothFollowDriver(LatLng driverPosition, {double? bearing}) {
    if (_mapController == null) return;

    final now = DateTime.now();
    if (_lastFollowCameraUpdate != null &&
        now.difference(_lastFollowCameraUpdate!) < _cameraFollowCooldown) {
      return;
    }
    _lastFollowCameraUpdate = now;

    // Use smoothed bearing from animation service for less jittery camera
    final rawBearing = bearing ?? _animatedDriverBearing;
    final cameraBearing = _carAnimationService?.smoothedBearing ?? rawBearing;
    
    // Calculate distance to target for dynamic zoom
    LatLng? targetLocation;
    if (widget.ridePhase == RidePhase.driverArriving && widget.pickupLocation != null) {
      targetLocation = LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng);
    } else if (widget.ridePhase == RidePhase.rideInProgress && widget.dropoffLocation != null) {
      targetLocation = LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng);
    }
    
    // Calculate dynamic zoom based on distance to destination
    double targetZoom = 16.5;
    if (targetLocation != null) {
      final distanceToTarget = _calculateDistance(driverPosition, targetLocation);
      targetZoom = CarAnimationService.calculateDynamicZoom(distanceToTarget);
    }
    
    // Calculate dynamic tilt based on ride phase and speed
    final currentSpeed = _carAnimationService?.currentSpeed ?? 0;
    final targetTilt = CarAnimationService.calculateDynamicTilt(
      isRideInProgress: widget.ridePhase == RidePhase.rideInProgress,
      speedMps: currentSpeed,
    );
    
    // Smooth transitions for zoom and tilt (lerp towards target)
    _currentCameraZoom = _currentCameraZoom + (targetZoom - _currentCameraZoom) * 0.15;
    _currentCameraTilt = _currentCameraTilt + (targetTilt - _currentCameraTilt) * 0.1;
    _currentCameraBearing = cameraBearing;
    
    // Project camera ahead in driving direction for navigation feel
    final metersAhead = widget.ridePhase == RidePhase.rideInProgress ? 55.0 : 40.0;
    final leadTarget = _projectPointAhead(driverPosition, cameraBearing, metersAhead: metersAhead);

    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: leadTarget,
          zoom: _currentCameraZoom,
          tilt: _currentCameraTilt,
          bearing: _currentCameraBearing,
        ),
      ),
    );
    
    // Log camera state for debugging
    if (widget.rideId != null) {
      debugPrint(
        '📷 Camera follow '
        'rideId=${widget.rideId} '
        'phase=${widget.ridePhase} '
        'driverLat=${driverPosition.latitude.toStringAsFixed(5)} '
        'driverLng=${driverPosition.longitude.toStringAsFixed(5)} '
        'zoom=${_currentCameraZoom.toStringAsFixed(1)} '
        'tilt=${_currentCameraTilt.toStringAsFixed(0)}° '
        'bearing=${_currentCameraBearing.toStringAsFixed(0)}°',
      );
    }
  }

  void _animateCameraToDriver(LocationCoordinate location) {
    final driverPos = _animatedDriverPosition ?? LatLng(location.lat, location.lng);
    
    // Calculate distance to target for dynamic zoom
    LatLng? targetLocation;
    if (widget.ridePhase == RidePhase.driverArriving && widget.pickupLocation != null) {
      targetLocation = LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng);
    } else if (widget.ridePhase == RidePhase.rideInProgress && widget.dropoffLocation != null) {
      targetLocation = LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng);
    }
    
    double targetZoom = 17.0;
    double targetTilt = 50.0;
    if (targetLocation != null) {
      final distanceToTarget = _calculateDistance(driverPos, targetLocation);
      targetZoom = CarAnimationService.calculateDynamicZoom(distanceToTarget);
      // Add slight zoom boost for recenter action
      targetZoom = (targetZoom + 0.5).clamp(13.0, 18.0);
    }
    
    // Use smooth bearing from animation service
    final cameraBearing = _carAnimationService?.smoothedBearing ?? _animatedDriverBearing;
    
    // Determine lead distance based on phase
    final metersAhead = widget.ridePhase == RidePhase.rideInProgress ? 50.0 : 35.0;
    final leadTarget = _projectPointAhead(driverPos, cameraBearing, metersAhead: metersAhead);
    
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: leadTarget,
          zoom: targetZoom,
          tilt: targetTilt,
          bearing: cameraBearing,
        ),
      ),
    );
    
    debugPrint(
      '📷 Recenter camera '
      'zoom=$targetZoom '
      'tilt=$targetTilt '
      'bearing=${cameraBearing.toStringAsFixed(0)}°',
    );
  }

  LatLng _projectPointAhead(
    LatLng from,
    double bearingDeg, {
    double metersAhead = 40,
  }) {
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

  Future<void> _getCurrentLocation() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _userLocation = LocationCoordinate(
          lat: position.latitude,
          lng: position.longitude,
        );
      });

      if (_isMapReady && _mapController != null) {
        _animateToLocation(_userLocation!);
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _animateToLocation(LocationCoordinate location, {double zoom = 16}) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(location.lat, location.lng),
          zoom: zoom,
        ),
      ),
    );
  }

  Future<void> _calculateRoute() async {
    // Use phase-based calculation
    await _calculateRouteForPhase();
  }
  
  /// Update polylines with premium Uber-style rendering
  /// Features:
  /// - Multi-layer polylines with glow, border, and main line
  /// - Different colors for driver arriving vs ride in progress
  /// - Dashed pattern for driver arriving phase
  /// - Smooth rounded caps and joints
  void _updatePolylines({bool isDriverArriving = false}) {
    final polylines = <Polyline>{};
    
    // Premium color palette
    final Color mainColor;
    final Color borderColor;
    final Color glowColor;
    
    if (isDriverArriving) {
      // Green-ish for driver arriving
      mainColor = const Color(0xFF34A853); // Google green
      borderColor = const Color(0xFF1E7E34);
      glowColor = const Color(0xFF34A853).withOpacity(0.20);
    } else {
      // Blue for ride in progress (Uber-style)
      mainColor = const Color(0xFF4285F4); // Google blue
      borderColor = const Color(0xFF1A56DB);
      glowColor = const Color(0xFF4285F4).withOpacity(0.20);
    }
    
    final routePoints = _remainingRoutePoints.length >= 2 
        ? _remainingRoutePoints 
        : _fullRoutePoints;
    
    if (routePoints.length >= 2) {
      // Uber/Rapido style: Clean, thin polyline with subtle border
      
      // Layer 1: Border/outline (dark, slightly wider)
      polylines.add(
        Polyline(
          polylineId: const PolylineId('route_border'),
          points: routePoints,
          color: borderColor,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          patterns: isDriverArriving 
              ? [PatternItem.dash(12), PatternItem.gap(8)]
              : const <PatternItem>[],
        ),
      );
      
      // Layer 2: Main route (colored line - thin like Uber/Rapido)
      polylines.add(
        Polyline(
          polylineId: const PolylineId('route_main'),
          points: routePoints,
          color: mainColor,
          width: 4,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
          patterns: isDriverArriving 
              ? [PatternItem.dash(12), PatternItem.gap(8)]
              : const <PatternItem>[],
        ),
      );
    }
    
    setState(() {
      _polylines = polylines;
    });
    
    // Log polyline update
    debugPrint(
      '🛣️ Polyline updated '
      'phase=${isDriverArriving ? "arriving" : "in_progress"} '
      'points=${routePoints.length} '
      'layers=${polylines.length}',
    );
  }

  LatLngBounds _getBoundsFromPoints(List<LatLng> points) {
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

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

  void _updateMarkers() {
    final markers = <Marker>{};

    // Nearby driver markers (search phase)
    for (final driver in widget.drivers) {
      if (driver.currentLocation != null) {
        markers.add(
          Marker(
            markerId: MarkerId('driver_${driver.id}'),
            position: LatLng(driver.currentLocation!.lat, driver.currentLocation!.lng),
            icon: _vehicleIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
            anchor: const Offset(0.5, 0.5),
            flat: true,
            infoWindow: InfoWindow(
              title: driver.name,
              snippet: '${driver.vehicleInfo?.type ?? 'Vehicle'} • ${driver.rating}⭐',
            ),
            onTap: () => widget.onDriverPress?.call(driver),
          ),
        );
      }
    }

    // Pickup/passenger marker: show only before ride start
    if (widget.pickupLocation != null &&
        (widget.ridePhase == RidePhase.searching || widget.ridePhase == RidePhase.driverArriving)) {
      markers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng),
          icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          anchor: const Offset(0.5, 1.0),
          infoWindow: const InfoWindow(title: 'Pickup'),
        ),
      );
    }

    // Drop marker: show only in searching preview
    // During active ride, keep map focused on vehicle + route only.
    if (widget.dropoffLocation != null && widget.ridePhase == RidePhase.searching) {
      markers.add(
        Marker(
          markerId: const MarkerId('dropoff'),
          position: LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng),
          icon: _dropoffIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          anchor: const Offset(0.5, 1.0),
          infoWindow: const InfoWindow(title: 'Destination'),
        ),
      );
    }

    // Active driver marker - show when driver location is available
    if (widget.driverLocation != null && 
        (widget.ridePhase == RidePhase.driverArriving || 
         widget.ridePhase == RidePhase.rideInProgress ||
         widget.rideInProgress)) {
      final driverPos = _animatedDriverPosition ?? 
                        LatLng(widget.driverLocation!.lat, widget.driverLocation!.lng);
      
      markers.add(
        Marker(
          markerId: const MarkerId('active_driver'),
          position: driverPos,
          icon: _vehicleIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          rotation: _animatedDriverBearing,
          anchor: const Offset(0.5, 0.5),
          flat: true,
          zIndex: 100,
        ),
      );
    }

    // Circles
    final circles = <Circle>{};
    
    // Search radius (only in search phase)
    if (_userLocation != null && widget.userType == 'rider' && 
        widget.ridePhase == RidePhase.searching && !widget.rideInProgress) {
      circles.add(
        Circle(
          circleId: const CircleId('search_radius_outer'),
          center: LatLng(_userLocation!.lat, _userLocation!.lng),
          radius: widget.searchRadius.toDouble(),
          strokeColor: _primaryColor.withOpacity(0.2),
          fillColor: _primaryColor.withOpacity(0.05),
          strokeWidth: 2,
        ),
      );
    }

    // Pickup pulse (when driver is arriving)
    if (widget.pickupLocation != null && widget.ridePhase == RidePhase.driverArriving) {
      circles.add(
        Circle(
          circleId: const CircleId('pickup_pulse'),
          center: LatLng(widget.pickupLocation!.lat, widget.pickupLocation!.lng),
          radius: 30,
          strokeColor: Colors.green.withOpacity(0.7),
          fillColor: Colors.green.withOpacity(0.15),
          strokeWidth: 3,
        ),
      );
    }

    // Destination pulse (when ride is in progress)
    if (widget.dropoffLocation != null && widget.ridePhase == RidePhase.rideInProgress) {
      circles.add(
        Circle(
          circleId: const CircleId('destination_pulse'),
          center: LatLng(widget.dropoffLocation!.lat, widget.dropoffLocation!.lng),
          radius: 25,
          strokeColor: Colors.red.withOpacity(0.7),
          fillColor: Colors.red.withOpacity(0.15),
          strokeWidth: 3,
        ),
      );
    }

    setState(() {
      _markers = markers;
      _circles = circles;
    });
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    
    if (_mapStyle != null) {
      controller.setMapStyle(_mapStyle);
    }
    
    setState(() => _isMapReady = true);

    if (_userLocation != null) {
      _animateToLocation(_userLocation!);
    }
    _updateMarkers();
    _calculateRouteForPhase();
  }

  void _onMapTap(LatLng position) {
    widget.onLocationPress?.call(position);
  }

  @override
  Widget build(BuildContext context) {
    final initialPosition = widget.currentUserLocation ?? _userLocation;
    
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: initialPosition != null
                ? LatLng(initialPosition.lat, initialPosition.lng)
                : LatLng(AppConfig.defaultLatitude, AppConfig.defaultLongitude),
            zoom: AppConfig.defaultZoom,
          ),
          onMapCreated: _onMapCreated,
          onTap: _onMapTap,
          onCameraMove: (position) => widget.onRegionChange?.call(position),
          markers: _markers,
          polylines: _polylines,
          circles: _circles,
          myLocationEnabled: widget.showUserLocation,
          myLocationButtonEnabled: false,
          compassEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          trafficEnabled: widget.showTraffic,
          buildingsEnabled: true,
          indoorViewEnabled: false,
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
          padding: const EdgeInsets.only(bottom: 200),
        ),
        
        // Driver distance/ETA overlay - Uber style
        if (_isMapReady && widget.driverLocation != null && 
            (widget.ridePhase == RidePhase.driverArriving || widget.ridePhase == RidePhase.rideInProgress))
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(
              child: _buildDriverDistanceChip(),
            ),
          ),
        
        // Recenter button
        if (_isMapReady)
          Positioned(
            right: 16,
            bottom: 220,
            child: _buildRecenterButton(),
          ),
      ],
    );
  }

  /// Uber-style driver distance/ETA chip
  Widget _buildDriverDistanceChip() {
    final isArriving = widget.ridePhase == RidePhase.driverArriving;
    final distanceText = _formatDistance(_driverDistanceMeters);
    final label = isArriving ? 'Driver arriving' : 'To destination';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isArriving ? Colors.green.withOpacity(0.1) : _primaryColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isArriving ? Icons.directions_car : Icons.flag,
              color: isArriving ? Colors.green : _primaryColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Row(
                children: [
                  Text(
                    '$_driverEtaMinutes min',
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(
                    distanceText,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
  }

  Widget _buildRecenterButton() {
    return Material(
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _recenterMap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Icon(
            widget.rideInProgress || widget.ridePhase != RidePhase.searching 
                ? Icons.gps_fixed 
                : Icons.my_location,
            color: _primaryColor,
            size: 26,
          ),
        ),
      ),
    );
  }

  void _recenterMap() {
    if (widget.driverLocation != null && 
        (widget.rideInProgress || widget.ridePhase != RidePhase.searching)) {
      _animateCameraToDriver(widget.driverLocation!);
    } else if (_userLocation != null) {
      _animateToLocation(_userLocation!, zoom: 16);
    }
  }

  @override
  void dispose() {
    _carAnimationService?.dispose();
    _mapController?.dispose();
    super.dispose();
  }
}
