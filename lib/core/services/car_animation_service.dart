import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Production-grade Uber-style car animation service for smooth marker movement and rotation.
/// 
/// Features:
/// - Smooth position interpolation with cubic easing between location updates
/// - Bearing calculation for car rotation with smooth wrap-around
/// - Distance-based animation duration for natural movement
/// - Handles overlapping updates gracefully by continuing from current animated position
/// - Provides camera bearing for navigation-style map following
class CarAnimationService {
  LatLng? _previousPosition;
  LatLng? _currentPosition;
  LatLng? _lastAnimatedPosition;
  double _previousBearing = 0;
  double _currentBearing = 0;
  double _smoothedBearing = 0; // For camera rotation - less jittery
  int _lastAnimationDurationMs = 1000;
  double _currentSpeed = 0; // meters per second
  
  AnimationController? _positionController;
  
  final TickerProvider _vsync;
  final Duration baseAnimationDuration;
  
  /// Callback when interpolated position updates
  final void Function(LatLng position, double bearing)? onUpdate;
  
  CarAnimationService({
    required TickerProvider vsync,
    Duration animationDuration = const Duration(milliseconds: 1000),
    this.onUpdate,
  }) : _vsync = vsync, baseAnimationDuration = animationDuration;

  /// Initialize controllers
  void init() {
    _positionController = AnimationController(
      vsync: _vsync,
      duration: baseAnimationDuration,
    )..addListener(_onAnimationUpdate);
    debugPrint('🚗 CarAnimationService initialized');
  }

  /// Update with new location. Triggers smooth animation to new position.
  void updateLocation(LatLng newPosition, {double? heading}) {
    debugPrint('🚗 updateLocation called: (${newPosition.latitude}, ${newPosition.longitude}), heading: $heading');
    
    if (_currentPosition == null) {
      // First position - no animation needed, just set it
      _currentPosition = newPosition;
      _previousPosition = newPosition;
      _lastAnimatedPosition = newPosition;
      if (heading != null) {
        _currentBearing = heading;
        _previousBearing = heading;
        _smoothedBearing = heading;
      }
      debugPrint('🚗 First position set, calling onUpdate');
      onUpdate?.call(newPosition, _currentBearing);
      return;
    }

    // If currently animating, use the last animated position as the starting point
    // for smoother transitions during rapid updates (critical for production feel)
    if (_positionController?.isAnimating == true && _lastAnimatedPosition != null) {
      _previousPosition = _lastAnimatedPosition;
    } else {
      _previousPosition = _currentPosition;
    }
    
    _currentPosition = newPosition;
    
    // Calculate distance-based animation duration
    final distance = calculateDistance(_previousPosition!, newPosition);
    final durationMs = _calculateAnimationDuration(distance);
    _lastAnimationDurationMs = durationMs;
    _positionController?.duration = Duration(milliseconds: durationMs);
    
    // Calculate speed for dynamic camera behavior
    if (durationMs > 0) {
      _currentSpeed = distance / (durationMs / 1000);
    }
    
    // Calculate bearing if not provided
    if (heading != null && heading != 0) {
      _previousBearing = _currentBearing;
      _currentBearing = heading;
    } else if (distance > 2) {
      // Only calculate bearing if moving more than 2 meters
      _previousBearing = _currentBearing;
      _currentBearing = calculateBearing(_previousPosition!, newPosition);
    }
    
    // Smooth bearing for camera (low-pass filter to reduce jitter)
    _smoothedBearing = interpolateBearing(_smoothedBearing, _currentBearing, 0.3);
    
    debugPrint('🚗 Starting animation: distance=${distance.toStringAsFixed(1)}m, duration=${durationMs}ms, bearing=${_currentBearing.toStringAsFixed(1)}°, speed=${_currentSpeed.toStringAsFixed(1)}m/s');
    
    // Start animation
    _positionController?.reset();
    _positionController?.forward();
  }
  
  /// Calculate animation duration based on distance
  /// Short distances = quick animation, long distances = longer animation
  /// Tuned for production-grade Uber-like feel
  int _calculateAnimationDuration(double distanceMeters) {
    // Production tuning:
    // - Very short moves (< 5m): 400ms minimum for smoothness
    // - Normal city driving (5-50m): Scale linearly ~50ms/meter
    // - Fast highway moves (> 100m): Cap at 2500ms to prevent laggy feel
    if (distanceMeters < 5) {
      return 400;
    } else if (distanceMeters < 15) {
      return (400 + (distanceMeters - 5) * 40).round();
    } else if (distanceMeters < 50) {
      return (800 + (distanceMeters - 15) * 45).round();
    } else {
      // For large jumps, use faster animation to catch up
      return min(2500, (1600 + (distanceMeters - 50) * 20).round());
    }
  }

  void _onAnimationUpdate() {
    if (_previousPosition == null || _currentPosition == null) return;
    
    final t = _positionController?.value ?? 0;
    
    // Production-grade easing: cubic ease-in-out for natural vehicle movement
    // Slightly faster start than pure easeInOut for responsiveness
    final easedT = Curves.easeInOutCubic.transform(t);
    
    // Interpolate position
    final interpolatedPosition = interpolatePosition(
      _previousPosition!,
      _currentPosition!,
      easedT,
    );
    
    // Track last animated position for smooth transitions
    _lastAnimatedPosition = interpolatedPosition;
    
    // Interpolate bearing (handle wrap-around at 360°)
    final interpolatedBearing = interpolateBearing(
      _previousBearing,
      _currentBearing,
      easedT,
    );
    
    onUpdate?.call(interpolatedPosition, interpolatedBearing);
  }

  /// Linearly interpolate between two LatLng positions
  static LatLng interpolatePosition(LatLng start, LatLng end, double fraction) {
    return LatLng(
      start.latitude + (end.latitude - start.latitude) * fraction,
      start.longitude + (end.longitude - start.longitude) * fraction,
    );
  }

  /// Interpolate bearing with wrap-around handling (0-360°)
  static double interpolateBearing(double start, double end, double fraction) {
    // Normalize bearings to 0-360
    start = start % 360;
    end = end % 360;
    if (start < 0) start += 360;
    if (end < 0) end += 360;
    
    // Find shortest rotation direction
    double diff = end - start;
    if (diff > 180) {
      diff -= 360;
    } else if (diff < -180) {
      diff += 360;
    }
    
    double result = start + diff * fraction;
    if (result < 0) result += 360;
    if (result >= 360) result -= 360;
    
    return result;
  }

  /// Calculate bearing (heading) between two points in degrees
  static double calculateBearing(LatLng start, LatLng end) {
    final lat1 = start.latitude * pi / 180;
    final lat2 = end.latitude * pi / 180;
    final dLng = (end.longitude - start.longitude) * pi / 180;
    
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    
    double bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360;
  }

  /// Calculate distance between two points in meters
  static double calculateDistance(LatLng start, LatLng end) {
    const earthRadius = 6371000.0; // meters
    
    final lat1 = start.latitude * pi / 180;
    final lat2 = end.latitude * pi / 180;
    final dLat = (end.latitude - start.latitude) * pi / 180;
    final dLng = (end.longitude - start.longitude) * pi / 180;
    
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    
    return earthRadius * c;
  }

  /// Get current interpolated position
  LatLng? get currentPosition => _currentPosition;
  
  /// Get current bearing
  double get currentBearing => _currentBearing;
  
  /// Get smoothed bearing for camera (less jittery than raw bearing)
  double get smoothedBearing => _smoothedBearing;
  
  /// Get current speed in meters per second
  double get currentSpeed => _currentSpeed;

  /// Last animation duration used for debugging.
  int get lastAnimationDurationMs => _lastAnimationDurationMs;
  
  /// Check if animation is currently running
  bool get isAnimating => _positionController?.isAnimating ?? false;

  /// Dispose controllers
  void dispose() {
    _positionController?.removeListener(_onAnimationUpdate);
    _positionController?.dispose();
  }
  
  /// Calculate optimal camera zoom based on distance to target
  /// Returns zoom level between 13 (far) and 17.5 (close)
  static double calculateDynamicZoom(double distanceMeters) {
    if (distanceMeters < 100) {
      return 17.5; // Very close - maximum zoom
    } else if (distanceMeters < 300) {
      return 17.0;
    } else if (distanceMeters < 500) {
      return 16.5;
    } else if (distanceMeters < 1000) {
      return 16.0;
    } else if (distanceMeters < 2000) {
      return 15.5;
    } else if (distanceMeters < 5000) {
      return 15.0;
    } else if (distanceMeters < 10000) {
      return 14.0;
    } else {
      return 13.0; // Far away - zoomed out
    }
  }
  
  /// Calculate optimal camera tilt based on ride phase and speed
  /// Returns tilt between 0 and 60 degrees
  static double calculateDynamicTilt({
    required bool isRideInProgress,
    double speedMps = 0,
  }) {
    if (!isRideInProgress) {
      // Driver arriving - moderate tilt for navigation feel
      return 35.0;
    }
    
    // Ride in progress - more tilt for immersive experience
    // Higher speed = more tilt (up to 55°)
    if (speedMps > 15) {
      return 55.0; // Fast driving
    } else if (speedMps > 8) {
      return 50.0; // Normal driving
    } else if (speedMps > 3) {
      return 45.0; // Slow driving
    } else {
      return 40.0; // Stopped or very slow
    }
  }
}

/// Mixin for StatefulWidgets that need car animation
mixin CarAnimationMixin<T extends StatefulWidget> on State<T>, TickerProviderStateMixin<T> {
  late CarAnimationService carAnimationService;
  
  LatLng? _animatedDriverPosition;
  double _animatedDriverBearing = 0;
  
  LatLng? get animatedDriverPosition => _animatedDriverPosition;
  double get animatedDriverBearing => _animatedDriverBearing;

  void initCarAnimation() {
    carAnimationService = CarAnimationService(
      vsync: this,
      animationDuration: const Duration(milliseconds: 1000),
      onUpdate: (position, bearing) {
        if (mounted) {
          setState(() {
            _animatedDriverPosition = position;
            _animatedDriverBearing = bearing;
          });
        }
      },
    );
    carAnimationService.init();
  }

  void updateDriverAnimation(double lat, double lng, {double? heading}) {
    carAnimationService.updateLocation(
      LatLng(lat, lng),
      heading: heading,
    );
  }

  void disposeCarAnimation() {
    carAnimationService.dispose();
  }
}
