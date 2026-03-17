import 'dart:async';
import 'package:flutter/material.dart';
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
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/settings_provider.dart';
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
  
  late String _selectedCabType; // Will be set from initialServiceType or default
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
  
  // Google Maps controller
  Completer<GoogleMapController> _mapController = Completer();
  GoogleMapController? _controller;
  
  // Directions service
  final DirectionsService _directionsService = DirectionsService();
  
  // Default location (Bangalore)
  LatLng _pickupLocation = const LatLng(12.9716, 77.5946);
  LatLng _destinationLocation = const LatLng(12.9816, 77.6046);
  
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  
  // Nearby drivers
  List<Map<String, dynamic>> _nearbyDrivers = [];
  BitmapDescriptor? _carIcon;
  BitmapDescriptor? _bikeIcon;
  BitmapDescriptor? _autoIcon;
  BitmapDescriptor? _cabPremiumIcon;
  
  // Route info
  String _distanceText = '';
  String _durationText = '';
  double _estimatedFare = 0;
  bool _isLoadingRoute = false;

  @override
  void initState() {
    super.initState();
    // Set selected cab type from parameter or use default
    _selectedCabType = widget.initialServiceType ?? 'bike_rescue';
    // Set scheduled time from parameter
    _scheduledTime = widget.scheduledTime;
    // Sync from provider if we have saved booking (e.g. returning after driver cancel)
    _loadFromProvider();
    _loadCustomMarkers();
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
    if (booking.pickupLocation != null && booking.pickupAddress != null && booking.pickupAddress!.isNotEmpty) {
      _pickupLocation = booking.pickupLocation!;
      _pickupController.text = booking.pickupAddress!;
    }
    if (booking.destinationLocation != null && booking.destinationAddress != null && booking.destinationAddress!.isNotEmpty) {
      _destinationLocation = booking.destinationLocation!;
      _destinationController.text = booking.destinationAddress!;
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
    
    if (scheduled.day == now.day && scheduled.month == now.month && scheduled.year == now.year) {
      return 'Today, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
    }
    final tomorrow = now.add(const Duration(days: 1));
    if (scheduled.day == tomorrow.day && scheduled.month == tomorrow.month && scheduled.year == tomorrow.year) {
      return 'Tomorrow, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
    }
    return '${scheduled.day}/${scheduled.month}, ${TimeOfDay.fromDateTime(scheduled).format(context)}';
  }
  
  bool get _isScheduledRide => _scheduledTime != null;
  
  /// Load custom vehicle icons from assets (bike, auto, cab, cab premium)
  /// 78x78 px for Uber/Ola-style visibility, transparent background
  Future<void> _loadCustomMarkers() async {
    try {
      const size = Size(78, 78);
      final config = ImageConfiguration(size: size, devicePixelRatio: 2.0);
      _bikeIcon = await BitmapDescriptor.fromAssetImage(
        config,
        'assets/map_icons/icon_bike.png',
      );
      _autoIcon = await BitmapDescriptor.fromAssetImage(
        config,
        'assets/map_icons/icon_auto.png',
      );
      _carIcon = await BitmapDescriptor.fromAssetImage(
        config,
        'assets/map_icons/icon_cab.png',
      );
      _cabPremiumIcon = await BitmapDescriptor.fromAssetImage(
        config,
        'assets/map_icons/icon_cab_premium.png',
      );
    } catch (e) {
      debugPrint('Map icons load failed, using fallback: $e');
      _carIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
      _bikeIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
      _autoIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan);
      _cabPremiumIcon = _carIcon;
    }
  }

  /// Map selected cab type id to the driver vehicle category for filtering
  /// (cab_premium uses same commercial_car drivers, but we show premium icon)
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
        return 'assets/vehicles/cab_premium.png';
      default:
        return 'assets/vehicles/cab_mini.png';
    }
  }
  
  /// Fetch nearby drivers from backend and show on map
  Future<void> _fetchNearbyDrivers() async {
    try {
      final data = await apiClient.getNearbyDrivers(
        _pickupLocation.latitude,
        _pickupLocation.longitude,
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
            'lat': d['currentLatitude'] ?? _pickupLocation.latitude + 0.005,
            'lng': d['currentLongitude'] ?? _pickupLocation.longitude + 0.005,
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
          'lat': _pickupLocation.latitude + latOffset,
          'lng': _pickupLocation.longitude + lngOffset,
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
  void _updateDriverMarkers() {
    final driverMarkers = <Marker>{};
    final activeCategory = _vehicleCategoryForCabType(_selectedCabType);

    for (final driver in _nearbyDrivers) {
      final type = driver['type'] ?? 'car';

      // Only show drivers matching the currently selected vehicle category
      if (type != activeCategory) continue;

      BitmapDescriptor icon;
      switch (type) {
        case 'bike':
          icon = _bikeIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);
          break;
        case 'auto':
          icon = _autoIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan);
          break;
        case 'car':
        default:
          icon = (_selectedCabType == 'cab_premium' ? _cabPremiumIcon : _carIcon) ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
      }
      
      driverMarkers.add(
        Marker(
          markerId: MarkerId('driver_${driver['id']}'),
          position: LatLng(driver['lat'], driver['lng']),
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          rotation: (driver['heading'] ?? 0).toDouble(),
          infoWindow: InfoWindow(
            title: driver['name'] ?? 'Driver',
            snippet: '${driver['rating']?.toStringAsFixed(1) ?? '4.5'} ★ • ${type.toUpperCase()}',
          ),
        ),
      );
    }
    
    // Combine with existing pickup/destination markers
    final existingMarkers = _markers.where((m) => 
      m.markerId.value == 'pickup' || m.markerId.value == 'destination'
    ).toSet();
    
    setState(() {
      _markers = {...existingMarkers, ...driverMarkers};
    });
  }
  
  /// Get current location and set as pickup
  Future<void> _getCurrentLocationForPickup() async {
    try {
      // Skip if we already have pickup from provider (e.g. returning with saved booking)
      final booking = ref.read(rideBookingProvider);
      if (booking.pickupLocation != null && 
          booking.pickupAddress != null && 
          booking.pickupAddress!.isNotEmpty &&
          booking.pickupAddress != 'Getting location...') {
        debugPrint('📍 Using pickup from provider: ${booking.pickupAddress}');
        if (mounted) {
          _setupMapElements();
          _fetchNearbyDrivers();
          if (booking.destinationLocation != null) _calculateRoute();
        }
        return;
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          // Use default location if permission denied
          _setDefaultPickup();
          return;
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        _setDefaultPickup();
        return;
      }
      
      // Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      if (!mounted) return;
      
      final pickupLatLng = LatLng(position.latitude, position.longitude);
      setState(() {
        _pickupLocation = pickupLatLng;
      });
      
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
          setState(() {
            _pickupController.text = pickupAddress;
          });
        } else {
          setState(() {
            _pickupController.text = 'Current Location';
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _pickupController.text = 'Current Location';
          });
        }
      }
      
      // CRITICAL: Update the provider with pickup location so it's available when creating ride
      ref.read(rideBookingProvider.notifier).setPickupLocation(pickupAddress, pickupLatLng);
      debugPrint('📍 Pickup location set in provider: $pickupAddress (${pickupLatLng.latitude}, ${pickupLatLng.longitude})');
      
      _setupMapElements();
      // Fetch nearby drivers
      _fetchNearbyDrivers();
      // Don't calculate route until destination is set
      
    } catch (e) {
      debugPrint('Error getting current location: $e');
      _setDefaultPickup();
    }
  }
  
  void _setDefaultPickup() {
    const defaultLatLng = LatLng(28.4595, 77.0266); // Default Gurgaon
    const defaultAddress = 'Getting location...';
    setState(() {
      _pickupLocation = defaultLatLng;
      _pickupController.text = defaultAddress;
    });
    // CRITICAL: Update the provider with default pickup location
    ref.read(rideBookingProvider.notifier).setPickupLocation(defaultAddress, defaultLatLng);
    debugPrint('📍 Default pickup location set in provider: $defaultAddress (${defaultLatLng.latitude}, ${defaultLatLng.longitude})');
    _setupMapElements();
    _fetchNearbyDrivers();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  void _setupMapElements() {
    // Add markers — only show destination marker once the user has set one
    _markers = {
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickupLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: 'Pickup', snippet: _pickupController.text),
        draggable: true,
        onDragEnd: (newPosition) async {
          setState(() => _pickupLocation = newPosition);
          await _reverseGeocodeAndUpdatePickup(newPosition);
          if (_destinationController.text.isNotEmpty) _calculateRoute();
        },
      ),
      if (_destinationController.text.isNotEmpty)
        Marker(
          markerId: const MarkerId('destination'),
          position: _destinationLocation,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(title: 'Destination', snippet: _destinationController.text),
          draggable: true,
          onDragEnd: (newPosition) async {
            setState(() => _destinationLocation = newPosition);
            await _reverseGeocodeAndUpdateDestination(newPosition);
            _calculateRoute();
          },
        ),
    };
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
        ref.read(rideBookingProvider.notifier).setPickupLocation(address, position);
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
          _destinationController.text = address.isNotEmpty ? address : 'Dropped Pin';
        });
        
        // Update provider
        ref.read(rideBookingProvider.notifier).setDestinationLocation(address, position);
      }
    } catch (e) {
      debugPrint('Reverse geocode error: $e');
      if (mounted) {
        setState(() => _destinationController.text = 'Dropped Pin');
      }
    }
  }

  /// Calculate route using Dijkstra's algorithm via DirectionsService
  Future<void> _calculateRoute() async {
    if (!mounted) return;
    setState(() {
      _isLoadingRoute = true;
      _isLoadingPricing = true;
    });
    
    try {
      debugPrint('🗺️ Calculating route using Dijkstra algorithm...');
      debugPrint('   From: ${_pickupLocation.latitude}, ${_pickupLocation.longitude}');
      debugPrint('   To: ${_destinationLocation.latitude}, ${_destinationLocation.longitude}');
      
      final waypoints = _stops.isNotEmpty
          ? _stops.map((s) => s.location).toList()
          : null;
      final route = await _directionsService.getRoute(
        origin: _pickupLocation,
        destination: _destinationLocation,
        waypoints: waypoints,
        mode: TravelMode.driving,
      );
      
      if (!mounted) return;
      
      debugPrint('✅ Route calculated: ${route.distanceText}, ${route.durationText}');
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
        pickupLocation: _pickupLocation,
        pickupAddress: _pickupController.text,
        destinationLocation: _destinationLocation,
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
        
        // Uber/Rapido-style polylines: border + fill + rounded caps
        _polylines = {
          Polyline(
            polylineId: const PolylineId('route_border'),
            points: route.points,
            color: const Color(0xFF1A1A1A),
            width: 7,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
          Polyline(
            polylineId: const PolylineId('route'),
            points: route.points,
            color: const Color(0xFF4285F4),
            width: 5,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };
        
        debugPrint('📍 Polyline created with ${route.points.length} points');
        
        // Keep driver markers and update pickup/destination/stops
        final driverMarkers = _markers.where((m) => 
          m.markerId.value.startsWith('driver_')
        ).toSet();
        
        final stopMarkers = <Marker>{};
        for (int i = 0; i < _stops.length; i++) {
          final stop = _stops[i];
          stopMarkers.add(
            Marker(
              markerId: MarkerId('stop_$i'),
              position: stop.location,
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
              infoWindow: InfoWindow(title: 'Stop ${i + 1}', snippet: stop.address),
              draggable: true,
              onDragEnd: (newPosition) {
                setState(() {
                  _stops[i] = RideStop(address: stop.address, location: newPosition);
                });
                _calculateRoute();
              },
            ),
          );
        }
        
        _markers = {
          ...driverMarkers,
          ...stopMarkers,
          Marker(
            markerId: const MarkerId('pickup'),
            position: _pickupLocation,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
            infoWindow: InfoWindow(
              title: 'Pickup',
              snippet: _pickupController.text,
            ),
            draggable: true,
            onDragEnd: (newPosition) {
              setState(() => _pickupLocation = newPosition);
              _calculateRoute();
            },
          ),
          Marker(
            markerId: const MarkerId('destination'),
            position: _destinationLocation,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            infoWindow: InfoWindow(
              title: 'Destination',
              snippet: _destinationController.text,
            ),
            draggable: true,
            onDragEnd: (newPosition) {
              setState(() => _destinationLocation = newPosition);
              _calculateRoute();
            },
          ),
        };
        
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

  /// Fetch ride pricing from backend
  Future<void> _fetchPricingFromBackend(double distance, int duration) async {
    try {
      debugPrint('💰 Fetching pricing from backend...');
      debugPrint('   Distance: ${distance}m, Duration: ${duration}s');
      
      // Backend: POST /api/pricing/calculate (with waypoints for multi-stop)
      final waypointsForPricing = _stops.isNotEmpty
          ? _stops.map((s) => {'lat': s.location.latitude, 'lng': s.location.longitude}).toList()
          : null;
      final data = await apiClient.getRidePricing(
        pickupLat: _pickupLocation.latitude,
        pickupLng: _pickupLocation.longitude,
        dropLat: _destinationLocation.latitude,
        dropLng: _destinationLocation.longitude,
        waypoints: waypointsForPricing,
        distanceKm: distance / 1000,
        durationMin: (duration / 60).ceil(),
      );

      // Backend returns: { success, data: { baseFare, distanceFare, timeFare, totalFare, distance, estimatedDuration, ... } }
      if (data['success'] == true) {
        final pricingData = data['data'] as Map<String, dynamic>? ?? {};
        final totalFare = (pricingData['totalFare'] as num?)?.toDouble() ?? 0;
        final baseFare = (pricingData['baseFare'] as num?)?.toDouble() ?? 0;
        
        // Generate cab type options from the base pricing
        final options = [
          CabType(id: 'bike_rescue', name: 'Bike Rescue', description: 'Quick bike rescue', iconName: 'two_wheeler', capacity: 1, fare: totalFare * 0.6, eta: '3 min'),
          CabType(id: 'auto', name: 'Auto', description: 'Auto rickshaw', iconName: 'electric_rickshaw', capacity: 3, fare: totalFare * 0.8, eta: '5 min'),
          CabType(id: 'cab_mini', name: 'Cab Mini', description: 'Compact car', iconName: 'directions_car', capacity: 4, fare: totalFare, eta: '7 min', isPopular: true),
          CabType(id: 'cab_xl', name: 'Cab XL', description: 'Spacious ride', iconName: 'airport_shuttle', capacity: 6, fare: totalFare * 1.3, eta: '10 min'),
          CabType(id: 'cab_premium', name: 'Premium', description: 'Luxury ride', iconName: 'diamond', capacity: 4, fare: totalFare * 1.8, eta: '12 min'),
        ];
        
        final fares = <String, double>{};
        for (final cab in options) {
          fares[cab.id] = cab.fare;
        }
        
        setState(() {
          _cabTypes = options;
          _cabFares = fares;
          _isSurgeActive = data['surge_active'] ?? false;
          _surgeMultiplier = (data['surge_multiplier'] ?? 1.0).toDouble();
          _distanceKmFromBackend = data['distance_km'] ?? '';
          _durationMinFromBackend = data['duration_min'] ?? 0;
          _isLoadingPricing = false;
        });
        
        debugPrint('✅ Pricing fetched: ${options.length} options');
        debugPrint('   Surge active: $_isSurgeActive (${_surgeMultiplier}x)');
      } else {
        debugPrint('❌ Pricing API returned unsuccessful');
        _loadFallbackPricing(distance, duration);
      }
    } catch (e) {
      debugPrint('❌ Error fetching pricing: $e');
      _loadFallbackPricing(distance, duration);
    }
  }

  /// Fallback pricing calculation if backend is unavailable
  void _loadFallbackPricing(double distance, int duration) {
    final distanceKm = distance / 1000;
    final durationMin = duration / 60;
    
    // Fallback cab types
    final fallbackTypes = [
      {'id': 'bike_rescue', 'name': 'Rescue Service', 'description': 'Quick rescue on two-wheeler — pickup and drop anywhere', 'icon': 'two_wheeler', 'base_fare': 20, 'per_km_rate': 6, 'per_min_rate': 1, 'capacity': 1, 'badge': 'Rescue', 'is_popular': true},
      {'id': 'auto', 'name': 'Auto', 'description': 'Budget-friendly auto rickshaw', 'icon': 'electric_rickshaw', 'base_fare': 25, 'per_km_rate': 8, 'per_min_rate': 1.5, 'capacity': 3, 'badge': 'Cheapest'},
      {'id': 'cab_mini', 'name': 'Cab Mini', 'description': 'Compact cars for city rides', 'icon': 'directions_car', 'base_fare': 40, 'per_km_rate': 12, 'per_min_rate': 2, 'capacity': 4},
      {'id': 'cab_xl', 'name': 'Cab XL', 'description': 'Spacious SUVs for groups', 'icon': 'airport_shuttle', 'base_fare': 80, 'per_km_rate': 18, 'per_min_rate': 3, 'capacity': 6, 'badge': 'Family'},
      {'id': 'cab_premium', 'name': 'Cab Premium', 'description': 'Luxury sedans with top drivers', 'icon': 'diamond', 'base_fare': 100, 'per_km_rate': 25, 'per_min_rate': 4, 'capacity': 4, 'badge': 'Premium'},
      {'id': 'personal_driver', 'name': 'Personal Driver', 'description': 'Hire a driver for your own car', 'icon': 'person', 'base_fare': 150, 'per_km_rate': 0, 'per_min_rate': 3.5, 'capacity': 4, 'badge': 'Hourly'},
    ];
    
    final options = fallbackTypes.map((type) {
      final fare = (type['base_fare'] as num) + (distanceKm * (type['per_km_rate'] as num)) + (durationMin * (type['per_min_rate'] as num));
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
      List<LatLng> allPoints = [_pickupLocation, _destinationLocation, ..._stops.map((s) => s.location)];
      
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
      debugPrint('   SW: (${bounds.southwest.latitude.toStringAsFixed(4)}, ${bounds.southwest.longitude.toStringAsFixed(4)})');
      debugPrint('   NE: (${bounds.northeast.latitude.toStringAsFixed(4)}, ${bounds.northeast.longitude.toStringAsFixed(4)})');
      
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Animate camera with padding for UI elements at top
      await _controller?.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 50), // 50 pixel padding from edges
      );
      
      debugPrint('✅ Map camera animated to show full route');
    } catch (e) {
      debugPrint('❌ Error fitting bounds: $e');
      // Fallback: center between pickup and destination
      try {
        final centerLat = (_pickupLocation.latitude + _destinationLocation.latitude) / 2;
        final centerLng = (_pickupLocation.longitude + _destinationLocation.longitude) / 2;
        await _controller?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(centerLat, centerLng), 12),
        );
      } catch (_) {}
    }
  }

  bool _locationWasSelected = false;

  void _showLocationSearchSheet({required bool isPickup, int? addStopAt, int? editStopAt}) {
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
                content: Text('Could not get coordinates. Please try a different search.'),
                backgroundColor: Colors.orange,
              ),
            );
            return;
          }
          setState(() {
            if (isPickup) {
              _pickupController.text = address;
              _pickupLocation = latLng;
              ref.read(rideBookingProvider.notifier).setPickupLocation(address, latLng);
            } else if (editStopAt != null) {
              if (editStopAt < _stops.length) {
                _stops[editStopAt] = RideStop(address: address, location: latLng);
                ref.read(rideBookingProvider.notifier).setStops(_stops);
              }
            } else if (addStopAt != null) {
              _stops.insert(addStopAt, RideStop(address: address, location: latLng));
              ref.read(rideBookingProvider.notifier).setStops(_stops);
            } else {
              _destinationController.text = address;
              _destinationLocation = latLng;
              ref.read(rideBookingProvider.notifier).setDestinationLocation(address, latLng);
            }
          });
          _setupMapElements();
          _updateDriverMarkers();
          if (_destinationController.text.isNotEmpty) {
            _calculateRoute().then((_) {
              Future.delayed(const Duration(milliseconds: 300), () {
                _fitRouteBounds(null);
              });
            });
          }
        },
      ),
    ).then((_) {
      // If sheet was dismissed without selecting a location AND we came via auto-open,
      // pop back to the home screen
      if (!_locationWasSelected && widget.autoOpenSearch && _destinationController.text.isEmpty) {
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
      body: SafeArea(
        child: Stack(
          children: [
            // Full-height map with header
            Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildMapSection()),
              ],
            ),
            // Draggable bottom sheet (Uber/Ola style - drag up/down)
            DraggableScrollableSheet(
              initialChildSize: 0.40,
              minChildSize: 0.25,
              maxChildSize: 0.90,
              snap: true,
              snapSizes: const [0.25, 0.40, 0.65, 0.90],
              builder: (context, scrollController) => _buildBottomSheet(scrollController),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ActiveRideBanner(),
            ),
          ],
        ),
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
                  final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : 'R';
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
                          child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                          const Text('View Profile', style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
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
              child: Text('Raahi v1.0.0', style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
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
            const Text('Help & Support', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                          const SnackBar(content: Text('Card payment selected')),
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
              child: const Icon(Icons.account_balance, color: Color(0xFFD4956A)),
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
            child: const Text('Link UPI', style: TextStyle(color: Colors.white)),
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
          // Spacer to maintain layout balance
          const SizedBox(width: 120),
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

  Widget _buildMapSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        children: [
          // Google Map
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  (_pickupLocation.latitude + _destinationLocation.latitude) / 2,
                  (_pickupLocation.longitude + _destinationLocation.longitude) / 2,
                ),
                zoom: 12,
              ),
              markers: _markers,
              polylines: _polylines,
              onMapCreated: (GoogleMapController controller) {
                _controller = controller;
                if (!_mapController.isCompleted) {
                  _mapController.complete(controller);
                }
                // Fit bounds after map is created and route is calculated
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (_polylines.isNotEmpty) {
                    _fitRouteBounds(null);
                  }
                });
              },
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              padding: const EdgeInsets.only(top: 120), // Padding for location inputs overlay
            ),
          ),
          
          // Loading indicator for route calculation
          if (_isLoadingRoute)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD4956A)),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Calculating best route...',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          
          // Location inputs overlay at top
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _buildLocationInputs(),
          ),
          
          // Center on route button
          Positioned(
            bottom: 50,
            right: 12,
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
          
          // Route info badge
          if (_distanceText.isNotEmpty && !_isLoadingRoute)
            Positioned(
              bottom: 12,
              left: 12,
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
                    const Icon(Icons.access_time, size: 16, color: Color(0xFF4285F4)),
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
      ),
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
                    Container(width: 2, height: 12, color: const Color(0xFFE0E0E0)),
                    const SizedBox(width: 18),
                    const Expanded(child: Divider(color: Color(0xFFE0E0E0))),
                  ],
                ),
                GestureDetector(
                  onTap: () => _showLocationSearchSheet(isPickup: false, editStopAt: i),
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
                            style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _stops.removeAt(i);
                              ref.read(rideBookingProvider.notifier).setStops(_stops);
                            });
                            if (_destinationController.text.isNotEmpty) _calculateRoute();
                          },
                          child: const Icon(Icons.close, size: 18, color: Color(0xFFBDBDBD)),
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
              onTap: () => _showLocationSearchSheet(isPickup: false, addStopAt: _stops.length),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Container(width: 2, height: 12, color: const Color(0xFFE0E0E0)),
                    const SizedBox(width: 18),
                    const Icon(Icons.add_circle_outline, size: 18, color: Color(0xFF4285F4)),
                    const SizedBox(width: 8),
                    Text(
                      'Add stop',
                      style: TextStyle(fontSize: 14, color: const Color(0xFF4285F4).withOpacity(0.9)),
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
    final bool showBookButton = _cabTypes.isNotEmpty && _destinationController.text.isNotEmpty;
    
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
              padding: EdgeInsets.fromLTRB(20, 12, 20, showBookButton ? 10 : 24),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F0EA),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.route, size: 12, color: const Color(0xFFD4956A)),
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
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.orange.shade300),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.bolt, size: 12, color: Colors.orange.shade700),
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
                    ],
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
                          border: Border.all(color: const Color(0xFFD4956A).withOpacity(0.3)),
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.add_location_alt, size: 48, color: const Color(0xFFD4956A).withOpacity(0.7)),
                            const SizedBox(height: 12),
                            const Text(
                              'Where do you want to go?',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Tap to enter your destination',
                              style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
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
                            Text('Loading services...', style: TextStyle(color: Color(0xFF888888))),
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
      {'id': 'bike_rescue', 'name': 'Rescue Service', 'desc': 'Quick two-wheeler pickup & drop', 'icon': Icons.two_wheeler, 'color': const Color(0xFFD4956A)},
      {'id': 'auto', 'name': 'Auto', 'desc': 'Budget-friendly auto rickshaw', 'icon': Icons.electric_rickshaw, 'color': const Color(0xFF4CAF50)},
      {'id': 'cab_mini', 'name': 'Cab Mini', 'desc': 'Compact cars for city rides', 'icon': Icons.directions_car, 'color': const Color(0xFF2196F3)},
      {'id': 'cab_xl', 'name': 'Cab XL', 'desc': 'Spacious SUVs for groups', 'icon': Icons.airport_shuttle, 'color': const Color(0xFF7B1FA2)},
      {'id': 'cab_premium', 'name': 'Cab Premium', 'desc': 'Luxury sedans with top drivers', 'icon': Icons.diamond, 'color': const Color(0xFFFF9800)},
      {'id': 'personal_driver', 'name': 'Personal Driver', 'desc': 'Hire a driver for your car', 'icon': Icons.person, 'color': const Color(0xFF455A64)},
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
              color: isSelected ? (svc['color'] as Color).withOpacity(0.08) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? (svc['color'] as Color) : const Color(0xFFE8E0D4),
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
                  child: Icon(svc['icon'] as IconData, color: svc['color'] as Color, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        svc['name'] as String,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        svc['desc'] as String,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 14, color: const Color(0xFFBDBDBD)),
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
            color: isSelected ? const Color(0xFFD4956A) : const Color(0xFFE8E8E8),
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
                    color: isSelected ? const Color(0xFFD4956A) : const Color(0xFF666666),
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
                          color: isSelected ? const Color(0xFFD4956A) : const Color(0xFF1A1A1A),
                        ),
                      ),
                      if (cab.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                      color: isSelected ? const Color(0xFFD4956A) : const Color(0xFF1A1A1A),
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
    final distanceKm = _distanceText.isNotEmpty ? double.tryParse(_distanceText.replaceAll(' km', '')) ?? 0 : 0;
    final durationMin = _durationText.isNotEmpty ? double.tryParse(_durationText.replaceAll(' min', '')) ?? 0 : 0;
    
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
          _buildFareRow('Base Fare', '₹${selectedCab.baseFare.toStringAsFixed(0)}'),
          _buildFareRow('Distance (${distanceKm.toStringAsFixed(1)} km × ₹${selectedCab.perKmRate.toStringAsFixed(0)})', 
              '₹${(distanceKm * selectedCab.perKmRate).toStringAsFixed(0)}'),
          _buildFareRow('Time (${durationMin.toStringAsFixed(0)} min × ₹${selectedCab.perMinRate.toStringAsFixed(0)})', 
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

        // Update provider with selected cab type
        ref.read(rideBookingProvider.notifier).setCabType(
          id: selectedCab.id,
          name: selectedCab.name,
          fare: fare,
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
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _needExtraDrivers && _driverCount > 1 ? const Color(0xFFD4956A) : const Color(0xFFE0E0E0),
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
                        ),
                        child: Icon(
                          Icons.remove,
                          size: 18,
                          color: _needExtraDrivers && _driverCount > 1 ? Colors.white : Colors.grey,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _needExtraDrivers ? const Color(0xFFD4956A) : const Color(0xFFE0E0E0),
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(7)),
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
  ConsumerState<_LocationSearchSheet> createState() => _LocationSearchSheetState();
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
        recent.latLng.longitude == s.latLng!.longitude
      );
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
        debugPrint('📍 Using device location for search bias: $searchBiasLocation');
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
          searchBiasLocation = const LatLng(25.45, 81.85); // Prayagraj/Allahabad as India fallback
          debugPrint('📍 Using India fallback for search bias');
        }
      }

      final placesResults = await _placesService.searchPlacesWithFallback(query, location: searchBiasLocation);
      debugPrint('🔍 Places API returned ${placesResults.length} results');
      
      if (placesResults.isNotEmpty) {
        setState(() {
          _suggestions = placesResults.map((place) => _LocationSuggestion(
            name: place.name,
            address: place.address,
            latLng: place.latLng,
            placeId: place.placeId,
          )).toList();
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
                address: '${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
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
                    widget.isPickup ? 'Enter pickup location' : 'Enter destination',
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
                    color: widget.isPickup ? const Color(0xFFD4956A) : const Color(0xFF4CAF50),
                    size: 18,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                          child: const Icon(Icons.clear, color: Color(0xFFBDBDBD)),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F8FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF4285F4).withOpacity(0.3)),
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
                _searchController.text.isEmpty ? 'Recent Locations' : 'Search Results',
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
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD4956A)),
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
                            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'No locations found',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Try a different search term',
                              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
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
          LatLng? latLng = await _placesService.getPlaceDetails(suggestion.placeId!);
          
          // Fallback: try geocoding if Place Details API fails
          if (latLng == null) {
            debugPrint('⚠️ Place Details failed, falling back to geocoding for: ${suggestion.name}');
            try {
              final locations = await locationFromAddress(
                '${suggestion.name}, ${suggestion.address}',
                localeIdentifier: 'en_IN',
              );
              if (locations.isNotEmpty) {
                latLng = LatLng(locations.first.latitude, locations.first.longitude);
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
                const SnackBar(content: Text('Could not get location coordinates. Try a different search.')),
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
        if (!widget.isPickup && suggestion.latLng != null && suggestion.name != 'Current Location') {
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
