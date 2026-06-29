import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/ride_stop.dart';
import '../providers/ride_booking_provider.dart';

/// Persists in-progress rider booking so scheduled rides survive app restarts.
class PendingRideStorage {
  PendingRideStorage._();

  static const _key = 'pending_ride_booking_v1';

  static Future<void> save(RideBookingState state) async {
    if (state.rideId == null || state.rideId!.isEmpty) {
      await clear();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'rideId': state.rideId,
      'rideOtp': state.rideOtp,
      'pickupAddress': state.pickupAddress,
      'destinationAddress': state.destinationAddress,
      'pickupLat': state.pickupLocation?.latitude,
      'pickupLng': state.pickupLocation?.longitude,
      'dropLat': state.destinationLocation?.latitude,
      'dropLng': state.destinationLocation?.longitude,
      'distanceText': state.distanceText,
      'durationText': state.durationText,
      'distance': state.distance,
      'duration': state.duration,
      'fare': state.fare,
      'selectedCabTypeId': state.selectedCabTypeId,
      'selectedCabTypeName': state.selectedCabTypeName,
      'scheduledTime': state.scheduledTime?.toIso8601String(),
      'stops': state.stops
          .map(
            (s) => {
              'address': s.address,
              if (s.location != null) 'lat': s.location!.latitude,
              if (s.location != null) 'lng': s.location!.longitude,
            },
          )
          .toList(),
    };
    await prefs.setString(_key, jsonEncode(payload));
  }

  static Future<RideBookingState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final rideId = map['rideId']?.toString();
      if (rideId == null || rideId.isEmpty) return null;

      LatLng? pickup;
      final pickupLat = _toDouble(map['pickupLat']);
      final pickupLng = _toDouble(map['pickupLng']);
      if (pickupLat != null && pickupLng != null) {
        pickup = LatLng(pickupLat, pickupLng);
      }

      LatLng? drop;
      final dropLat = _toDouble(map['dropLat']);
      final dropLng = _toDouble(map['dropLng']);
      if (dropLat != null && dropLng != null) {
        drop = LatLng(dropLat, dropLng);
      }

      DateTime? scheduledTime;
      final scheduledRaw = map['scheduledTime']?.toString();
      if (scheduledRaw != null && scheduledRaw.isNotEmpty) {
        scheduledTime = DateTime.tryParse(scheduledRaw);
      }

      final stops = parseRideStopsFromJson(map['stops']);

      return RideBookingState(
        rideId: rideId,
        rideOtp: map['rideOtp']?.toString(),
        pickupAddress: map['pickupAddress']?.toString(),
        destinationAddress: map['destinationAddress']?.toString(),
        pickupLocation: pickup,
        destinationLocation: drop,
        stops: stops,
        distanceText: map['distanceText']?.toString() ?? '',
        durationText: map['durationText']?.toString() ?? '',
        distance: _toDouble(map['distance']) ?? 0,
        duration: (map['duration'] as num?)?.toInt() ?? 0,
        fare: _toDouble(map['fare']) ?? 0,
        selectedCabTypeId: map['selectedCabTypeId']?.toString() ?? 'cab_mini',
        selectedCabTypeName:
            map['selectedCabTypeName']?.toString() ?? 'Cab',
        scheduledTime: scheduledTime,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
