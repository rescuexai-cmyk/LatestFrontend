import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:intl/intl.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/server_config_service.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../providers/driver_onboarding_provider.dart';
import '../../providers/driver_rides_provider.dart';

class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> with WidgetsBindingObserver {
  // SharedPreferences keys for driver session persistence
  static const String _prefIsOnline = 'driver_is_online';
  static const String _prefSessionStart = 'driver_session_start';
  static const String _prefFeePaidAt = 'driver_fee_paid_at';

  bool _isOnline = false;
  bool _isConnecting = false; // CRITICAL: Block UI while connecting
  String? _acceptingRideId; // CRITICAL: Track which ride is being accepted to disable button
  bool _canStartRides = true; // Backend-driven; fetched on load
  String? _verificationBannerMsg; // Non-null when driver is not yet verified
  double _todayEarnings = 0.0;
  int _todayTrips = 0;
  double _weekEarnings = 0.0;
  int _weekTrips = 0;
  String _onlineHours = '0h 0m';
  double _rating = 0.0;
  List<Map<String, dynamic>> _rideHistory = [];
  bool _isLoadingEarnings = false;
  bool _isLoadingHistory = false;
  final String _todayDate = DateFormat('dd.MM.yyyy').format(DateTime.now());
  
  // Google Maps
  final Completer<GoogleMapController> _mapController = Completer();
  LatLng _currentLocation = const LatLng(28.4595, 77.0266); // Default Gurgaon
  Set<Marker> _markers = {};

  // Auto-reconnect timer (exponential backoff when connection drops)
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  // Session expiry check timer
  Timer? _sessionExpiryTimer;

  // Real-time countdown for ride offer cards (15s timer ticks every second)
  Timer? _countdownTimer;

  // Location stream for real-time updates
  StreamSubscription<Position>? _positionStream;

  // WebSocket subscription
  VoidCallback? _rideOffersSubscription;
  
  // Connection status stream subscription
  StreamSubscription<bool>? _connectionStatusSubscription;
  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _getCurrentLocation();
    _setupWebSocketSubscription();
    _fetchEarnings();
    _fetchRideHistory();
    _fetchVerificationStatus();
    _restoreSessionState();
    _syncDriverLanguageToApp();
  }

  /// Sync driver's saved language (from onboarding) to app locale so whole app shows selected language
  void _syncDriverLanguageToApp() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final onboarding = ref.read(driverOnboardingProvider);
      final driverLang = onboarding.selectedLanguage;
      if (driverLang == null || driverLang.isEmpty) return;
      final settings = ref.read(settingsProvider);
      if (settings.languageCode == driverLang) return;
      try {
        final lang = supportedLanguages.firstWhere((l) => l.code == driverLang);
        if (mounted) {
          await ref.read(settingsProvider.notifier).setLanguage(lang.code, lang.name);
        }
      } catch (_) {
        // Language not in supported list, ignore
      }
    });
  }

  /// Fetch backend verification status on screen load.
  /// If the driver cannot start rides, disable Go Online and show banner.
  Future<void> _fetchVerificationStatus() async {
    try {
      final status = await ref.read(driverOnboardingProvider.notifier).fetchOnboardingStatus();
      if (!mounted) return;
      setState(() {
        _canStartRides = status.canStartRides;
        if (!status.canStartRides) {
          switch (status.onboardingStatus) {
            case OnboardingStatus.documentVerification:
            case OnboardingStatus.documentsUploaded:
              _verificationBannerMsg = 'Your documents are under review. This usually takes 24-48 hours.';
              break;
            case OnboardingStatus.rejected:
              _verificationBannerMsg = status.message ?? 'Your documents were rejected. Please re-upload.';
              break;
            case OnboardingStatus.notStarted:
            case OnboardingStatus.started:
              _verificationBannerMsg = 'Please complete driver onboarding before going online.';
              break;
            case OnboardingStatus.completed:
              _verificationBannerMsg = status.message ?? 'Your account is not eligible to accept rides right now.';
              break;
          }
        } else {
          _verificationBannerMsg = null;
        }
      });
    } catch (e) {
      debugPrint('Failed to fetch verification status: $e');
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lastLifecycleState = state;
    debugPrint('📱 App lifecycle state changed: $state');
    
    if (state == AppLifecycleState.resumed) {
      // Re-check verification on every resume
      _fetchVerificationStatus();
      if (_isOnline) {
        _ensureSocketConnection();
      }
    } else if (state == AppLifecycleState.paused && _isOnline) {
      debugPrint('📱 App paused - socket will auto-reconnect when resumed');
    }
  }
  
  /// Ensure real-time connection is active for the driver.
  /// Called on app resume when driver is online.
  Future<void> _ensureSocketConnection() async {
    final driverId = _driverId;
    if (driverId == 'unknown' || driverId.isEmpty) {
      debugPrint('⚠️ Cannot ensure connection - invalid driver ID');
      return;
    }
    
    debugPrint('🔄 Ensuring real-time connection for driver: $driverId');
    
    if (realtimeService.isConnected && realtimeService.isDriverOnline) {
      debugPrint('✅ Already connected');
      // Update H3 cell in case driver moved
      realtimeService.updateDriverH3(driverId, _currentLocation.latitude, _currentLocation.longitude);
      return;
    }
    
    debugPrint('🔌 Reconnecting real-time services...');
    final secureStorage = ref.read(secureStorageProvider);
    final token = await secureStorage.read(key: 'auth_token');
    
    final connected = await realtimeService.connectDriver(
      driverId,
      lat: _currentLocation.latitude,
      lng: _currentLocation.longitude,
      token: token,
      onEvent: _handleDriverEvent,
    );
    
    if (connected) {
      debugPrint('✅ Reconnected successfully');
    } else {
      debugPrint('❌ Reconnection failed');
    }
  }
  
  /// Get the current driver's ID from auth state
  String get _driverId {
    final user = ref.read(currentUserProvider);
    return user?.id ?? 'unknown';
  }

  // ---------------------------------------------------------------------------
  // Session persistence helpers
  // ---------------------------------------------------------------------------

  /// Restore persisted online state on screen (re-)creation.
  /// Re-checks backend verification before reconnecting.
  Future<void> _restoreSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    final wasOnline = prefs.getBool(_prefIsOnline) ?? false;

    if (wasOnline) {
      debugPrint('🔄 Restoring driver online session from SharedPreferences');

      final driverId = _driverId;
      if (driverId == 'unknown' || driverId.isEmpty) {
        debugPrint('❌ Cannot restore session - invalid driver ID');
        await _clearSessionData();
        return;
      }

      // Re-fetch verification status from backend before reconnecting
      try {
        final status = await ref.read(driverOnboardingProvider.notifier).fetchOnboardingStatus();
        if (!status.canStartRides) {
          debugPrint('❌ Session restore blocked — driver cannot start rides');
          await _clearSessionData();
          if (mounted) {
            setState(() {
              _canStartRides = false;
              _verificationBannerMsg = 'Your verification status changed. You cannot go online right now.';
            });
          }
          return;
        }
      } catch (e) {
        debugPrint('⚠️ Could not check verification during restore: $e');
      }
      
      setState(() => _isConnecting = true);

      final secureStorage = ref.read(secureStorageProvider);
      final token = await secureStorage.read(key: 'auth_token');
      
      debugPrint('🔄 Restoring driver connection for: $driverId');
      final registered = await realtimeService.connectDriver(
        driverId,
        lat: _currentLocation.latitude,
        lng: _currentLocation.longitude,
        token: token,
        onEvent: _handleDriverEvent,
      );
      
      if (!registered) {
        debugPrint('❌ Failed to restore session - could not register');
        final backendReason = realtimeService.takeLastRegistrationError();
        debugPrint('❌ Backend reason: $backendReason');
        setState(() => _isConnecting = false);
        await _clearSessionData();
        if (mounted) {
          _showConnectionErrorDialog(registrationMessage: backendReason);
        }
        return;
      }
      
      // CRITICAL: Update backend status FIRST before setting UI online
      try {
        await apiClient.updateDriverStatus(true, lat: _currentLocation.latitude, lng: _currentLocation.longitude);
        debugPrint('✅ Backend status restored successfully');
      } catch (e) {
        debugPrint('❌ Failed to restore driver status on backend: $e');
        // If backend fails, disconnect and clear session
        realtimeService.disconnectDriver();
        await _clearSessionData();
        setState(() => _isConnecting = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not restore online session. Please try going online again.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      setState(() {
        _isOnline = true;
        _isConnecting = false;
      });

      _startCountdownTimer();

      // Initial fetch when going online
      _fetchRideOffers();

      _startSessionExpiryChecker();
    }
  }

  Future<void> _persistOnlineState(bool online) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefIsOnline, online);
  }

  Future<void> _persistSessionStart() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefSessionStart, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _persistFeePaidAt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefFeePaidAt, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _clearSessionData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefIsOnline);
    await prefs.remove(_prefSessionStart);
    // NOTE: We keep _prefFeePaidAt so the 24-hour window persists across sessions
  }

  /// Returns true if the platform fee has been paid within the last 24 hours.
  Future<bool> _isFeePaidWithin24h() async {
    final prefs = await SharedPreferences.getInstance();
    final feePaidMs = prefs.getInt(_prefFeePaidAt);
    if (feePaidMs == null) return false;
    final feePaidAt = DateTime.fromMillisecondsSinceEpoch(feePaidMs);
    return DateTime.now().difference(feePaidAt).inHours < 24;
  }

  /// Returns true if the current session started less than 24 hours ago.
  Future<bool> _isSessionWithin24h() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionStartMs = prefs.getInt(_prefSessionStart);
    if (sessionStartMs == null) return false;
    final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
    return DateTime.now().difference(sessionStart).inHours < 24;
  }

  // ---------------------------------------------------------------------------
  // Platform fee dialog (₹39)
  // ---------------------------------------------------------------------------

  /// Show the platform fee popup. Returns true if the user confirmed payment.
  Future<bool> _showPlatformFeeDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.account_balance_wallet, color: Color(0xFF1A1A1A)),
            SizedBox(width: 8),
            Text('Platform Fee',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: const [
                  Text('₹39',
                      style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A))),
                  SizedBox(height: 8),
                  Text(
                    'Pay a one-time platform fee to go online for 24 hours.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF999999))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Pay & Go Online',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Penalty warning dialog (₹10)
  // ---------------------------------------------------------------------------

  /// Show the penalty warning popup. Returns true if the user confirms stopping.
  Future<bool> _showPenaltyWarningDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionStartMs = prefs.getInt(_prefSessionStart);
    String remainingText = '';
    if (sessionStartMs != null) {
      final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
      final elapsed = DateTime.now().difference(sessionStart);
      final remaining = const Duration(hours: 24) - elapsed;
      if (remaining.isNegative) {
        remainingText = '0h 0m';
      } else {
        remainingText = '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
      }
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFE53935)),
            SizedBox(width: 8),
            Text('Penalty Warning',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFFE53935))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3F3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text('₹10 Penalty',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFE53935))),
                  const SizedBox(height: 8),
                  Text(
                    'Stopping before your 24-hour session ends will incur a ₹10 penalty.\n\nTime remaining: $remainingText',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continue Riding',
                style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Stop Anyway',
                style: TextStyle(color: Color(0xFFE53935))),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Connection error dialog with retry option
  // ---------------------------------------------------------------------------

  /// Parse backend error into user-friendly title, body, CTA.
  _BackendError _classifyBackendError(String? message) {
    final lower = message?.toLowerCase() ?? '';
    if (lower.contains('status code of 401') ||
        lower.contains('unauthorized') ||
        lower.contains('invalid signature') ||
        lower.contains('jwt')) {
      return _BackendError(
        title: 'Session Expired',
        body: 'Your session has expired. Please log out and log in again.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: false,
      );
    }
    if (lower.contains('not verified') || lower.contains('verification') || lower.contains('driver_not_verified')) {
      return _BackendError(
        title: 'Verification Pending',
        body: 'Your documents are still under review. This usually takes 24-48 hours.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: true,
      );
    }
    if (lower.contains('penalty') || lower.contains('penalty_unpaid')) {
      return _BackendError(
        title: 'Unpaid Penalty',
        body: 'You have an outstanding penalty. Please clear it before going online.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: false,
      );
    }
    if (lower.contains('suspended') || lower.contains('account_suspended') || lower.contains('deactivated')) {
      return _BackendError(
        title: 'Account Suspended',
        body: 'Your account has been suspended. Please contact support for assistance.',
        cta: 'Contact Support',
        allowRetry: false,
        affectsEligibility: true,
      );
    }
    if (lower.contains('status code of 403') || lower.contains('forbidden')) {
      return _BackendError(
        title: 'Cannot Go Online',
        body: 'Your account is currently not eligible to go online. Please check onboarding/penalty status or contact support.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: false,
      );
    }
    return _BackendError(
      title: 'Registration Failed',
      body: 'Could not register with server. Please retry in a moment.',
      cta: 'Retry',
      allowRetry: true,
      affectsEligibility: false,
    );
  }

  Future<void> _showConnectionErrorDialog({String? registrationMessage}) async {
    final hasBackendReason = registrationMessage != null && registrationMessage.isNotEmpty;
    final classified = hasBackendReason ? _classifyBackendError(registrationMessage) : null;

    // Only eligibility-related failures should disable start rides.
    if (classified != null && classified.affectsEligibility) {
      setState(() {
        _canStartRides = false;
        _verificationBannerMsg = classified.body;
      });
      await _clearSessionData();
    }

    final shouldRetry = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              hasBackendReason ? Icons.warning_amber_rounded : Icons.wifi_off,
              color: const Color(0xFFE53935),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                classified?.title ?? 'Connection Failed',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (classified != null) ...[
              Text(
                classified.body,
                style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              ),
            ] else ...[
              const Text(
                'Could not connect to the server. This may be due to:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              _buildErrorReason(Icons.signal_wifi_off, 'Poor internet connection'),
              _buildErrorReason(Icons.cloud_off, 'Server may be temporarily down'),
              _buildErrorReason(Icons.security, 'Firewall or mobile data blocking port'),
              const SizedBox(height: 16),
              const Text(
                'Try switching to a different Wi-Fi, or retry later.',
                style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              classified != null && !classified.allowRetry ? classified.cta : 'Cancel',
              style: const TextStyle(color: Color(0xFF999999)),
            ),
          ),
          if (classified == null || classified.allowRetry) ...[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                context.push(AppRoutes.serverConfig);
              },
              child: const Text('Edit Server',
                  style: TextStyle(color: Color(0xFF4285F4))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Retry',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ],
      ),
    );

    if (shouldRetry == true && mounted) {
      _toggleOnlineStatus();
    }
  }

  Future<void> _showStartRideBlockedDialog(_BackendError classified) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFE53935)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                classified.title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          classified.body,
          style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(classified.cta),
          ),
        ],
      ),
    );
  }

  /// Shown when the device cannot reach the realtime service (port 5007) at all.
  Future<void> _showRealtimeUnreachableDialog() async {
    final shouldRetry = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.public_off, color: Color(0xFFE53935)),
            SizedBox(width: 8),
            Expanded(
              child: Text('Server Unreachable',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This device cannot reach the ride server. Often this happens when:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            _buildErrorReason(Icons.signal_cellular_alt, 'Mobile data may block the required port'),
            _buildErrorReason(Icons.wifi, 'Try a different Wi‑Fi network'),
            _buildErrorReason(Icons.vpn_lock, 'Corporate or public Wi‑Fi may block it'),
            const SizedBox(height: 12),
            const Text(
              'Switch network and tap Retry, or try again later.',
              style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(false);
              context.push(AppRoutes.serverConfig);
            },
            child: const Text('Edit Server',
                style: TextStyle(color: Color(0xFF4285F4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retry',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (shouldRetry == true && mounted) {
      _toggleOnlineStatus();
    }
  }

  Widget _buildErrorReason(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF888888)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Session expiry checker (24-hour re-prompt)
  // ---------------------------------------------------------------------------

  void _startSessionExpiryChecker() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      if (!_isOnline) return;
      final feeStillValid = await _isFeePaidWithin24h();
      if (!feeStillValid && mounted) {
        _sessionExpiryTimer?.cancel();
        _handleSessionExpiry();
      }
    });
  }

  Future<void> _handleSessionExpiry() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.timer_off, color: Color(0xFFFF9800)),
            SizedBox(width: 8),
            Text('Session Expired',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: const [
                  Text('₹39',
                      style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A))),
                  SizedBox(height: 8),
                  Text(
                    'Your 24-hour session has expired.\nPay ₹39 to continue riding.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Go Offline',
                style: TextStyle(color: Color(0xFF999999))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Pay & Continue',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _persistFeePaidAt();
      await _persistSessionStart();
      _startSessionExpiryChecker();
    } else {
      // Go offline without penalty (session already expired)
      await _goOffline();
    }
  }

  /// Internal helper to go offline (no penalty check).
  Future<void> _goOffline() async {
    // CRITICAL: Capture driver ID before clearing state
    final driverId = _driverId;
    
    setState(() => _isOnline = false);
    await _clearSessionData();

    try {
      await apiClient.updateDriverStatus(false);
    } catch (e) {
      debugPrint('Failed to update driver status: $e');
    }

    // Disconnect all real-time transports (SSE + Socket.io)
    debugPrint('🚗 Driver going offline: $driverId');
    realtimeService.disconnectDriver();
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You are now offline'),
          backgroundColor: Colors.grey,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _fetchEarnings() async {
    if (!mounted) return;
    setState(() => _isLoadingEarnings = true);
    try {
      final data = await apiClient.getDriverEarnings();
      if (!mounted) return;
      
      if (data['success'] == true) {
        final earnings = data['data'] as Map<String, dynamic>? ?? {};
        setState(() {
          _todayEarnings = (earnings['today']['amount'] ?? 0).toDouble();
          _todayTrips = earnings['today']['trips'] ?? 0;
          _weekEarnings = (earnings['week']['amount'] ?? 0).toDouble();
          _weekTrips = earnings['week']['trips'] ?? 0;
          _onlineHours = earnings['week']['online_hours'] ?? '0h 0m';
          _rating = (earnings['rating'] ?? 0.0).toDouble();
        });
        debugPrint('📊 Earnings fetched: Today ₹$_todayEarnings, Week ₹$_weekEarnings');
      }
    } catch (e) {
      debugPrint('❌ Error fetching earnings: $e');
    } finally {
      if (mounted) setState(() => _isLoadingEarnings = false);
    }
  }
  
  /// Fetch ride history. If [modalSetState] is provided (from a StatefulBuilder
  /// inside a modal), both parent and modal state are refreshed so the bottom
  /// sheet actually re-renders.
  Future<void> _fetchRideHistory({StateSetter? modalSetState}) async {
    final driverId = _driverId;
    debugPrint('📜 Fetching ride history for driverId: $driverId');

    if (driverId == 'unknown' || driverId.isEmpty) {
      debugPrint('⚠️ Driver ID is unknown/empty — skipping ride history fetch');
      return;
    }

    void update(VoidCallback fn) {
      if (mounted) setState(fn);
      modalSetState?.call(fn);
    }

    update(() => _isLoadingHistory = true);
    try {
      final data = await apiClient.getDriverTrips();
      debugPrint('Ride history response: success=${data['success']}');

      if (data['success'] == true) {
        final innerData = data['data'] as Map<String, dynamic>? ?? {};
        final rides = List<Map<String, dynamic>>.from(innerData['trips'] ?? []);
        update(() => _rideHistory = rides);
        debugPrint('📜 Ride history loaded: ${_rideHistory.length} rides');
      }
    } catch (e) {
      debugPrint('❌ Error fetching ride history: $e');
    } finally {
      update(() => _isLoadingHistory = false);
    }
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _sessionExpiryTimer?.cancel();
    _countdownTimer?.cancel();
    _positionStream?.cancel();
    _rideOffersSubscription?.call();
    _connectionStatusSubscription?.cancel();
    super.dispose();
  }

  /// Start 1s timer so ride offer countdown updates in real time (not just on refresh).
  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isOnline) setState(() {});
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      
      if (permission == LocationPermission.whileInUse || 
          permission == LocationPermission.always) {
        // Get initial position
        final position = await Geolocator.getCurrentPosition();
        _updatePosition(position);
        
        // Start continuous location stream for real-time updates
        _positionStream = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5, // Update every 5 meters of movement
          ),
        ).listen((Position position) {
          _updatePosition(position);
        });
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _updatePosition(Position position) async {
    if (!mounted) return;
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
      _updateMarkers();
    });
    
    try {
      final controller = await _mapController.future;
      if (mounted) controller.animateCamera(CameraUpdate.newLatLng(_currentLocation));
    } catch (_) {}
  }

  void _updateMarkers() {
    _markers = {
      Marker(
        markerId: const MarkerId('currentLocation'),
        position: _currentLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: const InfoWindow(title: 'Your Location'),
      ),
    };
  }

  void _setupWebSocketSubscription() {
    _connectionStatusSubscription?.cancel();
    _connectionStatusSubscription = realtimeService.connectionStatus.listen((connected) {
      if (!mounted || !_isOnline) return;
      final authState = ref.read(authStateProvider);
      if (authState.isLoggingOut || authState.user == null) return;
      debugPrint('🔌 Real-time connection status: $connected');
      if (!connected) {
        if (_lastLifecycleState != AppLifecycleState.resumed) return;
        _scheduleReconnect();
      } else {
        _reconnectAttempts = 0;
      }
    });
  }

  /// Schedule reconnect with exponential backoff when connection drops.
  void _scheduleReconnect() {
    if (!_isOnline || !mounted) return;
    final authState = ref.read(authStateProvider);
    if (authState.isLoggingOut || authState.user == null) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay = Duration(seconds: (1 << _reconnectAttempts.clamp(0, 5)).clamp(2, 30));
    debugPrint('🔄 Scheduling reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, () async {
      if (!mounted || !_isOnline) return;
      await _ensureSocketConnection();
    });
  }

  /// Unified handler for driver events from SSE or Socket.io.
  /// 
  /// REAL-TIME FIRST: Uses event data directly instead of REST polling.
  /// This is the industry-standard approach for scalability.
  void _handleDriverEvent(String type, Map<String, dynamic> data) {
    debugPrint('📡 Driver event received: $type');

    if (type == 'new_ride_offer') {
      final rideData = data['ride'] as Map<String, dynamic>?;
      if (rideData == null) {
        debugPrint('⚠️ new_ride_offer event missing ride data');
        return;
      }
      
      debugPrint('🚗 New ride offer received via real-time: ${rideData['rideId'] ?? rideData['id']}');

      // Haptic feedback for new ride
      Vibration.hasVibrator().then((hasVibrator) {
        if (hasVibrator == true) {
          Vibration.vibrate(duration: 500);
        }
      });

      if (mounted) {
        // REAL-TIME: Parse and add ride directly from event data
        // No REST call needed - this is O(1) instead of O(n) network overhead
        try {
          final offer = RideOffer.fromJson(rideData);
          final driverRidesNotifier = ref.read(driverRidesProvider.notifier);
          driverRidesNotifier.addRideOffer(offer);
          debugPrint('✅ Ride offer added from real-time event: ${offer.id}');
        } catch (e) {
          debugPrint('⚠️ Failed to parse ride from event, falling back to REST: $e');
          // Fallback to REST only if parsing fails
          ref.read(driverRidesProvider.notifier).fetchAvailableRides(
            lat: _currentLocation.latitude,
            lng: _currentLocation.longitude,
          );
        }
      }
    } else if (type == 'ride_taken') {
      final rideId = data['rideId'] as String?;
      debugPrint('🚫 Ride taken by another driver: $rideId');
      if (mounted && rideId != null) {
        ref.read(driverRidesProvider.notifier).removeRide(rideId);
        // Show subtle feedback
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride was taken by another driver'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } else if (type == 'ride_cancelled') {
      final rideId = data['rideId'] as String? ?? data['ride_id'] as String?;
      debugPrint('❌ Ride cancelled: $rideId');
      if (mounted && rideId != null) {
        final notifier = ref.read(driverRidesProvider.notifier);
        notifier.removeRide(rideId);
        // If the cancelled ride was our accepted ride (e.g. rider cancelled before OTP), clear it
        final acceptedRide = ref.read(driverRidesProvider).acceptedRide;
        if (acceptedRide != null && acceptedRide.id == rideId) {
          notifier.clearAcceptedRide();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['reason'] as String? ?? 'Ride was cancelled by rider'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } else if (type == 'ride_completed') {
      final rideId = data['rideId'] as String? ?? data['ride_id'] as String?;
      debugPrint('✅ Ride completed: $rideId');
      if (mounted && rideId != null) {
        final acceptedRide = ref.read(driverRidesProvider).acceptedRide;
        if (acceptedRide != null && acceptedRide.id == rideId) {
          ref.read(driverRidesProvider.notifier).clearAcceptedRide();
        }
      }
    } else if (type == 'connected') {
      debugPrint('✅ Real-time connection established');
      // On reconnect, do a single REST fetch to sync state
      if (mounted) {
        ref.read(driverRidesProvider.notifier).fetchAvailableRides(
          lat: _currentLocation.latitude,
          lng: _currentLocation.longitude,
        );
      }
    }
  }

  void _toggleOnlineStatus() async {
    // CRITICAL: Prevent double-tap while connecting
    if (_isConnecting) {
      debugPrint('⚠️ Already connecting, ignoring tap');
      return;
    }

    // Block going online if backend says driver can't start rides
    if (!_isOnline && !_canStartRides) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_verificationBannerMsg ?? 'You are not verified to go online yet.'),
            backgroundColor: const Color(0xFFD4956A),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    
    if (!_isOnline) {
      // ---- GOING ONLINE ----

      // 1. Check if platform fee was paid in the last 24 hours
      final feePaid = await _isFeePaidWithin24h();
      if (!feePaid) {
        final confirmed = await _showPlatformFeeDialog();
        if (!confirmed) return; // User cancelled – stay offline
        await _persistFeePaidAt();
      }

      // CRITICAL: Get driver ID FIRST before any async operations
      final driverId = _driverId;
      if (driverId == 'unknown' || driverId.isEmpty) {
        debugPrint('❌ Cannot go online - invalid driver ID');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Error: Could not identify driver. Please log out and log in again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      
      // CRITICAL: Block UI while connecting
      setState(() => _isConnecting = true);
      
      // 1.5 Pre-check: can we reach the realtime service (port 5007)?
      // We try the health check but don't block if it fails - let the actual connection attempt decide
      final canReachRealtime = await ServerConfigService.checkRealtimeReachable(timeout: const Duration(seconds: 10));
      if (!canReachRealtime) {
        debugPrint('⚠️ Health check failed but proceeding with connection attempt...');
        // Don't return - let the actual connection try and fail with a better error
      }
      
      // 2. Connect via SSE + Socket.io and register driver
      final secureStorage = ref.read(secureStorageProvider);
      final token = await secureStorage.read(key: 'auth_token');
      
      debugPrint('🚗 Driver going online: $driverId - connecting SSE + Socket.io...');
      final registered = await realtimeService.connectDriver(
        driverId,
        lat: _currentLocation.latitude,
        lng: _currentLocation.longitude,
        token: token,
        onEvent: _handleDriverEvent,
      );
      
      if (!registered) {
        final backendReason = realtimeService.takeLastRegistrationError();
        debugPrint('❌ Registration rejected by backend. Reason: $backendReason');
        setState(() => _isConnecting = false);
        if (mounted) {
          _showConnectionErrorDialog(registrationMessage: backendReason);
        }
        return;
      }
      
      debugPrint('✅ Driver $driverId connected successfully - updating backend status...');

      // 3. Auto-register as driver if not already registered
      try {
        await apiClient.startDriverOnboarding();
        debugPrint('Driver registered/onboarding started: $_driverId');
      } catch (e) {
        debugPrint('Driver registration (may already exist): $e');
      }

      // 4. CRITICAL: Update driver status on backend FIRST - this must succeed
      try {
        final statusResponse = await apiClient.updateDriverStatus(true, lat: _currentLocation.latitude, lng: _currentLocation.longitude);
        debugPrint('✅ Backend status updated: $statusResponse');
      } catch (e) {
        debugPrint('❌ Failed to update driver status on backend: $e');
        // CRITICAL: If backend fails, disconnect and show error
        realtimeService.disconnectDriver();
        setState(() => _isConnecting = false);
        if (mounted) {
          final classified = _classifyBackendError(e.toString());
          if (classified.affectsEligibility) {
            setState(() {
              _canStartRides = false;
              _verificationBannerMsg = classified.body;
            });
          }
          await _showStartRideBlockedDialog(classified);
        }
        return;
      }

      // 5. Only set online AFTER backend confirms
      setState(() {
        _isOnline = true;
        _isConnecting = false;
      });
      _startCountdownTimer();
      await _persistOnlineState(true);
      await _persistSessionStart();

      // 5. Initial fetch of ride offers
      _fetchRideOffers();

      // 6. Start the 24-hour session expiry checker
      _startSessionExpiryChecker();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You are now online!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      // ---- GOING OFFLINE ----

      // Check if session is within 24 hours → show penalty warning
      final within24h = await _isSessionWithin24h();
      if (within24h) {
        final confirmStop = await _showPenaltyWarningDialog();
        if (!confirmStop) return; // User chose to continue riding
      }

      await _goOffline();
    }
  }
  
  void _fetchRideOffers() {
    ref.read(driverRidesProvider.notifier).fetchAvailableRides(
      lat: _currentLocation.latitude,
      lng: _currentLocation.longitude,
    );
  }

  Future<void> _acceptRide(RideOffer offer) async {
    // CRITICAL: Prevent double-tap
    if (_acceptingRideId != null) {
      debugPrint('⚠️ Already accepting ride $_acceptingRideId, ignoring tap');
      return;
    }
    
    setState(() => _acceptingRideId = offer.id);
    debugPrint('🚗 Accepting ride: ${offer.id}');
    
    try {
      final success = await ref.read(driverRidesProvider.notifier).acceptRide(offer.id, driverId: _driverId);
      
      if (success && mounted) {
        // Navigate to active ride screen
        debugPrint('✅ Ride accepted successfully, navigating to active ride');
        context.push(AppRoutes.driverActiveRide);
      } else if (mounted) {
        // Get specific error from provider state
        final error = ref.read(driverRidesProvider).error;
        String errorMessage = 'Failed to accept ride';
        
        if (error != null) {
          if (error.contains('already been accepted')) {
            errorMessage = 'This ride was taken by another driver';
          } else if (error.contains('not authorized') || error.contains('FORBIDDEN')) {
            errorMessage = 'You are not authorized to accept rides. Please contact support.';
          } else {
            errorMessage = error;
          }
        }
        
        debugPrint('❌ Failed to accept ride: $errorMessage');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _acceptingRideId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Map
                  _buildMap(),
                  
                  // Start Ride / Stop Riding button - always centered at bottom
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 24,
                    child: Center(
                      child: Material(
                        color: Colors.transparent,
                        child: _buildRideToggleButton(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Verification banner
            if (_verificationBannerMsg != null && !_isOnline)
              _buildVerificationBanner(),
            _buildBottomSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFFFFF3E0),
      child: Row(
        children: [
          const Icon(Icons.hourglass_top_rounded, color: Color(0xFFE65100), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _verificationBannerMsg!,
              style: const TextStyle(fontSize: 13, color: Color(0xFFE65100), fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Menu button
          Builder(
            builder: (context) => GestureDetector(
              onTap: () => Scaffold.of(context).openDrawer(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.menu, color: Color(0xFF1A1A1A)),
              ),
            ),
          ),
          
          const Spacer(),
          
          // Earnings badge
          GestureDetector(
            onTap: _showEarnings,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '₹ ${_todayEarnings.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: _currentLocation,
            zoom: 15,
          ),
          markers: _markers,
          onMapCreated: (controller) {
            _mapController.complete(controller);
            _updateMarkers();
          },
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
        ),
        
        // Date overlay
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'Today - $_todayDate',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRideToggleButton() {
    // CRITICAL: Show connecting state to block double-taps
    if (_isConnecting) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF666666),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            SizedBox(width: 12),
            Text(
              'Connecting...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    
    // Different sizes for online (compact) vs offline (larger)
    final horizontalPadding = _isOnline ? 16.0 : 32.0;
    final verticalPadding = _isOnline ? 12.0 : 16.0;
    final fontSize = _isOnline ? 14.0 : 18.0;
    final iconSize = _isOnline ? 18.0 : 24.0;
    
    final bool disabledOffline = !_isOnline && !_canStartRides;

    return GestureDetector(
      onTap: _toggleOnlineStatus,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        decoration: BoxDecoration(
          color: disabledOffline
              ? Colors.grey[400]
              : _isOnline
                  ? const Color(0xFFE53935)
                  : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isOnline ? 'Stop Riding' : 'Start Ride',
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _isOnline ? Icons.stop_circle_outlined : Icons.power_settings_new,
              color: Colors.white,
              size: iconSize,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomSection() {
    final hasActiveRide = ref.watch(driverRidesProvider).acceptedRide != null;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status bar
          _buildStatusBar(),
          // Return to active ride card when driver went back during ongoing ride
          if (hasActiveRide) _buildActiveRideReturnCard(),
          // Ride offers (hidden when has active ride - they should return to ride)
          if (!hasActiveRide) _buildRideOffersSection(),
        ],
      ),
    );
  }

  /// Prominent card to return to active ride when driver pressed back
  Widget _buildActiveRideReturnCard() {
    final acceptedRide = ref.watch(driverRidesProvider).acceptedRide;
    if (acceptedRide == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => context.push(AppRoutes.driverActiveRide),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFD4956A).withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD4956A), width: 2),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: const Color(0xFFD4956A), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.directions_car, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Ongoing Ride',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${acceptedRide.pickupAddress} → ${acceptedRide.dropAddress}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFFD4956A)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isOnline ? "You're Online" : "You're Offline",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
            if (_isOnline) ...[
              const SizedBox(width: 8),
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRideOffersSection() {
    final driverRidesState = ref.watch(driverRidesProvider);
    final rideOffers = driverRidesState.rideOffers;
    final isLoading = driverRidesState.isLoading;

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        // Detect right swipe (positive velocity)
        if (details.primaryVelocity != null && details.primaryVelocity! > 500) {
          if (_isOnline && !isLoading) {
            debugPrint('🚗 Swipe right detected - loading more ride offers');
            // Add haptic feedback
            Vibration.vibrate(duration: 50);
            _fetchRideOffers();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Loading more ride offers...'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isOnline ? 'Ride Offers' : 'Ride Offers, Start Ride Now!',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF888888),
                      ),
                    ),
                    if (_isOnline && rideOffers.isNotEmpty)
                      Text(
                        'Swipe right to load more',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF4285F4).withOpacity(0.7),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
              if (_isOnline)
                GestureDetector(
                  onTap: () {
                    _fetchRideOffers();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Refreshing ride offers...')),
                    );
                  },
                  child: Row(
                    children: [
                      const Text(
                        'Refresh',
                        style: TextStyle(
                          color: Color(0xFF4285F4),
                          fontSize: 12,
                        ),
                      ),
                      if (isLoading) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4285F4)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
          
          const SizedBox(height: 8),
          
          // Ride offer cards - horizontal scroll
          // Use smaller height when offline to give more space for the map/Start button
          SizedBox(
            height: _isOnline ? 250 : 100,
            child: rideOffers.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isOnline ? Icons.hourglass_empty : Icons.power_settings_new,
                          size: _isOnline ? 48 : 32,
                          color: const Color(0xFFCCCCCC),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isOnline 
                              ? 'No ride requests available\nWaiting for new bookings...'
                              : 'Tap Start Ride above to go online',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: rideOffers.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: EdgeInsets.only(
                          right: index < rideOffers.length - 1 ? 10 : 0,
                        ),
                        child: _buildRideOfferCard(rideOffers[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildRideOfferCard(RideOffer offer) {
    final isGolden = offer.isGolden;
    final secondsLeft = 15 - DateTime.now().difference(offer.createdAt).inSeconds;
    final isExpiring = secondsLeft <= 5;
    
    // Don't show expired offers
    if (secondsLeft <= 0) return const SizedBox.shrink();
    
    return Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGolden ? const Color(0xFFD4956A) : const Color(0xFFE8E8E8),
          width: isGolden ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Type badge + countdown timer
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                offer.type,
                style: TextStyle(
                  fontSize: 11,
                  color: isGolden ? const Color(0xFFD4956A) : const Color(0xFF666666),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isExpiring ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${secondsLeft}s',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isExpiring ? Colors.red : Colors.green[700],
                  ),
                ),
              ),
            ],
          ),
          
          // Earning label and amount
          const Text(
            'Earning',
            style: TextStyle(
              fontSize: 10,
              color: Color(0xFF888888),
            ),
          ),
          Text(
            '₹${offer.earning.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isGolden ? const Color(0xFFD4956A) : const Color(0xFF4CAF50),
            ),
          ),
          
          const SizedBox(height: 6),
          
          // Pickup distance row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Pickup\nDistance',
                style: TextStyle(fontSize: 9, color: Color(0xFF888888), height: 1.2),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    offer.pickupDistance,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    offer.pickupTime,
                    style: const TextStyle(fontSize: 8, color: Color(0xFF888888)),
                  ),
                ],
              ),
            ],
          ),
          
          const SizedBox(height: 4),
          
          // Drop distance row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Drop\nDistance',
                style: TextStyle(fontSize: 9, color: Color(0xFF888888), height: 1.2),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    offer.dropDistance,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4CAF50),
                    ),
                  ),
                  Text(
                    offer.dropTime,
                    style: const TextStyle(fontSize: 8, color: Color(0xFF888888)),
                  ),
                ],
              ),
            ],
          ),
          
          const Divider(height: 12),
          
          // Pickup/Drop addresses
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pickup',
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
                    ),
                    Text(
                      offer.pickupAddress,
                      style: const TextStyle(fontSize: 8, color: Color(0xFF666666)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward, size: 10, color: Colors.grey[400]),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Drop',
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A)),
                    ),
                    Text(
                      offer.dropAddress,
                      style: const TextStyle(fontSize: 8, color: Color(0xFF666666)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 8),
          
          // Accept button - CRITICAL: Disable while accepting
          SizedBox(
            width: double.infinity,
            height: 32,
            child: ElevatedButton(
              // CRITICAL: Disable if not online OR if this ride is being accepted
              onPressed: (_isOnline && _acceptingRideId == null) ? () => _acceptRide(offer) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: isGolden ? const Color(0xFFD4956A) : const Color(0xFFD4956A),
                disabledBackgroundColor: _acceptingRideId == offer.id 
                    ? const Color(0xFF888888) // Gray when accepting this ride
                    : const Color(0xFFFFE4D6),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _acceptingRideId == offer.id
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Accepting...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isGolden ? 'Golden Ride' : 'Accept Ride',
                    style: TextStyle(
                      color: _isOnline ? Colors.white : const Color(0xFFD4956A).withOpacity(0.5),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.check_circle_outline,
                    size: 12,
                    color: _isOnline ? Colors.white : const Color(0xFFD4956A).withOpacity(0.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  // Check if any ride is currently being accepted (for disabling other accept buttons)
  bool get _isAcceptingAnyRide => _acceptingRideId != null;

  Widget _buildAccountSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFF0F0F0)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.person_outline, size: 18, color: Color(0xFF888888)),
          const SizedBox(width: 8),
          const Text(
            'Account',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF888888),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => _showAccountNotice(),
            child: const Icon(Icons.close, size: 18, color: Color(0xFF888888)),
          ),
        ],
      ),
    );
  }

  void _showAccountNotice() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person_outline, color: Color(0xFF888888)),
                const SizedBox(width: 8),
                const Text(
                  'Account',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Certain ratings are now excluded',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'For reasons outside of your control, such as traffic.',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF888888),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Builder(
              builder: (context) {
                final user = ref.watch(currentUserProvider);
                final displayName = user?.name ?? 'Driver';
                final displayPhone = user?.phone ?? '';
                final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : 'D';
                
                return Container(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: const Color(0xFFD4956A),
                        backgroundImage: user?.avatarUrl != null ? NetworkImage(user!.avatarUrl!) : null,
                        child: user?.avatarUrl == null ? Text(
                          initial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ) : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        displayPhone,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            
            const Divider(),
            
            // Menu items - using translations
            _buildDrawerItem(Icons.home, ref.tr('home'), () {
              Navigator.pop(context);
            }),
            _buildDrawerItem(Icons.history, ref.tr('ride_history'), () {
              Navigator.pop(context);
              _showRideHistory();
            }),
            _buildDrawerItem(Icons.account_balance_wallet, ref.tr('earnings'), () {
              Navigator.pop(context);
              _showEarnings();
            }),
            _buildDrawerItem(Icons.description_outlined, 'Update Documents', () {
              Navigator.pop(context);
              context.push(AppRoutes.driverOnboarding);
            }),
            _buildDrawerItem(Icons.settings, ref.tr('settings'), () {
              Navigator.pop(context);
              _showSettings();
            }),
            _buildDrawerItem(Icons.help_outline, ref.tr('help_support'), () {
              Navigator.pop(context);
              _showHelpSupport();
            }),
            
            // Logout option
            _buildDrawerItem(Icons.logout, ref.tr('logout'), () {
              Navigator.pop(context);
              _showLogoutConfirmation();
            }, isDestructive: true),
            
            const Spacer(),
            
            // App version
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Raahi Driver v1.0.0',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF888888),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showRideHistory() {
    bool hasFetched = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          // Trigger fetch once when the modal opens, passing setModalState
          // so the modal rebuilds when data arrives.
          if (!hasFetched) {
            hasFetched = true;
            Future.microtask(() => _fetchRideHistory(modalSetState: setModalState));
          }
          return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(
                      ref.tr('ride_history'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (_isLoadingHistory)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _rideHistory.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history, size: 64, color: Colors.grey[300]),
                            const SizedBox(height: 16),
                            Text(
                              _isLoadingHistory ? 'Loading...' : 'No ride history yet',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Complete rides to see your history',
                              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _rideHistory.length,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemBuilder: (context, index) {
                          return _buildHistoryCardFromData(_rideHistory[index]);
                        },
                      ),
              ),
            ],
          ),
        );
        },
      ),
    );
  }
  
  Widget _buildHistoryCardFromData(Map<String, dynamic> ride) {
    // Parse ride data from backend - backend returns 'drop_address' not 'destination_address'
    final pickupAddress = ride['pickup_address'] ?? 'Unknown pickup';
    final destAddress = ride['drop_address'] ?? ride['destination_address'] ?? 'Unknown destination';
    final fare = (ride['fare'] ?? 0).toDouble();
    final distance = (ride['distance'] ?? 0).toDouble();
    final createdAt = ride['created_at'] ?? ride['completed_at'];
    
    // Format date
    String dateStr = 'Unknown date';
    if (createdAt != null) {
      try {
        final parsed = DateTime.parse(createdAt.toString());
        final date = (parsed.isUtc ? parsed : parsed.toUtc())
            .add(const Duration(hours: 5, minutes: 30));
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final yesterday = today.subtract(const Duration(days: 1));
        final rideDate = DateTime(date.year, date.month, date.day);
        
        if (rideDate == today) {
          dateStr = 'Today, ${DateFormat('h:mm a').format(date)}';
        } else if (rideDate == yesterday) {
          dateStr = 'Yesterday, ${DateFormat('h:mm a').format(date)}';
        } else {
          dateStr = DateFormat('dd MMM, h:mm a').format(date);
        }
      } catch (_) {}
    }
    
    // Format distance
    String distanceStr = '${(distance / 1000).toStringAsFixed(1)} km';
    if (distance < 1000) {
      distanceStr = '${distance.toInt()} m';
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
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
                dateStr,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '₹${fare.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: Color(0xFF4CAF50),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFD4956A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pickupAddress,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.only(left: 3),
            width: 2,
            height: 20,
            color: const Color(0xFFE0E0E0),
          ),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  destAddress,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                distanceStr,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  void _showEarnings() {
    // All state is local to the modal for proper reactivity
    double availableBalance = 0;
    double pendingBalance = 0;
    double totalWithdrawn = 0;
    double minimumWithdrawal = 100;
    bool isLoading = true;
    bool isRefreshing = false;
    Map<String, dynamic>? primaryAccount;
    List<Map<String, dynamic>> payoutAccounts = [];
    
    // Local copies of earnings data for the modal
    double modalTodayEarnings = _todayEarnings;
    int modalTodayTrips = _todayTrips;
    double modalWeekEarnings = _weekEarnings;
    int modalWeekTrips = _weekTrips;
    String modalOnlineHours = _onlineHours;
    double modalRating = _rating;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          // Fetch all data for the modal
          Future<void> fetchAllData({bool refresh = false}) async {
            if (refresh) {
              setModalState(() => isRefreshing = true);
            }
            
            try {
              // Fetch earnings
              final earningsData = await apiClient.getDriverEarnings();
              if (earningsData['success'] == true) {
                final earnings = earningsData['data'] as Map<String, dynamic>? ?? {};
                modalTodayEarnings = (earnings['today']['amount'] ?? 0).toDouble();
                modalTodayTrips = earnings['today']['trips'] ?? 0;
                modalWeekEarnings = (earnings['week']['amount'] ?? 0).toDouble();
                modalWeekTrips = earnings['week']['trips'] ?? 0;
                modalOnlineHours = earnings['week']['online_hours'] ?? '0h 0m';
                modalRating = (earnings['rating'] ?? 0.0).toDouble();
                
                // Also update parent state
                if (mounted) {
                  setState(() {
                    _todayEarnings = modalTodayEarnings;
                    _todayTrips = modalTodayTrips;
                    _weekEarnings = modalWeekEarnings;
                    _weekTrips = modalWeekTrips;
                    _onlineHours = modalOnlineHours;
                    _rating = modalRating;
                  });
                }
              }
              
              // Fetch wallet
              final walletData = await apiClient.getDriverWallet();
              if (walletData['success'] == true) {
                final data = walletData['data'];
                availableBalance = (data['balance']?['available'] ?? 0).toDouble();
                pendingBalance = (data['balance']?['pending'] ?? 0).toDouble();
                totalWithdrawn = (data['stats']?['totalWithdrawn'] ?? 0).toDouble();
                minimumWithdrawal = (data['minimumWithdrawal'] ?? 100).toDouble();
                primaryAccount = data['primaryAccount'];
              }
              
              // Fetch payout accounts
              final accountsData = await apiClient.getPayoutAccounts();
              if (accountsData['success'] == true) {
                payoutAccounts = List<Map<String, dynamic>>.from(accountsData['data']?['accounts'] ?? []);
              }
            } catch (e) {
              debugPrint('Error fetching earnings data: $e');
            } finally {
              setModalState(() {
                isLoading = false;
                isRefreshing = false;
              });
            }
          }
          
          // Initial fetch
          if (isLoading && !isRefreshing) {
            fetchAllData();
          }
          
          return Container(
            height: MediaQuery.of(context).size.height * 0.85,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Row(
                  children: [
                    Text(
                      ref.tr('earnings'),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    if (isLoading || isRefreshing)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        onPressed: () => fetchAllData(refresh: true),
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh',
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Available Balance Card with Withdraw Button
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF2E7D32), Color(0xFF388E3C)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Available Balance',
                                    style: TextStyle(color: Colors.white70, fontSize: 14),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Text(
                                      'Withdrawable',
                                      style: TextStyle(color: Colors.white, fontSize: 10),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '₹${availableBalance.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: availableBalance >= minimumWithdrawal
                                      ? () {
                                          Navigator.pop(context);
                                          _showWithdrawSheet(availableBalance, minimumWithdrawal, payoutAccounts);
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: const Color(0xFF2E7D32),
                                    disabledBackgroundColor: Colors.white.withOpacity(0.5),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Text(
                                    availableBalance >= minimumWithdrawal
                                        ? 'Withdraw Now'
                                        : 'Min ₹${minimumWithdrawal.toInt()} required',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        // Today's Earnings Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFD4956A), Color(0xFFC47F4F)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ref.tr('today_earnings'),
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '₹${modalTodayEarnings.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 32,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '$modalTodayTrips ${ref.tr('trips_completed')}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        
                        // Weekly Summary
                        Text(
                          ref.tr('this_week'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: _buildEarningsStat(ref.tr('total_earnings'), '₹${modalWeekEarnings.toStringAsFixed(0)}')),
                            const SizedBox(width: 12),
                            Expanded(child: _buildEarningsStat(ref.tr('total_trips'), '$modalWeekTrips')),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: _buildEarningsStat(ref.tr('online_hours'), modalOnlineHours)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildEarningsStat(ref.tr('rating'), '${modalRating.toStringAsFixed(1)} ★')),
                          ],
                        ),
                        const SizedBox(height: 20),
                        
                        // Lifetime Stats
                        const Text(
                          'Lifetime',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: _buildEarningsStat('Total Withdrawn', '₹${totalWithdrawn.toStringAsFixed(0)}')),
                            const SizedBox(width: 12),
                            Expanded(child: _buildEarningsStat('Pending', '₹${pendingBalance.toStringAsFixed(0)}')),
                          ],
                        ),
                        const SizedBox(height: 20),
                        
                        // Payment Settings Section
                        const Text(
                          'Payment Settings',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        
                        // Primary Account Display
                        if (primaryAccount != null)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF4CAF50), width: 1),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF4CAF50).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    primaryAccount!['accountType'] == 'UPI'
                                        ? Icons.account_balance_wallet
                                        : Icons.account_balance,
                                    color: const Color(0xFF4CAF50),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        primaryAccount!['accountType'] == 'UPI'
                                            ? 'UPI: ${primaryAccount!['upiId']}'
                                            : '${primaryAccount!['bankName']} ${primaryAccount!['accountNumber']}',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                      Row(
                                        children: [
                                          const Icon(Icons.check_circle, size: 14, color: Color(0xFF4CAF50)),
                                          const SizedBox(width: 4),
                                          Text(
                                            primaryAccount!['isVerified'] == true ? 'Verified' : 'Primary Account',
                                            style: const TextStyle(fontSize: 12, color: Color(0xFF4CAF50)),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber, color: Color(0xFFFF9800)),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                    'Add a bank account or UPI to withdraw earnings',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        
                        // Manage Payment Methods Button
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              _showPaymentMethodsSheet();
                            },
                            icon: const Icon(Icons.settings),
                            label: const Text('Manage Payment Methods'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        
                        // Transaction History Button
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              _showTransactionHistory();
                            },
                            icon: const Icon(Icons.history),
                            label: const Text('View Transaction History'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  
  Widget _buildEarningsStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ],
      ),
    );
  }
  
  // Withdrawal Sheet
  void _showWithdrawSheet(double availableBalance, double minimumWithdrawal, List<Map<String, dynamic>> accounts) {
    final TextEditingController amountController = TextEditingController();
    String? selectedAccountId;
    bool isProcessing = false;
    String? errorMessage;
    
    // Find primary account
    final primaryAccount = accounts.firstWhere(
      (a) => a['isPrimary'] == true,
      orElse: () => accounts.isNotEmpty ? accounts.first : {},
    );
    selectedAccountId = primaryAccount['id'];
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Text(
                    'Withdraw Money',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              
              // Available Balance
              Text(
                'Available: ₹${availableBalance.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 16, color: Color(0xFF666666)),
              ),
              const SizedBox(height: 16),
              
              // Amount Input
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  hintText: '0',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  errorText: errorMessage,
                ),
                onChanged: (_) {
                  if (errorMessage != null) {
                    setModalState(() => errorMessage = null);
                  }
                },
              ),
              const SizedBox(height: 12),
              
              // Quick Amount Buttons
              Row(
                children: [
                  _buildQuickAmountButton('₹500', 500, amountController, setModalState, availableBalance),
                  const SizedBox(width: 8),
                  _buildQuickAmountButton('₹1000', 1000, amountController, setModalState, availableBalance),
                  const SizedBox(width: 8),
                  _buildQuickAmountButton('₹2000', 2000, amountController, setModalState, availableBalance),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        amountController.text = availableBalance.toStringAsFixed(0);
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('All'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              
              // Transfer To Section
              if (accounts.isNotEmpty) ...[
                const Text(
                  'Transfer To',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ...accounts.map((account) => RadioListTile<String>(
                  value: account['id'],
                  groupValue: selectedAccountId,
                  onChanged: (value) => setModalState(() => selectedAccountId = value),
                  title: Text(
                    account['accountType'] == 'UPI'
                        ? 'UPI: ${account['upiId']}'
                        : '${account['bankName']} ${account['accountNumber']}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    account['accountType'] == 'UPI' ? 'Instant' : '1-2 business days',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
              ] else
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber, color: Color(0xFFFF9800)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('Please add a payment method first'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              
              // Withdraw Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isProcessing || accounts.isEmpty
                      ? null
                      : () async {
                          final amount = double.tryParse(amountController.text) ?? 0;
                          
                          if (amount < minimumWithdrawal) {
                            setModalState(() => errorMessage = 'Minimum withdrawal is ₹${minimumWithdrawal.toInt()}');
                            return;
                          }
                          
                          if (amount > availableBalance) {
                            setModalState(() => errorMessage = 'Insufficient balance');
                            return;
                          }
                          
                          setModalState(() => isProcessing = true);
                          
                          try {
                            final result = await apiClient.requestWithdrawal(
                              amount: amount,
                              payoutAccountId: selectedAccountId,
                            );
                            
                            if (result['success'] == true && context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Withdrawal of ₹${amount.toStringAsFixed(0)} initiated!'),
                                  backgroundColor: const Color(0xFF4CAF50),
                                ),
                              );
                            } else {
                              setModalState(() {
                                errorMessage = result['message'] ?? 'Withdrawal failed';
                                isProcessing = false;
                              });
                            }
                          } catch (e) {
                            setModalState(() {
                              errorMessage = 'Error: ${e.toString()}';
                              isProcessing = false;
                            });
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Withdraw',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildQuickAmountButton(String label, double amount, TextEditingController controller, StateSetter setModalState, double maxAmount) {
    return Expanded(
      child: OutlinedButton(
        onPressed: amount <= maxAmount
            ? () => controller.text = amount.toStringAsFixed(0)
            : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(label),
      ),
    );
  }
  
  // Payment Methods Management Sheet
  void _showPaymentMethodsSheet() {
    List<Map<String, dynamic>> accounts = [];
    bool isLoading = true;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> fetchAccounts() async {
            try {
              final data = await apiClient.getPayoutAccounts();
              if (data['success'] == true) {
                setModalState(() {
                  accounts = List<Map<String, dynamic>>.from(data['data']?['accounts'] ?? []);
                  isLoading = false;
                });
              }
            } catch (e) {
              setModalState(() => isLoading = false);
            }
          }
          
          if (isLoading) {
            fetchAccounts();
          }
          
          return Container(
            height: MediaQuery.of(context).size.height * 0.7,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Row(
                  children: [
                    const Text(
                      'Payment Methods',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                
                if (isLoading)
                  const Center(child: CircularProgressIndicator())
                else ...[
                  // Existing Accounts
                  if (accounts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.account_balance_wallet_outlined, size: 48, color: Color(0xFF888888)),
                          SizedBox(height: 12),
                          Text(
                            'No payment methods added',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Add a bank account or UPI to withdraw your earnings',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Color(0xFF888888)),
                          ),
                        ],
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: accounts.length,
                        itemBuilder: (context, index) {
                          final account = accounts[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(12),
                              border: account['isPrimary'] == true
                                  ? Border.all(color: const Color(0xFF4CAF50))
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  account['accountType'] == 'UPI'
                                      ? Icons.account_balance_wallet
                                      : Icons.account_balance,
                                  color: const Color(0xFFD4956A),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        account['accountType'] == 'UPI'
                                            ? account['upiId'] ?? 'UPI'
                                            : '${account['bankName']} ${account['accountNumber']}',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                      if (account['isPrimary'] == true)
                                        const Text(
                                          'Primary',
                                          style: TextStyle(fontSize: 12, color: Color(0xFF4CAF50)),
                                        ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) async {
                                    if (value == 'primary') {
                                      try {
                                        await apiClient.setPrimaryPayoutAccount(account['id']);
                                        setModalState(() => isLoading = true);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Error: $e')),
                                          );
                                        }
                                      }
                                    } else if (value == 'delete') {
                                      try {
                                        await apiClient.deletePayoutAccount(account['id']);
                                        setModalState(() => isLoading = true);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Error: $e')),
                                          );
                                        }
                                      }
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (account['isPrimary'] != true)
                                      const PopupMenuItem(
                                        value: 'primary',
                                        child: Text('Set as Primary'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete', style: TextStyle(color: Colors.red)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  
                  const SizedBox(height: 16),
                  
                  // Add Account Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _showAddUpiSheet();
                          },
                          icon: const Icon(Icons.account_balance_wallet),
                          label: const Text('Add UPI'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _showAddBankSheet();
                          },
                          icon: const Icon(Icons.account_balance),
                          label: const Text('Add Bank'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
  
  // Add UPI Sheet
  void _showAddUpiSheet() {
    final TextEditingController upiController = TextEditingController();
    bool isAdding = false;
    String? errorMessage;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              const Text(
                'Add UPI ID',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              
              TextField(
                controller: upiController,
                decoration: InputDecoration(
                  labelText: 'UPI ID',
                  hintText: 'yourname@upi',
                  prefixIcon: const Icon(Icons.account_balance_wallet),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  errorText: errorMessage,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Example: yourname@paytm, yourname@ybl, yourname@oksbi',
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
              const SizedBox(height: 20),
              
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isAdding
                      ? null
                      : () async {
                          final upiId = upiController.text.trim();
                          if (!upiId.contains('@')) {
                            setModalState(() => errorMessage = 'Invalid UPI ID format');
                            return;
                          }
                          
                          setModalState(() => isAdding = true);
                          
                          try {
                            final result = await apiClient.addPayoutAccount(
                              accountType: 'UPI',
                              upiId: upiId,
                            );
                            
                            if (result['success'] == true && context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('UPI ID added successfully!'),
                                  backgroundColor: Color(0xFF4CAF50),
                                ),
                              );
                            } else {
                              setModalState(() {
                                errorMessage = result['message'] ?? 'Failed to add UPI';
                                isAdding = false;
                              });
                            }
                          } catch (e) {
                            setModalState(() {
                              errorMessage = 'Error: ${e.toString()}';
                              isAdding = false;
                            });
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4956A),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: isAdding
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Add UPI ID',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  // Add Bank Account Sheet
  void _showAddBankSheet() {
    final bankNameController = TextEditingController();
    final accountNumberController = TextEditingController();
    final ifscController = TextEditingController();
    final holderNameController = TextEditingController();
    bool isAdding = false;
    String? errorMessage;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const Text(
                  'Add Bank Account',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                
                if (errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(errorMessage!, style: const TextStyle(color: Colors.red))),
                      ],
                    ),
                  ),
                
                TextField(
                  controller: holderNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Account Holder Name',
                    prefixIcon: const Icon(Icons.person),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: bankNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Bank Name',
                    hintText: 'e.g., HDFC Bank',
                    prefixIcon: const Icon(Icons.account_balance),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: accountNumberController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Account Number',
                    prefixIcon: const Icon(Icons.numbers),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: ifscController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'IFSC Code',
                    hintText: 'e.g., HDFC0001234',
                    prefixIcon: const Icon(Icons.code),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 24),
                
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: isAdding
                        ? null
                        : () async {
                            // Validate
                            if (holderNameController.text.trim().isEmpty ||
                                bankNameController.text.trim().isEmpty ||
                                accountNumberController.text.trim().isEmpty ||
                                ifscController.text.trim().isEmpty) {
                              setModalState(() => errorMessage = 'Please fill all fields');
                              return;
                            }
                            
                            final ifsc = ifscController.text.trim().toUpperCase();
                            if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(ifsc)) {
                              setModalState(() => errorMessage = 'Invalid IFSC code format');
                              return;
                            }
                            
                            setModalState(() {
                              isAdding = true;
                              errorMessage = null;
                            });
                            
                            try {
                              final result = await apiClient.addPayoutAccount(
                                accountType: 'BANK_ACCOUNT',
                                bankName: bankNameController.text.trim(),
                                accountNumber: accountNumberController.text.trim(),
                                ifscCode: ifsc,
                                accountHolderName: holderNameController.text.trim(),
                              );
                              
                              if (result['success'] == true && context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Bank account added successfully!'),
                                    backgroundColor: Color(0xFF4CAF50),
                                  ),
                                );
                              } else {
                                setModalState(() {
                                  errorMessage = result['message'] ?? 'Failed to add bank account';
                                  isAdding = false;
                                });
                              }
                            } catch (e) {
                              setModalState(() {
                                errorMessage = 'Error: ${e.toString()}';
                                isAdding = false;
                              });
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4956A),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isAdding
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Text(
                            'Add Bank Account',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  // Transaction History Sheet
  void _showTransactionHistory() {
    List<Map<String, dynamic>> transactions = [];
    bool isLoading = true;
    int currentPage = 1;
    bool hasMore = true;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> fetchTransactions({bool loadMore = false}) async {
            if (loadMore && !hasMore) return;
            
            try {
              final data = await apiClient.getWalletTransactions(
                page: loadMore ? currentPage + 1 : 1,
                limit: 20,
              );
              
              if (data['success'] == true) {
                final newTransactions = List<Map<String, dynamic>>.from(
                  data['data']?['transactions'] ?? [],
                );
                final pagination = data['data']?['pagination'];
                
                setModalState(() {
                  if (loadMore) {
                    transactions.addAll(newTransactions);
                    currentPage++;
                  } else {
                    transactions = newTransactions;
                    currentPage = 1;
                  }
                  hasMore = pagination != null && currentPage < (pagination['totalPages'] ?? 1);
                  isLoading = false;
                });
              }
            } catch (e) {
              setModalState(() => isLoading = false);
            }
          }
          
          if (isLoading) {
            fetchTransactions();
          }
          
          return Container(
            height: MediaQuery.of(context).size.height * 0.8,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Row(
                  children: [
                    const Text(
                      'Transaction History',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                
                if (isLoading)
                  const Expanded(child: Center(child: CircularProgressIndicator()))
                else if (transactions.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 64, color: Color(0xFF888888)),
                          SizedBox(height: 16),
                          Text('No transactions yet', style: TextStyle(fontSize: 16, color: Color(0xFF888888))),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: transactions.length + (hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == transactions.length) {
                          fetchTransactions(loadMore: true);
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        
                        final tx = transactions[index];
                        final amount = (tx['amount'] as num).toDouble();
                        final isCredit = amount > 0;
                        final type = tx['type'] as String? ?? 'UNKNOWN';
                        
                        IconData icon;
                        Color iconColor;
                        switch (type) {
                          case 'RIDE_EARNING':
                            icon = Icons.directions_car;
                            iconColor = const Color(0xFF4CAF50);
                            break;
                          case 'WITHDRAWAL':
                            icon = Icons.account_balance_wallet;
                            iconColor = const Color(0xFFFF9800);
                            break;
                          case 'PENALTY':
                            icon = Icons.warning;
                            iconColor = Colors.red;
                            break;
                          case 'REFUND':
                            icon = Icons.replay;
                            iconColor = const Color(0xFF2196F3);
                            break;
                          default:
                            icon = Icons.swap_horiz;
                            iconColor = const Color(0xFF888888);
                        }
                        
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: iconColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(icon, color: iconColor, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tx['description'] ?? type.replaceAll('_', ' '),
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      _formatDate(tx['createdAt']),
                                      style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '${isCredit ? '+' : ''}₹${amount.abs().toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: isCredit ? const Color(0xFF4CAF50) : Colors.red,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
  
  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diff = now.difference(date);
      
      if (diff.inDays == 0) {
        return 'Today, ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
      } else if (diff.inDays == 1) {
        return 'Yesterday';
      } else if (diff.inDays < 7) {
        return '${diff.inDays} days ago';
      } else {
        return '${date.day}/${date.month}/${date.year}';
      }
    } catch (e) {
      return dateStr;
    }
  }
  
  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Consumer(
        builder: (context, ref, child) {
          final settings = ref.watch(settingsProvider);
          final settingsNotifier = ref.read(settingsProvider.notifier);
          final isDark = Theme.of(context).brightness == Brightness.dark;
          
          return Container(
            height: MediaQuery.of(context).size.height * 0.7,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF444444) : const Color(0xFFE0E0E0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      settingsNotifier.tr('settings'),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Notifications toggle
                _buildSettingsToggle(
                  Icons.notifications_outlined,
                  settingsNotifier.tr('notifications'),
                  settingsNotifier.tr('notifications_desc'),
                  settings.notificationsEnabled,
                  (value) => settingsNotifier.setNotifications(value),
                  isDark,
                ),
                // Privacy - Location sharing toggle
                _buildSettingsToggle(
                  Icons.location_on_outlined,
                  settingsNotifier.tr('location_sharing'),
                  settingsNotifier.tr('location_sharing_desc'),
                  settings.locationSharing,
                  (value) => settingsNotifier.setLocationSharing(value),
                  isDark,
                ),
                // Language selector
                _buildSettingsTileWithAction(
                  Icons.language,
                  settingsNotifier.tr('language'),
                  settings.languageName,
                  () => _showLanguageSelector(),
                  isDark,
                ),
                // Appearance toggle
                _buildSettingsToggle(
                  Icons.dark_mode_outlined,
                  settingsNotifier.tr('dark_mode'),
                  settingsNotifier.tr('dark_mode_desc'),
                  settings.isDarkMode,
                  (value) {
                    settingsNotifier.setDarkMode(value);
                  },
                  isDark,
                ),
                _buildSettingsTileWithAction(
                  Icons.description_outlined,
                  'Update Documents',
                  'Upload/review license and other documents',
                  () {
                    Navigator.pop(context);
                    context.push(AppRoutes.driverOnboarding);
                  },
                  isDark,
                ),
                // About
                _buildSettingsTileWithAction(
                  Icons.info_outline,
                  settingsNotifier.tr('about'),
                  settingsNotifier.tr('about_desc'),
                  () => _showAboutDialog(),
                  isDark,
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      context.go(AppRoutes.login);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(settingsNotifier.tr('logout')),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  
  Widget _buildSettingsToggle(IconData icon, String title, String subtitle, bool value, Function(bool) onChanged, bool isDark) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF666666), size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF888888) : const Color(0xFF888888))),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFFD4956A),
      ),
    );
  }
  
  Widget _buildSettingsTileWithAction(IconData icon, String title, String subtitle, VoidCallback onTap, bool isDark) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF666666), size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF888888) : const Color(0xFF888888))),
      trailing: Icon(Icons.chevron_right, color: isDark ? const Color(0xFF666666) : const Color(0xFFCCCCCC)),
      onTap: onTap,
    );
  }
  
  void _showLanguageSelector() {
    showDialog(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, child) {
          final settings = ref.watch(settingsProvider);
          final settingsNotifier = ref.read(settingsProvider.notifier);
          
          return AlertDialog(
            title: Text(settingsNotifier.tr('language')),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: supportedLanguages.length,
                itemBuilder: (context, index) {
                  final lang = supportedLanguages[index];
                  final isSelected = settings.languageCode == lang.code;
                  return ListTile(
                    title: Text(lang.name),
                    subtitle: Text(lang.nativeName, style: const TextStyle(fontSize: 12)),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: Color(0xFFD4956A))
                        : null,
                    onTap: () async {
                      if (isSelected) {
                        Navigator.of(dialogContext).pop();
                        return;
                      }
                      
                      // Close dialog first to avoid rebuild issues
                      Navigator.of(dialogContext).pop();
                      
                      // Small delay to let dialog animation finish before triggering app rebuild
                      await Future.delayed(const Duration(milliseconds: 300));
                      
                      if (!context.mounted) return;
                      
                      await settingsNotifier.setLanguage(lang.code, lang.name);
                      ref.read(driverOnboardingProvider.notifier).setLanguage(lang.code).catchError((_) {});
                      
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${lang.nativeName} - Language changed'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
  
  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFD4956A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: Text('R', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
              ),
            ),
            const SizedBox(width: 12),
            const Text('Raahi Driver'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version 1.0.0'),
            SizedBox(height: 8),
            Text('A modern ride-hailing app for drivers.', style: TextStyle(color: Color(0xFF888888))),
            SizedBox(height: 16),
            Text('© 2026 Raahi Technologies', style: TextStyle(fontSize: 12, color: Color(0xFF888888))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Opening Terms & Conditions...')),
              );
            },
            child: const Text('Terms & Privacy'),
          ),
        ],
      ),
    );
  }
  
  void _showHelpSupport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            Row(
              children: [
                const Text(
                  'Help & Support',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildHelpTileWithAction(Icons.headset_mic, 'Contact Support', 'Get help from our team', _showContactSupport),
            _buildHelpTileWithAction(Icons.article_outlined, 'FAQs', 'Find answers to common questions', _showFAQs),
            _buildHelpTileWithAction(Icons.report_problem_outlined, 'Report an Issue', 'Let us know about problems', _showReportIssue),
            _buildHelpTileWithAction(Icons.feedback_outlined, 'Send Feedback', 'Help us improve the app', _showFeedback),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.phone, color: Color(0xFFD4956A)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('24/7 Helpline', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('1800-123-4567', style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Dialing 1800-123-4567...')),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4956A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Call Now', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildHelpTileWithAction(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3E0),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: const Color(0xFFD4956A), size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
      onTap: onTap,
    );
  }
  
  void _showContactSupport() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Contact Support'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat, color: Color(0xFFD4956A)),
              title: const Text('Live Chat'),
              subtitle: const Text('Chat with support agent'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Opening live chat...')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.email, color: Color(0xFFD4956A)),
              title: const Text('Email Support'),
              subtitle: const Text('support@raahi.com'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Opening email...')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.phone, color: Color(0xFFD4956A)),
              title: const Text('Call Support'),
              subtitle: const Text('1800-123-4567'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Dialing support...')),
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }
  
  void _showFAQs() {
    final faqs = [
      {'q': 'How do I start accepting rides?', 'a': 'Tap "Start Ride" to go online and accept ride requests.'},
      {'q': 'How are earnings calculated?', 'a': 'Earnings include base fare + distance + time charges.'},
      {'q': 'What if a rider cancels?', 'a': 'You may receive a cancellation fee depending on the circumstances.'},
      {'q': 'How do I update my documents?', 'a': 'Open menu > Update Documents, or go to Settings > Update Documents.'},
      {'q': 'When are payments credited?', 'a': 'Payments are credited to your account within 24-48 hours.'},
    ];
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Frequently Asked Questions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: faqs.length,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemBuilder: (context, index) {
                  return ExpansionTile(
                    title: Text(faqs[index]['q']!, style: const TextStyle(fontWeight: FontWeight.w500)),
                    children: [Padding(padding: const EdgeInsets.all(16), child: Text(faqs[index]['a']!))],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showReportIssue() {
    final TextEditingController issueController = TextEditingController();
    String selectedCategory = 'App Issue';
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Report an Issue'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Category', style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: ['App Issue', 'Payment Issue', 'Ride Issue', 'Account Issue', 'Other']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => selectedCategory = v!),
                ),
                const SizedBox(height: 16),
                const Text('Describe the issue', style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                TextField(
                  controller: issueController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Please describe your issue in detail...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Issue reported successfully! We\'ll get back to you soon.')),
                );
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4956A)),
              child: const Text('Submit', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showFeedback() {
    int rating = 0;
    final TextEditingController feedbackController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Send Feedback'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('How would you rate your experience?'),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    return IconButton(
                      icon: Icon(
                        index < rating ? Icons.star : Icons.star_border,
                        color: const Color(0xFFD4956A),
                        size: 36,
                      ),
                      onPressed: () => setDialogState(() => rating = index + 1),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: feedbackController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Tell us more about your experience...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Thank you for your feedback!')),
                );
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4956A)),
              child: const Text('Submit', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap, {bool isDestructive = false}) {
    return ListTile(
      leading: Icon(icon, color: isDestructive ? Colors.red : const Color(0xFF1A1A1A)),
      title: Text(
        title,
        style: TextStyle(
          color: isDestructive ? Colors.red : null,
          fontWeight: isDestructive ? FontWeight.w500 : null,
        ),
      ),
      onTap: onTap,
    );
  }
  
  void _showLogoutConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              // Sign out via auth provider (handles intentional realtime stop + session clear)
              await ref.read(authStateProvider.notifier).signOut();
              if (mounted) {
                context.go(AppRoutes.login);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Logout', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

/// Classified backend error for structured UI display.
class _BackendError {
  final String title;
  final String body;
  final String cta;
  final bool allowRetry;
  final bool affectsEligibility;

  const _BackendError({
    required this.title,
    required this.body,
    required this.cta,
    required this.allowRetry,
    required this.affectsEligibility,
  });
}
