import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/directions_service.dart';
import '../../../../core/services/places_service.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/models/pricing_v2.dart';
import '../../../../core/utils/auto_map_icon.dart';
import '../../../../core/utils/bike_map_icon.dart';
import '../../providers/ride_booking_provider.dart';
import '../../../auth/providers/auth_provider.dart';

class FindTripScreen extends ConsumerStatefulWidget {
  final bool autoOpenSearch;
  final String? initialServiceType;
  final DateTime? scheduledTime;
  const FindTripScreen({
    super.key,
    this.autoOpenSearch = false,
    this.initialServiceType,
    this.scheduledTime,
  });

  @override
  ConsumerState<FindTripScreen> createState() => _FindTripScreenState();
}

// Cab type model - supports both static and dynamic data
class CabType {
  final String id;
  final String name;
  final String description;
  final String iconName;
  final double baseFare;
  final double perKmRate;
  final double perMinRate;
  final int capacity;
  final String eta;
  final bool isPopular;
  final String? badge;
  final double fare; // Calculated fare from backend
  final double surgeMultiplier;
  final bool isSurge;

  const CabType({
    required this.id,
    required this.name,
    required this.description,
    this.iconName = 'directions_car',
    this.baseFare = 0,
    this.perKmRate = 0,
    this.perMinRate = 0,
    required this.capacity,
    this.eta = '3-5 min',
    this.isPopular = false,
    this.badge,
    this.fare = 0,
    this.surgeMultiplier = 1.0,
    this.isSurge = false,
  });

  // Get icon based on iconName
  IconData get icon {
    switch (iconName) {
      case 'two_wheeler':
        return Icons.two_wheeler;
      case 'electric_rickshaw':
        return Icons.electric_rickshaw;
      case 'directions_car':
        return Icons.directions_car;
      case 'airport_shuttle':
        return Icons.airport_shuttle;
      case 'diamond':
        return Icons.diamond;
      case 'person':
        return Icons.person;
      default:
        return Icons.directions_car;
    }
  }

  factory CabType.fromJson(Map<String, dynamic> json) {
    return CabType(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      iconName: json['icon'] ?? 'directions_car',
      baseFare: (json['base_fare'] ?? 0).toDouble(),
      perKmRate: (json['per_km_rate'] ?? 0).toDouble(),
      perMinRate: (json['per_min_rate'] ?? 0).toDouble(),
      capacity: json['capacity'] ?? 4,
      eta: json['eta'] ?? '3-5 min',
      isPopular: json['is_popular'] ?? false,
      badge: json['badge'],
      fare: (json['fare'] ?? 0).toDouble(),
      surgeMultiplier: (json['surge_multiplier'] ?? 1.0).toDouble(),
      isSurge: json['is_surge'] ?? false,
    );
  }
}

class _FindTripScreenState extends ConsumerState<FindTripScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // Intermediate stops (Ola/Uber/Rapido style)
  List<RideStop> _stops = [];

  late String
      _selectedCabType; // Will be set from initialServiceType or default
  bool _needExtraDrivers = false;
  int _driverCount = 1;

  // Scheduled ride time (null = ride now)
  DateTime? _scheduledTime;

  // Cab types fetched from backend
  List<CabType> _cabTypes = [];
  bool _isLoadingPricing = false;
  bool _isSurgeActive = false;
  double _surgeMultiplier = 1.0;
  String _distanceKmFromBackend = '';
  int _durationMinFromBackend = 0;

  // Store calculated fares for each cab type (from backend)
  Map<String, double> _cabFares = {};

  // Pricing v2 features
  EcoPickup? _ecoPickup;
  RiderSubsidy? _riderSubsidy;
  ZoneHealth? _zoneHealth;
  MarketplaceMode _marketplaceMode = MarketplaceMode.scale;
  bool _showEcoPickup = false;
  double _savingsAmount = 0;

  // Google Maps controller
  Completer<GoogleMapController> _mapController = Completer();
  GoogleMapController? _controller;

  // Directions service
  final DirectionsService _directionsService = DirectionsService();

  // Locations - initialized to null, will be set from GPS or provider
  // CRITICAL: Do NOT use hardcoded defaults - causes wrong route calculations
  LatLng? _pickupLocation;
  LatLng? _destinationLocation;
  
  // Flag to track if pickup location has been properly initialized
  bool _pickupLocationReady = false;

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  // Nearby drivers
  List<Map<String, dynamic>> _nearbyDrivers = [];
  Set<Marker> _driverClusterMarkers = {};
  final Map<String, BitmapDescriptor> _clusterIconCache = {};
  Timer? _clusterPulseTimer;
  bool _clusterPulsePhase = false;
  double _currentZoomLevel = 12.0;
  BitmapDescriptor? _carIcon;
  BitmapDescriptor? _bikeIcon;
  BitmapDescriptor? _autoIcon;

  // Route info
  String _distanceText = '';
  String _durationText = '';
  double _estimatedFare = 0;
  bool _isLoadingRoute = false;

  // Map style for dark mode
  String? _mapStyle;
  bool _lastDarkMode = false;

  // Bottom sheet controller - to sync floating map elements with sheet drag
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_onSheetSizeChanged);
    _startClusterPulseTicker();
    // Set selected cab type from parameter or use default
    _selectedCabType = widget.initialServiceType ?? 'bike_rescue';
    // Set scheduled time from parameter
    _scheduledTime = widget.scheduledTime;
    // Sync from provider if we have saved booking (e.g. returning after driver cancel)
    _loadFromProvider();
    _loadCustomMarkers();
    _loadMapStyle();
    _getCurrentLocationForPickup();
    // Auto-open the destination search sheet if navigated from service card
    if (widget.autoOpenSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLocationSearchSheet(isPickup: false);
      });
    }
  }

  /// Load pickup/destination/stops from provider so polyline uses correct coordinates
  void _loadFromProvider() {
    final booking = ref.read(rideBookingProvider);
    if (booking.pickupLocation != null &&
        booking.pickupAddress != null &&
        booking.pickupAddress!.isNotEmpty &&
        booking.pickupAddress != 'Getting location...') {
      _pickupLocation = booking.pickupLocation!;
      _pickupController.text = booking.pickupAddress!;
      _pickupLocationReady = true;
      debugPrint('📍 Loaded pickup from provider: ${booking.pickupAddress}');
    }
    if (booking.destinationLocation != null &&
        booking.destinationAddress != null &&
        booking.destinationAddress!.isNotEmpty) {
      _destinationLocation = booking.destinationLocation!;
      _destinationController.text = booking.destinationAddress!;
      debugPrint('📍 Loaded destination from provider: ${booking.destinationAddress}');
    }
    if (booking.stops.isNotEmpty) {
      _stops = List.from(booking.stops);
    }
  }

  // Helper to format scheduled time for display
  String get _scheduledTimeDisplay {
    if (_scheduledTime == null) return 'Now';
    final now = DateTime.now();
    final scheduled = _scheduledTime!;

    if (scheduled.day == now.day &&
        scheduled.month == now.month &&
        scheduled.year == now.year) {
      return 'Today, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
    }
    final tomorrow = now.add(const Duration(days: 1));
    if (scheduled.day == tomorrow.day &&
        scheduled.month == tomorrow.month &&
        scheduled.year == tomorrow.year) {
      return 'Tomorrow, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
    }
    return '${scheduled.day}/${scheduled.month}, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
  }

  bool get _isScheduledRide => _scheduledTime != null;

  /// Top-down vehicle icon: remove black bg, resize, bottom shadow — only on opaque pixels.
  Future<BitmapDescriptor?> _loadVehicleMapIconProcessed(String assetPath,
      {String debugLabel = 'vehicle'}) async {
    try {
      final bytes = await rootBundle.load(assetPath);
      final original = img.decodeImage(bytes.buffer.asUint8List());
      if (original == null) return null;
      var image = original.convert(numChannels: 4);
      const thresh = 55;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final pixel = image.getPixel(x, y);
          final r = pixel.r.toInt();
          final g = pixel.g.toInt();
          final b = pixel.b.toInt();
          if (r < thresh && g < thresh && b < thresh) {
            image.setPixelRgba(x, y, r, g, b, 0);
          }
        }
      }
      image = img.copyResize(image, width: 120, height: 120,
          interpolation: img.Interpolation.cubic);
      final shadowStartY = (image.height * 0.52).floor();
      for (var y = shadowStartY; y < image.height; y++) {
        final t = (y - shadowStartY) / (image.height - shadowStartY);
        final blend = (t * 0.92).clamp(0.0, 1.0);
        for (var x = 0; x < image.width; x++) {
          final pixel = image.getPixel(x, y);
          if (pixel.a > 0.1) {
            final r = (pixel.r * (1 - blend)).round().clamp(0, 255);
            final g = (pixel.g * (1 - blend)).round().clamp(0, 255);
            final b = (pixel.b * (1 - blend)).round().clamp(0, 255);
            image.setPixelRgba(x, y, r, g, b, 255);
          }
        }
      }
      final pngBytes = Uint8List.fromList(img.encodePng(image));
      return BitmapDescriptor.fromBytes(pngBytes);
    } catch (e) {
      debugPrint('$debugLabel map icon load failed: $e');
      return null;
    }
  }

  /// Load custom vehicle icons from assets (bike, auto, cab, cab premium)
  /// Uber/Rapido style: ~40-50 logical pixels with device pixel ratio for crisp rendering
  Future<void> _loadCustomMarkers() async {
    try {
      // Uber/Rapido style icons - compact but visible
      const config =
          ImageConfiguration(size: Size(44, 44), devicePixelRatio: 2.5);
      // Bike: strip side black frame; keep shadow only under bike (see bike_map_icon.dart).
      _bikeIcon = await loadBikeMapIconProcessed(
            'assets/map_icons/icon_bike.png',
            debugLabel: 'Bike',
          ) ??
          await BitmapDescriptor.asset(
            config,
            'assets/map_icons/icon_bike.png',
          );
      // Auto: slightly elongated on map for clearer rickshaw “length”.
      _autoIcon = await loadAutoMapIconProcessed() ??
          await BitmapDescriptor.asset(
            config,
            'assets/map_icons/icon_auto.png',
          );
      _carIcon = await _loadVehicleMapIconProcessed(
            'assets/map_icons/icon_cab.png',
            debugLabel: 'Cab',
          ) ??
          await BitmapDescriptor.asset(config, 'assets/map_icons/icon_cab.png');
    } catch (e) {
      debugPrint('Map icons load failed, using fallback: $e');
      _carIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
      _bikeIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
      _autoIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan);
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
      if (_controller != null && _mapStyle != null) {
        _controller!.setMapStyle(_mapStyle);
      }
      debugPrint(
          '🗺️ Find trip map style loaded: ${isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  /// Map selected cab type id to the driver vehicle category for filtering.
  String _vehicleCategoryForCabType(String cabTypeId) {
    switch (cabTypeId) {
      case 'bike_rescue':
        return 'bike';
      case 'auto':
        return 'auto';
      default:
        return 'car';
    }
  }

  /// Get vehicle image asset path for cab type
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
        return 'assets/vehicles/captain.png';
      case 'personal_driver':
        return 'assets/vehicles/cab_premium.png';
      default:
        return 'assets/vehicles/cab_mini.png';
    }
  }

  Set<Marker> _mergeMapMarkers(
      Set<Marker> coreMarkers, Set<Marker> driverMarkers) {
    return {...coreMarkers, ...driverMarkers};
  }

  void _startClusterPulseTicker() {
    _clusterPulseTimer?.cancel();
    _clusterPulseTimer = Timer.periodic(const Duration(milliseconds: 850), (_) {
      if (!mounted) return;
      _clusterPulsePhase = !_clusterPulsePhase;
      _clusterIconCache.removeWhere((key, _) => key.startsWith('lg-'));
      _updateDriverMarkers();
    });
  }

  Future<BitmapDescriptor> _getClusterIcon(int count) async {
    final bucket = count < 5 ? 'sm' : (count <= 15 ? 'md' : 'lg');
    final cacheKey =
        '$bucket-$count-${bucket == 'lg' ? _clusterPulsePhase : false}';
    final cached = _clusterIconCache[cacheKey];
    if (cached != null) return cached;

    final double size = count < 5 ? 54 : (count <= 15 ? 68 : 82);
    final Color baseColor = count < 5
        ? const Color(0xFFEAB88F)
        : (count <= 15 ? const Color(0xFFD4956A) : const Color(0xFFB46D36));
    final Color strokeColor = const Color(0xFFFFF1E4);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    final radius = size / 2;

    if (count > 15) {
      final pulseScale = _clusterPulsePhase ? 1.12 : 0.98;
      final glowPaint = Paint()
        ..color = baseColor.withOpacity(_clusterPulsePhase ? 0.24 : 0.16);
      canvas.drawCircle(center, radius * pulseScale, glowPaint);
    }

    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.18)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 8);
    canvas.drawCircle(center.translate(0, 2), radius * 0.72, shadowPaint);

    final fillPaint = Paint()..color = baseColor;
    canvas.drawCircle(center, radius * 0.68, fillPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = strokeColor.withOpacity(0.90);
    canvas.drawCircle(center, radius * 0.68, ringPaint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: count.toString(),
        style: TextStyle(
          fontSize: count > 99 ? 18 : 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );

    final image =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final bitmap = BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
    _clusterIconCache[cacheKey] = bitmap;
    return bitmap;
  }

  Offset _latLngToWorldPoint(LatLng p, double zoom) {
    final scale = 256.0 * math.pow(2.0, zoom).toDouble();
    final x = (p.longitude + 180.0) / 360.0 * scale;
    final sinLat =
        math.sin(p.latitude * math.pi / 180.0).clamp(-0.9999, 0.9999);
    final y =
        (0.5 - (math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi))) * scale;
    return Offset(x, y);
  }

  List<_DriverVisualCluster> _buildVisualClusters(
      List<_NearbyDriver> drivers, double zoom) {
    if (drivers.isEmpty) return const [];
    if (zoom >= 16.5) {
      return drivers
          .map(
            (d) => _DriverVisualCluster(
              center: d.position,
              drivers: [d],
            ),
          )
          .toList();
    }

    final gridSizePx =
        zoom >= 15 ? 64.0 : (zoom >= 13 ? 76.0 : (zoom >= 11 ? 90.0 : 104.0));

    final clusters = <_DriverVisualCluster>[];
    final clusterCentersWorld = <Offset>[];

    for (final driver in drivers) {
      final point = _latLngToWorldPoint(driver.position, zoom);
      int matchedIndex = -1;

      for (int i = 0; i < clusterCentersWorld.length; i++) {
        if ((point - clusterCentersWorld[i]).distance <= gridSizePx) {
          matchedIndex = i;
          break;
        }
      }

      if (matchedIndex == -1) {
        clusters.add(
          _DriverVisualCluster(
            center: driver.position,
            drivers: [driver],
          ),
        );
        clusterCentersWorld.add(point);
      } else {
        final existing = clusters[matchedIndex];
        final combined = [...existing.drivers, driver];
        final avgLat =
            combined.map((d) => d.position.latitude).reduce((a, b) => a + b) /
                combined.length;
        final avgLng =
            combined.map((d) => d.position.longitude).reduce((a, b) => a + b) /
                combined.length;
        clusters[matchedIndex] = _DriverVisualCluster(
          center: LatLng(avgLat, avgLng),
          drivers: combined,
        );
        clusterCentersWorld[matchedIndex] =
            _latLngToWorldPoint(clusters[matchedIndex].center, zoom);
      }
    }

    return clusters;
  }

  BitmapDescriptor _iconForDriverType(String type) {
    switch (type) {
      case 'bike':
        return _bikeIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
      case 'auto':
        return _autoIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan);
      case 'car':
      default:
        // Mini / XL / premium all use the same cab map icon.
        return _carIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }
  }

  /// Fetch nearby drivers from backend and show on map
  Future<void> _fetchNearbyDrivers() async {
    // Skip if pickup location not ready
    if (_pickupLocation == null) {
      debugPrint('⏳ Skipping driver fetch - pickup location not ready');
      return;
    }
    
    try {
      final data = await apiClient.getNearbyDrivers(
        _pickupLocation!.latitude,
        _pickupLocation!.longitude,
        radius: 5,
      );

      if (!mounted) return;

      // Backend returns: { success, data: { drivers: [...], count, radius } }
      final innerData = data['data'] as Map<String, dynamic>?;
      final driversList = innerData?['drivers'] as List<dynamic>? ?? [];
      if (data['success'] == true && driversList.isNotEmpty) {
        final drivers = driversList.map((d) {
          return {
            'id': d['id'] ?? 'driver_${DateTime.now().millisecondsSinceEpoch}',
            'lat': d['currentLatitude'] ?? _pickupLocation!.latitude + 0.005,
            'lng': d['currentLongitude'] ?? _pickupLocation!.longitude + 0.005,
            'type': d['vehicleType'] ?? 'car',
            'name': d['user']?['firstName'] ?? 'Driver',
            'rating': d['rating'] ?? 4.5,
            'heading': (DateTime.now().millisecondsSinceEpoch % 360),
          };
        }).toList();

        setState(() {
          _nearbyDrivers = List<Map<String, dynamic>>.from(drivers);
        });
        _updateDriverMarkers();
        debugPrint('🚗 Loaded ${_nearbyDrivers.length} drivers from backend');
        return;
      }
    } catch (e) {
      debugPrint('Error fetching nearby drivers: $e');
    }

    // Generate simulated drivers if API fails or returns empty
    debugPrint('📍 Using simulated drivers');
    _generateSimulatedDrivers();
  }

  /// Generate simulated nearby drivers for demo — ensures each type has several
  void _generateSimulatedDrivers() {
    // Skip if pickup location not ready
    if (_pickupLocation == null) return;
    
    final random = DateTime.now().millisecondsSinceEpoch;
    final drivers = <Map<String, dynamic>>[];
    const types = ['car', 'bike', 'auto'];

    // 5 drivers per vehicle type so switching always shows vehicles
    for (final type in types) {
      for (int i = 0; i < 5; i++) {
        final seed = random + types.indexOf(type) * 1000 + i * 137;
        final latOffset = ((seed % 80) - 40) / 10000.0;
        final lngOffset = ((seed * 3 % 80) - 40) / 10000.0;
        drivers.add({
          'id': '${type}_$i',
          'lat': _pickupLocation!.latitude + latOffset,
          'lng': _pickupLocation!.longitude + lngOffset,
          'type': type,
          'name': '${type[0].toUpperCase()}${type.substring(1)} ${i + 1}',
          'rating': 4.5 + (i % 5) / 10,
          'heading': (seed + i * 45) % 360,
        });
      }
    }

    setState(() {
      _nearbyDrivers = drivers;
    });
    _updateDriverMarkers();
  }

  /// Update markers to include nearby drivers, filtered to match selected vehicle category
  Future<void> _updateDriverMarkers() async {
    final activeCategory = _vehicleCategoryForCabType(_selectedCabType);
    final visibleDrivers = <_NearbyDriver>[];

    for (final driver in _nearbyDrivers) {
      final type = driver['type'] ?? 'car';

      // Only show drivers matching the currently selected vehicle category
      if (type != activeCategory) continue;

      final lat = (driver['lat'] as num?)?.toDouble();
      final lng = (driver['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final nearbyDriver = _NearbyDriver(
        id: '${driver['id']}',
        position: LatLng(lat, lng),
        type: '$type',
        name: '${driver['name'] ?? 'Driver'}',
        rating: ((driver['rating'] as num?)?.toDouble() ?? 4.5),
        heading: ((driver['heading'] as num?)?.toDouble() ?? 0),
      );
      visibleDrivers.add(nearbyDriver);
    }

    final clusters = _buildVisualClusters(visibleDrivers, _currentZoomLevel);
    final driverMarkers = <Marker>{};

    for (final cluster in clusters) {
      if (cluster.count == 1) {
        final nearbyDriver = cluster.drivers.first;
        driverMarkers.add(
          Marker(
            markerId: MarkerId('driver_${nearbyDriver.id}'),
            position: nearbyDriver.position,
            icon: _iconForDriverType(nearbyDriver.type),
            anchor: const Offset(0.5, 0.5),
            rotation: nearbyDriver.heading,
            flat: true,
            infoWindow: InfoWindow(
              title: nearbyDriver.name,
              snippet:
                  '${nearbyDriver.rating.toStringAsFixed(1)} ★ • ${nearbyDriver.type.toUpperCase()}',
            ),
          ),
        );
      } else {
        final icon = await _getClusterIcon(cluster.count);
        driverMarkers.add(
          Marker(
            markerId: MarkerId('cluster_${cluster.clusterId}'),
            position: cluster.center,
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            onTap: () async {
              final map = _controller;
              if (map == null) return;
              final currentZoom = await map.getZoomLevel();
              await map.animateCamera(
                CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: cluster.center,
                    zoom: (currentZoom + 1.8).clamp(10.0, 18.0),
                  ),
                ),
              );
            },
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _driverClusterMarkers = driverMarkers;
      _markers = _mergeMapMarkers(_buildCoreMarkers(), _driverClusterMarkers);
    });
  }

  /// Get current location and set as pickup
  /// CRITICAL: This MUST complete before any route calculation
  Future<void> _getCurrentLocationForPickup() async {
    debugPrint('🔄 _getCurrentLocationForPickup: Starting...');
    
    try {
      // Skip if we already have valid pickup from provider (e.g. returning with saved booking)
      final booking = ref.read(rideBookingProvider);
      if (booking.pickupLocation != null &&
          booking.pickupAddress != null &&
          booking.pickupAddress!.isNotEmpty &&
          booking.pickupAddress != 'Getting location...') {
        debugPrint('📍 Using pickup from provider: ${booking.pickupAddress}');
        if (mounted) {
          setState(() {
            _pickupLocation = booking.pickupLocation;
            _pickupLocationReady = true;
          });
          _setupMapElements();
          _fetchNearbyDrivers();
          // Only calculate route if destination is also valid
          _tryCalculateRoute();
        }
        return;
      }

      // Show loading state while getting location
      if (mounted) {
        setState(() {
          _pickupController.text = 'Getting your location...';
        });
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      debugPrint('📍 Location permission status: $permission');
      
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('⚠️ Location permission denied by user');
          _handleLocationPermissionDenied();
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('⚠️ Location permission denied forever');
        _handleLocationPermissionDenied();
        return;
      }

      // Get current position - this is the REAL user location
      debugPrint('📍 Fetching current GPS position...');
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      if (!mounted) return;

      final pickupLatLng = LatLng(position.latitude, position.longitude);
      debugPrint('✅ GPS location obtained: ${pickupLatLng.latitude}, ${pickupLatLng.longitude}');

      // Get address from coordinates
      String pickupAddress = 'Current Location';
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );

        if (!mounted) return;

        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          final address = [
            place.street,
            place.subLocality,
            place.locality,
          ].where((s) => s != null && s.isNotEmpty).join(', ');

          pickupAddress = address.isNotEmpty ? address : 'Current Location';
        }
      } catch (e) {
        debugPrint('⚠️ Geocoding failed: $e');
      }

      if (!mounted) return;

      // CRITICAL: Set pickup location and mark as ready
      setState(() {
        _pickupLocation = pickupLatLng;
        _pickupController.text = pickupAddress;
        _pickupLocationReady = true;
      });

      // Update provider with real GPS location
      ref
          .read(rideBookingProvider.notifier)
          .setPickupLocation(pickupAddress, pickupLatLng);
      debugPrint(
          '✅ Pickup location set from GPS: $pickupAddress (${pickupLatLng.latitude}, ${pickupLatLng.longitude})');

      _setupMapElements();
      _fetchNearbyDrivers();
      
      // Try to calculate route if destination is already set
      _tryCalculateRoute();
      
    } catch (e) {
      debugPrint('❌ Error getting current location: $e');
      _handleLocationPermissionDenied();
    }
  }

  /// Handle case when location permission is denied or location fetch fails
  /// CRITICAL: Do NOT set a fake fallback location that would cause wrong routes
  void _handleLocationPermissionDenied() {
    if (!mounted) return;
    
    setState(() {
      _pickupController.text = 'Tap to set pickup location';
      _pickupLocationReady = false;
      // Keep _pickupLocation as null - do NOT set a default
    });
    
    debugPrint('⚠️ Location unavailable - user must manually select pickup');
    
    // Show a message to the user
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Please enable location or tap to select pickup location'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// Safely attempt route calculation - only if both locations are valid
  void _tryCalculateRoute() {
    debugPrint('🔄 _tryCalculateRoute: Checking conditions...');
    debugPrint('   Pickup ready: $_pickupLocationReady');
    debugPrint('   Pickup location: $_pickupLocation');
    debugPrint('   Destination location: $_destinationLocation');
    
    // STRICT GUARD: Only calculate if BOTH locations are valid
    if (!_pickupLocationReady || _pickupLocation == null || _destinationLocation == null) {
      debugPrint('⏳ Route calculation skipped - waiting for valid locations');
      return;
    }
    
    // SAFETY CHECK: Validate coordinates are reasonable
    if (!_isValidCoordinate(_pickupLocation!) || !_isValidCoordinate(_destinationLocation!)) {
      debugPrint('⚠️ Invalid coordinates detected - skipping route calculation');
      return;
    }
    
    debugPrint('✅ Both locations valid - calculating route');
    _calculateRoute();
  }
  
  /// Validate that coordinates are reasonable (not 0,0 or obviously wrong)
  bool _isValidCoordinate(LatLng coord) {
    // Check for null island (0,0)
    if (coord.latitude == 0 && coord.longitude == 0) return false;
    // Check for valid lat/lng ranges
    if (coord.latitude < -90 || coord.latitude > 90) return false;
    if (coord.longitude < -180 || coord.longitude > 180) return false;
    return true;
  }

  void _onSheetSizeChanged() {
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetController.dispose();
    _pickupController.dispose();
    _destinationController.dispose();
    _clusterPulseTimer?.cancel();
    super.dispose();
  }

  Set<Marker> _buildCoreMarkers() {
    final stopMarkers = <Marker>{};
    for (int i = 0; i < _stops.length; i++) {
      final stop = _stops[i];
      stopMarkers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: stop.location,
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(title: 'Stop ${i + 1}', snippet: stop.address),
          draggable: true,
          onDragEnd: (newPosition) {
            setState(() {
              _stops[i] =
                  RideStop(address: stop.address, location: newPosition);
            });
            _tryCalculateRoute();
          },
        ),
      );
    }

    final markers = <Marker>{...stopMarkers};
    
    // Pickup marker removed per design - location still used for routing
    
    // Only add destination marker if location is set and has address
    if (_destinationLocation != null && _destinationController.text.isNotEmpty) {
      markers.add(
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLocation!,
          icon:
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(
              title: 'Destination', snippet: _destinationController.text),
          draggable: true,
          onDragEnd: (newPosition) async {
            setState(() => _destinationLocation = newPosition);
            await _reverseGeocodeAndUpdateDestination(newPosition);
            _tryCalculateRoute();
          },
        ),
      );
    }
    
    return markers;
  }

  void _setupMapElements() {
    final core = _buildCoreMarkers();
    _markers = _mergeMapMarkers(core, _driverClusterMarkers);
  }

  /// Reverse geocode and update pickup address after dragging pin
  Future<void> _reverseGeocodeAndUpdatePickup(LatLng position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty && mounted) {
        final place = placemarks.first;
        final address = [
          place.name,
          place.subLocality,
          place.locality,
        ].where((e) => e != null && e.isNotEmpty).join(', ');

        setState(() {
          _pickupController.text = address.isNotEmpty ? address : 'Dropped Pin';
        });

        // Update provider
        ref
            .read(rideBookingProvider.notifier)
            .setPickupLocation(address, position);
      }
    } catch (e) {
      debugPrint('Reverse geocode error: $e');
      if (mounted) {
        setState(() => _pickupController.text = 'Dropped Pin');
      }
    }
  }

  /// Reverse geocode and update destination address after dragging pin
  Future<void> _reverseGeocodeAndUpdateDestination(LatLng position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty && mounted) {
        final place = placemarks.first;
        final address = [
          place.name,
          place.subLocality,
          place.locality,
        ].where((e) => e != null && e.isNotEmpty).join(', ');

        setState(() {
          _destinationController.text =
              address.isNotEmpty ? address : 'Dropped Pin';
        });

        // Update provider
        ref
            .read(rideBookingProvider.notifier)
            .setDestinationLocation(address, position);
      }
    } catch (e) {
      debugPrint('Reverse geocode error: $e');
      if (mounted) {
        setState(() => _destinationController.text = 'Dropped Pin');
      }
    }
  }

  /// Calculate route using Dijkstra's algorithm via DirectionsService
  /// CRITICAL: This should ONLY be called via _tryCalculateRoute() which validates locations
  Future<void> _calculateRoute() async {
    if (!mounted) return;
    
    // STRICT GUARD: Double-check locations are valid before proceeding
    if (_pickupLocation == null || _destinationLocation == null) {
      debugPrint('⚠️ _calculateRoute called with null locations - aborting');
      return;
    }
    
    // Clear old route data before calculating new
    setState(() {
      _polylines = {};
      _isLoadingRoute = true;
      _isLoadingPricing = true;
    });

    try {
      // DEBUG LOGGING - verify coordinates before route call
      debugPrint('========================================');
      debugPrint('🗺️ ROUTE DEBUG - Calculating route:');
      debugPrint('   Pickup: ${_pickupLocation!.latitude}, ${_pickupLocation!.longitude}');
      debugPrint('   Drop: ${_destinationLocation!.latitude}, ${_destinationLocation!.longitude}');
      debugPrint('========================================');

      final waypoints =
          _stops.isNotEmpty ? _stops.map((s) => s.location).toList() : null;
      final route = await _directionsService.getRoute(
        origin: _pickupLocation!,
        destination: _destinationLocation!,
        waypoints: waypoints,
        mode: TravelMode.driving,
      );
      
      // SAFETY CHECK: If route distance is absurdly large (>200km), warn and potentially skip
      final distanceKm = route.distance / 1000;
      if (distanceKm > 200) {
        debugPrint('⚠️ WARNING: Route distance is ${distanceKm.toStringAsFixed(1)} km - unusually large!');
        debugPrint('   This may indicate incorrect coordinates');
      }

      if (!mounted) return;

      debugPrint(
          '✅ Route calculated: ${route.distanceText}, ${route.durationText}');
      debugPrint('   Path points: ${route.points.length}');

      // Fetch pricing from backend
      await _fetchPricingFromBackend(route.distance, route.duration.toInt());

      if (!mounted) return;

      // Use selected cab type fare for the provider
      double fare = 0;
      if (_cabTypes.isNotEmpty) {
        final selectedCab = _cabTypes.firstWhere(
          (c) => c.id == _selectedCabType,
          orElse: () => _cabTypes.first,
        );
        fare = selectedCab.fare;
      }

      // Save route info and stops to provider
      ref.read(rideBookingProvider.notifier).setStops(_stops);
      ref.read(rideBookingProvider.notifier).updateRouteInfo(
            pickupLocation: _pickupLocation!,
            pickupAddress: _pickupController.text,
            destinationLocation: _destinationLocation!,
            destinationAddress: _destinationController.text,
            distance: route.distance,
            duration: route.duration.toInt(),
            fare: fare,
            polylinePoints: route.points,
          );

      setState(() {
        _distanceText = route.distanceText;
        _durationText = route.durationText;
        _estimatedFare = fare;

        // Uber/Rapido-style polylines: thin, clean lines
        _polylines = {
          Polyline(
            polylineId: const PolylineId('route_border'),
            points: route.points,
            color: const Color(0xFF1A1A1A),
            width: 3,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
          Polyline(
            polylineId: const PolylineId('route'),
            points: route.points,
            color: Colors.black,
            width: 2,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };

        debugPrint('📍 Polyline created with ${route.points.length} points');

        _markers = _mergeMapMarkers(_buildCoreMarkers(), _driverClusterMarkers);

        _isLoadingRoute = false;
      });

      // Animate camera to fit the entire route with all polyline points
      await Future.delayed(const Duration(milliseconds: 200));
      await _fitRouteBounds(route.bounds);
    } catch (e) {
      debugPrint('❌ Route calculation error: $e');
      setState(() {
        _isLoadingRoute = false;
        _isLoadingPricing = false;
      });
    }
  }

  /// Fetch ride pricing from backend (v2 with subsidy, eco pickup, zone health)
  Future<void> _fetchPricingFromBackend(double distance, int duration) async {
    // Guard: ensure both locations are valid
    if (_pickupLocation == null || _destinationLocation == null) {
      debugPrint('⚠️ Cannot fetch pricing - locations not ready');
      return;
    }
    
    try {
      debugPrint('💰 Fetching pricing v2 from backend...');
      debugPrint('   Distance: ${distance}m, Duration: ${duration}s');

      // Backend: POST /api/pricing/calculate (with waypoints for multi-stop)
      final waypointsForPricing = _stops.isNotEmpty
          ? _stops
              .map((s) =>
                  {'lat': s.location.latitude, 'lng': s.location.longitude})
              .toList()
          : null;
      final data = await apiClient.getRidePricing(
        pickupLat: _pickupLocation!.latitude,
        pickupLng: _pickupLocation!.longitude,
        dropLat: _destinationLocation!.latitude,
        dropLng: _destinationLocation!.longitude,
        waypoints: waypointsForPricing,
        distanceKm: distance / 1000,
        durationMin: (duration / 60).ceil(),
      );

      // Backend returns v2 pricing with subsidy, eco pickup, zone health
      if (data['success'] == true) {
        final pricingData = data['data'] as Map<String, dynamic>? ?? {};

        // Parse v2 pricing features
        RiderSubsidy? subsidy;
        EcoPickup? ecoPickup;
        ZoneHealth? zoneHealth;
        MarketplaceMode mode = MarketplaceMode.scale;
        double totalSavings = 0;

        // Parse rider subsidy (launch mode feature)
        if (pricingData['rider_subsidy'] != null ||
            pricingData['riderSubsidy'] != null) {
          subsidy = RiderSubsidy.fromJson(
              pricingData['rider_subsidy'] ?? pricingData['riderSubsidy']);
        }

        // Parse eco pickup option
        if (pricingData['eco_pickup'] != null ||
            pricingData['ecoPickup'] != null) {
          ecoPickup = EcoPickup.fromJson(
              pricingData['eco_pickup'] ?? pricingData['ecoPickup']);
        }

        // Parse zone health
        if (pricingData['zone_health'] != null ||
            pricingData['zoneHealth'] != null) {
          zoneHealth = ZoneHealth.fromJson(
              pricingData['zone_health'] ?? pricingData['zoneHealth']);
        }

        // Parse marketplace mode
        final modeStr = pricingData['marketplace_mode'] ??
            pricingData['marketplaceMode'] ??
            'scale';
        if (modeStr == 'launch') {
          mode = MarketplaceMode.launch;
        }

        // Parse cab options from backend (v2 returns per-category pricing)
        final List<CabType> options = [];
        final cabOptionsData = pricingData['cab_options'] ??
            pricingData['cabOptions'] ??
            pricingData['options'];

        if (cabOptionsData != null && cabOptionsData is List) {
          // Backend provides cab options directly
          for (final opt in cabOptionsData) {
            final cabData = opt as Map<String, dynamic>;
            final originalFare = (cabData['original_fare'] ??
                    cabData['originalFare'] ??
                    cabData['fare'] ??
                    0)
                .toDouble();
            final effectiveFare = (cabData['effective_fare'] ??
                    cabData['effectiveFare'] ??
                    cabData['fare'] ??
                    0)
                .toDouble();
            final cabSavings = originalFare - effectiveFare;

            options.add(CabType(
              id: cabData['id'] ?? cabData['vehicle_type'] ?? '',
              name: cabData['name'] ?? '',
              description: cabData['description'] ?? '',
              iconName:
                  _getIconName(cabData['id'] ?? cabData['vehicle_type'] ?? ''),
              capacity: cabData['capacity'] ?? 4,
              fare: effectiveFare,
              baseFare:
                  (cabData['base_fare'] ?? cabData['baseFare'] ?? 0).toDouble(),
              perKmRate: (cabData['per_km_rate'] ?? cabData['perKmRate'] ?? 0)
                  .toDouble(),
              perMinRate:
                  (cabData['per_min_rate'] ?? cabData['perMinRate'] ?? 0)
                      .toDouble(),
              eta: cabData['eta'] ?? '5 min',
              isPopular: cabData['is_popular'] ?? cabData['isPopular'] ?? false,
              badge: cabData['badge'],
              surgeMultiplier: (cabData['surge_multiplier'] ??
                      cabData['surgeMultiplier'] ??
                      1.0)
                  .toDouble(),
              isSurge: cabData['is_surge'] ?? cabData['isSurge'] ?? false,
            ));

            if (cabSavings > totalSavings) totalSavings = cabSavings;
          }
        } else {
          // Fallback: Generate from base fare if backend doesn't provide options
          final totalFare =
              (pricingData['totalFare'] ?? pricingData['total_fare'] ?? 0)
                  .toDouble();
          final subsidyMultiplier =
              subsidy?.isActive == true ? (1 - subsidy!.subsidyPct) : 1.0;

          options.addAll([
            CabType(
                id: 'bike_rescue',
                name: 'Bike Rescue',
                description: 'Quick bike rescue',
                iconName: 'two_wheeler',
                capacity: 1,
                fare: (totalFare * 0.6 * subsidyMultiplier)
                    .clamp(20.0, double.infinity),
                eta: '3 min'),
            CabType(
                id: 'auto',
                name: 'Auto',
                description: 'Auto rickshaw',
                iconName: 'electric_rickshaw',
                capacity: 3,
                fare: (totalFare * 0.8 * subsidyMultiplier)
                    .clamp(25.0, double.infinity),
                eta: '5 min'),
            CabType(
                id: 'cab_mini',
                name: 'Cab Mini',
                description: 'Compact car',
                iconName: 'directions_car',
                capacity: 4,
                fare: (totalFare * subsidyMultiplier)
                    .clamp(40.0, double.infinity),
                eta: '7 min',
                isPopular: true),
            CabType(
                id: 'cab_xl',
                name: 'Cab XL',
                description: 'Spacious ride',
                iconName: 'airport_shuttle',
                capacity: 6,
                fare: (totalFare * 1.3 * subsidyMultiplier)
                    .clamp(80.0, double.infinity),
                eta: '10 min'),
            CabType(
                id: 'cab_premium',
                name: 'Premium',
                description: 'Luxury ride',
                iconName: 'diamond',
                capacity: 4,
                fare: (totalFare * 1.8 * subsidyMultiplier)
                    .clamp(100.0, double.infinity),
                eta: '12 min'),
          ]);

          if (subsidy?.isActive == true) {
            totalSavings = totalFare * subsidy!.subsidyPct;
            if (totalSavings > subsidy.maxSubsidyCap)
              totalSavings = subsidy.maxSubsidyCap;
          }
        }

        // Add eco pickup option if available
        if (ecoPickup != null && ecoPickup.isAvailable) {
          final baseFare = options.isNotEmpty ? options.first.fare : 100.0;
          final ecoFare = (baseFare * (1 - ecoPickup.discountPct))
              .clamp(15.0, double.infinity);
          options.insert(
              0,
              CabType(
                id: 'eco_pickup',
                name: 'Eco Pickup',
                description:
                    'Walk ${ecoPickup.walkDistanceMeters.round()}m, save ₹${ecoPickup.calculateSavings(baseFare).round()}',
                iconName: 'directions_walk',
                capacity: 1,
                fare: ecoFare.toDouble(),
                eta: '2 min',
                badge: 'Save ${(ecoPickup.discountPct * 100).round()}%',
              ));
        }

        final fares = <String, double>{};
        for (final cab in options) {
          fares[cab.id] = cab.fare;
        }

        // Parse surge info
        final isSurge = pricingData['surge_active'] ??
            pricingData['surgeActive'] ??
            pricingData['is_surge'] ??
            false;
        final surgeMultiplier = (pricingData['surge_multiplier'] ??
                pricingData['surgeMultiplier'] ??
                1.0)
            .toDouble();

        setState(() {
          _cabTypes = options;
          _cabFares = fares;
          _isSurgeActive = isSurge;
          _surgeMultiplier = surgeMultiplier;
          _distanceKmFromBackend =
              (pricingData['distance_km'] ?? pricingData['distanceKm'] ?? '')
                  .toString();
          _durationMinFromBackend = (pricingData['duration_min'] ??
                  pricingData['durationMin'] ??
                  pricingData['estimatedDuration'] ??
                  0)
              .toInt();
          _isLoadingPricing = false;

          // v2 features
          _riderSubsidy = subsidy;
          _ecoPickup = ecoPickup;
          _zoneHealth = zoneHealth;
          _marketplaceMode = mode;
          _savingsAmount = totalSavings;
          _showEcoPickup = ecoPickup?.isAvailable ?? false;
        });

        debugPrint('✅ Pricing v2 fetched: ${options.length} options');
        debugPrint(
            '   Mode: ${mode.name}, Surge: $_isSurgeActive (${_surgeMultiplier}x)');
        debugPrint(
            '   Subsidy active: ${subsidy?.isActive ?? false}, Savings: ₹${totalSavings.round()}');
        debugPrint('   Eco pickup: ${ecoPickup?.isAvailable ?? false}');
        debugPrint('   Zone health: ${zoneHealth?.status.name ?? 'unknown'}');
      } else {
        debugPrint(
            '❌ Pricing API returned unsuccessful: ${data['message'] ?? 'Unknown error'}');
        _loadFallbackPricing(distance, duration);
      }
    } catch (e) {
      debugPrint('❌ Error fetching pricing: $e');
      _loadFallbackPricing(distance, duration);
    }
  }

  /// Get icon name for vehicle type
  String _getIconName(String vehicleType) {
    switch (vehicleType.toLowerCase()) {
      case 'bike':
      case 'bike_rescue':
        return 'two_wheeler';
      case 'auto':
        return 'electric_rickshaw';
      case 'cab_mini':
      case 'mini':
        return 'directions_car';
      case 'cab_xl':
      case 'xl':
        return 'airport_shuttle';
      case 'cab_premium':
      case 'premium':
        return 'diamond';
      case 'eco_pickup':
        return 'directions_walk';
      default:
        return 'directions_car';
    }
  }

  /// Fallback pricing calculation if backend is unavailable
  void _loadFallbackPricing(double distance, int duration) {
    final distanceKm = distance / 1000;
    final durationMin = duration / 60;

    // Fallback cab types
    final fallbackTypes = [
      {
        'id': 'bike_rescue',
        'name': 'Rescue Service',
        'description': 'Quick rescue on two-wheeler — pickup and drop anywhere',
        'icon': 'two_wheeler',
        'base_fare': 20,
        'per_km_rate': 6,
        'per_min_rate': 1,
        'capacity': 1,
        'badge': 'Rescue',
        'is_popular': true
      },
      {
        'id': 'auto',
        'name': 'Auto',
        'description': 'Budget-friendly auto rickshaw',
        'icon': 'electric_rickshaw',
        'base_fare': 25,
        'per_km_rate': 8,
        'per_min_rate': 1.5,
        'capacity': 3,
        'badge': 'Cheapest'
      },
      {
        'id': 'cab_mini',
        'name': 'Cab Mini',
        'description': 'Compact cars for city rides',
        'icon': 'directions_car',
        'base_fare': 40,
        'per_km_rate': 12,
        'per_min_rate': 2,
        'capacity': 4
      },
      {
        'id': 'cab_xl',
        'name': 'Cab XL',
        'description': 'Spacious SUVs for groups',
        'icon': 'airport_shuttle',
        'base_fare': 80,
        'per_km_rate': 18,
        'per_min_rate': 3,
        'capacity': 6,
        'badge': 'Family'
      },
      {
        'id': 'cab_premium',
        'name': 'Cab Premium',
        'description': 'Luxury sedans with top drivers',
        'icon': 'diamond',
        'base_fare': 100,
        'per_km_rate': 25,
        'per_min_rate': 4,
        'capacity': 4,
        'badge': 'Premium'
      },
      {
        'id': 'personal_driver',
        'name': 'Personal Driver',
        'description': 'Hire a driver for your own car',
        'icon': 'person',
        'base_fare': 150,
        'per_km_rate': 0,
        'per_min_rate': 3.5,
        'capacity': 4,
        'badge': 'Hourly'
      },
    ];

    final options = fallbackTypes.map((type) {
      final fare = (type['base_fare'] as num) +
          (distanceKm * (type['per_km_rate'] as num)) +
          (durationMin * (type['per_min_rate'] as num));
      return CabType.fromJson({
        ...type,
        'fare': fare.round(),
        'eta': '3-5 min',
      });
    }).toList();

    final fares = <String, double>{};
    for (final cab in options) {
      fares[cab.id] = cab.fare;
    }

    setState(() {
      _cabTypes = options;
      _cabFares = fares;
      _isLoadingPricing = false;
    });

    debugPrint('⚠️ Using fallback pricing');
  }

  Future<void> _fitRouteBounds(LatLngBounds? routeBounds) async {
    try {
      // Wait for controller if not ready
      if (_controller == null) {
        if (!_mapController.isCompleted) {
          debugPrint('⏳ Waiting for map controller...');
          _controller = await _mapController.future;
        } else {
          _controller = await _mapController.future;
        }
      }

      // Calculate bounds from all points (polyline points + markers + stops)
      // Guard: ensure both locations are valid
      if (_pickupLocation == null || _destinationLocation == null) {
        debugPrint('⚠️ Cannot fit bounds - locations not ready');
        return;
      }
      
      List<LatLng> allPoints = [
        _pickupLocation!,
        _destinationLocation!,
        ..._stops.map((s) => s.location)
      ];

      // Add all polyline points if available
      if (_polylines.isNotEmpty) {
        for (final polyline in _polylines) {
          allPoints.addAll(polyline.points);
        }
      }

      // Find min/max from all points
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

      // Add padding to bounds (more padding for better visibility)
      final latPadding = (maxLat - minLat) * 0.15; // 15% padding
      final lngPadding = (maxLng - minLng) * 0.15;
      final minPadding = 0.002; // Minimum padding

      final bounds = LatLngBounds(
        southwest: LatLng(
          minLat - (latPadding > minPadding ? latPadding : minPadding),
          minLng - (lngPadding > minPadding ? lngPadding : minPadding),
        ),
        northeast: LatLng(
          maxLat + (latPadding > minPadding ? latPadding : minPadding),
          maxLng + (lngPadding > minPadding ? lngPadding : minPadding),
        ),
      );

      debugPrint('📍 Fitting map to bounds with ${allPoints.length} points');
      debugPrint(
          '   SW: (${bounds.southwest.latitude.toStringAsFixed(4)}, ${bounds.southwest.longitude.toStringAsFixed(4)})');
      debugPrint(
          '   NE: (${bounds.northeast.latitude.toStringAsFixed(4)}, ${bounds.northeast.longitude.toStringAsFixed(4)})');

      await Future.delayed(const Duration(milliseconds: 100));

      // Animate camera with padding for UI elements at top
      await _controller?.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 50), // 50 pixel padding from edges
      );

      debugPrint('✅ Map camera animated to show full route');
    } catch (e) {
      debugPrint('❌ Error fitting bounds: $e');
      // Fallback: center between pickup and destination
      if (_pickupLocation != null && _destinationLocation != null) {
        try {
          final centerLat =
              (_pickupLocation!.latitude + _destinationLocation!.latitude) / 2;
          final centerLng =
              (_pickupLocation!.longitude + _destinationLocation!.longitude) / 2;
          await _controller?.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(centerLat, centerLng), 12),
          );
        } catch (_) {}
      }
    }
  }

  bool _locationWasSelected = false;

  void _showLocationSearchSheet(
      {required bool isPickup, int? addStopAt, int? editStopAt}) {
    _locationWasSelected = false;
    final isStop = addStopAt != null || editStopAt != null;
    final initialVal = isPickup
        ? _pickupController.text
        : isStop && editStopAt != null && editStopAt < _stops.length
            ? _stops[editStopAt].address
            : isStop
                ? ''
                : _destinationController.text;
    final bias = isPickup ? _destinationLocation : _pickupLocation;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LocationSearchSheet(
        isPickup: isPickup,
        initialValue: initialVal,
        biasLocation: bias,
        onLocationSelected: (address, latLng) {
          _locationWasSelected = true;
          if (latLng == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Could not get coordinates. Please try a different search.'),
                backgroundColor: Colors.orange,
              ),
            );
            return;
          }
          setState(() {
            if (isPickup) {
              _pickupController.text = address;
              _pickupLocation = latLng;
              _pickupLocationReady = true; // Mark pickup as ready
              ref
                  .read(rideBookingProvider.notifier)
                  .setPickupLocation(address, latLng);
              debugPrint('📍 Pickup set from search: $address');
            } else if (editStopAt != null) {
              if (editStopAt < _stops.length) {
                _stops[editStopAt] =
                    RideStop(address: address, location: latLng);
                ref.read(rideBookingProvider.notifier).setStops(_stops);
              }
            } else if (addStopAt != null) {
              _stops.insert(
                  addStopAt, RideStop(address: address, location: latLng));
              ref.read(rideBookingProvider.notifier).setStops(_stops);
            } else {
              _destinationController.text = address;
              _destinationLocation = latLng;
              ref
                  .read(rideBookingProvider.notifier)
                  .setDestinationLocation(address, latLng);
              debugPrint('📍 Destination set from search: $address');
            }
          });
          _setupMapElements();
          _updateDriverMarkers();
          // Use safe route calculation that checks both locations
          _tryCalculateRoute();
          if (_destinationLocation != null) {
            Future.delayed(const Duration(milliseconds: 300), () {
              _fitRouteBounds(null);
            });
          }
        },
      ),
    ).then((_) {
      // If sheet was dismissed without selecting a location AND we came via auto-open,
      // pop back to the home screen
      if (!_locationWasSelected &&
          widget.autoOpenSearch &&
          _destinationController.text.isEmpty) {
        if (mounted && context.canPop()) {
          context.pop();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      endDrawer: _buildDrawer(),
      body: Stack(
        children: [
          // Full-bleed map base layer
          Positioned.fill(child: _buildMapSection()),

          // Top controls floating over map
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 8),
                    _buildLocationInputs(),
                  ],
                ),
              ),
            ),
          ),

          // Draggable bottom sheet (Uber/Ola style - drag up/down)
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.40,
            minChildSize: 0.25,
            maxChildSize: 0.90,
            snap: true,
            snapSizes: const [0.25, 0.40, 0.65, 0.90],
            builder: (context, scrollController) =>
                _buildBottomSheet(scrollController),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ActiveRideBanner(),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFFF5F0EA),
              ),
              child: Builder(
                builder: (context) {
                  final user = ref.watch(currentUserProvider);
                  final displayName = user?.name ?? user?.email ?? 'Rider';
                  final initial = displayName.isNotEmpty
                      ? displayName[0].toUpperCase()
                      : 'R';
                  return Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4956A),
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: Center(
                          child: Text(initial,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 16)),
                          const Text('View Profile',
                              style: TextStyle(
                                  color: Color(0xFF888888), fontSize: 12)),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),

            // Menu items
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('Home'),
              onTap: () {
                Navigator.pop(context);
                context.go(AppRoutes.home);
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('My Rides'),
              onTap: () {
                Navigator.pop(context);
                context.push(AppRoutes.history);
              },
            ),
            ListTile(
              leading: const Icon(Icons.payment),
              title: const Text('Payment Methods'),
              onTap: () {
                Navigator.pop(context);
                _showPaymentMethodsSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_offer),
              title: const Text('Offers & Promos'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Offers coming soon')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Help & Support'),
              onTap: () {
                Navigator.pop(context);
                _showHelpSupport();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                context.push(AppRoutes.profile);
              },
            ),

            const Spacer(),

            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Raahi v1.0.0',
                  style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  void _showHelpSupport() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Help & Support',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.phone, color: Color(0xFFD4956A)),
              title: const Text('Call Support'),
              subtitle: const Text('1800-123-4567'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.email, color: Color(0xFFD4956A)),
              title: const Text('Email Us'),
              subtitle: const Text('support@raahi.com'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.chat, color: Color(0xFFD4956A)),
              title: const Text('Live Chat'),
              subtitle: const Text('Available 24/7'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showPaymentMethodsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Payments',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    // Personal Wallet Section
                    const Text(
                      'Personal Wallet',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    _buildPaymentTile(
                      icon: Icons.account_balance_wallet,
                      iconColor: const Color(0xFFD4956A),
                      title: 'Raahi Wallet',
                      trailing: '₹0',
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Raahi Wallet selected'),
                            backgroundColor: Color(0xFF4CAF50),
                          ),
                        );
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentTile(
                      icon: Icons.qr_code_scanner,
                      iconColor: Colors.grey,
                      title: 'QR Pay',
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('QR Pay selected')),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    // UPI Section
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'UPI',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Pay by any UPI app',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildPaymentTile(
                      icon: Icons.payment,
                      iconColor: const Color(0xFF00BAF2),
                      title: 'Paytm UPI',
                      subtitle: 'Assured ₹25-₹200 Cashback',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiLinkDialog('Paytm UPI');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentTile(
                      icon: Icons.g_mobiledata,
                      iconColor: const Color(0xFF4285F4),
                      title: 'GPay UPI',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiLinkDialog('GPay UPI');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentTile(
                      icon: Icons.phone_android,
                      iconColor: const Color(0xFF5F259F),
                      title: 'PhonePe',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiLinkDialog('PhonePe');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentTile(
                      icon: Icons.account_balance,
                      iconColor: const Color(0xFF00695C),
                      title: 'BHIM UPI',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiLinkDialog('BHIM UPI');
                      },
                    ),
                    const SizedBox(height: 24),
                    // Other Methods
                    const Text(
                      'Other methods',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    _buildPaymentTile(
                      icon: Icons.credit_card,
                      iconColor: Colors.white,
                      title: 'Credit/Debit Card',
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Card payment selected')),
                        );
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentTile(
                      icon: Icons.money,
                      iconColor: const Color(0xFF4CAF50),
                      title: 'Cash',
                      subtitle: 'Pay on delivery',
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Cash selected'),
                            backgroundColor: Color(0xFF4CAF50),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    String? trailing,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                ],
              ),
            ),
            trailing != null
                ? Text(
                    trailing,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  void _showUpiLinkDialog(String upiMethod) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFD4956A).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  const Icon(Icons.account_balance, color: Color(0xFFD4956A)),
            ),
            const SizedBox(width: 12),
            Text(upiMethod, style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your $upiMethod ID',
              style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: 'mobile@upi',
                prefixIcon: const Icon(Icons.alternate_email),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final upiId = controller.text.trim();
              if (upiId.isEmpty || !upiId.contains('@')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a valid UPI ID')),
                );
                return;
              }
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('$upiMethod linked: $upiId'),
                  backgroundColor: const Color(0xFF4CAF50),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD4956A),
            ),
            child:
                const Text('Link UPI', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Back button
          GestureDetector(
            onTap: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(AppRoutes.home);
              }
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              child: const Icon(
                Icons.arrow_back,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ),
          // Zone health indicator (pricing v2)
          if (_zoneHealth != null) _buildZoneHealthIndicator(),
          // Menu button
          GestureDetector(
            onTap: () {
              _scaffoldKey.currentState?.openEndDrawer();
            },
            child: const Icon(
              Icons.menu,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ],
      ),
    );
  }

  /// Build zone health indicator (pricing v2 feature)
  Widget _buildZoneHealthIndicator() {
    if (_zoneHealth == null) return const SizedBox.shrink();

    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (_zoneHealth!.status) {
      case ZoneHealthStatus.critical:
        statusColor = Colors.red;
        statusText = 'High Demand';
        statusIcon = Icons.local_fire_department;
        break;
      case ZoneHealthStatus.moderate:
        statusColor = Colors.orange;
        statusText = 'Moderate';
        statusIcon = Icons.trending_up;
        break;
      case ZoneHealthStatus.healthy:
        statusColor = Colors.green;
        statusText = 'Normal';
        statusIcon = Icons.check_circle;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon, size: 14, color: statusColor),
          const SizedBox(width: 4),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
          if (_zoneHealth!.status == ZoneHealthStatus.critical) ...[
            const SizedBox(width: 4),
            Text(
              '~${_zoneHealth!.etaP90.round()}min',
              style: TextStyle(
                fontSize: 10,
                color: statusColor.withOpacity(0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMapSection() {
    final screenHeight = MediaQuery.of(context).size.height;
    double sheetFraction = 0.40;
    try {
      final s = _sheetController.size;
      if (s > 0 && s <= 1) sheetFraction = s;
    } catch (_) {
      // Controller may not be attached yet (e.g. before sheet builds)
    }
    final sheetHeightPx = screenHeight * sheetFraction;

    return Stack(
      children: [
        // Google Map (full-bleed)
        Positioned.fill(
          child: Builder(
            builder: (context) {
              // Watch dark mode changes and reload style if needed
              final isDarkMode = ref.watch(settingsProvider).isDarkMode;
              if (isDarkMode != _lastDarkMode) {
                _lastDarkMode = isDarkMode;
                _loadMapStyle();
              }
              // Calculate initial camera position - use pickup if available, else default
              final initialTarget = _pickupLocation != null && _destinationLocation != null
                  ? LatLng(
                      (_pickupLocation!.latitude + _destinationLocation!.latitude) / 2,
                      (_pickupLocation!.longitude + _destinationLocation!.longitude) / 2,
                    )
                  : _pickupLocation ?? const LatLng(28.4595, 77.0266); // Gurgaon default for initial map view only
              
              return GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: initialTarget,
                  zoom: 12,
                ),
                markers: _markers,
                polylines: _polylines,
                onMapCreated: (GoogleMapController controller) {
                  _controller = controller;
                  if (!_mapController.isCompleted) {
                    _mapController.complete(controller);
                  }
                  _currentZoomLevel = 12.0;
                  // Apply map style
                  if (_mapStyle != null) {
                    controller.setMapStyle(_mapStyle);
                  }
                  _updateDriverMarkers();
                  // Fit bounds after map is created and route is calculated
                  Future.delayed(const Duration(milliseconds: 500), () {
                    if (_polylines.isNotEmpty) {
                      _fitRouteBounds(null);
                    }
                  });
                },
                onCameraMove: (position) {
                  _currentZoomLevel = position.zoom;
                },
                onCameraIdle: _updateDriverMarkers,
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                // Keep route/map labels visible below top overlays and above bottom sheet.
                padding: EdgeInsets.only(top: 220, bottom: sheetHeightPx),
              );
            },
          ),
        ),

        // Loading indicator for route calculation
        if (_isLoadingRoute)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: Center(
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const UberShimmer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UberShimmerBox(width: 160, height: 14),
                        SizedBox(height: 10),
                        UberShimmerBox(width: 120, height: 12),
                        SizedBox(height: 10),
                        UberShimmerBox(width: 180, height: 10),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

        // Center on route button (moves with bottom sheet)
        Positioned(
          bottom: sheetHeightPx + 20,
          right: 16,
          child: GestureDetector(
            onTap: () => _fitRouteBounds(null),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(
                Icons.center_focus_strong,
                size: 22,
                color: Color(0xFF4285F4),
              ),
            ),
          ),
        ),

        // Route info badge (moves with bottom sheet)
        if (_distanceText.isNotEmpty && !_isLoadingRoute)
          Positioned(
            bottom: sheetHeightPx + 20,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.route, size: 16, color: Color(0xFF4285F4)),
                  const SizedBox(width: 6),
                  Text(
                    _distanceText,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: const BoxDecoration(
                      color: Color(0xFF888888),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.access_time,
                      size: 16, color: Color(0xFF4285F4)),
                  const SizedBox(width: 4),
                  Text(
                    _durationText,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLocationInputs() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Find a trip header
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              ref.tr('find_trip'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Pickup location - Tappable
          GestureDetector(
            onTap: () => _showLocationSearchSheet(isPickup: true),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFFD4956A),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _pickupController.text.isEmpty
                          ? ref.tr('enter_pickup')
                          : _pickupController.text,
                      style: TextStyle(
                        fontSize: 14,
                        color: _pickupController.text.isEmpty
                            ? const Color(0xFFBDBDBD)
                            : const Color(0xFF1A1A1A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(
                    Icons.edit,
                    size: 16,
                    color: Color(0xFFBDBDBD),
                  ),
                ],
              ),
            ),
          ),

          // Stops (Ola/Uber/Rapido style)
          ..._stops.asMap().entries.map((e) {
            final i = e.key;
            final stop = e.value;
            return Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 4),
                    Container(
                        width: 2, height: 12, color: const Color(0xFFE0E0E0)),
                    const SizedBox(width: 18),
                    const Expanded(child: Divider(color: Color(0xFFE0E0E0))),
                  ],
                ),
                GestureDetector(
                  onTap: () =>
                      _showLocationSearchSheet(isPickup: false, editStopAt: i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: const Color(0xFF4285F4),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            stop.address,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF1A1A1A)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _stops.removeAt(i);
                              ref
                                  .read(rideBookingProvider.notifier)
                                  .setStops(_stops);
                            });
                            _tryCalculateRoute();
                          },
                          child: const Icon(Icons.close,
                              size: 18, color: Color(0xFFBDBDBD)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
          // Add stop button (max 3 stops like Uber/Ola)
          if (_stops.length < 3)
            GestureDetector(
              onTap: () => _showLocationSearchSheet(
                  isPickup: false, addStopAt: _stops.length),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Container(
                        width: 2, height: 12, color: const Color(0xFFE0E0E0)),
                    const SizedBox(width: 18),
                    const Icon(Icons.add_circle_outline,
                        size: 18, color: Color(0xFF4285F4)),
                    const SizedBox(width: 8),
                    Text(
                      'Add stop',
                      style: TextStyle(
                          fontSize: 14,
                          color: const Color(0xFF4285F4).withOpacity(0.9)),
                    ),
                  ],
                ),
              ),
            ),

          // Divider with connecting line (before destination)
          Row(
            children: [
              const SizedBox(width: 4),
              Container(
                width: 2,
                height: 20,
                color: const Color(0xFFE0E0E0),
              ),
              const SizedBox(width: 18),
              const Expanded(
                child: Divider(color: Color(0xFFE0E0E0)),
              ),
            ],
          ),

          // Destination - Tappable
          GestureDetector(
            onTap: () => _showLocationSearchSheet(isPickup: false),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    size: 14,
                    color: Color(0xFF4CAF50),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _destinationController.text.isEmpty
                          ? ref.tr('enter_destination')
                          : _destinationController.text,
                      style: TextStyle(
                        fontSize: 14,
                        color: _destinationController.text.isEmpty
                            ? const Color(0xFFBDBDBD)
                            : const Color(0xFF1A1A1A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(
                    Icons.edit,
                    size: 16,
                    color: Color(0xFFBDBDBD),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSheet(ScrollController scrollController) {
    final bool showBookButton =
        _cabTypes.isNotEmpty && _destinationController.text.isNotEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Scrollable content - uses sheet's scrollController for proper drag + scroll
          Expanded(
            child: ListView(
              controller: scrollController,
              padding:
                  EdgeInsets.fromLTRB(20, 12, 20, showBookButton ? 10 : 24),
              physics: const ClampingScrollPhysics(),
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0E0E0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Select Ride header with route info
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Services',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        if (_isLoadingPricing)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                    if (_distanceText.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F0EA),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.route,
                                size: 12, color: const Color(0xFFD4956A)),
                            const SizedBox(width: 4),
                            Text(
                              _distanceText,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFFD4956A),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _durationText.isNotEmpty
                            ? 'Estimated arrival: $_durationText'
                            : 'Select a service to get started',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ),
                    // Surge pricing indicator
                    if (_isSurgeActive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.shade300),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt,
                                size: 12, color: Colors.orange.shade700),
                            const SizedBox(width: 2),
                            Text(
                              '${_surgeMultiplier}x',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.orange.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Launch mode savings indicator
                    if (_riderSubsidy?.isActive == true && _savingsAmount > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.green.shade300),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.local_offer,
                                size: 12, color: Colors.green.shade700),
                            const SizedBox(width: 2),
                            Text(
                              'Save ₹${_savingsAmount.round()}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),

                // Launch mode promotional banner
                if (_marketplaceMode == MarketplaceMode.launch &&
                    _riderSubsidy != null &&
                    _riderSubsidy!.isActive)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.green.shade50, Colors.green.shade100],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.green.shade400,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.celebration,
                              color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Launch Offer Active!',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.green.shade800,
                                ),
                              ),
                              Text(
                                '${(_riderSubsidy!.subsidyPct * 100).round()}% off on all rides (up to ₹${_riderSubsidy!.maxSubsidyCap.round()})',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),

                // Show destination prompt when no destination is set
                if (_destinationController.text.isEmpty)
                  GestureDetector(
                    onTap: () => _showLocationSearchSheet(isPickup: false),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F0EA),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: const Color(0xFFD4956A).withOpacity(0.3)),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.add_location_alt,
                              size: 48,
                              color: const Color(0xFFD4956A).withOpacity(0.7)),
                          const SizedBox(height: 12),
                          const Text(
                            'Where do you want to go?',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1A1A1A)),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Tap to enter your destination',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF888888)),
                          ),
                        ],
                      ),
                    ),
                  )
                // Loading state
                else if (_isLoadingPricing && _cabTypes.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Loading services...',
                              style: TextStyle(color: Color(0xFF888888))),
                        ],
                      ),
                    ),
                  )
                else
                  // Cab options list
                  ..._cabTypes.map((cab) => _buildCabOption(cab)),

                if (showBookButton) ...[
                  const SizedBox(height: 12),
                  _buildDriverCountSelector(),
                  const SizedBox(height: 16),
                  if (_cabFares.isNotEmpty) _buildFareBreakdown(),
                ],
              ],
            ),
          ),

          // Fixed Book Ride button at bottom
          if (showBookButton)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: _buildBookRideButton(),
            ),
        ],
      ),
    );
  }

  // Service cards shown before destination is set
  List<Widget> _buildServiceCards() {
    final services = [
      {
        'id': 'bike_rescue',
        'name': 'Rescue Service',
        'desc': 'Quick two-wheeler pickup & drop',
        'icon': Icons.two_wheeler,
        'color': const Color(0xFFD4956A)
      },
      {
        'id': 'auto',
        'name': 'Auto',
        'desc': 'Budget-friendly auto rickshaw',
        'icon': Icons.electric_rickshaw,
        'color': const Color(0xFF4CAF50)
      },
      {
        'id': 'cab_mini',
        'name': 'Cab Mini',
        'desc': 'Compact cars for city rides',
        'icon': Icons.directions_car,
        'color': const Color(0xFF2196F3)
      },
      {
        'id': 'cab_xl',
        'name': 'Cab XL',
        'desc': 'Spacious SUVs for groups',
        'icon': Icons.airport_shuttle,
        'color': const Color(0xFF7B1FA2)
      },
      {
        'id': 'cab_premium',
        'name': 'Cab Premium',
        'desc': 'Luxury sedans with top drivers',
        'icon': Icons.diamond,
        'color': const Color(0xFFFF9800)
      },
      {
        'id': 'personal_driver',
        'name': 'Personal Driver',
        'desc': 'Hire a driver for your car',
        'icon': Icons.person,
        'color': const Color(0xFF455A64)
      },
    ];

    return services.map((svc) {
      final isSelected = _selectedCabType == svc['id'];
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onTap: () {
            setState(() => _selectedCabType = svc['id'] as String);
            _updateDriverMarkers();
            _showLocationSearchSheet(isPickup: false);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isSelected
                  ? (svc['color'] as Color).withOpacity(0.08)
                  : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? (svc['color'] as Color)
                    : const Color(0xFFE8E0D4),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (svc['color'] as Color).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(svc['icon'] as IconData,
                      color: svc['color'] as Color, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        svc['name'] as String,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A1A)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        svc['desc'] as String,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF888888)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    size: 14, color: const Color(0xFFBDBDBD)),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildCabOption(CabType cab) {
    final isSelected = _selectedCabType == cab.id;
    final fare = _cabFares[cab.id];

    return GestureDetector(
      onTap: () {
        setState(() => _selectedCabType = cab.id);
        _updateDriverMarkers();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFAF8F5) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color:
                isSelected ? const Color(0xFFD4956A) : const Color(0xFFE8E8E8),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFFD4956A).withOpacity(0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            // Cab image
            Container(
              width: 70,
              height: 56,
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFD4956A).withOpacity(0.08)
                    : const Color(0xFFF8F8F8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  _getVehicleImage(cab.id),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    cab.icon,
                    color: isSelected
                        ? const Color(0xFFD4956A)
                        : const Color(0xFF666666),
                    size: 28,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Cab details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        cab.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? const Color(0xFFD4956A)
                              : const Color(0xFF1A1A1A),
                        ),
                      ),
                      if (cab.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cab.id == 'auto'
                                ? const Color(0xFFE8F5E9)
                                : cab.id == 'cab_premium'
                                    ? const Color(0xFFFFF3E0)
                                    : const Color(0xFFE3F2FD),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            cab.badge!,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: cab.id == 'auto'
                                  ? const Color(0xFF4CAF50)
                                  : cab.id == 'cab_premium'
                                      ? const Color(0xFFFF9800)
                                      : const Color(0xFF2196F3),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    cab.description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF888888),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.person,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${cab.capacity}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 2),
                      Text(
                        cab.eta,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Price
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (fare != null)
                  Text(
                    '₹${fare.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? const Color(0xFFD4956A)
                          : const Color(0xFF1A1A1A),
                    ),
                  )
                else
                  Text(
                    '₹${cab.baseFare.toStringAsFixed(0)}+',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[600],
                    ),
                  ),
                if (isSelected)
                  const Icon(
                    Icons.check_circle,
                    color: Color(0xFFD4956A),
                    size: 20,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFareBreakdown() {
    final selectedCab = _cabTypes.firstWhere((c) => c.id == _selectedCabType);
    final fare = _cabFares[_selectedCabType] ?? 0;
    final distanceKm = _distanceText.isNotEmpty
        ? double.tryParse(_distanceText.replaceAll(' km', '')) ?? 0
        : 0;
    final durationMin = _durationText.isNotEmpty
        ? double.tryParse(_durationText.replaceAll(' min', '')) ?? 0
        : 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Fare Estimate - ${selectedCab.name}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'BEST PRICE',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF4CAF50),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildFareRow(
              'Base Fare', '₹${selectedCab.baseFare.toStringAsFixed(0)}'),
          _buildFareRow(
              'Distance (${distanceKm.toStringAsFixed(1)} km × ₹${selectedCab.perKmRate.toStringAsFixed(0)})',
              '₹${(distanceKm * selectedCab.perKmRate).toStringAsFixed(0)}'),
          _buildFareRow(
              'Time (${durationMin.toStringAsFixed(0)} min × ₹${selectedCab.perMinRate.toStringAsFixed(0)})',
              '₹${(durationMin * selectedCab.perMinRate).toStringAsFixed(0)}'),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              Text(
                '₹${fare.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFD4956A),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFareRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF666666),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ],
      ),
    );
  }

  static const double _intercityThresholdKm = 50;

  Widget _buildBookRideButton() {
    final selectedCab = _cabTypes.firstWhere((c) => c.id == _selectedCabType);
    final fare = _cabFares[_selectedCabType] ?? selectedCab.baseFare;
    final bookingState = ref.read(rideBookingProvider);
    final distanceKm = bookingState.distance / 1000;

    return GestureDetector(
      onTap: () {
        // Block intercity rides for now
        if (distanceKm > _intercityThresholdKm) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: const [
                  Icon(Icons.info_outline, color: Color(0xFFD4956A), size: 28),
                  SizedBox(width: 12),
                  Text('Intercity Coming Soon'),
                ],
              ),
              content: const Text(
                'Rides between different cities are not available yet. We are working on bringing intercity rides soon. Please book a ride within the same city for now.',
                style: TextStyle(fontSize: 15),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }

        // Update provider with selected cab type (including pricing v2 data)
        final isEcoPickup = selectedCab.id == 'eco_pickup';
        ref.read(rideBookingProvider.notifier).setCabType(
              id: selectedCab.id,
              name: selectedCab.name,
              fare: fare,
              originalFare: _riderSubsidy != null && _riderSubsidy!.isActive
                  ? fare / (1 - _riderSubsidy!.subsidyPct)
                  : fare,
              subsidyAmount: _savingsAmount,
              isSubsidyApplied: _riderSubsidy?.isActive ?? false,
              isEcoPickup: isEcoPickup,
              ecoPickupAddress:
                  isEcoPickup ? _ecoPickup?.suggestedPickupAddress : null,
              ecoPickupLocation: isEcoPickup && _ecoPickup != null
                  ? LatLng(
                      _ecoPickup!.suggestedLat,
                      _ecoPickup!.suggestedLng,
                    )
                  : null,
            );
        // Set driver count
        ref.read(rideBookingProvider.notifier).setDriverCount(_driverCount);
        // Navigate to payment screen
        context.push(AppRoutes.ridePayment);
      },
      child: Container(
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFD4956A), Color(0xFFC47F4F)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFD4956A).withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selectedCab.icon,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              fare != null
                  ? '${ref.tr('book')} ${selectedCab.name} • ₹${fare.toStringAsFixed(0)}'
                  : '${ref.tr('book')} ${selectedCab.name}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward,
              color: Colors.white,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverCountSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                ref.tr('select_drivers'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const Spacer(),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE0E0E0)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: _needExtraDrivers && _driverCount > 1
                          ? () => setState(() => _driverCount--)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _needExtraDrivers && _driverCount > 1
                              ? const Color(0xFFD4956A)
                              : const Color(0xFFE0E0E0),
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(7)),
                        ),
                        child: Icon(
                          Icons.remove,
                          size: 18,
                          color: _needExtraDrivers && _driverCount > 1
                              ? Colors.white
                              : Colors.grey,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      color: Colors.white,
                      child: Text(
                        '$_driverCount',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _needExtraDrivers
                          ? () => setState(() => _driverCount++)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _needExtraDrivers
                              ? const Color(0xFFD4956A)
                              : const Color(0xFFE0E0E0),
                          borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(7)),
                        ),
                        child: Icon(
                          Icons.add,
                          size: 18,
                          color: _needExtraDrivers ? Colors.white : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  "Don't Need extra Drivers?",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: _needExtraDrivers,
                  onChanged: (value) {
                    setState(() {
                      _needExtraDrivers = value;
                      if (!value) _driverCount = 1;
                    });
                  },
                  activeColor: const Color(0xFFD4956A),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Location Search Bottom Sheet with saved places integration
class _LocationSearchSheet extends ConsumerStatefulWidget {
  final bool isPickup;
  final String initialValue;
  final LatLng? biasLocation;
  final Function(String address, LatLng? latLng) onLocationSelected;

  const _LocationSearchSheet({
    required this.isPickup,
    required this.initialValue,
    this.biasLocation,
    required this.onLocationSelected,
  });

  @override
  ConsumerState<_LocationSearchSheet> createState() =>
      _LocationSearchSheetState();
}

class _LocationSearchSheetState extends ConsumerState<_LocationSearchSheet> {
  late TextEditingController _searchController;
  List<_LocationSuggestion> _suggestions = [];
  bool _isLoading = false;
  Timer? _debounce;
  final PlacesService _placesService = PlacesService();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialValue);
    _loadInitialSuggestions();
  }

  /// Load saved places + recent locations as initial suggestions
  void _loadInitialSuggestions() {
    final savedLocationsState = ref.read(savedLocationsProvider);
    final suggestions = <_LocationSuggestion>[];

    // Add "Current Location" option at top
    suggestions.add(_LocationSuggestion(
      name: 'Current Location',
      address: 'Use GPS to detect your location',
      latLng: null,
      icon: Icons.my_location,
    ));

    // Add Home if saved
    if (savedLocationsState.homeLocation != null) {
      final home = savedLocationsState.homeLocation!;
      suggestions.add(_LocationSuggestion(
        name: 'Home',
        address: home.address,
        latLng: home.latLng,
        placeId: home.placeId,
        icon: Icons.home_rounded,
      ));
    }

    // Add Work if saved
    if (savedLocationsState.workLocation != null) {
      final work = savedLocationsState.workLocation!;
      suggestions.add(_LocationSuggestion(
        name: 'Work',
        address: work.address,
        latLng: work.latLng,
        placeId: work.placeId,
        icon: Icons.work_rounded,
      ));
    }

    // Add favorites
    for (final fav in savedLocationsState.favorites) {
      suggestions.add(_LocationSuggestion(
        name: fav.name,
        address: fav.address,
        latLng: fav.latLng,
        placeId: fav.placeId,
        icon: Icons.favorite_rounded,
      ));
    }

    // Add recent locations (up to 5)
    for (final recent in savedLocationsState.recentLocations.take(5)) {
      // Skip if already in suggestions (Home/Work/Favorites)
      final alreadyAdded = suggestions.any((s) =>
          s.latLng != null &&
          recent.latLng.latitude == s.latLng!.latitude &&
          recent.latLng.longitude == s.latLng!.longitude);
      if (!alreadyAdded) {
        suggestions.add(_LocationSuggestion(
          name: recent.name,
          address: recent.address,
          latLng: recent.latLng,
          placeId: recent.placeId,
          icon: Icons.history_rounded,
        ));
      }
    }

    // Fallback: if no saved locations, show some defaults
    if (suggestions.length <= 1) {
      suggestions.addAll([
        _LocationSuggestion(
          name: 'U Block, DLF Phase 3',
          address: 'Sector 24, Gurugram, Haryana',
          latLng: const LatLng(28.4595, 77.0266),
        ),
        _LocationSuggestion(
          name: 'Cyber Hub',
          address: 'DLF Cyber City, Gurugram',
          latLng: const LatLng(28.4949, 77.0887),
        ),
      ]);
    }

    setState(() => _suggestions = suggestions);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    // End Places API session when sheet closes
    _placesService.endSession();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    // Cancel previous debounce timer
    _debounce?.cancel();

    if (query.isEmpty) {
      _loadInitialSuggestions();
      setState(() => _isLoading = false);
      return;
    }

    // Show loading
    setState(() => _isLoading = true);

    // Debounce the search - reduced to 300ms for faster response
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchLocation(query);
    });
  }

  Future<void> _searchLocation(String query) async {
    try {
      debugPrint('🔍 Searching for: "$query" (length: ${query.length})');

      // Use device location for search bias (critical for relevant suggestions in user's city)
      // Fallback: widget.biasLocation (parent's pickup/destination) -> ride booking -> India center
      LatLng? searchBiasLocation;
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 3),
        );
        searchBiasLocation = LatLng(position.latitude, position.longitude);
        debugPrint(
            '📍 Using device location for search bias: $searchBiasLocation');
      } catch (e) {
        debugPrint('📍 Geolocator failed, using fallback for search bias: $e');
        searchBiasLocation = widget.biasLocation;
        if (searchBiasLocation == null) {
          final booking = ref.read(rideBookingProvider);
          searchBiasLocation = widget.isPickup
              ? booking.destinationLocation ?? booking.pickupLocation
              : booking.pickupLocation;
        }
        if (searchBiasLocation == null) {
          searchBiasLocation = const LatLng(
              25.45, 81.85); // Prayagraj/Allahabad as India fallback
          debugPrint('📍 Using India fallback for search bias');
        }
      }

      final placesResults = await _placesService.searchPlacesWithFallback(query,
          location: searchBiasLocation);
      debugPrint('🔍 Places API returned ${placesResults.length} results');

      if (placesResults.isNotEmpty) {
        setState(() {
          _suggestions = placesResults
              .map((place) => _LocationSuggestion(
                    name: place.name,
                    address: place.address,
                    latLng: place.latLng,
                    placeId: place.placeId,
                  ))
              .toList();
          _isLoading = false;
        });
        return;
      }

      // Fallback to geocoding if Places API returns nothing
      debugPrint('📍 Places API empty, falling back to geocoding...');

      try {
        final List<Location> locations = await locationFromAddress(
          query,
          localeIdentifier: 'en_IN',
        );

        if (locations.isNotEmpty) {
          final suggestions = <_LocationSuggestion>[];

          for (final location in locations.take(5)) {
            try {
              final placemarks = await placemarkFromCoordinates(
                location.latitude,
                location.longitude,
              );

              if (placemarks.isNotEmpty) {
                final place = placemarks.first;
                final name = place.name ?? place.street ?? query;
                final address = [
                  place.subLocality,
                  place.locality,
                  place.administrativeArea,
                ].where((e) => e != null && e.isNotEmpty).join(', ');

                suggestions.add(_LocationSuggestion(
                  name: name,
                  address: address.isNotEmpty ? address : 'India',
                  latLng: LatLng(location.latitude, location.longitude),
                ));
              }
            } catch (_) {
              suggestions.add(_LocationSuggestion(
                name: query,
                address:
                    '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
                latLng: LatLng(location.latitude, location.longitude),
              ));
            }
          }

          if (suggestions.isNotEmpty) {
            setState(() {
              _suggestions = suggestions;
              _isLoading = false;
            });
            return;
          }
        }
      } catch (e) {
        debugPrint('Geocoding fallback error: $e');
      }

      // No results found
      setState(() {
        _suggestions = [
          _LocationSuggestion(
            name: query,
            address: 'No results found. Try a more specific address.',
            latLng: null,
            icon: Icons.search_off,
          ),
        ];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Search error: $e');
      setState(() {
        _suggestions = [
          _LocationSuggestion(
            name: query,
            address: 'Search error. Please try again.',
            latLng: null,
            icon: Icons.error_outline,
          ),
        ];
        _isLoading = false;
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _isLoading = true);

    try {
      // Check permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Get address from coordinates
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      String address = 'Current Location';
      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        address = [
          place.name,
          place.street,
          place.subLocality,
          place.locality,
        ].where((e) => e != null && e.isNotEmpty).take(3).join(', ');
      }

      widget.onLocationSelected(
        address,
        LatLng(position.latitude, position.longitude),
      );

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error getting current location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error getting location: $e')),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE0E0E0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, color: Color(0xFF1A1A1A)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    widget.isPickup
                        ? 'Enter pickup location'
                        : 'Enter destination',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Search input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                onSubmitted: (query) {
                  if (query.isNotEmpty) {
                    _searchLocation(query);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Search any location (e.g., PVR Allahabad)',
                  hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                  prefixIcon: Icon(
                    widget.isPickup ? Icons.circle : Icons.location_on,
                    color: widget.isPickup
                        ? const Color(0xFFD4956A)
                        : const Color(0xFF4CAF50),
                    size: 18,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                          child:
                              const Icon(Icons.clear, color: Color(0xFFBDBDBD)),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Use Current Location button
          if (widget.isPickup)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GestureDetector(
                onTap: _getCurrentLocation,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F8FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF4285F4).withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4285F4),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Use Current Location',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                            Text(
                              'Get your GPS location',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF888888),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Color(0xFF4285F4)),
                    ],
                  ),
                ),
              ),
            ),

          const SizedBox(height: 12),

          // Section header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _searchController.text.isEmpty
                    ? 'Recent Locations'
                    : 'Search Results',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF888888),
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Suggestions list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Color(0xFFD4956A)),
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Searching locations...',
                          style: TextStyle(color: Color(0xFF888888)),
                        ),
                      ],
                    ),
                  )
                : _suggestions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off,
                                size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'No locations found',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Try a different search term',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[400]),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _suggestions.length,
                        itemBuilder: (context, index) {
                          final suggestion = _suggestions[index];
                          return _buildSuggestionTile(suggestion);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionTile(_LocationSuggestion suggestion) {
    return GestureDetector(
      onTap: () async {
        if (suggestion.name == 'Current Location') {
          _getCurrentLocation();
          return;
        }

        // If we have a placeId but no coordinates, fetch them
        if (suggestion.latLng == null && suggestion.placeId != null) {
          setState(() => _isLoading = true);
          LatLng? latLng =
              await _placesService.getPlaceDetails(suggestion.placeId!);

          // Fallback: try geocoding if Place Details API fails
          if (latLng == null) {
            debugPrint(
                '⚠️ Place Details failed, falling back to geocoding for: ${suggestion.name}');
            try {
              final locations = await locationFromAddress(
                '${suggestion.name}, ${suggestion.address}',
                localeIdentifier: 'en_IN',
              );
              if (locations.isNotEmpty) {
                latLng =
                    LatLng(locations.first.latitude, locations.first.longitude);
              }
            } catch (e) {
              debugPrint('Geocoding fallback also failed: $e');
            }
          }

          setState(() => _isLoading = false);

          if (latLng != null) {
            // Save to recent locations if this is a destination selection
            if (!widget.isPickup) {
              ref.read(savedLocationsProvider.notifier).addRecentLocation(
                    name: suggestion.name,
                    address: suggestion.address,
                    location: latLng,
                    placeId: suggestion.placeId,
                  );
            }

            widget.onLocationSelected(
              '${suggestion.name}, ${suggestion.address}',
              latLng,
            );
            if (mounted) Navigator.pop(context);
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text(
                        'Could not get location coordinates. Try a different search.')),
              );
            }
          }
          return;
        }

        if (suggestion.latLng == null) {
          // Location not found, try searching again
          _searchLocation(suggestion.name);
          return;
        }

        // Save to recent locations if this is a destination selection (not pickup)
        if (!widget.isPickup &&
            suggestion.latLng != null &&
            suggestion.name != 'Current Location') {
          ref.read(savedLocationsProvider.notifier).addRecentLocation(
                name: suggestion.name,
                address: suggestion.address,
                location: suggestion.latLng!,
                placeId: suggestion.placeId,
              );
        }

        widget.onLocationSelected(
          '${suggestion.name}${suggestion.address.isNotEmpty ? ', ${suggestion.address}' : ''}',
          suggestion.latLng,
        );
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFF0F0F0)),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _getIconBackgroundColor(suggestion.icon),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                suggestion.icon ?? Icons.location_on_outlined,
                color: _getIconColor(suggestion.icon),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  if (suggestion.address.isNotEmpty)
                    Text(
                      suggestion.address,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF888888),
                      ),
                    ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              color: Color(0xFFBDBDBD),
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Color _getIconBackgroundColor(IconData? icon) {
    if (icon == Icons.my_location) return const Color(0xFFE3F2FD);
    if (icon == Icons.home_rounded) return const Color(0xFFE8F5E9);
    if (icon == Icons.work_rounded) return const Color(0xFFFFF3E0);
    if (icon == Icons.favorite_rounded) return const Color(0xFFFFEBEE);
    if (icon == Icons.history_rounded) return const Color(0xFFF5F5F5);
    return const Color(0xFFF5F5F5);
  }

  Color _getIconColor(IconData? icon) {
    if (icon == Icons.my_location) return const Color(0xFF4285F4);
    if (icon == Icons.home_rounded) return const Color(0xFF4CAF50);
    if (icon == Icons.work_rounded) return const Color(0xFFFF9800);
    if (icon == Icons.favorite_rounded) return const Color(0xFFE91E63);
    if (icon == Icons.history_rounded) return const Color(0xFF9E9E9E);
    return const Color(0xFF888888);
  }
}

class _LocationSuggestion {
  final String name;
  final String address;
  final LatLng? latLng;
  final IconData? icon;
  final String? placeId;

  _LocationSuggestion({
    required this.name,
    required this.address,
    this.latLng,
    this.icon,
    this.placeId,
  });
}

class _NearbyDriver {
  final String id;
  final LatLng position;
  final String type;
  final String name;
  final double rating;
  final double heading;

  const _NearbyDriver({
    required this.id,
    required this.position,
    required this.type,
    required this.name,
    required this.rating,
    required this.heading,
  });
}

class _DriverVisualCluster {
  final LatLng center;
  final List<_NearbyDriver> drivers;

  const _DriverVisualCluster({
    required this.center,
    required this.drivers,
  });

  int get count => drivers.length;

  String get clusterId {
    final ids = drivers.map((d) => d.id).toList()..sort();
    return ids.join('_');
  }
}
