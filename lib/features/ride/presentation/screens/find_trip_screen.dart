import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:ionicons/ionicons.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/directions_service.dart';
import '../../../../core/services/places_service.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../../core/widgets/figma_square_back_button.dart';
import '../../../../core/widgets/schedule_ride_sheet.dart';
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
  /// From hub "Later": pick drop first, then show schedule sheet (no time on home).
  final bool scheduleAfterLocations;
  const FindTripScreen({
    super.key,
    this.autoOpenSearch = false,
    this.initialServiceType,
    this.scheduledTime,
    this.scheduleAfterLocations = false,
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
  static const Color _findTripAccent = Color(0xFFD4956A);
  /// Figma map pills (Frame 1410081802)
  static const Color _figmaPillBrown = Color(0xFFCF923D);
  static const Color _figmaPillLabel = Color(0xFF5B5B5B);
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

  /// Prevents stacking multiple auto-opens from _tryCalculateRoute.
  bool _deferredSchedulePickerShown = false;

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
  /// From last [RouteResult]; used so pickup pill ≠ drop when multi-leg.
  int _routeLegCount = 0;
  int _firstLegDurationMin = 0;
  /// Screen positions (map-local px) for floating pills above pickup/drop.
  Offset? _pickupPillAnchor;
  Offset? _dropPillAnchor;
  /// Ignore stale [getScreenCoordinate] results when camera moves quickly.
  int _pillAnchorGen = 0;
  DateTime? _lastPillRefreshDuringMove;
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
    // If not auto-opening search, attempt route (e.g. provider already has both places).
    if (!widget.autoOpenSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _tryCalculateRoute();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
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

  /// Chip label aligned with Services hub (implicit now → "Later").
  String get _scheduleChipLabel {
    if (_scheduledTime == null) return 'Later';
    final now = DateTime.now();
    final scheduled = _scheduledTime!;
    if (scheduled.day == now.day &&
        scheduled.month == now.month &&
        scheduled.year == now.year) {
      return DateFormat('h:mm a').format(scheduled);
    }
    final tomorrow = now.add(const Duration(days: 1));
    if (scheduled.day == tomorrow.day &&
        scheduled.month == tomorrow.month &&
        scheduled.year == tomorrow.year) {
      return 'Tomorrow, ${DateFormat('h:mm a').format(scheduled)}';
    }
    return DateFormat('MMM d, h:mm a').format(scheduled);
  }

  bool _hasValidPickupAndDestination() {
    return _pickupLocationReady &&
        _pickupLocation != null &&
        _destinationLocation != null &&
        _pickupController.text.trim().isNotEmpty &&
        _destinationController.text.trim().isNotEmpty &&
        _isValidCoordinate(_pickupLocation!) &&
        _isValidCoordinate(_destinationLocation!);
  }

  /// Hub "Later" flow: open schedule sheet only after pickup + drop are set.
  void _maybeShowDeferredSchedulePicker() {
    if (!widget.scheduleAfterLocations) return;
    if (_deferredSchedulePickerShown) return;
    if (_scheduledTime != null) return;
    if (!_hasValidPickupAndDestination()) return;

    _deferredSchedulePickerShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showFindTripSchedulePicker();
    });
  }

  void _showFindTripSchedulePicker([VoidCallback? afterClose]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ScheduleRidePickerSheet(
        currentSchedule: _scheduledTime,
        accentColor: _findTripAccent,
        onConfirm: (DateTime selected) {
          if (mounted) setState(() => _scheduledTime = selected);
          Navigator.pop(ctx);
          afterClose?.call();
        },
      ),
    );
  }

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
      textDirection: ui.TextDirection.ltr,
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
    _maybeShowDeferredSchedulePicker();
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
      if (stop.location == null) continue;
      stopMarkers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: stop.location!,
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

    // Pickup + destination: no default pins — pills + polyline show route (Figma).
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
      _routeLegCount = 0;
      _firstLegDurationMin = 0;
    });

    try {
      // DEBUG LOGGING - verify coordinates before route call
      debugPrint('========================================');
      debugPrint('🗺️ ROUTE DEBUG - Calculating route:');
      debugPrint('   Pickup: ${_pickupLocation!.latitude}, ${_pickupLocation!.longitude}');
      debugPrint('   Drop: ${_destinationLocation!.latitude}, ${_destinationLocation!.longitude}');
      debugPrint('========================================');

      final waypointCoords = _stops
          .where((s) => s.location != null)
          .map((s) => s.location!)
          .toList();
      final waypoints =
          waypointCoords.isEmpty ? null : waypointCoords;
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
        _routeLegCount = route.legCount;
        _firstLegDurationMin =
            math.max(1, (route.firstLegDurationSeconds / 60).ceil());

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
        _routeLegCount = 0;
        _firstLegDurationMin = 0;
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
      final completeStops = _stops.where((s) => s.location != null).toList();
      final waypointsForPricing = completeStops.isNotEmpty
          ? completeStops
              .map((s) => {
                    'lat': s.location!.latitude,
                    'lng': s.location!.longitude,
                  })
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
        ..._stops.where((s) => s.location != null).map((s) => s.location!),
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
      if (mounted) await _refreshMapPillPositions();
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
      if (mounted) await _refreshMapPillPositions();
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
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            return _LocationSearchSheet(
              isPickup: isPickup,
              selectingStop: isStop,
              initialValue: initialVal,
              biasLocation: bias,
              showTripOverview: !isStop,
              pickupDisplay: _pickupController.text.isEmpty
                  ? ref.tr('enter_pickup')
                  : _pickupController.text,
              destinationDisplay: _destinationController.text.isEmpty
                  ? ref.tr('enter_destination')
                  : _destinationController.text,
              stops: List<RideStop>.from(_stops),
              scheduleLabel: () => _scheduleChipLabel,
              onScheduleTap: () {
                if (!_hasValidPickupAndDestination()) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Please choose both pickup and destination first.',
                      ),
                    ),
                  );
                  return;
                }
                _showFindTripSchedulePicker(() => modalSetState(() {}));
              },
              onTripPickupTap: () {
                Navigator.pop(sheetContext);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showLocationSearchSheet(isPickup: true);
                });
              },
              onTripDestinationTap: () {
                Navigator.pop(sheetContext);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showLocationSearchSheet(isPickup: false);
                });
              },
              onTripAddStopTap: _stops.length < 3
                  ? () {
                      if (isStop) {
                        Navigator.pop(sheetContext);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          _showLocationSearchSheet(
                              isPickup: false, addStopAt: _stops.length);
                        });
                      } else {
                        setState(() {
                          _stops.add(const RideStop(address: '', location: null));
                          ref
                              .read(rideBookingProvider.notifier)
                              .setStops(_stops);
                        });
                        modalSetState(() {});
                      }
                    }
                  : null,
              onTripEditStopTap: isStop
                  ? (i) {
                      Navigator.pop(sheetContext);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _showLocationSearchSheet(
                            isPickup: false, editStopAt: i);
                      });
                    }
                  : (_) {},
              onTripRemoveStopTap: (i) {
                if (i < 0 || i >= _stops.length) return;
                setState(() {
                  _stops.removeAt(i);
                  ref.read(rideBookingProvider.notifier).setStops(_stops);
                });
                modalSetState(() {});
                _tryCalculateRoute();
              },
              tripPickupController: !isStop ? _pickupController : null,
              onTripDestinationClear: !isStop
                  ? () {
                      setState(() {
                        _destinationController.clear();
                        _destinationLocation = null;
                        _distanceText = '';
                        _durationText = '';
                        _estimatedFare = 0;
                        _polylines = {};
                        _routeLegCount = 0;
                        _firstLegDurationMin = 0;
                        _dropPillAnchor = null;
                      });
                      ref
                          .read(rideBookingProvider.notifier)
                          .clearDestinationAndRoute();
                      modalSetState(() {});
                      _setupMapElements();
                      _updateDriverMarkers();
                    }
                  : null,
              onBookNowTap: !isStop
                  ? () {
                      if (_pickupLocation != null &&
                          _destinationLocation != null &&
                          _pickupController.text.trim().isNotEmpty &&
                          _destinationController.text.trim().isNotEmpty) {
                        Navigator.pop(sheetContext);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Please choose both pickup and destination.'),
                          ),
                        );
                      }
                    }
                  : null,
              bookNowEnabled: !isStop &&
                  _pickupLocation != null &&
                  _destinationLocation != null &&
                  _pickupController.text.trim().isNotEmpty &&
                  _destinationController.text.trim().isNotEmpty,
              onLocationSelected:
                  (address, latLng, {bool? asPickup, int? stopIndex}) {
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
                if (stopIndex != null) {
                  setState(() {
                    if (stopIndex >= 0 && stopIndex < _stops.length) {
                      _stops[stopIndex] =
                          RideStop(address: address, location: latLng);
                      ref.read(rideBookingProvider.notifier).setStops(_stops);
                    }
                  });
                  modalSetState(() {});
                  _setupMapElements();
                  _updateDriverMarkers();
                  _tryCalculateRoute();
                  if (_destinationLocation != null) {
                    Future.delayed(const Duration(milliseconds: 300), () {
                      _fitRouteBounds(null);
                    });
                  }
                  return;
                }
                final pickupFlow = asPickup ?? isPickup;
                setState(() {
                  if (pickupFlow) {
                    _pickupController.text = address;
                    _pickupLocation = latLng;
                    _pickupLocationReady = true;
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
                modalSetState(() {});
                _setupMapElements();
                _updateDriverMarkers();
                _tryCalculateRoute();
                if (_destinationLocation != null) {
                  Future.delayed(const Duration(milliseconds: 300), () {
                    _fitRouteBounds(null);
                  });
                }
                if (!isStop &&
                    _pickupController.text.trim().isNotEmpty &&
                    _destinationController.text.trim().isNotEmpty &&
                    _pickupLocation != null &&
                    _destinationLocation != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (Navigator.canPop(sheetContext)) {
                      Navigator.pop(sheetContext);
                    }
                  });
                }
              },
            );
          },
        );
      },
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 4),
                    _buildAddStopRow(),
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
          if (_zoneHealth != null) _buildZoneHealthIndicator(),
          GestureDetector(
            onTap: () => _scaffoldKey.currentState?.openEndDrawer(),
            child: const Icon(
              Icons.menu,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ],
      ),
    );
  }

  /// Add stop — same as former location card (max 3 stops).
  Widget _buildAddStopRow() {
    if (_stops.length >= 3) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _showLocationSearchSheet(
          isPickup: false,
          addStopAt: _stops.length,
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.add_circle_outline,
            size: 18, color: Color(0xFF4285F4)),
        label: Text(
          'Add stop',
          style: TextStyle(
            fontSize: 14,
            color: const Color(0xFF4285F4).withValues(alpha: 0.9),
            fontWeight: FontWeight.w500,
          ),
        ),
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

  /// Total route duration in minutes (drop-off pill + route badge).
  int _routeMinutesForPill() {
    if (_durationMinFromBackend > 0) return _durationMinFromBackend;
    if (_durationText.isEmpty) return 0;
    final m = RegExp(r'(\d+)').firstMatch(_durationText);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    return 0;
  }

  /// Pick-up brown block: first leg only when Directions has multiple legs; otherwise "—"
  /// (full trip time is shown on drop-off only).
  int? _pickupMinutesForPill() {
    if (_durationText.isEmpty && !_isLoadingRoute) return null;
    if (_routeLegCount <= 1) return null;
    return _firstLegDurationMin > 0 ? _firstLegDurationMin : null;
  }

  int? _dropMinutesForPill() {
    final m = _routeMinutesForPill();
    return m > 0 ? m : null;
  }

  (double, double) _pillMetrics() {
    final sw = MediaQuery.sizeOf(context).width;
    final sx = sw / 390.0;
    final pillW = math.min(211 * sx, sw * 0.45);
    final pillH = pillW * (45.0 / 211.0);
    return (pillW, pillH);
  }

  /// Native map returns screen pixels; Flutter layout uses logical pixels on Android.
  Offset _mapScreenCoordToLogicalOffset(ScreenCoordinate sc) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final x = sc.x.toDouble();
    final y = sc.y.toDouble();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return Offset(x / dpr, y / dpr);
    }
    return Offset(x, y);
  }

  /// Places pills above pickup/drop LatLng using map screen coordinates.
  Future<void> _refreshMapPillPositions() async {
    final c = _controller;
    if (c == null || !mounted) return;
    final gen = ++_pillAnchorGen;
    Offset? pick;
    Offset? drop;
    try {
      if (_pickupLocation != null) {
        final sc = await c.getScreenCoordinate(_pickupLocation!);
        if (!mounted || gen != _pillAnchorGen) return;
        pick = _mapScreenCoordToLogicalOffset(sc);
      }
      if (_destinationLocation != null &&
          _destinationController.text.isNotEmpty) {
        final sc2 = await c.getScreenCoordinate(_destinationLocation!);
        if (!mounted || gen != _pillAnchorGen) return;
        drop = _mapScreenCoordToLogicalOffset(sc2);
      }
      if (!mounted || gen != _pillAnchorGen) return;
      setState(() {
        _pickupPillAnchor = pick;
        _dropPillAnchor = drop;
      });
    } catch (e) {
      debugPrint('Map pill anchor: $e');
      if (mounted && gen == _pillAnchorGen) {
        setState(() {
          _pickupPillAnchor = null;
          _dropPillAnchor = null;
        });
      }
    }
  }

  /// Figma Frame 1410081802 — floating map pill (pick-up or drop-off).
  Widget _buildFigmaMapLocationPill({
    required bool isPickup,
    required VoidCallback onTap,
    required int? minutesForBrown,
  }) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final sx = w / 390.0;
    final pillW = math.min(211 * sx, w * 0.45);
    final pillH = pillW * (45.0 / 211.0);
    final brownW = pillW * (40.0 / 211.0);
    final showMinutes = minutesForBrown != null && minutesForBrown > 0;
    final address = isPickup
        ? (_pickupController.text.isEmpty
            ? ref.tr('enter_pickup')
            : _pickupController.text)
        : (_destinationController.text.isEmpty
            ? ref.tr('enter_destination')
            : _destinationController.text);
    final empty = isPickup
        ? _pickupController.text.isEmpty
        : _destinationController.text.isEmpty;

    return Material(
      elevation: 0,
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: pillW,
          height: pillH,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(9),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                offset: const Offset(0, 4),
                blurRadius: 4,
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: brownW,
                height: pillH,
                child: ColoredBox(
                  color: _figmaPillBrown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        showMinutes ? '$minutesForBrown' : '—',
                        style: GoogleFonts.poppins(
                          fontSize: math.min(25 * sx, 22),
                          fontWeight: FontWeight.w500,
                          height: 38 / 25,
                          letterSpacing: -1.25,
                          color: Colors.black,
                        ),
                      ),
                      Text(
                        'min',
                        style: GoogleFonts.poppins(
                          fontSize: math.min(10 * sx, 10),
                          fontWeight: FontWeight.w300,
                          height: 15 / 10,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 10 * sx, right: 8 * sx),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPickup ? 'Pick-up' : 'Drop off',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          height: 18 / 12,
                          color: _figmaPillLabel,
                        ),
                      ),
                      Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 21 / 14,
                          color: empty
                              ? const Color(0xFFBDBDBD)
                              : Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(right: 2 * sx),
                child: const Icon(
                  Icons.keyboard_arrow_right_rounded,
                  size: 18.5,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pills anchored above pickup/drop on the map, with top-corner fallback.
  Widget _buildMapPillPositioned({
    required bool isPickup,
    required double mapPillLeft,
    required double mapPillTop,
    required double sheetHeightPx,
  }) {
    final mq = MediaQuery.of(context);
    final sh = mq.size.height;
    final (pillW, pillH) = _pillMetrics();
    final anchor = isPickup ? _pickupPillAnchor : _dropPillAnchor;
    final minutes = isPickup ? _pickupMinutesForPill() : _dropMinutesForPill();

    if (anchor != null) {
      // Center horizontally on the projected point; do not clamp to screen edges
      // (that detached pills from markers near left/right). Light vertical bounds only.
      final left = anchor.dx - pillW / 2;
      var top = anchor.dy - pillH - 14;
      top = top.clamp(0.0, sh - pillH);
      return Positioned(
        left: left,
        top: top,
        child: _buildFigmaMapLocationPill(
          isPickup: isPickup,
          minutesForBrown: minutes,
          onTap: () => _showLocationSearchSheet(isPickup: isPickup),
        ),
      );
    }

    return Positioned(
      left: isPickup ? mapPillLeft : null,
      right: isPickup ? null : mapPillLeft,
      top: mapPillTop,
      child: _buildFigmaMapLocationPill(
        isPickup: isPickup,
        minutesForBrown: minutes,
        onTap: () => _showLocationSearchSheet(isPickup: isPickup),
      ),
    );
  }

  Widget _buildMapSection() {
    final screenHeight = MediaQuery.of(context).size.height;
    final pt = MediaQuery.of(context).padding.top;
    final sw = MediaQuery.sizeOf(context).width;
    final sx = sw / 390.0;
    final mapPillLeft = 9 * sx;
    final mapPillTop = pt + 68;
    double sheetFraction = 0.40;
    try {
      final s = _sheetController.size;
      if (s > 0 && s <= 1) sheetFraction = s;
    } catch (_) {
      // Controller may not be attached yet (e.g. before sheet builds)
    }
    final sheetHeightPx = screenHeight * sheetFraction;

    return Stack(
      clipBehavior: Clip.none,
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
                  Future.delayed(const Duration(milliseconds: 700), () {
                    if (mounted) _refreshMapPillPositions();
                  });
                },
                onCameraMove: (position) {
                  _currentZoomLevel = position.zoom;
                  // Keep pills glued to LatLngs during pinch/zoom/pan (idle-only felt laggy).
                  final now = DateTime.now();
                  if (_lastPillRefreshDuringMove == null ||
                      now.difference(_lastPillRefreshDuringMove!) >=
                          const Duration(milliseconds: 24)) {
                    _lastPillRefreshDuringMove = now;
                    _refreshMapPillPositions();
                  }
                },
                onCameraIdle: () {
                  _lastPillRefreshDuringMove = null;
                  _updateDriverMarkers();
                  _refreshMapPillPositions();
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                // Top overlays: Figma map pills + header (no large location card).
                padding: EdgeInsets.only(top: 130, bottom: sheetHeightPx),
              );
            },
          ),
        ),

        // Figma pick-up / drop-off — above map points (see _refreshMapPillPositions)
        _buildMapPillPositioned(
          isPickup: true,
          mapPillLeft: mapPillLeft,
          mapPillTop: mapPillTop,
          sheetHeightPx: sheetHeightPx,
        ),
        _buildMapPillPositioned(
          isPickup: false,
          mapPillLeft: mapPillLeft,
          mapPillTop: mapPillTop,
          sheetHeightPx: sheetHeightPx,
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

/// Gold stepper: pickup ring → optional + nodes per stop → drop ring (fills card height).
class _PlanRideMultiStopRail extends StatelessWidget {
  const _PlanRideMultiStopRail({
    required this.gold,
    required this.stopCount,
  });

  final Color gold;
  final int stopCount;

  static const double _topRing = 26;
  static const double _bottomRing = 22;
  static const double _stopNode = 22;

  @override
  Widget build(BuildContext context) {
    final nodes = <Widget>[
      Container(
        width: _topRing,
        height: _topRing,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: gold, width: 7),
        ),
      ),
      ...List.generate(
        stopCount,
        (_) => Container(
          width: _stopNode,
          height: _stopNode,
          decoration: BoxDecoration(
            color: gold,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.add, color: Colors.white, size: 14),
        ),
      ),
      SizedBox(
        width: _bottomRing,
        height: _bottomRing,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: gold, width: 2),
              ),
            ),
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: gold,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    ];

    return SizedBox(
      width: 26,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            left: 12,
            top: _topRing,
            bottom: _bottomRing,
            child: Container(width: 2, color: gold),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: nodes,
          ),
        ],
      ),
    );
  }
}

/// Figma: "Add Spot" pill — no fill, solid border only (matches updated design).
class _PlanRideChipAddSpot extends StatelessWidget {
  const _PlanRideChipAddSpot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(200),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(200),
            border: Border.all(
              color: const Color(0xFF292D32),
              width: 0.92,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Add Spot',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w400,
                  fontSize: 12,
                  height: 18 / 12,
                  letterSpacing: -0.36,
                  color: Color(0xFF000000),
                ),
              ),
              const SizedBox(width: 7.34),
              Transform.translate(
                offset: const Offset(0, -1),
                child: const Text(
                  '+',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w500,
                    fontSize: 19.2,
                    height: 1,
                    color: Color(0xFF000000),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRoundedRectPainter extends CustomPainter {
  _DashedRoundedRectPainter({
    required this.color,
    required this.borderRadius,
    this.dashWidth = 3.5,
    this.dashSpace = 3,
  });

  final Color color;
  final double borderRadius;
  final double dashWidth;
  final double dashSpace;

  @override
  void paint(Canvas canvas, Size size) {
    final maxR = math.min(size.width, size.height) / 2 - 1;
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Radius.circular(math.min(borderRadius, maxR)),
    );
    final path = Path()..addRRect(r);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final len = math.min(dashWidth, metric.length - distance);
        canvas.drawPath(metric.extractPath(distance, distance + len), paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.dashWidth != dashWidth ||
      oldDelegate.dashSpace != dashSpace;
}

/// Figma: "Add Home" — white fill, dashed outline, outlined home icon in gold.
class _PlanRideChipAddHome extends StatelessWidget {
  const _PlanRideChipAddHome({required this.onTap});

  final VoidCallback onTap;

  static const _gold = Color(0xFFCF923D);

  @override
  Widget build(BuildContext context) {
    const radius = 200.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Colors.white),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DashedRoundedRectPainter(
                    color: const Color(0xFF292D32),
                    borderRadius: radius,
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Add Home',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w400,
                        fontSize: 12,
                        height: 18 / 12,
                        letterSpacing: -0.36,
                        color: Color(0xFF000000),
                      ),
                    ),
                    const SizedBox(width: 7.34),
                    Icon(
                      Icons.home_outlined,
                      size: 14,
                      color: _gold.withValues(alpha: 0.95),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plan Your Ride: when home exists — dashed **gold** border, `Home: address…`, black circle + white house (Figma).
/// Text area fills drop-off; only the home icon opens **edit home**.
class _PlanRideHomeSetChip extends StatelessWidget {
  const _PlanRideHomeSetChip({
    required this.address,
    required this.onTextTap,
    required this.onEditHomeIconTap,
  });

  final String address;
  final VoidCallback onTextTap;
  final VoidCallback onEditHomeIconTap;

  static const _gold = Color(0xFFCF923D);

  @override
  Widget build(BuildContext context) {
    const radius = 200.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.white)),
          Positioned.fill(
            child: CustomPaint(
              painter: _DashedRoundedRectPainter(
                color: _gold,
                borderRadius: radius,
                dashWidth: 3.2,
                dashSpace: 2.8,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
            child: Row(
              children: [
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onTextTap,
                      borderRadius: BorderRadius.circular(radius),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontSize: 12,
                                height: 18 / 12,
                                letterSpacing: -0.36,
                              ),
                              children: [
                                const TextSpan(
                                  text: 'Home: ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF000000),
                                  ),
                                ),
                                TextSpan(
                                  text: address,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w400,
                                    color: Color(0xFF303030),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onEditHomeIconTap,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Color(0xFF000000),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.home_rounded,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool _latLngRoughlyEqual(LatLng a, LatLng b) {
  return (a.latitude - b.latitude).abs() < 0.0001 &&
      (a.longitude - b.longitude).abs() < 0.0001;
}

/// Figma **Add Home** sheet: same plan-ride background; search + recents (no duplicate Home row).
class _AddHomeSheet extends ConsumerStatefulWidget {
  const _AddHomeSheet();

  @override
  ConsumerState<_AddHomeSheet> createState() => _AddHomeSheetState();
}

class _AddHomeSheetState extends ConsumerState<_AddHomeSheet> {
  static const _gold = Color(0xFFCF923D);
  static const _sheetBgAsset =
      'assets/images/plan_ride_sheet_background.png';

  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  final PlacesService _placesService = PlacesService();
  Timer? _debounce;
  List<_LocationSuggestion> _suggestions = [];
  _LocationSuggestion? _selected;
  bool _isLoading = false;
  bool _showSuccess = false;
  bool _savedThisSession = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadInitialList();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _placesService.endSession();
    super.dispose();
  }

  void _loadInitialList() {
    final saved = ref.read(savedLocationsProvider);
    final suggestions = <_LocationSuggestion>[];
    final homeLl = saved.homeLocation?.latLng;

    if (saved.workLocation != null) {
      final w = saved.workLocation!;
      suggestions.add(_LocationSuggestion(
        name: 'Work',
        address: w.address,
        latLng: w.latLng,
        placeId: w.placeId,
        icon: Icons.work_rounded,
      ));
    }
    for (final fav in saved.favorites) {
      if (homeLl != null &&
          _latLngRoughlyEqual(fav.latLng, homeLl)) {
        continue;
      }
      suggestions.add(_LocationSuggestion(
        name: fav.name,
        address: fav.address,
        latLng: fav.latLng,
        placeId: fav.placeId,
        icon: Icons.favorite_rounded,
      ));
    }
    for (final recent in saved.recentLocations.take(8)) {
      if (homeLl != null &&
          _latLngRoughlyEqual(recent.latLng, homeLl)) {
        continue;
      }
      final already = suggestions.any((s) =>
          s.latLng != null &&
          _latLngRoughlyEqual(s.latLng!, recent.latLng));
      if (!already) {
        suggestions.add(_LocationSuggestion(
          name: recent.name,
          address: recent.address,
          latLng: recent.latLng,
          placeId: recent.placeId,
          icon: Icons.history_rounded,
          fromRecent: true,
        ));
      }
    }

    if (suggestions.isEmpty) {
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

    if (!mounted) return;
    setState(() => _suggestions = suggestions);
  }

  Future<LatLng?> _resolveBias() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 3),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      final booking = ref.read(rideBookingProvider);
      return booking.pickupLocation ??
          booking.destinationLocation ??
          const LatLng(25.45, 81.85);
    }
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      _loadInitialList();
      setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);
    final bias = await _resolveBias();
    try {
      final placesResults = await _placesService.searchPlacesWithFallback(
        query,
        location: bias,
      );
      if (!mounted) return;
      if (placesResults.isNotEmpty) {
        setState(() {
          _suggestions = placesResults
              .map(
                (place) => _LocationSuggestion(
                  name: place.name,
                  address: place.address,
                  latLng: place.latLng,
                  placeId: place.placeId,
                ),
              )
              .toList();
          _isLoading = false;
        });
        return;
      }

      final locations = await locationFromAddress(
        query,
        localeIdentifier: 'en_IN',
      );
      if (!mounted) return;
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
      debugPrint('AddHome search error: $e');
      if (mounted) {
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
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(q);
    });
  }

  Future<void> _selectSuggestion(_LocationSuggestion s) async {
    if (s.name == 'Current Location') return;

    LatLng? latLng = s.latLng;
    if (latLng == null && s.placeId != null) {
      setState(() => _isLoading = true);
      latLng = await _placesService.getPlaceDetails(s.placeId!);
      if (latLng == null) {
        try {
          final locations = await locationFromAddress(
            '${s.name}, ${s.address}',
            localeIdentifier: 'en_IN',
          );
          if (locations.isNotEmpty) {
            latLng =
                LatLng(locations.first.latitude, locations.first.longitude);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _isLoading = false);
    }

    if (latLng == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not get coordinates for this place.'),
          ),
        );
      }
      return;
    }

    final line =
        '${s.name}${s.address.isNotEmpty ? ', ${s.address}' : ''}';
    if (!mounted) return;
    setState(() {
      _selected = _LocationSuggestion(
        name: s.name,
        address: s.address,
        latLng: latLng,
        placeId: s.placeId,
        icon: s.icon,
        fromRecent: s.fromRecent,
      );
      _searchController.text = line;
    });
  }

  Future<void> _commitSetHome() async {
    final sel = _selected;
    if (sel?.latLng == null) return;
    final line =
        '${sel!.name}${sel.address.isNotEmpty ? ', ${sel.address}' : ''}';
    final label = sel.name.split(',').first.trim();
    await ref.read(savedLocationsProvider.notifier).setHomeLocation(
          name: label.isEmpty ? 'Home' : label,
          address: line,
          location: sel.latLng!,
          placeId: sel.placeId,
        );
    if (!mounted) return;
    setState(() {
      _showSuccess = true;
      _savedThisSession = true;
    });
  }

  void _onChangeHomeTapped() {
    setState(() {
      _selected = null;
      _searchController.clear();
      _showSuccess = false;
    });
    _loadInitialList();
    _searchFocus.requestFocus();
  }

  Widget _buildListTile(_LocationSuggestion s) {
    final selected = _selected != null &&
        _selected!.latLng != null &&
        s.latLng != null &&
        _latLngRoughlyEqual(_selected!.latLng!, s.latLng!);
    return InkWell(
      onTap: () => _selectSuggestion(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade200),
          ),
          color: selected ? const Color(0xFFF5F5F5) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _gold, width: 1.32),
                ),
                child: Icon(
                  Icons.schedule_rounded,
                  size: 14,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF000000),
                      height: 1.5,
                    ),
                  ),
                  if (s.address.isNotEmpty)
                    Text(
                      s.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 14.19,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF929292),
                        height: 1.48,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Figma Group 39380: `bottom: 122px` — toast sits just above Set Home. Derive from footer stack.
  double _successBannerBottomOffset(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Matches footer: SafeArea + `EdgeInsets.fromLTRB(..., 12 + bottomInset * 0.25)` + button block.
    const footerBottomPad = 12.0;
    const buttonVerticalPad = 15.0 * 2;
    const buttonTextApprox = 22.0;
    const gapToastAboveButton = 10.0;
    return bottomInset +
        footerBottomPad +
        bottomInset * 0.25 +
        buttonVerticalPad +
        buttonTextApprox +
        gapToastAboveButton;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final saved = ref.watch(savedLocationsProvider);
    final home = saved.homeLocation;

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F0),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            offset: const Offset(0, -4),
            blurRadius: 19.75,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -44,
            left: -4,
            right: -4,
            bottom: 0,
            child: Image.asset(
              _sheetBgAsset,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.35),
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFFFFF8F0)),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 6),
                  width: 49,
                  height: 3,
                  decoration: BoxDecoration(
                    color: const Color(0xFF424242),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 0),
                child: Row(
                  children: [
                    FigmaSquareBackButton(
                      minTapSize: 40,
                      onPressed: () => Navigator.pop(context, _savedThisSession),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Add Home',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w500,
                        fontSize: 16,
                        height: 24 / 16,
                        color: Color(0xFF010101),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  constraints: const BoxConstraints(minHeight: 50),
                  padding: const EdgeInsets.only(
                    left: 18.41,
                    right: 8.6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12.995),
                    border: Border.all(
                      width: _searchFocus.hasFocus ? 1.1 : 0.92,
                      color: const Color(0xFFCBC6BB).withValues(
                        alpha: _searchFocus.hasFocus ? 0.72 : 0.5,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        offset: const Offset(0, 3),
                        blurRadius: 8,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        offset: const Offset(0, 1),
                        blurRadius: 2,
                      ),
                    ],
                  ),
                  alignment: Alignment.centerLeft,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      inputDecorationTheme: const InputDecorationTheme(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        onChanged: _onSearchChanged,
                        textAlignVertical: TextAlignVertical.center,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                          height: 21 / 14,
                          color: Color(0xFF000000),
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Search',
                          hintStyle: TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                            height: 21 / 14,
                            color: Color(0xFF929292),
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          isDense: true,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (home != null) ...[
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(22, 14, 22, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(200),
                          child: Stack(
                            children: [
                              const Positioned.fill(
                                  child: ColoredBox(color: Colors.white)),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _DashedRoundedRectPainter(
                                    color: const Color(0xFF292D32),
                                    borderRadius: 200,
                                    dashWidth: 3.2,
                                    dashSpace: 2.8,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                child: Row(
                                  children: [
                                    const Icon(Icons.home_rounded,
                                        size: 14, color: Color(0xFF000000)),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: RichText(
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        text: TextSpan(
                                          style: const TextStyle(
                                            fontFamily: 'Poppins',
                                            fontSize: 12,
                                            height: 18 / 12,
                                            letterSpacing: -0.36,
                                            color: Color(0xFF303030),
                                          ),
                                          children: [
                                            const TextSpan(
                                              text: 'Home: ',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w500,
                                                color: Color(0xFF000000),
                                              ),
                                            ),
                                            TextSpan(
                                              text: home.address,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w400,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _onChangeHomeTapped,
                          borderRadius: BorderRadius.circular(200),
                          child: Ink(
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(200),
                              border: Border.all(
                                color: const Color(0xFF292D32),
                                width: 0.92,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            child: const Text(
                              'Change?',
                              style: TextStyle(
                                fontFamily: 'Poppins',
                                fontWeight: FontWeight.w400,
                                fontSize: 12,
                                letterSpacing: -0.36,
                                color: Color(0xFF000000),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _searchController.text.trim().isEmpty
                      ? 'Recent Locations'
                      : 'Search Results',
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF5B5B5B),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(_gold),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: _suggestions.length,
                        itemBuilder: (ctx, i) =>
                            _buildListTile(_suggestions[i]),
                      ),
              ),
              Material(
                color: Colors.white,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        offset: const Offset(0, -3.92),
                        blurRadius: 19.75,
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          16, 10, 16, 12 + bottomInset * 0.25),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity:
                                _selected?.latLng != null ? 1 : 0.45,
                            child: Material(
                              color: const Color(0xFF000000),
                              borderRadius:
                                  BorderRadius.circular(280),
                              child: InkWell(
                                borderRadius:
                                    BorderRadius.circular(280),
                                onTap: _selected?.latLng != null
                                    ? _commitSetHome
                                    : null,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 15),
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'Set Home',
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 16.65,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFFFFFFFF),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_showSuccess)
            Positioned(
              left: 0,
              right: 0,
              bottom: _successBannerBottomOffset(context),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(172),
                    child: Container(
                      width: 208,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color.fromRGBO(56, 163, 95, 0.1),
                        borderRadius: BorderRadius.circular(172),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10, right: 4),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Home Set Successfully',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w400,
                                  fontSize: 14,
                                  height: 21 / 14,
                                  color: Color(0xFF38A35F),
                                ),
                              ),
                            ),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _showSuccess = false),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color.fromRGBO(
                                        56, 163, 95, 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Color(0xFF000000),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Location Search Bottom Sheet with saved places integration
class _LocationSearchSheet extends ConsumerStatefulWidget {
  final bool isPickup;
  /// True when picking an intermediate stop (hide Set Home on recents).
  final bool selectingStop;
  final bool showTripOverview;
  final String pickupDisplay;
  final String destinationDisplay;
  final List<RideStop> stops;
  final String Function() scheduleLabel;
  final VoidCallback onScheduleTap;
  final VoidCallback onTripPickupTap;
  final VoidCallback onTripDestinationTap;
  final VoidCallback? onTripAddStopTap;
  final void Function(int index) onTripEditStopTap;
  final void Function(int index) onTripRemoveStopTap;
  final String initialValue;
  final LatLng? biasLocation;
  /// [asPickup] when non-null selects pickup vs destination in trip-overview mode; otherwise parent uses sheet [isPickup].
  /// [stopIndex] when non-null updates intermediate stop at that index (inline plan-ride UI).
  final void Function(String address, LatLng? latLng,
      {bool? asPickup, int? stopIndex}) onLocationSelected;
  /// Parent pickup controller — required for editable pickup when [ showTripOverview ] is true.
  final TextEditingController? tripPickupController;
  /// Trip overview only: primary CTA; parent should pop or show SnackBar.
  final VoidCallback? onBookNowTap;
  /// Visual emphasis when pickup + destination are ready (parent-owned state).
  final bool bookNowEnabled;
  /// Plan Your Ride: clear drop-off in parent + provider (× on destination field).
  final VoidCallback? onTripDestinationClear;

  const _LocationSearchSheet({
    required this.isPickup,
    this.selectingStop = false,
    this.showTripOverview = false,
    this.pickupDisplay = '',
    this.destinationDisplay = '',
    this.stops = const [],
    required this.scheduleLabel,
    required this.onScheduleTap,
    required this.onTripPickupTap,
    required this.onTripDestinationTap,
    this.onTripAddStopTap,
    required this.onTripEditStopTap,
    required this.onTripRemoveStopTap,
    required this.initialValue,
    this.biasLocation,
    required this.onLocationSelected,
    this.tripPickupController,
    this.onBookNowTap,
    this.bookNowEnabled = false,
    this.onTripDestinationClear,
  });

  @override
  ConsumerState<_LocationSearchSheet> createState() =>
      _LocationSearchSheetState();
}

class _LocationSearchSheetState extends ConsumerState<_LocationSearchSheet> {
  late TextEditingController _searchController;
  List<TextEditingController> _stopControllers = [];
  /// When set, suggestion / current-location apply to this intermediate stop index.
  int? _editingStopIndex;
  List<_LocationSuggestion> _suggestions = [];
  bool _isLoading = false;
  Timer? _debounce;
  final PlacesService _placesService = PlacesService();
  late final FocusNode _tripPickupFocusNode;
  late final FocusNode _tripDestFocusNode;
  /// Which row last drove search / selection in trip-overview mode.
  bool _tripSelectionIsPickup = false;

  /// Plan Your Ride: which field last had focus — recents/search taps fill that field (focus can be lost before tap).
  bool _lastPlanRideFieldWasPickup = true;

  /// Drop-off field: keep caret at start of address (pickup-style), not at end.
  static TextEditingValue _destTextValue(String text) => TextEditingValue(
        text: text,
        selection: const TextSelection.collapsed(offset: 0),
      );

  void _syncStopControllerList() {
    while (_stopControllers.length < widget.stops.length) {
      final i = _stopControllers.length;
      _stopControllers
          .add(TextEditingController(text: widget.stops[i].address));
    }
    while (_stopControllers.length > widget.stops.length) {
      _stopControllers.removeLast().dispose();
    }
    if (_editingStopIndex != null &&
        _editingStopIndex! >= widget.stops.length) {
      _editingStopIndex = null;
    }
  }

  bool get _tripOverviewMode =>
      widget.showTripOverview && !widget.selectingStop;

  /// Whether the next suggestion tap should update pickup (vs drop) in trip-overview mode.
  bool get _tapAppliesToPickup {
    if (!_tripOverviewMode) return widget.isPickup;
    if (_editingStopIndex != null) return false;
    return _lastPlanRideFieldWasPickup;
  }

  @override
  void initState() {
    super.initState();
    _stopControllers = widget.stops
        .map((s) => TextEditingController(text: s.address))
        .toList();
    _tripPickupFocusNode = FocusNode();
    _tripDestFocusNode = FocusNode();
    if (_tripOverviewMode) {
      _tripSelectionIsPickup = widget.isPickup;
      _lastPlanRideFieldWasPickup = widget.isPickup;
      _tripPickupFocusNode.addListener(_onTripPickupFocusChanged);
      _tripDestFocusNode.addListener(_onTripDestFocusChanged);
    }
    _searchController = TextEditingController();
    if (_tripOverviewMode || !widget.isPickup) {
      _searchController.value = _destTextValue(widget.initialValue);
    } else {
      _searchController.text = widget.initialValue;
    }
    _loadInitialSuggestions();
  }

  @override
  void didUpdateWidget(covariant _LocationSearchSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != oldWidget.initialValue) {
      if (_tripOverviewMode || !widget.isPickup) {
        _searchController.value = _destTextValue(widget.initialValue);
      } else {
        _searchController.value = TextEditingValue(
          text: widget.initialValue,
          selection:
              TextSelection.collapsed(offset: widget.initialValue.length),
        );
      }
    }
    if (widget.stops.length != oldWidget.stops.length) {
      _syncStopControllerList();
    } else {
      for (var i = 0; i < widget.stops.length; i++) {
        if (widget.stops[i].address != oldWidget.stops[i].address) {
          _stopControllers[i].text = widget.stops[i].address;
        }
      }
    }
  }

  /// Load saved places + recent locations as initial suggestions
  void _loadInitialSuggestions() {
    final savedLocationsState = ref.read(savedLocationsProvider);
    final suggestions = <_LocationSuggestion>[];

    // Current Location is the blue card above the list (avoids duplicate rows).

    // Home: use **Add Home** flow only in Plan Your Ride (avoid duplicate list row).
    if (savedLocationsState.homeLocation != null && !_tripOverviewMode) {
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
    final savedHomeLl = savedLocationsState.homeLocation?.latLng;
    for (final recent in savedLocationsState.recentLocations.take(5)) {
      // Plan Your Ride: don’t repeat saved Home as a recent row (shown on Home pill).
      if (_tripOverviewMode &&
          savedHomeLl != null &&
          _latLngRoughlyEqual(recent.latLng, savedHomeLl)) {
        continue;
      }
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
          fromRecent: true,
        ));
      }
    }

    // Fallback: if no saved locations, show some defaults
    if (suggestions.isEmpty) {
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

    setState(() {
      _suggestions = suggestions;
    });
  }

  void _onTripPickupFocusChanged() {
    if (!_tripOverviewMode || !_tripPickupFocusNode.hasFocus) return;
    setState(() {
      _lastPlanRideFieldWasPickup = true;
      _tripSelectionIsPickup = true;
    });
  }

  void _onTripDestFocusChanged() {
    if (!_tripOverviewMode || !_tripDestFocusNode.hasFocus) return;
    setState(() {
      _lastPlanRideFieldWasPickup = false;
      _tripSelectionIsPickup = false;
    });
  }

  @override
  void dispose() {
    if (_tripOverviewMode) {
      _tripPickupFocusNode.removeListener(_onTripPickupFocusChanged);
      _tripDestFocusNode.removeListener(_onTripDestFocusChanged);
    }
    _searchController.dispose();
    for (final c in _stopControllers) {
      c.dispose();
    }
    _tripPickupFocusNode.dispose();
    _tripDestFocusNode.dispose();
    _debounce?.cancel();
    // End Places API session when sheet closes
    _placesService.endSession();
    super.dispose();
  }

  void _onTripStopSearchChanged(int index, String query) {
    if (!_tripOverviewMode) return;
    setState(() {
      _editingStopIndex = index;
      _tripSelectionIsPickup = false;
    });
    _debounce?.cancel();
    if (query.isEmpty) {
      _loadInitialSuggestions();
      setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchLocation(query, asPickupBias: false);
    });
  }

  void _onTripPickupSearchChanged(String query) {
    if (!_tripOverviewMode) return;
    setState(() {
      _editingStopIndex = null;
      _tripSelectionIsPickup = true;
      _lastPlanRideFieldWasPickup = true;
    });
    _debounce?.cancel();

    if (query.isEmpty) {
      _loadInitialSuggestions();
      setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = true);
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchLocation(query, asPickupBias: true);
    });
  }

  void _onSearchChanged(String query) {
    if (_tripOverviewMode) {
      setState(() {
        _editingStopIndex = null;
        _tripSelectionIsPickup = false;
        _lastPlanRideFieldWasPickup = false;
      });
    }
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
      _searchLocation(query,
          asPickupBias: _tripOverviewMode ? false : null);
    });
  }

  Future<void> _searchLocation(String query, {bool? asPickupBias}) async {
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
          final pickupSide = asPickupBias ?? widget.isPickup;
          searchBiasLocation = pickupSide
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

      final stopIdx = _editingStopIndex;
      if (stopIdx != null && _tripOverviewMode) {
        widget.onLocationSelected(
          address,
          LatLng(position.latitude, position.longitude),
          stopIndex: stopIdx,
        );
      } else {
        final applyPickup = _tapAppliesToPickup;
        widget.onLocationSelected(
          address,
          LatLng(position.latitude, position.longitude),
          asPickup: _tripOverviewMode ? applyPickup : null,
        );
      }

      if (mounted) {
        setState(() => _isLoading = false);
        if (_tripOverviewMode) {
          if (stopIdx != null) {
            _stopControllers[stopIdx].value = TextEditingValue(
              text: address,
              selection: TextSelection.collapsed(offset: address.length),
            );
          } else if (!_tapAppliesToPickup) {
            _searchController.value = _destTextValue(address);
          }
          _loadInitialSuggestions();
        } else {
          Navigator.pop(context);
        }
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

  /// Destination / single-mode search field. When [hideInnerPrefix] is true, outer row supplies the map pin.
  Widget _buildSearchTextField({
    required bool insetInTripCard,
    bool hideInnerPrefix = false,
    bool softInsetBorder = false,
    bool plainTripField = false,
    FocusNode? focusNode,
    bool autofocus = true,
  }) {
    final boxDecoration = plainTripField && insetInTripCard
        ? null
        : BoxDecoration(
            color: insetInTripCard ? Colors.white : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(12),
            border: insetInTripCard
                ? Border.all(
                    color: softInsetBorder
                        ? const Color(0xFFE0E0E0)
                        : const Color(0xFF424242),
                    width: 1,
                  )
                : null,
          );

    final field = TextField(
      controller: _searchController,
      focusNode: focusNode,
      autofocus: autofocus,
      onChanged: _onSearchChanged,
      onTap: _tripOverviewMode
          ? () => setState(() {
                _editingStopIndex = null;
                _tripSelectionIsPickup = false;
                _lastPlanRideFieldWasPickup = false;
              })
          : null,
      onSubmitted: (query) {
        if (query.isNotEmpty) {
          _searchLocation(query,
              asPickupBias: _tripOverviewMode ? false : null);
        }
      },
      minLines: plainTripField ? 1 : null,
      maxLines: plainTripField ? 1 : null,
      textAlignVertical: plainTripField ? TextAlignVertical.center : null,
      style: plainTripField
          ? const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF000000),
              height: 1.35,
            )
          : null,
      strutStyle: plainTripField
          ? const StrutStyle(
              fontFamily: 'Poppins',
              fontSize: 14,
              height: 1.35,
              forceStrutHeight: true,
              leading: 0,
            )
          : null,
      decoration: InputDecoration(
        hintText: plainTripField
            ? 'Enter destination'
            : 'Search any location (e.g., PVR Allahabad)',
        hintStyle: TextStyle(
          fontFamily: plainTripField ? 'Poppins' : null,
          fontSize: plainTripField ? 14 : null,
          fontWeight: plainTripField ? FontWeight.w500 : null,
          color: plainTripField
              ? const Color(0xFF929292)
              : const Color(0xFFBDBDBD),
        ),
        isCollapsed: plainTripField,
        prefixIcon: hideInnerPrefix
            ? null
            : Icon(
                widget.isPickup ? Icons.circle : Icons.location_on,
                color: widget.isPickup ? _planOrange : const Color(0xFF4CAF50),
                size: 18,
              ),
        suffixIcon: plainTripField
            ? (_searchController.text.trim().isNotEmpty
                ? Tooltip(
                    message: 'Clear destination',
                    child: IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: Colors.grey.shade600,
                      ),
                      onPressed: () {
                        _searchController.value = _destTextValue('');
                        _onSearchChanged('');
                        widget.onTripDestinationClear?.call();
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 24,
                      ),
                      alignment: Alignment.center,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  )
                : null)
            : (_searchController.text.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                    child: const Icon(Icons.clear, color: Color(0xFFBDBDBD)),
                  )
                : null),
        border: plainTripField ? InputBorder.none : InputBorder.none,
        enabledBorder:
            plainTripField ? InputBorder.none : InputBorder.none,
        focusedBorder:
            plainTripField ? InputBorder.none : InputBorder.none,
        filled: plainTripField ? false : null,
        fillColor: plainTripField ? Colors.transparent : null,
        contentPadding: EdgeInsets.only(
          left: hideInnerPrefix ? (plainTripField ? 0 : 12) : 8,
          right: plainTripField ? 2 : 0,
          top: plainTripField ? 0 : 12,
          bottom: plainTripField ? 0 : 12,
        ),
        isDense: true,
        suffixIconConstraints: plainTripField
            ? const BoxConstraints.tightFor(width: 32, height: 24)
            : const BoxConstraints(maxWidth: 36, maxHeight: 22),
      ),
    );

    if (boxDecoration == null) {
      return field;
    }
    return Container(
      decoration: boxDecoration,
      child: field,
    );
  }

  /// User-provided full-sheet background (plan ride / Figma art).
  static const _planRideSheetBgAsset =
      'assets/images/plan_ride_sheet_background.png';
  /// Figma accent gold
  static const _planOrange = Color(0xFFCF923D);

  Widget _buildPlanYourRideHeader() {
    final schedule = widget.scheduleLabel();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FigmaSquareBackButton(
          minTapSize: 40,
          onPressed: () => Navigator.pop(context),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Plan Your Ride',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFF010101),
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: const Color(0x80EDEDED),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(184),
            side: BorderSide(
              color: const Color(0x80CBC6BB),
              width: 0.92,
            ),
          ),
          child: InkWell(
            onTap: widget.onScheduleTap,
            borderRadius: BorderRadius.circular(184),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.5, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.access_time_rounded,
                      size: 14.7, color: Color(0xFF000000)),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      schedule,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.4,
                        color: Color(0xFF000000),
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.keyboard_arrow_down_rounded,
                      size: 16, color: Color(0xFF000000)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlanRideTripCard() {
    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Color(0xFF5B5B5B),
      height: 1.5,
    );

    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PlanRideMultiStopRail(
              gold: _planOrange,
              stopCount: widget.stops.length,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Pick-up', style: labelStyle),
                  const SizedBox(height: 2),
                  if (widget.tripPickupController != null)
                    TextField(
                      controller: widget.tripPickupController,
                      focusNode: _tripPickupFocusNode,
                      autofocus: widget.isPickup,
                      minLines: 1,
                      maxLines: 2,
                      onChanged: _onTripPickupSearchChanged,
                      onTap: () => setState(() {
                        _editingStopIndex = null;
                        _tripSelectionIsPickup = true;
                        _lastPlanRideFieldWasPickup = true;
                      }),
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF000000),
                        height: 1.2,
                      ),
                      strutStyle: const StrutStyle(
                        fontFamily: 'Poppins',
                        fontSize: 14,
                        height: 1.2,
                        forceStrutHeight: true,
                        leading: 0,
                      ),
                      decoration: InputDecoration(
                        hintText: 'My current location',
                        hintStyle: const TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF929292),
                          height: 1.2,
                        ),
                        filled: false,
                        fillColor: Colors.transparent,
                        isDense: true,
                        isCollapsed: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    )
                  else
                    InkWell(
                      onTap: widget.onTripPickupTap,
                      child: Text(
                        widget.pickupDisplay.isEmpty
                            ? 'My current location'
                            : widget.pickupDisplay,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                          color: widget.pickupDisplay.isEmpty
                              ? const Color(0xFF929292)
                              : const Color(0xFF000000),
                        ),
                      ),
                    ),
                  if (widget.stops.isEmpty) ...[
                    const SizedBox(height: 14),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFFB8B8B8),
                    ),
                    const SizedBox(height: 14),
                  ],
                  for (int i = 0; i < widget.stops.length; i++) ...[
                    const SizedBox(height: 6),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Colors.grey.shade200,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Add Stop', style: labelStyle),
                              const SizedBox(height: 2),
                              TextField(
                                controller: _stopControllers[i],
                                minLines: 1,
                                maxLines: 2,
                                onChanged: (q) =>
                                    _onTripStopSearchChanged(i, q),
                                onTap: () => setState(() {
                                  _editingStopIndex = i;
                                  _tripSelectionIsPickup = false;
                                }),
                                style: const TextStyle(
                                  fontFamily: 'Poppins',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF000000),
                                  height: 1.2,
                                ),
                                strutStyle: const StrutStyle(
                                  fontFamily: 'Poppins',
                                  fontSize: 14,
                                  height: 1.2,
                                  forceStrutHeight: true,
                                  leading: 0,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Add a stop',
                                  hintStyle: const TextStyle(
                                    fontFamily: 'Poppins',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF929292),
                                    height: 1.2,
                                  ),
                                  filled: false,
                                  isDense: true,
                                  isCollapsed: true,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 18, color: Colors.grey.shade500),
                          onPressed: () => widget.onTripRemoveStopTap(i),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          tooltip: 'Remove stop',
                        ),
                      ],
                    ),
                  ],
                  if (widget.stops.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFFB8B8B8),
                    ),
                    const SizedBox(height: 14),
                  ],
                  const Text('Drop off', style: labelStyle),
                  const SizedBox(height: 4),
                  _buildSearchTextField(
                    insetInTripCard: true,
                    hideInnerPrefix: true,
                    softInsetBorder: true,
                    plainTripField: true,
                    focusNode: _tripDestFocusNode,
                    autofocus: !widget.isPickup,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAddHomeSheet() {
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _AddHomeSheet(),
    ).then((saved) {
      if (saved == true && mounted) _loadInitialSuggestions();
    });
  }

  Widget _buildPlanRideActionPills() {
    if (!_tripOverviewMode || widget.selectingStop) {
      return const SizedBox.shrink();
    }
    final addSpot = widget.onTripAddStopTap;
    final home = ref.watch(savedLocationsProvider).homeLocation;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (addSpot != null) ...[
            _PlanRideChipAddSpot(onTap: addSpot),
            const SizedBox(width: 6),
          ],
          if (home != null)
            Expanded(
              child: _PlanRideHomeSetChip(
                address: home.address,
                onTextTap: () {
                  widget.onLocationSelected(
                    home.address,
                    home.latLng,
                    asPickup: false,
                  );
                },
                onEditHomeIconTap: _openAddHomeSheet,
              ),
            )
          else
            _PlanRideChipAddHome(onTap: _openAddHomeSheet),
        ],
      ),
    );
  }

  Widget _buildPlanRideHero() {
    // Background image is painted behind the whole sheet in [build]; this is foreground only.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            width: 49,
            height: 3,
            decoration: BoxDecoration(
              color: const Color(0xFF424242),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPlanYourRideHeader(),
              const SizedBox(height: 14),
              _buildPlanRideTripCard(),
              const SizedBox(height: 10),
              _buildPlanRideActionPills(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final showBookBar =
        _tripOverviewMode && widget.onBookNowTap != null;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: _tripOverviewMode ? const Color(0xFFFFF8F0) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            offset: const Offset(0, -4),
            blurRadius: 19.75,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_tripOverviewMode)
            // Bleed past top so rounded corners + any gap don’t show dark map behind.
            Positioned(
              top: -44,
              left: -4,
              right: -4,
              bottom: 0,
              child: Image.asset(
                _planRideSheetBgAsset,
                fit: BoxFit.cover,
                alignment: const Alignment(0, -0.35),
                filterQuality: FilterQuality.high,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: Color(0xFFFFF8F0)),
              ),
            )
          else
            const Positioned.fill(
              child: ColoredBox(color: Colors.white),
            ),
          Column(
            children: [
          if (!_tripOverviewMode)
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 49,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFF424242),
                borderRadius: BorderRadius.circular(4),
              ),
            ),

          if (_tripOverviewMode)
            _buildPlanRideHero()
          else
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.arrow_back_rounded,
                        color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.selectingStop
                          ? 'Stop location'
                          : widget.isPickup
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

          if (!_tripOverviewMode) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildSearchTextField(insetInTripCard: false),
            ),
            const SizedBox(height: 12),
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
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Current Location',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                            Text(
                              'Use GPS to detect your location',
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
          ] else
            const SizedBox(height: 4),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _searchController.text.isEmpty
                    ? 'Recent Locations'
                    : 'Search Results',
                style: TextStyle(
                  fontFamily: _tripOverviewMode ? 'Poppins' : null,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _tripOverviewMode
                      ? const Color(0xFF5B5B5B)
                      : const Color(0xFF888888),
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          Expanded(
            child: _isLoading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(_planOrange),
                        ),
                        const SizedBox(height: 16),
                        const Text(
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
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          showBookBar ? 20 + bottomInset : 16,
                        ),
                        itemCount: _suggestions.length,
                        itemBuilder: (context, index) {
                          final suggestion = _suggestions[index];
                          return _buildSuggestionTile(suggestion);
                        },
                      ),
          ),
          if (showBookBar)
            Material(
              elevation: 0,
              color: Colors.white,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      offset: const Offset(0, -3.92),
                      blurRadius: 19.75,
                    ),
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: widget.bookNowEnabled ? 1 : 0.45,
                      child: Material(
                        color: const Color(0xFF000000),
                        borderRadius: BorderRadius.circular(280),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(280),
                          onTap: widget.onBookNowTap,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            alignment: Alignment.center,
                            child: const Text(
                              'Book Now',
                              style: TextStyle(
                                fontFamily: 'Poppins',
                                fontSize: 16.65,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFFFFFFFF),
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isSameAsSavedHome(_LocationSuggestion suggestion) {
    final home = ref.read(savedLocationsProvider).homeLocation;
    if (home == null || suggestion.latLng == null) return false;
    final latDiff = (home.latitude - suggestion.latLng!.latitude).abs();
    final lngDiff = (home.longitude - suggestion.latLng!.longitude).abs();
    return latDiff < 0.001 && lngDiff < 0.001;
  }

  bool _isFavorite(_LocationSuggestion suggestion) {
    if (suggestion.latLng == null) return false;
    for (final f in ref.read(savedLocationsProvider).favorites) {
      final latDiff =
          (f.latitude - suggestion.latLng!.latitude).abs();
      final lngDiff =
          (f.longitude - suggestion.latLng!.longitude).abs();
      if (latDiff < 0.001 && lngDiff < 0.001) return true;
    }
    return false;
  }

  Future<void> _setRecentAsHome(_LocationSuggestion suggestion) async {
    final latLng = suggestion.latLng;
    if (latLng == null) return;
    await ref.read(savedLocationsProvider.notifier).setHomeLocation(
          name: suggestion.name,
          address: suggestion.address,
          location: latLng,
          placeId: suggestion.placeId,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Home address saved'),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
    _loadInitialSuggestions();
  }

  Future<void> _handleSuggestionTap(_LocationSuggestion suggestion) async {
    if (suggestion.name == 'Current Location') {
      _getCurrentLocation();
      return;
    }

    if (suggestion.latLng == null && suggestion.placeId != null) {
      setState(() => _isLoading = true);
      LatLng? latLng =
          await _placesService.getPlaceDetails(suggestion.placeId!);

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
        final stopIdx = _editingStopIndex;
        final tripOv = _tripOverviewMode;
        if (stopIdx != null && tripOv) {
          ref.read(savedLocationsProvider.notifier).addRecentLocation(
                name: suggestion.name,
                address: suggestion.address,
                location: latLng,
                placeId: suggestion.placeId,
              );
          final line = '${suggestion.name}, ${suggestion.address}';
          widget.onLocationSelected(line, latLng, stopIndex: stopIdx);
          if (mounted) {
            _stopControllers[stopIdx].value = TextEditingValue(
              text: line,
              selection: TextSelection.collapsed(offset: line.length),
            );
            _debounce?.cancel();
            _loadInitialSuggestions();
          }
        } else {
          final applyPickup = _tapAppliesToPickup;
          final destinationSide = !applyPickup;
          if (destinationSide) {
            ref.read(savedLocationsProvider.notifier).addRecentLocation(
                  name: suggestion.name,
                  address: suggestion.address,
                  location: latLng,
                  placeId: suggestion.placeId,
                );
          }

          final asPickup = tripOv ? applyPickup : null;
          final line = '${suggestion.name}, ${suggestion.address}';
          widget.onLocationSelected(
            line,
            latLng,
            asPickup: asPickup,
          );
          if (tripOv && !applyPickup) {
            _searchController.value = _destTextValue(line);
          }
          if (tripOv && mounted) {
            _debounce?.cancel();
            _loadInitialSuggestions();
          }
          if (!tripOv && mounted) Navigator.pop(context);
        }
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
      _searchLocation(suggestion.name,
          asPickupBias:
              _tripOverviewMode ? _tapAppliesToPickup : null);
      return;
    }

    final stopIdx = _editingStopIndex;
    final tripOv = _tripOverviewMode;
    if (stopIdx != null && tripOv) {
      ref.read(savedLocationsProvider.notifier).addRecentLocation(
            name: suggestion.name,
            address: suggestion.address,
            location: suggestion.latLng!,
            placeId: suggestion.placeId,
          );
      final line =
          '${suggestion.name}${suggestion.address.isNotEmpty ? ', ${suggestion.address}' : ''}';
      widget.onLocationSelected(
        line,
        suggestion.latLng,
        stopIndex: stopIdx,
      );
      if (mounted) {
        _stopControllers[stopIdx].value = TextEditingValue(
          text: line,
          selection: TextSelection.collapsed(offset: line.length),
        );
        _debounce?.cancel();
        _loadInitialSuggestions();
      }
    } else {
      final applyPickup = _tapAppliesToPickup;
      final destinationSide = !applyPickup;
      if (destinationSide &&
          suggestion.latLng != null &&
          suggestion.name != 'Current Location') {
        ref.read(savedLocationsProvider.notifier).addRecentLocation(
              name: suggestion.name,
              address: suggestion.address,
              location: suggestion.latLng!,
              placeId: suggestion.placeId,
            );
      }

      final asPickup = tripOv ? applyPickup : null;
      final line =
          '${suggestion.name}${suggestion.address.isNotEmpty ? ', ${suggestion.address}' : ''}';
      widget.onLocationSelected(
        line,
        suggestion.latLng,
        asPickup: asPickup,
      );
      if (tripOv && !applyPickup) {
        _searchController.value = _destTextValue(line);
      }
      if (tripOv && mounted) {
        _debounce?.cancel();
        _loadInitialSuggestions();
      }
      if (!tripOv && mounted) Navigator.pop(context);
    }
  }

  Widget _buildSuggestionTile(_LocationSuggestion suggestion) {
    final tripOverview = _tripOverviewMode;
    final destinationSide = tripOverview
        ? (_editingStopIndex != null || !_tapAppliesToPickup)
        : !widget.isPickup;
    final showHomeHeart = destinationSide &&
        !tripOverview &&
        !widget.selectingStop &&
        suggestion.fromRecent &&
        suggestion.latLng != null &&
        suggestion.name != 'Current Location';
    final homeMatch = showHomeHeart && _isSameAsSavedHome(suggestion);
    final heartFilled = homeMatch || _isFavorite(suggestion);
    final figmaRecentRow = tripOverview &&
        suggestion.fromRecent &&
        _searchController.text.trim().isEmpty;
    final usePill = suggestion.fromRecent &&
        _searchController.text.trim().isEmpty &&
        !_tripOverviewMode;

    final titleStyle = figmaRecentRow
        ? const TextStyle(
            fontFamily: 'Poppins',
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Color(0xFF000000),
            height: 1.5,
          )
        : const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          );
    final subtitleStyle = figmaRecentRow
        ? const TextStyle(
            fontFamily: 'Poppins',
            fontSize: 14.19,
            fontWeight: FontWeight.w400,
            color: Color(0xFF929292),
            height: 1.48,
          )
        : const TextStyle(
            fontSize: 13,
            color: Color(0xFF888888),
          );

    final leading = figmaRecentRow
        ? Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _planOrange, width: 1.32),
              ),
              child: Icon(
                Icons.schedule_rounded,
                size: 14,
                color: Colors.grey.shade700,
              ),
            ),
          )
        : Container(
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
          );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _handleSuggestionTap(suggestion),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: usePill ? 12 : (figmaRecentRow ? 10 : 8),
                horizontal: usePill ? 14 : 0,
              ),
              child: Row(
                children: [
                  leading,
                  SizedBox(width: figmaRecentRow ? 10 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.name,
                          style: titleStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (suggestion.address.isNotEmpty)
                          Text(
                            suggestion.address,
                            style: subtitleStyle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (!figmaRecentRow)
                    const Icon(
                      Icons.arrow_forward_ios,
                      color: Color(0xFFBDBDBD),
                      size: 16,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (showHomeHeart)
          IconButton(
            tooltip: 'Set as Home',
            onPressed: () => _setRecentAsHome(suggestion),
            icon: Icon(
              heartFilled ? Icons.favorite : Icons.favorite_border,
              color: heartFilled
                  ? const Color(0xFFD14544)
                  : const Color(0xFF292D32),
              size: 15,
            ),
          ),
      ],
    );

    if (usePill) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: const Color(0xFFEEEEEE),
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: row,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: figmaRecentRow
                ? const Color(0xFFE8E8E8)
                : const Color(0xFFF0F0F0),
          ),
        ),
      ),
      child: row,
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
  /// True when this row came from [SavedLocationsState.recentLocations] (shows Set Home heart on destination sheet).
  final bool fromRecent;

  _LocationSuggestion({
    required this.name,
    required this.address,
    this.latLng,
    this.icon,
    this.placeId,
    this.fromRecent = false,
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
