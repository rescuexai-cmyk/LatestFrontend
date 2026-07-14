import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'push_notification_service.dart';

/// Shows a one-shot welcome notification when a rider enters (or first opens
/// the app in) a Raahi operational city.
class CityWelcomeService {
  CityWelcomeService._();

  static const _prefsLastCityKey = 'raahi_last_welcomed_city_code';
  static const _prefsLastLatKey = 'raahi_city_welcome_last_lat';
  static const _prefsLastLngKey = 'raahi_city_welcome_last_lng';

  /// Ignore tiny GPS jitter — only re-check after ~2 km movement.
  static const _minMoveMeters = 2000.0;

  static DateTime? _lastCheckAt;
  static bool _inFlight = false;

  /// Call after obtaining a fresh device location (services hub / app resume).
  static Future<void> maybeNotifyForLocation({
    required double lat,
    required double lng,
  }) async {
    if (_inFlight) return;
    final now = DateTime.now();
    if (_lastCheckAt != null &&
        now.difference(_lastCheckAt!) < const Duration(seconds: 20)) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastLat = prefs.getDouble(_prefsLastLatKey);
      final lastLng = prefs.getDouble(_prefsLastLngKey);
      if (lastLat != null && lastLng != null) {
        final moved = Geolocator.distanceBetween(lastLat, lastLng, lat, lng);
        final lastCity = prefs.getString(_prefsLastCityKey);
        // Same spot and already welcomed somewhere — skip network.
        if (moved < _minMoveMeters && lastCity != null && lastCity.isNotEmpty) {
          return;
        }
      }

      _inFlight = true;
      _lastCheckAt = now;

      final availability =
          await apiClient.getCityAvailability(lat: lat, lng: lng);
      await prefs.setDouble(_prefsLastLatKey, lat);
      await prefs.setDouble(_prefsLastLngKey, lng);

      if (!availability.available || availability.cityCode.isEmpty) {
        debugPrint(
            '🏙️ City welcome: Raahi not available here (${availability.cityCode})');
        // Clear so re-entering an operational city welcomes again.
        await prefs.remove(_prefsLastCityKey);
        return;
      }

      final lastCode = prefs.getString(_prefsLastCityKey);
      if (lastCode == availability.cityCode) {
        debugPrint(
            '🏙️ City welcome: already welcomed for ${availability.cityCode}');
        return;
      }

      final shown = await pushNotificationService.showCityWelcomeNotification(
        availability.cityName,
      );
      if (shown) {
        await prefs.setString(_prefsLastCityKey, availability.cityCode);
        debugPrint(
            '🏙️ City welcome notified for ${availability.cityName} (${availability.cityCode})');
      }
    } catch (e) {
      debugPrint('🏙️ City welcome check failed: $e');
    } finally {
      _inFlight = false;
    }
  }
}
