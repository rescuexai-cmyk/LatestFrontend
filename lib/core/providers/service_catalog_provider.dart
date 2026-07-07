import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/service_catalog.dart';
import '../services/api_client.dart';
import '../../features/ride/providers/ride_booking_provider.dart';

/// Backend-driven service availability for the services hub / booking screens.
///
/// Resolution order (all failures are non-fatal — the UI falls back to its
/// hardcoded service list whenever this returns null or lacks an id):
///   1. Network fetch (pricing-service), cached to SharedPreferences on success
///   2. Cached response from a previous session (any age)
///   3. Bundled `assets/config/default_services.json`
///   4. null → caller uses its local defaults
class ServiceCatalogNotifier extends StateNotifier<AsyncValue<ServiceCatalog?>> {
  ServiceCatalogNotifier(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;

  static const _cacheKey = 'service_catalog_cache_v1';
  static const _cacheTsKey = 'service_catalog_cache_ts_v1';
  static const _ttl = Duration(hours: 6);
  static const _defaultAsset = 'assets/config/default_services.json';

  Future<void> load({bool forceRefresh = false}) async {
    // Serve a fresh-enough cache immediately to avoid blocking the hub.
    if (!forceRefresh) {
      final cached = await _readCache(respectTtl: true);
      if (cached != null) {
        state = AsyncValue.data(cached);
      }
    }

    try {
      final booking = _ref.read(rideBookingProvider);
      final pickup = booking.pickupLocation;

      final raw = await _ref.read(apiClientProvider).getAvailableServices(
            lat: pickup?.latitude,
            lng: pickup?.longitude,
          );
      final catalog = ServiceCatalog.fromJson(raw);
      await _writeCache(raw);
      state = AsyncValue.data(catalog);
      return;
    } catch (e) {
      debugPrint('serviceCatalog: network fetch failed: $e');
    }

    // Network failed — fall back to stale cache, then bundled default.
    if (state.value == null) {
      final stale = await _readCache(respectTtl: false);
      if (stale != null) {
        state = AsyncValue.data(stale);
        return;
      }
      final bundled = await _readBundledDefault();
      state = AsyncValue.data(bundled);
    }
  }

  Future<ServiceCatalog?> _readCache({required bool respectTtl}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_cacheKey);
      if (json == null) return null;

      if (respectTtl) {
        final ts = prefs.getInt(_cacheTsKey) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - ts;
        if (age > _ttl.inMilliseconds) return null;
      }

      final map = jsonDecode(json);
      if (map is Map<String, dynamic>) return ServiceCatalog.fromJson(map);
    } catch (e) {
      debugPrint('serviceCatalog: cache read failed: $e');
    }
    return null;
  }

  Future<void> _writeCache(Map<String, dynamic> raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(raw));
      await prefs.setInt(
          _cacheTsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('serviceCatalog: cache write failed: $e');
    }
  }

  Future<ServiceCatalog?> _readBundledDefault() async {
    try {
      final json = await rootBundle.loadString(_defaultAsset);
      final map = jsonDecode(json);
      if (map is Map<String, dynamic>) return ServiceCatalog.fromJson(map);
    } catch (e) {
      debugPrint('serviceCatalog: bundled default read failed: $e');
    }
    return null;
  }
}

final serviceCatalogProvider = StateNotifierProvider<ServiceCatalogNotifier,
    AsyncValue<ServiceCatalog?>>((ref) {
  return ServiceCatalogNotifier(ref);
});

/// Convenience: the resolved catalog or null while loading / on total failure.
final serviceCatalogValueProvider = Provider<ServiceCatalog?>((ref) {
  return ref.watch(serviceCatalogProvider).value;
});
