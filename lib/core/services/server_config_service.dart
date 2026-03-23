import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage server configuration at runtime.
/// Stores API and WebSocket URLs in SharedPreferences so
/// the APK can connect to any backend without rebuilding.
///
/// Guarantees:
/// - On APK update (version change): saved config is auto-cleared.
/// - On build-default change (different --dart-define): saved config is auto-cleared.
/// - On startup: health check validates the active URL; resets if unreachable.
class ServerConfigService {
  static const String _keyApiUrl = 'server_api_url';
  static const String _keyWsUrl = 'server_ws_url';
  static const String _keyConfigured = 'server_configured';
  static const String _keyBuildDefault = 'server_build_default';
  static const String _keyAppVersion = 'server_app_version';

  static String? _apiUrl;
  static String? _wsUrl;
  static bool _isConfigured = false;
  static bool _isHealthy = false;
  static const Duration _healthTimeout = Duration(seconds: 6);
  static const int _healthRetries = 2;

  /// The compile-time app version (bumped on every meaningful build).
  static const String _appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue:
        '2.4.3', // Bumped - revert to no trailing slash, use origin-only baseUrl
  );

  /// The compile-time default API URL for this build.
  /// Production: DigitalOcean droplet
  static String get buildDefault => const String.fromEnvironment(
        'API_URL',
        defaultValue: 'https://api.raahionrescue.com',
      );

  /// Must be called once at app startup (before ApiClient is used).
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    bool shouldClear = false;

    // 1. Version change → clear (APK was updated)
    final previousVersion = prefs.getString(_keyAppVersion);
    if (previousVersion != null && previousVersion != _appVersion) {
      debugPrint(
          '🔄 App version changed ($previousVersion → $_appVersion), clearing server config');
      shouldClear = true;
    }

    // 2. Build default changed → clear (different --dart-define IP)
    final previousBuildDefault = prefs.getString(_keyBuildDefault);
    if (previousBuildDefault != null && previousBuildDefault != buildDefault) {
      debugPrint(
          '🔄 Build default changed ($previousBuildDefault → $buildDefault), clearing server config');
      shouldClear = true;
    }

    if (shouldClear) {
      await prefs.remove(_keyApiUrl);
      await prefs.remove(_keyWsUrl);
      await prefs.remove(_keyConfigured);
    }

    // Persist current version + build default
    await prefs.setString(_keyAppVersion, _appVersion);
    await prefs.setString(_keyBuildDefault, buildDefault);

    _apiUrl = prefs.getString(_keyApiUrl);
    _wsUrl = prefs.getString(_keyWsUrl);
    _isConfigured = prefs.getBool(_keyConfigured) ?? false;

    // Migrate: clear stale WS URLs that used wrong port 4004
    if (_wsUrl != null && _wsUrl!.contains(':4004')) {
      _wsUrl = null;
      await prefs.remove(_keyWsUrl);
    }

    // Migrate: clear WS URLs that use ws:// scheme (socket_io_client needs HTTP)
    if (_wsUrl != null &&
        (_wsUrl!.startsWith('ws://') || _wsUrl!.startsWith('wss://'))) {
      debugPrint('🔄 Clearing stale ws:// URL, socket_io_client requires HTTP');
      _wsUrl = null;
      await prefs.remove(_keyWsUrl);
    }

    // Migrate: clear WS URLs that use port 5007 directly (should use /realtime path instead)
    if (_wsUrl != null && _wsUrl!.contains(':5007')) {
      debugPrint(
          '🔄 Clearing stale :5007 URL, should use /realtime path via nginx');
      _wsUrl = null;
      await prefs.remove(_keyWsUrl);
    }

    // 3. Validate connectivity — if saved URL is unreachable, fall back to build default
    await _validateAndFallback(prefs);
  }

  /// Ping /health on the active URL. If it fails and there's a saved URL,
  /// clear it so the build default is used instead.
  static Future<void> _validateAndFallback(SharedPreferences prefs) async {
    final activeUrl = apiUrl;
    _isHealthy = await _checkHealth(activeUrl);

    if (!_isHealthy && _apiUrl != null && _apiUrl!.isNotEmpty) {
      // Saved URL is unreachable — try the build default instead
      debugPrint(
          '⚠️ Saved URL ($activeUrl) unreachable, trying build default ($buildDefault)');
      final defaultHealthy = await _checkHealth(buildDefault);
      if (defaultHealthy) {
        debugPrint('✅ Build default reachable, clearing stale saved config');
        await prefs.remove(_keyApiUrl);
        await prefs.remove(_keyWsUrl);
        await prefs.remove(_keyConfigured);
        _apiUrl = null;
        _wsUrl = null;
        _isConfigured = false;
        _isHealthy = true;
      }
    }

    debugPrint('🔌 Server config: url=$apiUrl, healthy=$_isHealthy');
  }

  /// Quick HTTP health check (3-second timeout).
  /// Tries /health first, then /rides/available as fallback.
  static Future<bool> _checkHealth(String baseUrl) async {
    Future<bool> tryGet(
      String url, {
      required bool Function(int statusCode) acceptStatus,
    }) async {
      for (var attempt = 1; attempt <= _healthRetries; attempt++) {
        HttpClient? client;
        try {
          client = HttpClient()..connectionTimeout = _healthTimeout;
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close().timeout(_healthTimeout);
          if (acceptStatus(response.statusCode)) {
            return true;
          }
        } catch (e) {
          debugPrint(
              '   health attempt $attempt/$_healthRetries failed for $url: $e');
          if (attempt < _healthRetries) {
            await Future.delayed(const Duration(milliseconds: 350));
          }
        } finally {
          client?.close(force: true);
        }
      }
      return false;
    }

    // Remove any trailing slash for consistent URL building
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;

    // Attempt 1: /health at the server root
    try {
      final healthUrl = '$cleanBase/health';
      if (await tryGet(
        healthUrl,
        acceptStatus: (code) => code >= 200 && code < 400,
      )) {
        return true;
      }
    } catch (e) {
      debugPrint('   /health check failed for $baseUrl: $e');
    }

    // Attempt 2: try an actual API endpoint (use /api/auth/me)
    try {
      if (await tryGet(
        '$cleanBase/api/auth/me',
        // 401/403 means backend is reachable but auth required.
        acceptStatus: (code) =>
            (code >= 200 && code < 400) || code == 401 || code == 403,
      )) {
        return true;
      }
    } catch (e) {
      debugPrint('   API fallback check failed for $baseUrl: $e');
    }

    return false;
  }

  /// Whether the backend is reachable (set during init).
  static bool get isHealthy => _isHealthy;

  /// Whether the user has configured the server URL at least once.
  static bool get isConfigured => _isConfigured;

  /// The current API base URL. Falls back to compile-time default.
  static String get apiUrl {
    if (_apiUrl != null && _apiUrl!.isNotEmpty) return _apiUrl!;
    return buildDefault;
  }

  /// The current WebSocket URL. Always derived from API URL for consistency.
  static String get wsUrl {
    if (_wsUrl != null && _wsUrl!.isNotEmpty) return _wsUrl!;
    return deriveWsUrl(apiUrl);
  }

  /// Save server configuration and mark as configured.
  static Future<void> save({
    required String apiUrl,
    required String wsUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiUrl, apiUrl);
    await prefs.setString(_keyWsUrl, wsUrl);
    await prefs.setBool(_keyConfigured, true);
    _apiUrl = apiUrl;
    _wsUrl = wsUrl;
    _isConfigured = true;
    _isHealthy = true;
  }

  /// Clear saved configuration (revert to defaults).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyApiUrl);
    await prefs.remove(_keyWsUrl);
    await prefs.remove(_keyConfigured);
    _apiUrl = null;
    _wsUrl = null;
    _isConfigured = false;
  }

  /// Re-run health check (callable from UI retry buttons).
  static Future<bool> revalidate() async {
    _isHealthy = await _checkHealth(apiUrl);
    return _isHealthy;
  }

  /// HTTP URL for the realtime service (same as wsUrl since Socket.io uses HTTP).
  static String get realtimeHttpUrl {
    // wsUrl is now HTTP/HTTPS (not ws/wss) for socket_io_client
    return wsUrl;
  }

  /// Check if the realtime service is reachable from this device.
  /// Uses nginx-proxied /realtime endpoint (port 80) for better mobile compatibility.
  static Future<bool> checkRealtimeReachable(
      {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      final url = Uri.parse('$realtimeHttpUrl/health');
      debugPrint('🔌 Realtime health check: $url');
      final client = HttpClient()..connectionTimeout = timeout;
      final request = await client.getUrl(url);
      final response = await request.close().timeout(timeout);
      client.close(force: true);
      final ok = response.statusCode == 200;
      debugPrint(
          '🔌 Realtime health: ${response.statusCode} -> ${ok ? "OK" : "FAIL"}');
      return ok;
    } catch (e) {
      debugPrint('🔌 Realtime health check failed: $e');
      return false;
    }
  }

  /// Derive the Socket.io URL from an API URL automatically.
  ///
  /// IMPORTANT: socket_io_client package expects HTTP/HTTPS URLs, NOT ws/wss.
  /// The package handles transport (polling → websocket upgrade) internally.
  ///
  /// Production DigitalOcean setup:
  /// - API Gateway on port 3000 (proxied through nginx on port 80 at /api)
  /// - Realtime/Socket.io service on port 5007 (proxied through nginx on port 80 at /realtime)
  ///
  /// Mobile networks often block non-standard ports, so we use nginx proxy.
  static String deriveWsUrl(String apiUrl) {
    try {
      final uri = Uri.parse(apiUrl);
      // Socket.io client uses HTTP/HTTPS, not ws/wss
      final scheme = uri.scheme == 'https' ? 'https' : 'http';

      // If URL has explicit port that's not 80/443, use it as-is
      // (likely a development/local setup)
      if (uri.hasPort && uri.port != 80 && uri.port != 443) {
        // For gateway port 3000, use realtime port 5007 in dev
        if (uri.port == 3000) {
          return '$scheme://${uri.host}:5007';
        }
        return '$scheme://${uri.host}:${uri.port}';
      }

      // Production: Use nginx-proxied realtime endpoint on port 80
      // This works better with mobile networks that block non-standard ports
      return '$scheme://${uri.host}/realtime';
    } catch (_) {
      return 'https://api.raahionrescue.com/realtime';
    }
  }
}
