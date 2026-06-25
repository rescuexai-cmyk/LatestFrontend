import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/server_config_service.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/services/realtime_service.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/widgets/upi_app_icon.dart';
import '../../../../core/models/pricing_v2.dart';
import '../../../../core/models/user.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../providers/driver_onboarding_provider.dart';
import '../../providers/personal_driver_onboarding_provider.dart';
import '../../providers/driver_rides_provider.dart';
import '../../providers/driver_subscription_provider.dart';
import '../../providers/driver_penalty_provider.dart';
import '../ride_stack/ride_stack_sheet.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import '../../../../core/widgets/figma_square_back_button.dart';

class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen>
    with WidgetsBindingObserver {
  // SharedPreferences keys for driver session persistence
  static const String _prefIsOnline = 'driver_is_online';
  static const String _prefSessionStart = 'driver_session_start';
  static const String _prefFeePaidAt = 'driver_fee_paid_at';

  bool _isOnline = false;
  bool _isConnecting = false; // CRITICAL: Block UI while connecting
  String?
      _acceptingRideId; // CRITICAL: Track which ride is being accepted to disable button
  bool _canStartRides = true; // Backend-driven; fetched on load
  bool _isPersonalRescueDriver = false;
  String? _verificationBannerMsg; // Non-null when driver is not yet verified
  double _todayEarnings = 0.0;
  int _todayTrips = 0;
  double _weekEarnings = 0.0;
  int _weekTrips = 0;
  String _onlineHours = '';
  double _rating = 0.0;
  List<Map<String, dynamic>> _rideHistory = [];
  bool _isLoadingEarnings = false;
  bool _isLoadingHistory = false;
  final String _todayDate = DateFormat('dd.MM.yyyy').format(DateTime.now());

  // Pricing v2: Driver quests and boosts
  List<DriverQuest> _activeQuests = [];
  DriverBoost? _activeBoost;
  bool _isLoadingQuests = false;

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
  Timer? _offerCleanupTimer;

  // Location stream for real-time updates
  StreamSubscription<Position>? _positionStream;

  // WebSocket subscription
  VoidCallback? _rideOffersSubscription;

  // Connection status stream subscription
  StreamSubscription<bool>? _connectionStatusSubscription;
  StreamSubscription<RemoteMessage>? _pushForegroundSubscription;
  String? _activeIncomingRideId;
  final Map<String, DateTime> _recentIncomingRides = {};
  // Set after early stop confirmation; next online attempt should resolve penalty first.
  bool _penaltyLikelyAfterEarlyStop = false;
  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;
  DateTime? _lastStatusSyncAt;
  String? _driverRecordId;

  // Map style for dark mode
  String? _mapStyle;
  bool _lastDarkMode = false;
  GoogleMapController? _mapControllerInstance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hydrateDriverRecordId();
    _getCurrentLocation();
    _setupWebSocketSubscription();
    _fetchEarnings();
    _fetchRideHistory();
    _restoreSessionState();
    _ensureDriverPrefsMatchAppLanguage();
    _loadMapStyle();
    _fetchDriverQuests();
    _setupPushRideListener();

    // Provider updates must run after the first frame (Riverpod rule).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(driverRidesProvider.notifier).resetForNewSession(
            preserveAcceptedRide: true,
          );
      unawaited(_initDriverProfile());
    });
  }

  Future<void> _initDriverProfile() async {
    await ref.read(personalDriverOnboardingProvider.notifier).ensureLoaded();
    if (!mounted) return;

    final isPersonal = ref.read(isPersonalRescueDriverModeProvider);
    setState(() => _isPersonalRescueDriver = isPersonal);

    ref.read(driverRidesProvider.notifier).setPersonalRescueDriverMode(isPersonal);
    _syncDriverOfferFilter();

    if (isPersonal) {
      await _fetchPersonalDriverVerificationStatus();
    } else {
      await _fetchVerificationStatus();
      await _fetchSubscriptionStatus();
    }
  }

  void _syncDriverOfferFilter() {
    if (_isPersonalRescueDriver) {
      ref.read(driverRidesProvider.notifier).setRegisteredDriverVehicleType(
            PersonalDriverOnboardingState.vehicleTypeId,
          );
      return;
    }
    ref.read(driverRidesProvider.notifier).setRegisteredDriverVehicleType(
          ref.read(driverOnboardingProvider).selectedVehicleType,
        );
  }

  Future<void> _fetchPersonalDriverVerificationStatus() async {
    final pd = ref.read(personalDriverOnboardingProvider);
    if (!mounted) return;
    setState(() {
      _canStartRides = pd.canStartRescueJobs;
      if (!pd.canStartRescueJobs) {
        _verificationBannerMsg =
            'Your personal driver documents are under review. This usually takes 24–48 hours.';
      } else {
        _verificationBannerMsg = null;
      }
    });
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
      if (_mapControllerInstance != null && _mapStyle != null) {
        _mapControllerInstance!.setMapStyle(_mapStyle);
      }
      debugPrint(
          '🗺️ Driver home map style loaded: ${isDarkMode ? "dark" : "light"}');
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }
  }

  /// Keep `driver_language` prefs + backend driver language aligned with **app locale**
  /// (`settings`). App settings reflect the UX language the user picks in Rider or Driver settings;
  /// we previously synced the other direction and blocked language changes after dialog pop.
  void _ensureDriverPrefsMatchAppLanguage() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final settings = ref.read(settingsProvider);
      final code = settings.languageCode;
      final onboarding = ref.read(driverOnboardingProvider);

      try {
        final lang = resolveAppLanguage(code);
        if (onboarding.selectedLanguage == lang.code) return;

        await ref.read(driverOnboardingProvider.notifier).setLanguage(lang.code);
      } catch (e, st) {
        debugPrint('❌ Failed to sync driver_language to app locale: $e\n$st');
      }
    });
  }

  /// Fetch backend verification status on screen load.
  /// If the driver cannot start rides, disable Go Online and show banner.
  Future<void> _fetchVerificationStatus() async {
    try {
      final status = await ref
          .read(driverOnboardingProvider.notifier)
          .fetchOnboardingStatus();
      if (!mounted) return;
      setState(() {
        _canStartRides = status.canStartRides;
        if (!status.canStartRides) {
          switch (status.onboardingStatus) {
            case OnboardingStatus.documentVerification:
            case OnboardingStatus.documentsUploaded:
              _verificationBannerMsg =
                  'Your documents are under review. This usually takes 24-48 hours.';
              break;
            case OnboardingStatus.rejected:
              _verificationBannerMsg = status.message ??
                  'Your documents were rejected. Please re-upload.';
              break;
            case OnboardingStatus.notStarted:
            case OnboardingStatus.started:
              _verificationBannerMsg =
                  'Please complete driver onboarding before going online.';
              break;
            case OnboardingStatus.completed:
              _verificationBannerMsg = status.message ??
                  'Your account is not eligible to accept rides right now.';
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

  /// Fetch subscription status from backend on screen load.
  Future<void> _fetchSubscriptionStatus() async {
    try {
      await ref.read(driverSubscriptionProvider.notifier).checkSubscriptionStatus();
      debugPrint('📅 Subscription status fetched');
    } catch (e) {
      debugPrint('Failed to fetch subscription status: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lastLifecycleState = state;
    debugPrint('📱 App lifecycle state changed: $state');

    if (state == AppLifecycleState.resumed) {
      if (_isPersonalRescueDriver) {
        _fetchPersonalDriverVerificationStatus();
      } else {
        _fetchVerificationStatus();
        _fetchSubscriptionStatus();
      }
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
    if (_driverId == 'unknown' || _driverId.isEmpty) {
      await _hydrateDriverRecordId();
    }
    final driverId = _driverId;
    if (driverId == 'unknown' || driverId.isEmpty) {
      debugPrint('⚠️ Cannot ensure connection - invalid driver ID');
      return;
    }

    debugPrint('🔄 Ensuring real-time connection for driver: $driverId');

    if (realtimeService.isConnected && realtimeService.isDriverOnline) {
      debugPrint('✅ Already connected');
      // Update H3 cell in case driver moved
      realtimeService.updateDriverH3(
          driverId, _currentLocation.latitude, _currentLocation.longitude);
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
    return _driverRecordId ?? 'unknown';
  }

  /// Resolve canonical driver id from backend profile.
  Future<void> _hydrateDriverRecordId() async {
    if (_driverRecordId != null && _driverRecordId!.isNotEmpty) return;
    try {
      final profile = await apiClient.getDriverProfile();
      final data = profile['data'];
      String? resolvedId;
      if (data is Map<String, dynamic>) {
        resolvedId =
            (data['driver_id'] ?? data['driverId'] ?? data['id'])?.toString();
      }

      if (resolvedId != null && resolvedId.isNotEmpty) {
        if (mounted) {
          setState(() => _driverRecordId = resolvedId);
        } else {
          _driverRecordId = resolvedId;
        }
        debugPrint('🪪 Resolved canonical driver id: $resolvedId');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to resolve canonical driver id: $e');
    }
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

      if (_driverId == 'unknown' || _driverId.isEmpty) {
        await _hydrateDriverRecordId();
      }
      final driverId = _driverId;
      if (driverId == 'unknown' || driverId.isEmpty) {
        debugPrint('❌ Cannot restore session - invalid driver ID');
        await _clearSessionData();
        return;
      }

      // Re-fetch verification status from backend before reconnecting
      try {
        final status = await ref
            .read(driverOnboardingProvider.notifier)
            .fetchOnboardingStatus();
        if (!status.canStartRides) {
          debugPrint('❌ Session restore blocked — driver cannot start rides');
          await _clearSessionData();
          if (mounted) {
            setState(() {
              _canStartRides = false;
              _verificationBannerMsg =
                  'Your verification status changed. You cannot go online right now.';
            });
          }
          return;
        }
      } catch (e) {
        debugPrint('⚠️ Could not check verification during restore: $e');
      }

      // Ensure no stale offers are shown after app relaunch/re-login.
      final ridesNotifier = ref.read(driverRidesProvider.notifier);
      ridesNotifier.resetForNewSession(preserveAcceptedRide: true);
      // Fresh connection attempt: drop any previous transport state first.
      realtimeService.disconnectDriver();

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
        await apiClient.updateDriverStatus(true,
            lat: _currentLocation.latitude, lng: _currentLocation.longitude);
        debugPrint('✅ Backend status restored successfully');
      } catch (e) {
        debugPrint('❌ Failed to restore driver status on backend: $e');
        // If backend fails, disconnect and clear session
        realtimeService.disconnectDriver();
        await _clearSessionData();
        setState(() => _isConnecting = false);
        if (mounted) {
          AppMessenger.showDriverErrorBanner(context, ref.tr('restore_session_failed'));
        }
        return;
      }

      setState(() {
        _isOnline = true;
        _isConnecting = false;
      });

      _startCountdownTimer();
      _startOfferCleanupTimer();

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
    await prefs.setInt(
        _prefSessionStart, DateTime.now().millisecondsSinceEpoch);
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
  // Subscription check before going online (backend-driven)
  // ---------------------------------------------------------------------------

  /// Check subscription status from backend and navigate to payment if needed.
  /// Returns true if driver can go online, false otherwise.
  Future<bool> _checkSubscriptionBeforeGoingOnline() async {
    try {
      // Check subscription status from backend
      final canGoOnline = await ref
          .read(driverSubscriptionProvider.notifier)
          .checkSubscriptionStatus();

      if (canGoOnline) {
        // Subscription is active, persist locally for session expiry checker
        await _persistFeePaidAt();
        return true;
      }

      // Subscription expired or never purchased - navigate to payment screen
      if (mounted) {
        final result = await context.push<bool>(AppRoutes.driverSubscriptionPayment);
        if (result == true) {
          // Payment successful, persist locally
          await _persistFeePaidAt();
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ Failed to check subscription status: $e');
      // Fallback to local check if backend is unavailable
      final localFeePaid = await _isFeePaidWithin24h();
      if (localFeePaid) return true;

      // Show payment screen as fallback
      if (mounted) {
        final result = await context.push<bool>(AppRoutes.driverSubscriptionPayment);
        if (result == true) {
          await _persistFeePaidAt();
          return true;
        }
      }
      return false;
    }
  }

  /// Pre-check penalty before going online so we can show payment options
  /// instead of the generic "Cannot Go Online" blocker.
  Future<bool> _resolvePenaltyBeforeGoingOnline() async {
    try {
      final notifier = ref.read(driverPenaltyProvider.notifier);
      final hasPending = await notifier.checkPenaltyStatus();
      final st = ref.read(driverPenaltyProvider);
      final shouldForcePenaltyFlow = _penaltyLikelyAfterEarlyStop;
      final hasActionablePenalty =
          hasPending || st.hasPendingPenalty || st.penaltyAmount > 0;
      if (hasActionablePenalty || shouldForcePenaltyFlow) {
        final resolved = await _showPendingPenaltyDialog(
          allowEstimatedAmountIfMissing: shouldForcePenaltyFlow,
        );
        if (resolved) {
          _penaltyLikelyAfterEarlyStop = false;
          return true;
        }
        return false;
      }
      _penaltyLikelyAfterEarlyStop = false;
    } catch (e) {
      debugPrint('⚠️ Penalty pre-check failed: $e');
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Platform fee dialog — amount from AppConfig.dailyPlatformFee - LEGACY, kept for session expiry
  // ---------------------------------------------------------------------------

  /// Show the platform fee popup. Returns true if the user confirmed payment.
  Future<bool> _showPlatformFeeDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.account_balance_wallet, color: Color(0xFF1A1A1A)),
            const SizedBox(width: 8),
            Text(ref.tr('platform_fee'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
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
                children: [
                  Text(
                      '₹${AppConfig.dailyPlatformFee.toInt()}',
                      style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 8),
                  const Text(
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
            child: Text(ref.tr('cancel'),
                style: const TextStyle(color: Color(0xFF999999))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ref.tr('pay_go_online'),
                style: const TextStyle(color: Colors.white)),
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
        remainingText =
            '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
      }
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFE53935)),
            const SizedBox(width: 8),
            Text(ref.tr('penalty_warning'),
                style: const TextStyle(
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
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF666666)),
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
            child: Text(ref.tr('continue_riding'),
                style: const TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ref.tr('stop_anyway'),
                style: const TextStyle(color: Color(0xFFE53935))),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Pending penalty dialog with payment options
  // ---------------------------------------------------------------------------

  /// Show pending penalty payment in a bottom sheet (wallet / UPI).
  /// Returns true only when penalty is successfully cleared.
  Future<bool> _showPendingPenaltyDialog(
      {bool allowEstimatedAmountIfMissing = false}) async {
    // Fetch penalty status first
    final penaltyNotifier = ref.read(driverPenaltyProvider.notifier);
    await penaltyNotifier.checkPenaltyStatus();
    final penaltyState = ref.read(driverPenaltyProvider);

    if (!mounted) return false;

    // Amount for UI / UPI: use API value, or ₹10 when backend flags pending but omits amount
    var displayPenalty = penaltyState.penaltyAmount > 0
        ? penaltyState.penaltyAmount
        : 0.0;
    if (displayPenalty <= 0 &&
        (allowEstimatedAmountIfMissing || penaltyState.hasPendingPenalty)) {
      displayPenalty = 10.0;
    }

    if (displayPenalty <= 0) {
      if (mounted) {
        AppMessenger.showDriverErrorBanner(context, 'Could not load penalty details. Please try again or contact support.');
      }
      return false;
    }

    final canPayWallet = penaltyState.walletBalance > 10 &&
        penaltyState.walletBalance >= displayPenalty &&
        displayPenalty > 0;

    final txController = TextEditingController();
    bool paymentInitiated = false;
    bool processing = false;

    final resolved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> launchUpi([String? appScheme]) async {
            final note = Uri.encodeComponent('Driver penalty payment');
            final amount = displayPenalty.toStringAsFixed(2);
            final uri = Uri.parse(
              appScheme == null
                  ? 'upi://pay?pa=${AppConfig.companyUpiId}&pn=${Uri.encodeComponent(AppConfig.companyName)}&am=$amount&cu=INR&tn=$note'
                  : '$appScheme://pay?pa=${AppConfig.companyUpiId}&pn=${Uri.encodeComponent(AppConfig.companyName)}&am=$amount&cu=INR&tn=$note',
            );
            final launched =
                await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (launched) {
              setSheetState(() => paymentInitiated = true);
            } else if (mounted) {
              AppMessenger.showDriverErrorBanner(context, 'Unable to open UPI app');
            }
          }

          Future<void> payWithWallet() async {
            setSheetState(() => processing = true);
            final success = await penaltyNotifier.clearPenaltyWithWallet();
            setSheetState(() => processing = false);
            if (success && mounted) {
              Navigator.of(sheetCtx).pop(true);
            } else if (mounted) {
              final error = ref.read(driverPenaltyProvider).error;
              AppMessenger.showDriverErrorBanner(context, error ?? 'Failed to clear penalty');
            }
          }

          Future<void> confirmUpiPayment() async {
            setSheetState(() => processing = true);
            final success = await penaltyNotifier.clearPenaltyWithUpi(
              transactionId: txController.text.trim().isEmpty
                  ? null
                  : txController.text.trim(),
            );
            setSheetState(() => processing = false);
            if (success && mounted) {
              Navigator.of(sheetCtx).pop(true);
            } else if (mounted) {
              final error = ref.read(driverPenaltyProvider).error;
              AppMessenger.showDriverErrorBanner(context, error ?? 'Failed to verify payment');
            }
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
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
                  'Complete Payment to Go Online',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3F3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFD4D4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Penalty: ₹${displayPenalty.toInt()}',
                        style: const TextStyle(
                          color: Color(0xFFB71C1C),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        penaltyState.penaltyReason ?? 'Pending penalty',
                        style: const TextStyle(color: Color(0xFF666666)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (canPayWallet) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: processing ? null : payWithWallet,
                      icon: const Icon(Icons.account_balance_wallet),
                      label: Text('Pay ₹${displayPenalty.toInt()} from Wallet'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (!canPayWallet) ...[
                  const Text(
                    'Pay via UPI',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: processing ? null : () => launchUpi('gpay'),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UpiAppIcon(appName: 'GPay', size: 18),
                          SizedBox(width: 6),
                          Text('GPay'),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: processing ? null : () => launchUpi('phonepe'),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UpiAppIcon(appName: 'PhonePe', size: 18),
                          SizedBox(width: 6),
                          Text('PhonePe'),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: processing ? null : () => launchUpi('paytm'),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UpiAppIcon(appName: 'Paytm', size: 18),
                          SizedBox(width: 6),
                          Text('Paytm'),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: processing ? null : () => launchUpi(),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UpiAppIcon(appName: 'UPI', size: 18),
                          SizedBox(width: 6),
                          Text('Any UPI App'),
                        ],
                      ),
                    ),
                  ],
                ),
                if (paymentInitiated) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: txController,
                    decoration: const InputDecoration(
                      labelText: 'Transaction ID (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: processing ? null : confirmUpiPayment,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A1A1A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: processing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Confirm Payment'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(sheetCtx).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
        },
      ),
    );
    txController.dispose();
    if (resolved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Penalty cleared. You can go online now.'),
          backgroundColor: Colors.green,
        ),
      );
      return true;
    }
    return false;
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
    if (lower.contains('not verified') ||
        lower.contains('verification') ||
        lower.contains('driver_not_verified')) {
      return _BackendError(
        title: 'Verification Pending',
        body:
            'Your documents are still under review. This usually takes 24-48 hours.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: true,
      );
    }
    if (lower.contains('penalty') ||
        lower.contains('penalty_unpaid') ||
        lower.contains('unpaid_penalty') ||
        lower.contains('penalty_pending') ||
        lower.contains('pending_penalty')) {
      return _BackendError(
        title: 'Pending Penalty',
        body:
            'You have a pending penalty. How would you like to clear it?',
        cta: 'Clear Penalty',
        allowRetry: false,
        affectsEligibility: false,
        isPenalty: true,
      );
    }
    if (lower.contains('suspended') ||
        lower.contains('account_suspended') ||
        lower.contains('deactivated')) {
      return _BackendError(
        title: 'Account Suspended',
        body:
            'Your account has been suspended. Please contact support for assistance.',
        cta: 'Contact Support',
        allowRetry: false,
        affectsEligibility: true,
      );
    }
    if (lower.contains('status code of 403') ||
        lower.contains('forbidden') ||
        lower.contains(' 403 ') ||
        lower.endsWith(' 403')) {
      return _BackendError(
        title: 'Cannot Go Online',
        body:
            'Your account is currently not eligible to go online. Please check onboarding/penalty status or contact support.',
        cta: 'OK',
        allowRetry: false,
        affectsEligibility: false,
        offerPenaltyResolution: true,
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
    final hasBackendReason =
        registrationMessage != null && registrationMessage.isNotEmpty;
    final classified =
        hasBackendReason ? _classifyBackendError(registrationMessage) : null;

    // Handle penalty case specially - show penalty payment dialog
    if (classified != null && classified.isPenalty) {
      _penaltyLikelyAfterEarlyStop = true;
      final resolved =
          await _showPendingPenaltyDialog(allowEstimatedAmountIfMissing: true);
      if (resolved) return;
    }

    // 403 / "not eligible" often means unpaid penalty but socket message omits the word "penalty"
    if (classified != null && classified.offerPenaltyResolution) {
      _penaltyLikelyAfterEarlyStop = true;
      final resolved = await _tryShowPenaltyFlowForBlockedDriver();
      if (resolved) return;
    }

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
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
              _buildErrorReason(
                  Icons.signal_wifi_off, 'Poor internet connection'),
              _buildErrorReason(
                  Icons.cloud_off, 'Server may be temporarily down'),
              _buildErrorReason(
                  Icons.security, 'Firewall or mobile data blocking port'),
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
              classified != null && !classified.allowRetry
                  ? classified.cta
                  : 'Cancel',
              style: const TextStyle(color: Color(0xFF999999)),
            ),
          ),
          if (classified == null || classified.allowRetry) ...[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                context.push(AppRoutes.serverConfig);
              },
              child: Text(ref.tr('edit_server'),
                  style: const TextStyle(color: Color(0xFF4285F4))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ref.tr('retry'),
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ],
      ),
    );

    if (shouldRetry == true && mounted) {
      _toggleOnlineStatus();
    }
  }

  /// If backend reports a pending penalty (GET /api/driver/penalty/status), show wallet/UPI flow.
  /// Returns true if we handled it (driver saw penalty UI).
  Future<bool> _tryShowPenaltyFlowForBlockedDriver() async {
    if (!mounted) return false;
    try {
      final notifier = ref.read(driverPenaltyProvider.notifier);
      final hasPending = await notifier.checkPenaltyStatus();
      final st = ref.read(driverPenaltyProvider);
      if (!mounted) return false;
      if (hasPending || st.hasPendingPenalty || st.penaltyAmount > 0) {
        debugPrint(
            '📛 Penalty flow: hasPending=$hasPending amount=${st.penaltyAmount}');
        return await _showPendingPenaltyDialog();
      }
      debugPrint(
          '📛 Penalty API: no pending penalty (403 may be onboarding/subscription)');
    } catch (e) {
      debugPrint('⚠️ Penalty resolution check failed: $e');
    }
    return false;
  }

  /// After [updateDriverStatus] fails: offer penalty payment when applicable.
  Future<void> _handleDriverBlockedAfterStatusUpdate(
      _BackendError classified) async {
    if (!mounted) return;
    if (classified.isPenalty) {
      _penaltyLikelyAfterEarlyStop = true;
      final resolved =
          await _showPendingPenaltyDialog(allowEstimatedAmountIfMissing: true);
      if (resolved) return;
    }
    if (classified.offerPenaltyResolution) {
      _penaltyLikelyAfterEarlyStop = true;
      final resolved = await _tryShowPenaltyFlowForBlockedDriver();
      if (resolved) return;
    }
    await _showStartRideBlockedDialog(classified);
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
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
          children: [
            const Icon(Icons.public_off, color: Color(0xFFE53935)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(ref.tr('server_unreachable'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18)),
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
            _buildErrorReason(Icons.signal_cellular_alt,
                'Mobile data may block the required port'),
            _buildErrorReason(Icons.wifi, 'Try a different Wi‑Fi network'),
            _buildErrorReason(
                Icons.vpn_lock, 'Corporate or public Wi‑Fi may block it'),
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
            child: Text(ref.tr('cancel'),
                style: const TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(false);
              context.push(AppRoutes.serverConfig);
            },
            child: Text(ref.tr('edit_server'),
                style: const TextStyle(color: Color(0xFF4285F4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ref.tr('retry'),
                style: const TextStyle(color: Colors.white)),
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
    // Navigate to subscription payment screen
    if (mounted) {
      final result = await context.push<bool>(AppRoutes.driverSubscriptionPayment);
      
      if (result == true) {
        // Payment successful
        await _persistFeePaidAt();
        await _persistSessionStart();
        _startSessionExpiryChecker();
      } else {
        // User cancelled or payment failed - go offline
        await _goOffline();
      }
    } else {
      await _goOffline();
    }
  }

  /// Internal helper to go offline (no penalty check).
  Future<void> _goOffline() async {
    // CRITICAL: Capture driver ID before clearing state
    final driverId = _driverId;

    setState(() => _isOnline = false);
    
    // Clear all offers when going offline
    ref.read(driverRidesProvider.notifier).clearAllOffers();
    
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
    _offerCleanupTimer?.cancel();
    _offerCleanupTimer = null;

    if (mounted) {
      AppMessenger.showDriverErrorBanner(context, ref.tr('you_are_offline'));
    }
  }

  /// Fetch driver quests (pricing v2 feature)
  Future<void> _fetchDriverQuests() async {
    if (!mounted) return;
    setState(() => _isLoadingQuests = true);
    try {
      final data = await apiClient.getDriverQuests();
      if (!mounted) return;

      if (data['success'] == true) {
        // Handle both nested and flat response formats
        final responseData = data['data'];
        List<dynamic> questsList = [];

        if (responseData is Map<String, dynamic>) {
          questsList = responseData['quests'] as List<dynamic>? ?? [];
        } else if (responseData is List) {
          questsList = responseData;
        }

        setState(() {
          _activeQuests = questsList
              .whereType<Map>()
              .map((q) => DriverQuest.fromJson(
                    Map<String, dynamic>.from(q),
                  ))
              .where((q) => !q.isCompleted)
              .toList();
        });

        // Also fetch boost status
        _fetchDriverBoost();

        debugPrint('🎯 Quests fetched: ${_activeQuests.length} active');
        for (final quest in _activeQuests) {
          debugPrint(
              '   - ${quest.title}: ${quest.completedRides}/${quest.targetRides} (₹${quest.rewardAmount})');
        }
      } else {
        debugPrint('⚠️ Quests API returned unsuccessful, using defaults');
        setState(() {
          _activeQuests = DriverQuest.getDefaultQuests();
        });
      }
    } catch (e) {
      debugPrint('❌ Error fetching quests: $e');
      // Use default quests as fallback
      setState(() {
        _activeQuests = DriverQuest.getDefaultQuests();
      });
    } finally {
      if (mounted) setState(() => _isLoadingQuests = false);
    }
  }

  /// Fetch driver boost status (pricing v2 feature)
  Future<void> _fetchDriverBoost() async {
    try {
      // Get vehicle type from driver profile if available
      final driverProfile = ref.read(driverOnboardingProvider);
      final vehicleType = driverProfile.selectedVehicleType ?? 'auto';

      final data = await apiClient.getDriverBoost(
        vehicleType,
        _currentLocation.latitude,
        _currentLocation.longitude,
      );

      if (data['success'] == true) {
        final boostData = data['data'];
        if (boostData != null) {
          setState(() {
            _activeBoost =
                DriverBoost.fromJson(boostData as Map<String, dynamic>);
          });
          debugPrint(
              '⚡ Boost status: ${_activeBoost?.isActive ?? false}, Amount: ₹${_activeBoost?.boostAmount ?? 0}');
        }
      }
    } catch (e) {
      debugPrint('❌ Error fetching boost: $e');
    }
  }

  Future<void> _fetchEarnings() async {
    if (!mounted) return;
    setState(() => _isLoadingEarnings = true);
    try {
      final data = await apiClient.getDriverEarnings();
      if (!mounted) return;

      final body = Map<String, dynamic>.from(data);
      if (!_truthyApiSuccess(body['success'])) return;

      final root = _driverEarningsDataRoot(body);
      debugPrint(
          '📊 _fetchEarnings root keys=${root.keys.toList()}');

      setState(() {
        if (root.isNotEmpty) {
          final earnings = root;
          final todayRaw = earnings['today'] ??
              earnings['Today'] ??
              earnings['daily'] ??
              earnings['day'];
          final td = _parseEarningsPeriodBucket(todayRaw);
          if (td.$1 > 0) _todayEarnings = td.$1;
          if (td.$2 > 0) _todayTrips = td.$2;

          final weekRaw = earnings['week'] ??
              earnings['Week'] ??
              earnings['this_week'] ??
              earnings['thisWeek'] ??
              earnings['weekly'];
          final wk = _parseEarningsPeriodBucket(weekRaw);
          if (wk.$1 > 0) _weekEarnings = wk.$1;
          if (wk.$2 > 0) _weekTrips = wk.$2;

          if (weekRaw is Map<String, dynamic>) {
            final hoursRaw = weekRaw['online_hours'] ??
                weekRaw['onlineHours'] ??
                weekRaw['hours_online'] ??
                weekRaw['hoursOnline'] ??
                weekRaw['online_time'] ??
                weekRaw['onlineTime'];
            final hrs = hoursRaw?.toString().trim();
            if (hrs != null && hrs.isNotEmpty) {
              _onlineHours = hrs;
            }
          }

          _rating = _dynDouble(
            earnings['rating'] ??
                earnings['driverRating'] ??
                earnings['avgRating'] ??
                earnings['averageRating'],
          );
        }
      });
      debugPrint(
          '📊 Earnings fetched: Today ₹$_todayEarnings, Week ₹$_weekEarnings');
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

      if (_truthyApiSuccess(data['success'])) {
        final innerData = data['data'] as Map<String, dynamic>? ?? {};
        final listRaw = innerData['trips'] ??
            innerData['rides'] ??
            innerData['history'] ??
            innerData['tripHistory'] ??
            innerData['trip_history'] ??
            innerData['completedTrips'];

        List<Map<String, dynamic>> rides = [];
        if (listRaw is List) {
          rides = listRaw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
        debugPrint('📜 Trip list extracted: ${rides.length} rides');
        update(() => _rideHistory = rides);
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
    _offerCleanupTimer?.cancel();
    _positionStream?.cancel();
    _rideOffersSubscription?.call();
    _connectionStatusSubscription?.cancel();
    _pushForegroundSubscription?.cancel();
    if (pushNotificationService.onNotificationAction ==
        _handleNotificationRideAction) {
      pushNotificationService.onNotificationAction = null;
    }
    super.dispose();
  }

  /// Start 1s timer so ride offer countdown updates in real time (not just on refresh).
  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isOnline) setState(() {});
    });
  }

  /// Periodically removes stale/invalid offers so cards auto-expire even if UI timers miss.
  void _startOfferCleanupTimer() {
    _offerCleanupTimer?.cancel();
    _offerCleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_isOnline) return;
      ref.read(driverRidesProvider.notifier).cleanupStaleOffers();
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

    // Keep realtime in-memory driver state (RAMEN/H3) fresh while online.
    // This improves rider->driver matching accuracy during active sessions.
    if (_isOnline) {
      final driverId = _driverId;
      if (driverId != 'unknown' && driverId.isNotEmpty) {
        unawaited(
          realtimeService.updateDriverLocation(
            driverId,
            position.latitude,
            position.longitude,
            heading: position.heading,
            speed: position.speed,
          ),
        );
        unawaited(
          realtimeService.updateDriverH3(
            driverId,
            position.latitude,
            position.longitude,
          ),
        );

        final now = DateTime.now();
        final shouldSyncStatus = _lastStatusSyncAt == null ||
            now.difference(_lastStatusSyncAt!) >= const Duration(seconds: 30);
        if (shouldSyncStatus) {
          _lastStatusSyncAt = now;
          unawaited(
            apiClient.updateDriverStatus(
              true,
              lat: position.latitude,
              lng: position.longitude,
            ),
          );
        }
      }
    }

    try {
      final controller = await _mapController.future;
      if (mounted)
        controller.animateCamera(CameraUpdate.newLatLng(_currentLocation));
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
    _connectionStatusSubscription =
        realtimeService.connectionStatus.listen((connected) {
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

  void _setupPushRideListener() {
    _pushForegroundSubscription?.cancel();
    _pushForegroundSubscription =
        pushNotificationService.notificationStream.listen((message) {
      _handleIncomingRidePush(message);
    });
    pushNotificationService.onNotificationAction =
        _handleNotificationRideAction;
  }

  Future<void> _handleNotificationRideAction(
    String action,
    Map<String, dynamic> data,
  ) async {
    if (!mounted) return;
    final actionId = action.toUpperCase();
    final isRideAction = actionId == NotificationActions.acceptRide ||
        actionId == NotificationActions.declineRide;
    if (!isRideAction || !_isOnline) return;

    final offer = _resolveRideOfferForAction(data);
    if (offer == null) return;

    if (actionId == NotificationActions.acceptRide) {
      // Reuse the same in-screen accept flow (state + route unchanged).
      await _acceptRide(offer);
      return;
    }

    await _declineRideOffer(offer, reason: 'Declined from heads-up action');
  }

  RideOffer? _resolveRideOfferForAction(Map<String, dynamic> data) {
    final rideId = (data['rideId'] ?? data['id'] ?? '').toString();
    final state = ref.read(driverRidesProvider);
    
    // Check active offer first
    if (state.activeOffer?.id == rideId) {
      final offer = state.activeOffer!;
      return _isIncomingOfferActiveAndFresh(offer) ? offer : null;
    }
    
    // Check pending offers
    for (final offer in state.pendingOffers) {
      if (offer.id == rideId) {
        return _isIncomingOfferActiveAndFresh(offer) ? offer : null;
      }
    }

    try {
      final hydrated = _rideOfferFromPushPayload(data);
      if (!_isIncomingOfferActiveAndFresh(hydrated)) {
        debugPrint('🧹 Ignoring stale notification action offer ${hydrated.id}');
        return null;
      }
      final added =
          ref.read(driverRidesProvider.notifier).addRideOffer(hydrated);
      if (!added) {
        debugPrint(
            '🛑 Notification action offer not queued: ${hydrated.id}');
        return null;
      }
      return hydrated;
    } catch (e) {
      debugPrint('Failed to resolve ride from notification action: $e');
      return null;
    }
  }

  bool _isRideRequestPayload(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString().toUpperCase();
    final event =
        (data['event'] ?? data['status'] ?? '').toString().toUpperCase();
    return type == NotificationTypes.newRide ||
        (type == 'RIDE_UPDATE' && event == 'NEW_RIDE_REQUEST');
  }

  double _parseFare(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    final raw = value.toString();
    final clean = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(clean) ?? 0;
  }

  RideOffer _rideOfferFromPushPayload(Map<String, dynamic> data) {
    final pickupDist = (data['pickupDistance'] ?? data['pickup_distance'] ?? '0 km')
        .toString();
    final dropDist = (data['dropDistance'] ??
            data['drop_distance'] ??
            data['tripDistance'] ??
            data['trip_distance'] ??
            data['estimatedDistance'] ??
            data['distance'] ??
            pickupDist)
        .toString();
    final rideIdRaw = data['rideId'] ?? data['id'] ?? data['requestId'];
    final rideId = (rideIdRaw == null || rideIdRaw.toString().isEmpty)
        ? 'push_${DateTime.now().millisecondsSinceEpoch}'
        : rideIdRaw.toString();
    return RideOffer.fromJson({
      'rideId': rideId,
      'id': rideId,
      'vehicleType':
          (data['vehicleType'] ?? data['serviceType'] ?? 'bike_rescue')
              .toString(),
      'estimatedFare': _parseFare(data['fare'] ?? data['estimatedFare']),
      'pickup_distance': pickupDist,
      'pickupTime': (data['pickupTime'] ?? 'Now').toString(),
      'drop_distance': dropDist.isNotEmpty ? dropDist : pickupDist,
      'dropTime': (data['dropTime'] ?? '').toString(),
      'pickupAddress':
          (data['pickup'] ?? data['pickupAddress'] ?? 'Pickup').toString(),
      'dropAddress': (data['drop'] ?? data['dropAddress'] ?? 'Drop').toString(),
      'passengerName':
          data['riderName']?.toString() ?? data['passengerName']?.toString(),
      'timestamp': DateTime.now().toIso8601String(),
      'status': 'searching',
      'rideType': data['rideType'],
      'isRescueRequest': data['isRescueRequest'],
      'rescueMultiDriver': data['rescueMultiDriver'],
      'driversNeeded': data['driversNeeded'],
      'rescueRoleNeeded': data['rescueRoleNeeded'] ??
          data['rescue_role_needed'] ??
          data['requiredRescueRole'] ??
          data['driverRoleNeeded'],
      'hasVehicle': data['hasVehicle'],
      'vehicleDropAddress': data['vehicleDropAddress'],
    });
  }

  bool _isOfferStatusActive(String status) {
    final s = status.toLowerCase();
    if (s == 'cancelled' || s == 'completed' || s == 'expired') return false;
    return s == 'searching' || s == 'pending';
  }

  bool _isIncomingOfferActiveAndFresh(RideOffer offer, {int maxAgeSeconds = 90}) {
    if (!_isOfferStatusActive(offer.status)) return false;
    final age = DateTime.now().difference(offer.createdAt).inSeconds;
    return age <= maxAgeSeconds;
  }

  bool _distanceLabelHasPositiveKm(String s) {
    final m = RegExp(r'([\d.]+)\s*km').firstMatch(s.trim().toLowerCase());
    if (m != null) {
      final km = double.tryParse(m.group(1)!);
      return km != null && km > 0;
    }
    return false;
  }

  /// Parses RideOffer ETA labels like "1 hr 47 min away" → minutes when possible.
  int? _inferTripMinutesFromEtaLabel(String raw) {
    final t = raw.toLowerCase();
    if (t.isEmpty ||
        t == '< 1 min away' ||
        RegExp(r'^0\s*m(?:in)?').hasMatch(t)) {
      return null;
    }
    int total = 0;
    final hr = RegExp(r'(\d+)\s*hr\b').firstMatch(t);
    if (hr != null) total += int.parse(hr.group(1)!) * 60;
    final minPlain = RegExp(r'(\d+)\s*m(?:ins?)?\b').firstMatch(t);
    if (minPlain != null) total += int.parse(minPlain.group(1)!);
    return total > 0 ? total : null;
  }

  String _fareDigitsForRideNotificationPayload(double fare) {
    if ((fare - fare.round()).abs() < 1e-6) return fare.round().toString();
    return fare.toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
  }

  Map<String, dynamic> _ridePayloadFromOffer(RideOffer offer) {
    final pickup = offer.pickupDistance.trim();
    final drop = offer.dropDistance.trim();
    final distanceForTray = _distanceLabelHasPositiveKm(drop)
        ? drop
        : (_distanceLabelHasPositiveKm(pickup) ? pickup : (drop.isNotEmpty ? drop : pickup));

    final payload = <String, dynamic>{
      'type': NotificationTypes.newRide,
      'rideId': offer.id,
      'pickup': offer.pickupAddress,
      'drop': offer.dropAddress,
      'distance': distanceForTray,
      'pickupDistance': pickup,
      'dropDistance': drop,
      'dropTime': offer.dropTime,
      // Fare without currency symbol — [PushNotificationService] adds a single ₹.
      'fare': _fareDigitsForRideNotificationPayload(offer.earning),
      'estimatedFare': offer.earning,
      if (offer.riderName != null) 'riderName': offer.riderName,
    };

    final tripMins = _inferTripMinutesFromEtaLabel(offer.dropTime);
    if (tripMins != null) payload['estimatedDurationMinutes'] = tripMins;

    return payload;
  }

  Future<void> _handleIncomingRidePush(RemoteMessage message) async {
    if (!mounted || !_isOnline) return;
    if (!_isRideRequestPayload(message.data)) return;

    try {
      final offer = _rideOfferFromPushPayload(message.data);
      if (!_isIncomingOfferActiveAndFresh(offer)) {
        debugPrint(
            '🧹 Push offer ignored (stale/invalid): id=${offer.id} status=${offer.status}');
        return;
      }
      final added = ref.read(driverRidesProvider.notifier).addRideOffer(offer);
      if (!added) {
        debugPrint(
            '🛑 Push ride not queued: ${offer.id} type=${offer.type}');
        return;
      }
      await _showIncomingRideOverlay(offer, source: 'push');
    } catch (e) {
      debugPrint('⚠️ Failed to handle incoming ride push: $e');
    }
  }

  Future<void> _declineRideOffer(RideOffer offer,
      {String reason = 'Declined by driver'}) async {
    final notifier = ref.read(driverRidesProvider.notifier);
    // Persist local rejection so replayed duplicate events are ignored.
    notifier.markOfferRejected(offer.id);
    // If it's the active card, decline normally; otherwise remove from queue.
    final activeId = ref.read(driverRidesProvider).activeOffer?.id;
    if (activeId == offer.id) {
      notifier.declineActiveOffer();
    } else {
      notifier.removeRide(offer.id);
    }
    try {
      await apiClient.declineRide(offer.id, reason: reason);
    } catch (e) {
      debugPrint('Decline ride API failed: $e');
    }
  }

  Future<void> _showIncomingRideOverlay(
    RideOffer offer, {
    required String source,
  }) async {
    if (!mounted || !_isOnline) return;
    if (_activeIncomingRideId == offer.id) return;

    final now = DateTime.now();
    final lastShownAt = _recentIncomingRides[offer.id];
    if (lastShownAt != null && now.difference(lastShownAt).inSeconds < 8) {
      return;
    }
    _recentIncomingRides[offer.id] = now;

    await pushNotificationService.showIncomingRideHeadsUp(
      data: _ridePayloadFromOffer(offer),
    );

    if (!mounted) return;
    debugPrint('📣 Processing ride offer (${offer.id}) from $source');
    
    // The offer is already added to the provider via addRideOffer
    // The provider handles the activeOffer/pendingOffers queue logic
  }

  /// Schedule reconnect with exponential backoff when connection drops.
  void _scheduleReconnect() {
    if (!_isOnline || !mounted) return;
    final authState = ref.read(authStateProvider);
    if (authState.isLoggingOut || authState.user == null) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay =
        Duration(seconds: (1 << _reconnectAttempts.clamp(0, 5)).clamp(2, 30));
    debugPrint(
        '🔄 Scheduling reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
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
      final rawRide = data['ride'];
      if (rawRide is! Map) {
        debugPrint('⚠️ new_ride_offer event missing ride data');
        return;
      }
      final rideData = normalizeRideOfferEventJson(
        Map<String, dynamic>.from(rawRide as Map),
      );

      debugPrint(
          '🚗 New ride offer received via real-time: ${rideData['rideId'] ?? rideData['id']}');

      if (mounted) {
        try {
          final offer = RideOffer.fromJson(rideData);
          if (!_isIncomingOfferActiveAndFresh(offer)) {
            debugPrint(
                '🧹 Realtime offer ignored (stale/invalid): id=${offer.id} status=${offer.status}');
            return;
          }
          final driverRidesNotifier = ref.read(driverRidesProvider.notifier);
          final added = driverRidesNotifier.addRideOffer(offer);
          if (!added) {
            debugPrint(
                '🛑 Realtime ride not queued: ${offer.id} type=${offer.type} status=${offer.status}');
            return;
          }
          Vibration.hasVibrator().then((hasVibrator) {
            if (hasVibrator == true) {
              Vibration.vibrate(duration: 500);
            }
          });
          unawaited(_showIncomingRideOverlay(offer, source: 'realtime'));
          debugPrint('✅ Ride offer added from real-time event: ${offer.id}');
        } catch (e) {
          debugPrint('⚠️ Failed to parse ride from realtime event: $e');
        }
      }
    } else if (type == 'ride_taken') {
      final rideId = data['rideId'] as String?;
      debugPrint('🚫 Ride taken by another driver: $rideId');
      if (mounted && rideId != null) {
        // Remove from offers (handles both active and pending)
        ref.read(driverRidesProvider.notifier).removeRide(rideId);
        // Show subtle feedback
        AppMessenger.showDriverErrorBanner(context, ref.tr('ride_taken_by_another'));
      }
    } else if (type == 'ride_cancelled') {
      final rideId = rideIdFromRealtimePayload(data);
      debugPrint('❌ Ride cancelled: $rideId');
      if (mounted && rideId != null) {
        final notifier = ref.read(driverRidesProvider.notifier);
        // Remove from offers (handles both active and pending)
        notifier.removeRide(rideId);
        // If the cancelled ride was our accepted ride, clear it and return home
        final acceptedRide = ref.read(driverRidesProvider).acceptedRide;
        if (acceptedRide != null && acceptedRide.id == rideId) {
          notifier.clearAcceptedRide();
          final reason = data['reason'] as String? ??
              data['cancelReason'] as String? ??
              ref.tr('ride_cancelled_by_rider');
          if (!mounted) return;
          final onActiveRideScreen =
              GoRouter.of(context).routeInformationProvider.value.uri.path ==
                  AppRoutes.driverActiveRide;
          if (onActiveRideScreen) {
            // Active ride screen listens for acceptedRide clearing and exits.
            return;
          }
          AppMessenger.showDriverErrorBanner(context, reason);
          context.go(AppRoutes.driverHome);
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
      // Do not replay historical offers on reconnect.
      ref.read(driverRidesProvider.notifier).cleanupStaleOffers();
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
        AppMessenger.showDriverErrorBanner(context, _verificationBannerMsg ??
                'You are not verified to go online yet.');
      }
      return;
    }

    if (!_isOnline) {
      // ---- GOING ONLINE ----

      if (!_isPersonalRescueDriver) {
        // 1. Check subscription status from backend
        final subscriptionAllowed = await _checkSubscriptionBeforeGoingOnline();
        if (!subscriptionAllowed) return; // User needs to pay or cancelled
      }

      // 1.1 Resolve pending penalty via dynamic payment sheet.
      final penaltyResolved = await _resolvePenaltyBeforeGoingOnline();
      if (!penaltyResolved) return;

      // CRITICAL: Get driver ID FIRST before any async operations
      if (_driverId == 'unknown' || _driverId.isEmpty) {
        await _hydrateDriverRecordId();
      }
      final driverId = _driverId;
      if (driverId == 'unknown' || driverId.isEmpty) {
        debugPrint('❌ Cannot go online - invalid driver ID');
        if (mounted) {
          AppMessenger.showDriverErrorBanner(context, ref.tr('driver_id_error'));
        }
        return;
      }

      // Fresh online session: clear stale in-memory offers before any replay.
      final ridesNotifier = ref.read(driverRidesProvider.notifier);
      ridesNotifier.resetForNewSession(preserveAcceptedRide: true);
      // Disconnect any previous transport to avoid duplicate listeners/replayed events.
      realtimeService.disconnectDriver();

      // CRITICAL: Block UI while connecting
      setState(() => _isConnecting = true);

      // 1.5 Pre-check: can we reach the realtime service (port 5007)?
      // We try the health check but don't block if it fails - let the actual connection attempt decide
      final canReachRealtime = await ServerConfigService.checkRealtimeReachable(
          timeout: const Duration(seconds: 10));
      if (!canReachRealtime) {
        debugPrint(
            '⚠️ Health check failed but proceeding with connection attempt...');
        // Don't return - let the actual connection try and fail with a better error
      }

      // 2. Connect via SSE + Socket.io and register driver
      final secureStorage = ref.read(secureStorageProvider);
      final token = await secureStorage.read(key: 'auth_token');

      debugPrint(
          '🚗 Driver going online: $driverId - connecting SSE + Socket.io...');
      final registered = await realtimeService.connectDriver(
        driverId,
        lat: _currentLocation.latitude,
        lng: _currentLocation.longitude,
        token: token,
        onEvent: _handleDriverEvent,
      );

      if (!registered) {
        final backendReason = realtimeService.takeLastRegistrationError();
        debugPrint(
            '❌ Registration rejected by backend. Reason: $backendReason');
        setState(() => _isConnecting = false);
        if (mounted) {
          _showConnectionErrorDialog(registrationMessage: backendReason);
        }
        return;
      }

      debugPrint(
          '✅ Driver $driverId connected successfully - updating backend status...');

      // 3. Auto-register as driver if not already registered
      try {
        await apiClient.startDriverOnboarding();
        debugPrint('Driver registered/onboarding started: $_driverId');
      } catch (e) {
        debugPrint('Driver registration (may already exist): $e');
      }

      // 4. CRITICAL: Update driver status on backend FIRST - this must succeed
      try {
        final statusResponse = await apiClient.updateDriverStatus(true,
            lat: _currentLocation.latitude, lng: _currentLocation.longitude);
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
          await _handleDriverBlockedAfterStatusUpdate(classified);
        }
        return;
      }

      // 5. Only set online AFTER backend confirms
      setState(() {
        _isOnline = true;
        _isConnecting = false;
      });
      _lastStatusSyncAt = null;
      if (driverId != 'unknown' && driverId.isNotEmpty) {
        unawaited(
          realtimeService.updateDriverLocation(
            driverId,
            _currentLocation.latitude,
            _currentLocation.longitude,
          ),
        );
        unawaited(
          realtimeService.updateDriverH3(
            driverId,
            _currentLocation.latitude,
            _currentLocation.longitude,
          ),
        );
      }
      _startCountdownTimer();
      _startOfferCleanupTimer();
      await _persistOnlineState(true);
      await _persistSessionStart();

      // 5. Initial fetch of ride offers
      _fetchRideOffers();

      // 6. Start the 24-hour session expiry checker
      _startSessionExpiryChecker();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.tr('you_are_online')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
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
        _penaltyLikelyAfterEarlyStop = true;
      } else {
        _penaltyLikelyAfterEarlyStop = false;
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

  Future<void> _openActiveRideAndRefresh() async {
    await context.push(AppRoutes.driverActiveRide);
    if (!mounted) return;
    await _fetchDriverQuests();
  }

  Future<void> _openRescueJobAndRefresh() async {
    await context.push(AppRoutes.driverRescueJob);
    if (!mounted) return;
    await _fetchDriverQuests();
  }

  bool _isPreOtpRescueJob(RideOffer ride) {
    final status = ride.rescueStatus?.toUpperCase();
    if (status == null || status.isEmpty) return true;
    return status == 'PENDING' ||
        status == 'DRIVER1_ACCEPTED' ||
        status == 'BOTH_ACCEPTED' ||
        status == 'DRIVERS_EN_ROUTE' ||
        status == 'DRIVERS_ARRIVED';
  }

  Future<void> _acceptRide(RideOffer offer) async {
    // CRITICAL: Prevent double-tap
    if (_acceptingRideId != null) {
      debugPrint('⚠️ Already accepting ride $_acceptingRideId, ignoring tap');
      return;
    }

    setState(() => _acceptingRideId = offer.id);
    debugPrint(
      '🚗 Accepting ${offer.isRescue ? 'rescue' : 'ride'}: ${offer.id}',
    );

    try {
      final success = await ref
          .read(driverRidesProvider.notifier)
          .acceptOffer(offer, driverId: _driverId);

      if (success && mounted) {
        final accepted = ref.read(driverRidesProvider).acceptedRide;
        if (accepted?.isRescue == true) {
          debugPrint('✅ Rescue accepted, navigating to rescue job screen');
          await _openRescueJobAndRefresh();
        } else {
          debugPrint('✅ Ride accepted successfully, navigating to active ride');
          await _openActiveRideAndRefresh();
        }
      } else if (mounted) {
        // Get specific error from provider state
        final error = ref.read(driverRidesProvider).error;
        String errorMessage = 'Failed to accept ride';

        if (error != null) {
          if (error.contains('already been accepted')) {
            errorMessage = 'This ride was taken by another driver';
          } else if (error.contains('not authorized') ||
              error.contains('FORBIDDEN')) {
            errorMessage =
                'You are not authorized to accept rides. Please contact support.';
          } else {
            errorMessage = error;
          }
        }

        debugPrint('❌ Failed to accept ride: $errorMessage');
        AppMessenger.showDriverErrorBanner(context, errorMessage);
      }
    } finally {
      if (mounted) {
        setState(() => _acceptingRideId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DriverOnboardingState>(driverOnboardingProvider, (_, next) {
      if (_isPersonalRescueDriver) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isPersonalRescueDriver) return;
        ref.read(driverRidesProvider.notifier).setRegisteredDriverVehicleType(
              next.selectedVehicleType,
            );
      });
    });

    ref.listen<PersonalDriverOnboardingState>(personalDriverOnboardingProvider,
        (_, next) {
      if (!_isPersonalRescueDriver) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isPersonalRescueDriver) return;
        _fetchPersonalDriverVerificationStatus();
      });
    });

    final driverRidesState = ref.watch(driverRidesProvider);
    final hasActiveOffer = driverRidesState.hasActiveOffer && _isOnline;

    return Scaffold(
      backgroundColor: Colors.white,
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Stack(
          children: [
            // Main content
            Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Map
                      _buildMap(),

                      // Start Ride / Stop Riding button - always centered at bottom
                      // Hide when ride stack is visible
                      if (!hasActiveOffer)
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
                // Hide bottom section when ride stack is visible
                if (!hasActiveOffer) _buildBottomSection(),
              ],
            ),
            
            // Ride Stack Overlay - 50% height from bottom (SINGLE OFFER CARD UI)
            if (hasActiveOffer)
              RideStackOverlay(
                onAccept: (ride) => _acceptRide(ride),
                onDecline: (ride) => _declineRideOffer(ride),
              ),
            // While an incoming-offer overlay is visible, bottom tray is hidden;
            // keep resume affordance visible above the overlay if a trip is in progress.
            if (driverRidesState.acceptedRide != null && hasActiveOffer)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.sizeOf(context).height * 0.5 +
                    MediaQuery.paddingOf(context).bottom +
                    8,
                child: Material(
                  elevation: 10,
                  shadowColor: Colors.black38,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  color: Colors.transparent,
                  child: _buildActiveRideReturnCard(compact: true),
                ),
              ),
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
          const Icon(Icons.hourglass_top_rounded,
              color: Color(0xFFE65100), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _verificationBannerMsg!,
              style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFE65100),
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalRescueModeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCF923D)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.emergency, color: Color(0xFFCF923D), size: 16),
          SizedBox(width: 4),
          Text(
            'Rescue Driver',
            style: TextStyle(
              color: Color(0xFFCF923D),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionStatusBadge() {
    final subscriptionState = ref.watch(driverSubscriptionProvider);
    final subscription = subscriptionState.subscription;

    if (subscription == null || !subscription.isActive) {
      // Not active - show expired/pay badge
      return GestureDetector(
        onTap: () => context.push(AppRoutes.driverSubscriptionPayment),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.red.shade100,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.red.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.red.shade700, size: 16),
              const SizedBox(width: 4),
              Text(
                'Pass Expired',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Active subscription - show countdown
    final validTill = subscription.validTillFormatted;
    return GestureDetector(
      onTap: () => _showSubscriptionInfo(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700, size: 16),
            const SizedBox(width: 4),
            Text(
              'Till $validTill',
              style: TextStyle(
                color: Colors.green.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSubscriptionInfo() {
    final subscriptionState = ref.read(driverSubscriptionProvider);
    final subscription = subscriptionState.subscription;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.verified, color: Colors.green.shade600),
            const SizedBox(width: 8),
            const Text('Daily Pass Active',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Status:',
                          style: TextStyle(color: Colors.grey)),
                      Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: Colors.green.shade600, size: 18),
                          const SizedBox(width: 4),
                          Text('Active',
                              style: TextStyle(
                                  color: Colors.green.shade700,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Valid Till:',
                          style: TextStyle(color: Colors.grey)),
                      Text(
                        subscription?.validTillFormatted ?? 'N/A',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Remaining:',
                          style: TextStyle(color: Colors.grey)),
                      Text(
                        subscription?.remainingTimeFormatted ?? 'N/A',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.green.shade700),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You can accept unlimited rides during this period.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
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

          if (_isPersonalRescueDriver)
            _buildPersonalRescueModeBadge()
          else ...[
            // Subscription status badge
            _buildSubscriptionStatusBadge(),
            const SizedBox(width: 8),
          ],

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
    // Watch dark mode changes
    final isDarkMode = ref.watch(settingsProvider).isDarkMode;
    if (isDarkMode != _lastDarkMode) {
      _lastDarkMode = isDarkMode;
      _loadMapStyle();
    }

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
            _mapControllerInstance = controller;
            // Apply map style
            if (_mapStyle != null) {
              controller.setMapStyle(_mapStyle);
            }
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
            UberShimmer(
              baseColor: Color(0x88FFFFFF),
              highlightColor: Color(0xFFFFFFFF),
              child: UberShimmerBox(
                width: 44,
                height: 14,
                borderRadius: BorderRadius.all(Radius.circular(8)),
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
              _isOnline
                  ? (_isPersonalRescueDriver ? 'Stop Rescue' : 'Stop Riding')
                  : (_isPersonalRescueDriver ? 'Start Rescue' : 'Start Ride'),
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
          // Driver quests section (pricing v2)
          if (_activeQuests.isNotEmpty && !hasActiveRide) _buildQuestsSection(),
          // Active boost indicator
          if (_activeBoost?.isActive == true && !hasActiveRide)
            _buildBoostIndicator(),
          // Return to active ride card when driver went back during ongoing ride
          if (hasActiveRide) _buildActiveRideReturnCard(),
          // Idle state message when online but no active offer
          // (Ride offers are now shown as single card overlay, not tiles)
          if (!hasActiveRide && _isOnline) _buildIdleStateSection(),
        ],
      ),
    );
  }

  /// Build idle state section when driver is online but no active offer
  Widget _buildIdleStateSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.hourglass_empty,
            size: 48,
            color: Color(0xFFCCCCCC),
          ),
          const SizedBox(height: 12),
          const Text(
            'Waiting for ride requests...',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF888888),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'New rides will appear automatically',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  /// Build driver quests section (pricing v2 feature)
  Widget _buildQuestsSection() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.emoji_events,
                      color: Colors.amber.shade700, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Daily Quests',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ],
              ),
              if (_isLoadingQuests)
                const UberShimmer(
                  child: UberShimmerBox(
                    width: 40,
                    height: 12,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _activeQuests.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _buildQuestCard(_activeQuests[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestCard(DriverQuest quest) {
    final progress = quest.progress.clamp(0.0, 1.0);
    final isNearComplete = progress >= 0.8;

    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isNearComplete
              ? [Colors.amber.shade50, Colors.amber.shade100]
              : [Colors.grey.shade50, Colors.grey.shade100],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isNearComplete ? Colors.amber.shade300 : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                quest.isPeakHour ? Icons.access_time : Icons.local_taxi,
                size: 14,
                color: isNearComplete
                    ? Colors.amber.shade700
                    : Colors.grey.shade600,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  quest.title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isNearComplete
                        ? Colors.amber.shade800
                        : const Color(0xFF1A1A1A),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${quest.completedRides}/${quest.targetRides} rides',
            style: TextStyle(
              fontSize: 10,
              height: 1.2,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(
                      isNearComplete
                          ? Colors.amber.shade600
                          : const Color(0xFFD4956A),
                    ),
                    minHeight: 4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '₹${quest.rewardAmount.round()}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isNearComplete
                      ? Colors.amber.shade700
                      : const Color(0xFFD4956A),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Build boost indicator (pricing v2 feature)
  Widget _buildBoostIndicator() {
    if (_activeBoost == null || !_activeBoost!.isActive)
      return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.purple.shade50, Colors.purple.shade100],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.purple.shade400,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Boost Active!',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.purple.shade800,
                  ),
                ),
                Text(
                  'Earn +₹${_activeBoost!.boostAmount.round()} extra per ride',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.purple.shade600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.purple.shade400,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '+₹${_activeBoost!.boostAmount.round()}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Prominent card to return to active ride when driver pressed back
  Widget _buildActiveRideReturnCard({bool compact = false}) {
    final acceptedRide = ref.watch(driverRidesProvider).acceptedRide;
    if (acceptedRide == null) return const SizedBox.shrink();
    final isRescueJob =
        acceptedRide.isRescue && _isPreOtpRescueJob(acceptedRide);
    final titleStyle = TextStyle(
      fontSize: compact ? 15 : 18,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF1A1A1A),
    );
    final subtitleStyle = TextStyle(
      fontSize: compact ? 11 : 12,
      color: const Color(0xFF666666),
    );
    final iconBox = compact ? 44.0 : 56.0;
    final iconSize = compact ? 22.0 : 28.0;

    return GestureDetector(
      onTap: isRescueJob ? _openRescueJobAndRefresh : _openActiveRideAndRefresh,
      child: Container(
        margin: compact
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFD4956A).withOpacity(0.15),
          borderRadius: BorderRadius.circular(compact ? 14 : 16),
          border: Border.all(
            color: const Color(0xFFD4956A),
            width: compact ? 1.5 : 2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: iconBox,
              height: iconBox,
              decoration: BoxDecoration(
                color: const Color(0xFFD4956A),
                borderRadius: BorderRadius.circular(compact ? 10 : 12),
              ),
              child: Icon(
                isRescueJob ? Icons.emergency : Icons.directions_car,
                color: Colors.white,
                size: iconSize,
              ),
            ),
            SizedBox(width: compact ? 12 : 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRescueJob ? 'Ongoing Rescue' : 'Ongoing Ride',
                    style: titleStyle,
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  Text(
                    '${acceptedRide.pickupAddress} → ${acceptedRide.dropAddress}',
                    style: subtitleStyle,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              size: compact ? 14 : 16,
              color: const Color(0xFFD4956A),
            ),
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
    final drawerW = MediaQuery.sizeOf(context).width;
    final user = ref.watch(currentUserProvider);
    return Drawer(
      width: drawerW,
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  const SizedBox(width: 48),
                  Expanded(
                    child: Text(
                      ref.tr('profile'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textPrimary),
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 8,
                  bottom: 24 + MediaQuery.paddingOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDriverDrawerUserCard(user),
                    const SizedBox(height: 22),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color:
                              AppColors.secondaryDark.withValues(alpha: 0.55),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                Colors.black.withValues(alpha: 0.045),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _DriverDrawerMenuItem(
                              icon: Icons.swap_horiz_rounded,
                              title: 'Switch to Rider',
                              subtitle:
                                  'Browse and book rides as a passenger',
                              onTap: () {
                                Navigator.pop(context);
                                context.go(AppRoutes.services);
                              },
                            ),
                            const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE8E8E8),
                            ),
                            _DriverDrawerMenuItem(
                              icon: Icons.history_rounded,
                              title: ref.tr('ride_history'),
                              subtitle: 'Past trips and details',
                              onTap: () {
                                Navigator.pop(context);
                                _showRideHistory();
                              },
                            ),
                            const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE8E8E8),
                            ),
                            _DriverDrawerMenuItem(
                              icon:
                                  Icons.account_balance_wallet_rounded,
                              title: ref.tr('earnings'),
                              subtitle: 'Payouts and weekly summary',
                              onTap: () {
                                Navigator.pop(context);
                                _showEarnings();
                              },
                            ),
                            const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE8E8E8),
                            ),
                            _DriverDrawerMenuItem(
                              icon: Icons.description_outlined,
                              title: 'Update Documents',
                              subtitle:
                                  'Licence, vehicle, and profile',
                              onTap: () {
                                Navigator.pop(context);
                                context.push(
                                  '${AppRoutes.driverOnboarding}?isUpdateMode=true&returnToProfile=true',
                                );
                              },
                            ),
                            const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE8E8E8),
                            ),
                            _DriverDrawerMenuItem(
                              icon: Icons.settings_outlined,
                              title: ref.tr('settings'),
                              subtitle: 'Preferences and account',
                              onTap: () {
                                Navigator.pop(context);
                                _showSettings();
                              },
                            ),
                            const Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0xFFE8E8E8),
                            ),
                            _DriverDrawerMenuItem(
                              icon: Icons.help_outline_rounded,
                              title: ref.tr('help_support'),
                              subtitle: 'Get help while driving',
                              onTap: () {
                                Navigator.pop(context);
                                _showHelpSupport();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showLogoutConfirmation();
                        },
                        icon: const Icon(Icons.logout, color: AppColors.error),
                        label: Text(
                          ref.tr('logout'),
                          style: const TextStyle(color: AppColors.error),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.error),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showDeleteAccountDialog();
                        },
                        icon: const Icon(Icons.delete_forever_outlined,
                            color: AppColors.error, size: 18),
                        label: const Text(
                          'Delete Account',
                          style:
                              TextStyle(color: AppColors.error, fontSize: 13),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Raahi Driver v1.0.0',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverDrawerUserCard(User? user) {
    final onboarding = ref.watch(driverOnboardingProvider);
    final displayName = user?.name ?? 'Driver';
    final displayEmail = user?.email ?? '';
    final displayPhone = user?.phone ?? '';
    final initials = _getUserInitials(displayName);
    final profilePhotoDetail = onboarding.backendStatus.documentDetails
        .where((d) => d.type == 'PROFILE_PHOTO' && d.url != null)
        .fold<BackendDocumentInfo?>(
      null,
      (best, current) {
        if (best == null) return current;
        final bestTs = best.uploadedAt?.millisecondsSinceEpoch ?? 0;
        final curTs = current.uploadedAt?.millisecondsSinceEpoch ?? 0;
        return curTs >= bestTs ? current : best;
      },
    );
    final rawAvatarUrl = (profilePhotoDetail?.url?.isNotEmpty == true)
        ? profilePhotoDetail!.url
        : user?.avatarUrl;
    final avatarUrl = (() {
      if (rawAvatarUrl == null || rawAvatarUrl.isEmpty) return null;
      final resolved = _resolveAvatarUrl(rawAvatarUrl);
      if (resolved == null || resolved.isEmpty) return null;
      final uploadedAtMs = profilePhotoDetail?.uploadedAt?.millisecondsSinceEpoch;
      if (uploadedAtMs == null) return resolved;
      final separator = resolved.contains('?') ? '&' : '?';
      return '$resolved${separator}v=$uploadedAtMs';
    })();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.inputBackground,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: AppColors.secondary.withValues(alpha: 0.22),
            child: ClipOval(
              child: avatarUrl != null
                  ? Image.network(
                      avatarUrl,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _driverDrawerAvatarFallback(
                        initials,
                        radius: 36,
                      ),
                    )
                  : _driverDrawerAvatarFallback(initials, radius: 36),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (displayEmail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    displayEmail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                ],
                if (displayPhone.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _drawerFormatPhone(displayPhone),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _driverDrawerRatingChip(
            isLoading: _isLoadingEarnings,
            ratingText: !_isLoadingEarnings && _rating > 0
                ? _rating.toStringAsFixed(1)
                : 'N/A',
          ),
        ],
      ),
    );
  }

  Widget _driverDrawerRatingChip({
    required bool isLoading,
    required String ratingText,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFD54F)),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 26),
              child: Align(
                alignment: Alignment.center,
                child: isLoading
                    ? const SizedBox(
                        height: 16,
                        width: 34,
                        child: UberShimmer(
                          child: UberShimmerBox(width: 34, height: 14),
                        ),
                      )
                    : Text(
                        ratingText,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _driverDrawerAvatarFallback(String initials, {required double radius}) {
    final d = radius * 2;
    return Container(
      width: d,
      height: d,
      color: AppColors.secondary.withValues(alpha: 0.35),
      alignment: Alignment.center,
      child: Text(
        initials.length > 1 ? initials.substring(0, 2) : initials,
        style: TextStyle(
          fontSize: radius * 0.7,
          fontWeight: FontWeight.bold,
          color: AppColors.secondary,
        ),
      ),
    );
  }

  String _drawerFormatPhone(String phone) {
    var digits = phone.replaceFirst(RegExp(r'^\+91\s*'), '');
    digits = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 10) {
      return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
    }
    return phone.startsWith('+') ? phone : '+91 $phone';
  }

  String? _resolveAvatarUrl(String? rawUrl) {
    if (rawUrl == null) return null;
    final input = rawUrl.trim();
    if (input.isEmpty) return null;

    final uri = Uri.tryParse(input);
    if (uri != null && uri.hasScheme) return input;

    final apiUri = Uri.tryParse(AppConfig.apiUrl);
    if (apiUri == null || !apiUri.hasScheme) return input;
    final origin = '${apiUri.scheme}://${apiUri.authority}';

    if (input.startsWith('/')) return '$origin$input';
    return '$origin/$input';
  }

  /// Build two-letter initials from name (e.g. "Shikha Parashar" -> "SP")
  String _getUserInitials(String name) {
    if (name.isEmpty) return 'D';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  /// Show delete account confirmation dialog
  Future<void> _showDeleteAccountDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Account'),
        content: const Text(
          'Are you sure you want to permanently delete your account? '
          'All your data including ride history, earnings, and documents '
          'will be permanently removed. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ref.tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final response = await apiClient.deleteAccount();
        if (response['success'] == true) {
          await ref.read(authStateProvider.notifier).signOut();
          if (mounted) {
            context.go(AppRoutes.login);
          }
        } else {
          if (mounted) {
            AppMessenger.showDriverErrorBanner(
                context, response['message'] ?? 'Failed to delete account');
          }
        }
      } catch (e) {
        if (mounted) {
          AppMessenger.showDriverErrorBanner(context, 'Failed to delete account');
        }
      }
    }
  }

  void _showRideHistory({StateSetter? modalSetState, BuildContext? overlayContext}) {
    bool hasFetched = false;

    final sheetContextForModal = overlayContext ?? context;

    showModalBottomSheet(
      context: sheetContextForModal,
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
            Future.microtask(
                () => _fetchRideHistory(modalSetState: setModalState));
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
                        const UberShimmer(
                          child: UberShimmerBox(
                            width: 46,
                            height: 12,
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
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
                              Icon(Icons.history,
                                  size: 64, color: Colors.grey[300]),
                              const SizedBox(height: 16),
                              Text(
                                _isLoadingHistory
                                    ? 'Loading...'
                                    : 'No ride history yet',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Complete rides to see your history',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[400]),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: _rideHistory.length,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemBuilder: (context, index) {
                            return _buildHistoryCardFromData(
                                _rideHistory[index]);
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
    final destAddress = ride['drop_address'] ??
        ride['destination_address'] ??
        'Unknown destination';
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

  double _dynDouble(dynamic v) {
    if (v == null) return 0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  int _dynInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? 0;
  }

  bool _truthyApiSuccess(dynamic s) =>
      s == true || s == 1 || s == 'true' || s == 'success';

  /// Normalizes GET /api/driver/earnings bodies that wrap or nest period maps.
  Map<String, dynamic> _driverEarningsDataRoot(Map<String, dynamic> body) {
    if (!_truthyApiSuccess(body['success'])) {
      debugPrint(
          '📊 getDriverEarnings: success not true (keys=${body.keys.toList()})');
    }
    final d = body['data'];
    if (d is! Map) return {};
    Map<String, dynamic> root = Map<String, dynamic>.from(d);
    final inner = root['earnings'];
    if (inner is Map) {
      final im = Map<String, dynamic>.from(inner);
      final innerHasPeriod = im.containsKey('today') ||
          im.containsKey('week') ||
          im.containsKey('Today') ||
          im.containsKey('Week');
      final outerMissing =
          !(root.containsKey('today') || root.containsKey('week'));
      if (innerHasPeriod || outerMissing) {
        root = im;
      }
    }
    return root;
  }

  /// Parses one period object (today / week / lifetime) with varying field names.
  (double amount, int trips) _parseEarningsPeriodBucket(dynamic raw) {
    if (raw == null) return (0.0, 0);
    if (raw is num) return (_dynDouble(raw), 0);

    if (raw is List && raw.isNotEmpty) {
      return _parseEarningsPeriodBucket(raw.first);
    }

    if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);

      dynamic pickAmt() {
        const keys = [
          'amount',
          'totalAmount',
          'total_amount',
          'earning',
          'earnings',
          'total',
          'totalEarnings',
          'total_earnings',
          'driverEarnings',
          'driver_earnings',
          'gross',
          'net',
          'netAmount',
          'tripEarnings',
          'fare',
          'fareTotal',
          'payoutAmount',
          'withdrawable_amount',
        ];
        for (final k in keys) {
          final v = m[k];
          if (v != null) return v;
        }
        return null;
      }

      dynamic pickTrips() {
        const keys = [
          'trips',
          'tripCount',
          'trip_count',
          'completedTrips',
          'completed_trips',
          'rides',
          'ridesCount',
          'ride_count',
          'completedRides',
          'trip_total',
          'tripTotal',
        ];
        for (final k in keys) {
          final v = m[k];
          if (v != null) return v;
        }
        return null;
      }

      var amount = _dynDouble(pickAmt());
      var trips = _dynInt(pickTrips());

      final nest = m['stats'] ?? m['summary'];
      if (nest is Map) {
        final nm = Map<String, dynamic>.from(nest);
        if (amount <= 0) {
          for (final k in ['total', 'amount', 'totalEarnings', 'earnings']) {
            final v = nm[k];
            if (v != null) {
              amount = _dynDouble(v);
              break;
            }
          }
        }
        if (trips <= 0) {
          for (final k in ['trips', 'tripCount', 'completedTrips', 'rides']) {
            final v = nm[k];
            if (v != null) {
              trips = _dynInt(v);
              break;
            }
          }
        }
      }

      return (amount, trips);
    }
    return (0.0, 0);
  }

  /// Derives totals from trip list when aggregated earnings endpoints return zeros.
  ({
    double todayEarnings,
    int todayTrips,
    double weekEarnings,
    int weekTrips,
    double lifetimeEarnings,
    int lifetimeTrips,
  }) _rideHistoryAggregates(List<Map<String, dynamic>> rides) {
    DateTime dayOnly(DateTime d) =>
        DateTime(d.year, d.month, d.day);
    DateTime mondayWeekStart(DateTime localDay) =>
        dayOnly(localDay.subtract(Duration(days: localDay.weekday - DateTime.monday)));

    double fareOf(Map<String, dynamic> ride) => _dynDouble(
          ride['fare'] ??
              ride['driverFare'] ??
              ride['driver_fare'] ??
              ride['driverShare'] ??
              ride['driver_share'] ??
              ride['earning'] ??
              ride['driverEarnings'] ??
              ride['amount'] ??
              ride['fareAmount'],
        );

    DateTime? rideDayUtcSafe(Map<String, dynamic> ride) {
      final iso = ride['completed_at'] ??
          ride['completedAt'] ??
          ride['ended_at'] ??
          ride['endedAt'] ??
          ride['created_at'] ??
          ride['createdAt'];
      if (iso == null) return null;
      try {
        final parsed = DateTime.parse(iso.toString());
        final local = parsed.isUtc ? parsed.toLocal() : parsed;
        return dayOnly(local);
      } catch (_) {
        return null;
      }
    }

    double tEarnings = 0, wEarnings = 0, lEarnings = 0;
    int tTrips = 0, wTrips = 0;
    final now = DateTime.now();
    final todayD = dayOnly(now);
    final wkStart = mondayWeekStart(now);

    for (final r in rides) {
      final m = Map<String, dynamic>.from(r);
      final fare = fareOf(m);
      lEarnings += fare;
      final d = rideDayUtcSafe(m);
      if (d == null) continue;
      if (d == todayD) {
        tEarnings += fare;
        tTrips++;
      }
      if (!d.isBefore(wkStart)) {
        wEarnings += fare;
        wTrips++;
      }
    }

    final lTrips = rides.length;

    return (
      todayEarnings: tEarnings,
      todayTrips: tTrips,
      weekEarnings: wEarnings,
      weekTrips: wTrips,
      lifetimeEarnings: lEarnings,
      lifetimeTrips: lTrips,
    );
  }

  /// Fills `{key}` placeholders in [AppStrings] templates.
  String _localizedTemplate(String templateKey, Map<String, String> params) {
    var raw = AppStrings.get(
        templateKey, ref.read(settingsProvider).languageCode);
    params.forEach((k, v) => raw = raw.replaceAll('{$k}', v));
    return raw;
  }

  void _showEarnings() {
    double availableBalance = 0;
    double minimumWithdrawal = 0;
    bool withdrawalMinimumConfigured = false;
    bool withdrawEligibleBadge = false;
    bool isLoading = true;
    bool isRefreshing = false;
    Map<String, dynamic>? primaryAccount;
    List<Map<String, dynamic>> payoutAccounts = [];

    double modalTodayEarnings = _todayEarnings;
    int modalTodayTrips = _todayTrips;
    double modalWeekEarnings = _weekEarnings;
    int modalWeekTrips = _weekTrips;
    String modalOnlineHours = _onlineHours;
    double modalRating = _rating;
    double modalLifetimeEarnings = 0;
    int modalLifetimeTrips = 0;

    bool modalInitialFetchScheduled = false;

    int safeInt(dynamic v) => _dynInt(v);
    double safeDouble(dynamic v) => _dynDouble(v);

    double lifetimeEarningsFromEarnings(Map<String, dynamic> e) {
      for (final key in ['lifetime', 'all_time', 'allTime', 'overall']) {
        final raw = e[key];
        if (raw is Map) {
          final rm = Map<String, dynamic>.from(raw);
          final a = rm['amount'] ??
              rm['total'] ??
              rm['earnings'] ??
              rm['gross'];
          if (a != null) return safeDouble(a);
        }
      }
      final flat =
          e['lifetimeEarnings'] ?? e['lifetime_earnings'] ?? e['totalEarnings'];
      if (flat != null) return safeDouble(flat);
      return 0;
    }

    int lifetimeTripsFromEarnings(Map<String, dynamic> e) {
      for (final key in ['lifetime', 'all_time', 'allTime', 'overall']) {
        final raw = e[key];
        if (raw is Map) {
          final rm = Map<String, dynamic>.from(raw);
          final t =
              rm['trips'] ?? rm['totalTrips'] ?? rm['lifetimeTrips'];
          if (t != null) return safeInt(t);
        }
      }
      final flat = e['lifetimeTrips'] ?? e['totalTripsLifetime'];
      if (flat != null) return safeInt(flat);
      return 0;
    }

    double lifetimeEarningsFromWallet(Map<String, dynamic>? d) {
      final stats = d?['stats'];
      if (stats is! Map<String, dynamic>) return 0;
      for (final k in [
        'lifetimeEarnings',
        'totalEarnings',
        'grossLifetimeEarnings',
        'lifetime_earnings',
      ]) {
        final v = stats[k];
        if (v != null) {
          final x = safeDouble(v);
          if (x > 0) return x;
        }
      }
      return 0;
    }

    int lifetimeTripsFromWallet(Map<String, dynamic>? d) {
      final stats = d?['stats'];
      if (stats is! Map<String, dynamic>) return 0;
      for (final k in [
        'lifetimeTrips',
        'totalTripsCompleted',
        'completedTrips',
        'totalTrips',
      ]) {
        final v = stats[k];
        if (v != null) {
          final x = safeInt(v);
          if (x > 0) return x;
        }
      }
      return 0;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> fetchAllData({bool refresh = false}) async {
            if (refresh) {
              setModalState(() => isRefreshing = true);
            }

            try {
              final earningsData = await apiClient.getDriverEarnings();
              Map<String, dynamic>? walletPayload;

              final earningsPayload = _driverEarningsDataRoot(
                  Map<String, dynamic>.from(earningsData));
              debugPrint(
                  '📊 driver earnings normalized keys=${earningsPayload.keys.toList()}');
              if (earningsPayload.isNotEmpty) {
                final earnings = earningsPayload;

                final todayRaw = earnings['today'] ??
                    earnings['Today'] ??
                    earnings['daily'] ??
                    earnings['day'];
                final td = _parseEarningsPeriodBucket(todayRaw);
                if (td.$1 > 0) modalTodayEarnings = td.$1;
                if (td.$2 > 0) modalTodayTrips = td.$2;

                final weekRaw = earnings['week'] ??
                    earnings['Week'] ??
                    earnings['this_week'] ??
                    earnings['thisWeek'] ??
                    earnings['weekly'];
                final wk = _parseEarningsPeriodBucket(weekRaw);
                if (wk.$1 > 0) modalWeekEarnings = wk.$1;
                if (wk.$2 > 0) modalWeekTrips = wk.$2;

                final weekHoursSource =
                    weekRaw is Map<String, dynamic> ? weekRaw : null;
                if (weekHoursSource != null) {
                  final hrsRaw = weekHoursSource['online_hours'] ??
                      weekHoursSource['onlineHours'] ??
                      weekHoursSource['hours_online'] ??
                      weekHoursSource['hoursOnline'] ??
                      weekHoursSource['online_time'] ??
                      weekHoursSource['onlineTime'];
                  final hrs = hrsRaw?.toString().trim();
                  if (hrs != null && hrs.isNotEmpty) {
                    modalOnlineHours = hrs;
                  }
                }

                modalRating = _dynDouble(
                  earnings['rating'] ??
                      earnings['driverRating'] ??
                      earnings['avgRating'] ??
                      earnings['averageRating'],
                );
                modalLifetimeEarnings = lifetimeEarningsFromEarnings(earnings);
                modalLifetimeTrips = lifetimeTripsFromEarnings(earnings);
              }

              final walletData = await apiClient.getDriverWallet();
              if (walletData['success'] == true) {
                walletPayload = walletData['data'] as Map<String, dynamic>?;
                final data = walletPayload!;
                final dynMin = data['minimumWithdrawal'] ??
                    data['minimum_withdrawal'] ??
                    data['minWithdrawAmount'] ??
                    data['minWithdrawal'] ??
                    data['withdrawalMinimum'];
                withdrawalMinimumConfigured = dynMin != null;
                minimumWithdrawal = withdrawalMinimumConfigured
                    ? safeDouble(dynMin)
                    : 0;

                final balDyn = data['balance'];
                Map<String, dynamic>? balanceMap;
                if (balDyn is Map) {
                  balanceMap = Map<String, dynamic>.from(balDyn);
                }
                availableBalance = safeDouble(
                    balanceMap?['available'] ?? balanceMap?['balance']);

                bool explicitEligible = [
                  data['withdrawableEligible'],
                  data['withdrawable_eligible'],
                  data['isWithdrawable'],
                  data['eligibleForWithdrawal'],
                ].contains(true);

                bool balanceEligible = balanceMap != null &&
                    ([
                          balanceMap['withdrawableEligible'],
                          balanceMap['withdrawable_eligible'],
                          balanceMap['withdrawable'],
                          balanceMap['isWithdrawable'],
                        ].contains(true) ||
                        (balanceMap['withdrawableAmount'] is num &&
                            safeDouble(balanceMap['withdrawableAmount']) > 0));

                withdrawEligibleBadge = explicitEligible ||
                    balanceEligible ||
                    availableBalance > 0;

                primaryAccount = data['primaryAccount'] is Map
                    ? Map<String, dynamic>.from(data['primaryAccount'] as Map)
                    : null;

                if (modalLifetimeEarnings <= 0) {
                  final fallback = lifetimeEarningsFromWallet(walletPayload);
                  if (fallback > 0) modalLifetimeEarnings = fallback;
                }
                if (modalLifetimeTrips <= 0) {
                  final tf = lifetimeTripsFromWallet(walletPayload);
                  if (tf > 0) modalLifetimeTrips = tf;
                }
              }

              await _fetchRideHistory(modalSetState: setModalState);

              final tripAgg = _rideHistoryAggregates(_rideHistory);
              if (modalTodayEarnings <= 0 && tripAgg.todayEarnings > 0) {
                modalTodayEarnings = tripAgg.todayEarnings;
              }
              if (modalTodayTrips <= 0 && tripAgg.todayTrips > 0) {
                modalTodayTrips = tripAgg.todayTrips;
              }
              if (modalWeekEarnings <= 0 && tripAgg.weekEarnings > 0) {
                modalWeekEarnings = tripAgg.weekEarnings;
              }
              if (modalWeekTrips <= 0 && tripAgg.weekTrips > 0) {
                modalWeekTrips = tripAgg.weekTrips;
              }
              if (modalLifetimeEarnings <= 0 &&
                  tripAgg.lifetimeEarnings > 0) {
                modalLifetimeEarnings = tripAgg.lifetimeEarnings;
              }
              if (modalLifetimeTrips <= 0 && tripAgg.lifetimeTrips > 0) {
                modalLifetimeTrips = tripAgg.lifetimeTrips;
              }

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
              setModalState(() {});

              final accountsData = await apiClient.getPayoutAccounts();
              if (accountsData['success'] == true) {
                payoutAccounts = List<Map<String, dynamic>>.from(
                    accountsData['data']?['accounts'] ?? []);
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

          if (!modalInitialFetchScheduled) {
            modalInitialFetchScheduled = true;
            fetchAllData();
          }

          final showWithdrawalGate =
              withdrawalMinimumConfigured && minimumWithdrawal > 0;
          final double remainingToWithdraw = showWithdrawalGate &&
                  availableBalance < minimumWithdrawal
              ? (minimumWithdrawal - availableBalance).clamp(0.0, double.infinity)
              : 0.0;
          final double progressTowardMin = showWithdrawalGate
              ? (availableBalance / minimumWithdrawal).clamp(0.0, 1.0)
              : 1.0;
          final int pctTowardMin =
              showWithdrawalGate ? (progressTowardMin * 100).round() : 100;

          final canWithdrawNow = !isLoading &&
              availableBalance > 0 &&
              (!showWithdrawalGate ||
                  availableBalance >= minimumWithdrawal);

          const Color earningsPageBg = Color(0xFFF3F4F6);
          const Color earningsHeaderBg = Color(0xFFE9EAEC);
          const Color earningsHeroDark = Color(0xFF1A1A1A);
          const Color earningsOrangeAccent = Color(0xFFE87C35);
          const Color earningsTanIconBg = Color(0xFFD9C4AE);
          const Color logoutBorder = Color(0xFFE55B3C);

          Widget tanChevronTile({
            required IconData icon,
            required String label,
            required String value,
            required VoidCallback onTap,
            FontWeight labelFontWeight = FontWeight.w500,
            FontWeight valueFontWeight = FontWeight.w700,
            double iconSquare = 44,
            double iconSize = 22,
          }) {
            return Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: isLoading ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                  child: Row(
                    children: [
                      Container(
                        width: iconSquare,
                        height: iconSquare,
                        decoration: BoxDecoration(
                          color: earningsTanIconBg,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          icon,
                          color: const Color(0xFF5C4B3F),
                          size: iconSize,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: labelFontWeight,
                                color: const Color(0xFF1A1A1A),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: valueFontWeight,
                                color: const Color(0xFF1A1A1A),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.grey.shade400,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
              height: MediaQuery.of(context).size.height * 0.92,
              color: earningsPageBg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColoredBox(
                    color: earningsHeaderBg,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                      child: Column(
                        children: [
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: const Color(0xFFBDBFC4),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              FigmaSquareBackButton(
                                onPressed: () =>
                                    Navigator.pop(sheetContext),
                              ),
                              Expanded(
                                child: Text(
                                  ref.tr('earnings'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1A1A1A),
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed:
                                    isLoading ? null : () => fetchAllData(refresh: true),
                                icon: isRefreshing
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.refresh_rounded,
                                        color: Color(0xFF1A1A1A)),
                                tooltip: ref.tr('refresh'),
                              ),
                              IconButton(
                                onPressed: () =>
                                    Navigator.pop(sheetContext),
                                icon: const Icon(Icons.close_rounded,
                                    color: Color(0xFF1A1A1A)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isLoading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 28),
                                  child: Center(
                                    child: UberShimmer(
                                      child: UberShimmerBox(
                                        width: double.infinity,
                                        height: 220,
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(18)),
                                      ),
                                    ),
                                  ),
                                )
                              else ...[
                                Container(
                                  decoration: BoxDecoration(
                                    color: earningsHeroDark,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  padding: const EdgeInsets.fromLTRB(
                                      18, 16, 18, 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text.rich(
                                              TextSpan(
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 13,
                                                ),
                                                children: [
                                                  TextSpan(
                                                    text:
                                                        '${ref.tr('available_balance_label')} ',
                                                  ),
                                                  TextSpan(
                                                    text:
                                                        '₹${availableBalance.toStringAsFixed(2)}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (withdrawEligibleBadge)
                                            Container(
                                              padding: const EdgeInsets
                                                  .symmetric(
                                                  horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1E8449),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.verified_user_rounded,
                                                    color: Colors.white,
                                                    size: 12,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    ref.tr(
                                                        'withdrawable_label'),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 14),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  ref.tr('today_earnings'),
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '₹${modalTodayEarnings.toStringAsFixed(2)}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 34,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '$modalTodayTrips ${ref.tr('trips_completed')}',
                                                  style: const TextStyle(
                                                    color: Colors.white60,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          SizedBox(
                                            height: 86,
                                            width: 92,
                                            child: Stack(
                                              alignment:
                                                  Alignment.bottomRight,
                                              children: [
                                                Positioned(
                                                  right: 4,
                                                  bottom: 28,
                                                  child: Icon(
                                                    Icons.currency_rupee,
                                                    size: 40,
                                                    color: Colors.white
                                                        .withOpacity(0.12),
                                                  ),
                                                ),
                                                Positioned(
                                                  right: 26,
                                                  bottom: 42,
                                                  child: Icon(
                                                    Icons.currency_rupee,
                                                    size: 36,
                                                    color: Colors.white
                                                        .withOpacity(0.22),
                                                  ),
                                                ),
                                                Positioned(
                                                  right: 12,
                                                  bottom: 52,
                                                  child: Icon(
                                                    Icons.currency_rupee,
                                                    size: 32,
                                                    color: Colors.white
                                                        .withOpacity(0.35),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 18),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Expanded(
                                            child: showWithdrawalGate
                                                ? Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Row(
                                                        children: [
                                                          Expanded(
                                                            child: Text(
                                                              remainingToWithdraw >
                                                                      0
                                                                  ? _localizedTemplate(
                                                                      'withdrawal_remain_to_minimum',
                                                                      {
                                                                        'amount': remainingToWithdraw
                                                                            .toStringAsFixed(2),
                                                                      },
                                                                    )
                                                                  : ref.tr(
                                                                      'withdrawal_unlocked'),
                                                              style: const TextStyle(
                                                                color: Colors
                                                                    .white70,
                                                                fontSize: 13,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                            ),
                                                          ),
                                                          Text(
                                                            '$pctTowardMin%',
                                                            style: const TextStyle(
                                                              color:
                                                                  earningsOrangeAccent,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      const SizedBox(height: 8),
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(999),
                                                        child:
                                                            LinearProgressIndicator(
                                                          value:
                                                              progressTowardMin,
                                                          minHeight: 6,
                                                          backgroundColor: Colors
                                                              .white
                                                              .withOpacity(
                                                                  0.12),
                                                          valueColor:
                                                              const AlwaysStoppedAnimation<
                                                                  Color>(
                                                            earningsOrangeAccent,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                          const SizedBox(width: 12),
                                          Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              onTap: canWithdrawNow
                                                  ? () {
                                                      Navigator.pop(
                                                          sheetContext);
                                                      _showWithdrawSheet(
                                                          availableBalance,
                                                          minimumWithdrawal,
                                                          payoutAccounts);
                                                    }
                                                  : null,
                                              borderRadius:
                                                  BorderRadius.circular(24),
                                              child: Ink(
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                      0xFF3A3A3A),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          24),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 14,
                                                        vertical: 12),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      canWithdrawNow
                                                          ? Icons.payments_rounded
                                                          : Icons
                                                              .lock_rounded,
                                                      color: earningsOrangeAccent,
                                                      size: 18,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      ref.tr('withdraw'),
                                                      style: TextStyle(
                                                        color:
                                                            earningsOrangeAccent,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              const SizedBox(height: 22),
                              Text(
                                ref.tr('this_week'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  tanChevronTile(
                                    icon: Icons.trending_up_rounded,
                                    label: ref.tr('total_earnings'),
                                    value:
                                        '₹${modalWeekEarnings.toStringAsFixed(0)}',
                                    onTap: () => _showTransactionHistory(
                                        overlayContext: sheetContext),
                                  ),
                                  const SizedBox(height: 10),
                                  tanChevronTile(
                                    icon: Icons.directions_car_rounded,
                                    label: ref.tr('total_trips'),
                                    value: '$modalWeekTrips',
                                    onTap: () => _showRideHistory(
                                        overlayContext: sheetContext,
                                        modalSetState: setModalState),
                                  ),
                                  const SizedBox(height: 10),
                                  tanChevronTile(
                                    icon: Icons.schedule_rounded,
                                    label: ref.tr('online_hours'),
                                    value: modalOnlineHours.isEmpty
                                        ? ref.tr(
                                            'online_hours_not_reported')
                                        : modalOnlineHours,
                                    onTap: () {
                                      if (isLoading) return;
                                      showDialog<void>(
                                        context: sheetContext,
                                        builder: (dCtx) => AlertDialog(
                                          title:
                                              Text(ref.tr('online_hours')),
                                          content: Text(modalOnlineHours),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dCtx),
                                              child: Text(ref.tr('ok')),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  tanChevronTile(
                                    icon: Icons.star_rounded,
                                    label: ref.tr('rating'),
                                    value:
                                        '${modalRating.toStringAsFixed(1)}',
                                    onTap: () {
                                      if (isLoading) return;
                                      showDialog<void>(
                                        context: sheetContext,
                                        builder: (dCtx) => AlertDialog(
                                          title: Text(ref.tr('rating')),
                                          content: Text(
                                            _localizedTemplate(
                                              'rating_star_display',
                                              {
                                                'rating': modalRating
                                                    .toStringAsFixed(1),
                                              },
                                            ),
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dCtx),
                                              child: Text(ref.tr('ok')),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),

                              const SizedBox(height: 22),
                              Text(
                                ref.tr('lifetime_heading'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  tanChevronTile(
                                    icon: Icons.shopping_bag_outlined,
                                    label: ref.tr('total_earnings'),
                                    value:
                                        '₹${modalLifetimeEarnings.toStringAsFixed(0)}',
                                    iconSquare: 40,
                                    iconSize: 26,
                                    onTap: () => _showTransactionHistory(
                                        overlayContext: sheetContext),
                                  ),
                                  const SizedBox(height: 10),
                                  tanChevronTile(
                                    icon: Icons.directions_car_rounded,
                                    label: ref.tr('total_trips'),
                                    value: '$modalLifetimeTrips',
                                    iconSquare: 40,
                                    iconSize: 26,
                                    onTap: () => _showRideHistory(
                                        overlayContext: sheetContext,
                                        modalSetState: setModalState),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              Text(
                                ref.tr('payment_settings'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (primaryAccount != null)
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                        color: const Color(0xFF43A047),
                                        width: 1),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF43A047)
                                              .withOpacity(0.1),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          primaryAccount!['accountType'] ==
                                                  'UPI'
                                              ? Icons.account_balance_wallet
                                              : Icons.account_balance,
                                          color: const Color(0xFF43A047),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              primaryAccount!['accountType'] ==
                                                      'UPI'
                                                  ? _localizedTemplate(
                                                      'payment_upi_line',
                                                      {
                                                        'upi':
                                                            '${primaryAccount!['upiId'] ?? ''}',
                                                      },
                                                    )
                                                  : _localizedTemplate(
                                                      'payment_bank_account_line',
                                                      {
                                                        'bank':
                                                            '${primaryAccount!['bankName'] ?? ''}',
                                                        'account':
                                                            '${primaryAccount!['accountNumber'] ?? ''}',
                                                      },
                                                    ),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              children: [
                                                const Icon(Icons.check_circle,
                                                    size: 14,
                                                    color:
                                                        Color(0xFF43A047)),
                                                const SizedBox(width: 4),
                                                Text(
                                                  primaryAccount!['isVerified'] ==
                                                          true
                                                      ? ref.tr('verified')
                                                      : ref.tr(
                                                          'primary_account_label'),
                                                  style: const TextStyle(
                                                      fontSize: 12,
                                                      color:
                                                          Color(0xFF43A047)),
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
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.warning_amber_rounded,
                                          color: Color(0xFFFF9800)),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          ref.tr('add_payment_desc'),
                                          style:
                                              Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      _showPaymentMethodsSheet(
                                          overlayContext: sheetContext),
                                  icon: const Icon(Icons.settings_rounded),
                                  label:
                                      Text(ref.tr('manage_payment_methods')),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    backgroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Center(
                                child: TextButton.icon(
                                  onPressed: () =>
                                      _showTransactionHistory(
                                          overlayContext: sheetContext),
                                  icon: const Icon(Icons.history_rounded,
                                      size: 20),
                                  label: Text(ref.tr(
                                      'view_transaction_history')),
                                ),
                              ),
                            ],
                          ),
                        ),

                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.fromLTRB(
                              16,
                              12,
                              16,
                              12 + MediaQuery.of(context).padding.bottom,
                            ),
                            decoration: BoxDecoration(
                              color: earningsPageBg,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.06),
                                  offset: const Offset(0, -4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                WidgetsBinding.instance.addPostFrameCallback(
                                    (_) {
                                  if (!mounted) return;
                                  _showLogoutConfirmation();
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14),
                                side: const BorderSide(
                                    color: logoutBorder,
                                    width: 1),
                                foregroundColor: logoutBorder,
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.logout_rounded,
                                      color: logoutBorder.withOpacity(
                                          .95)),
                                  const SizedBox(width: 8),
                                  Text(
                                    ref.tr('logout'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Withdrawal Sheet
  void _showWithdrawSheet(double availableBalance, double minimumWithdrawal,
      List<Map<String, dynamic>> accounts) {
    final TextEditingController amountController = TextEditingController();
    String? selectedAccountId;
    bool isProcessing = false;
    String? errorMessage;

    // Pre-capture translations for StatefulBuilder
    final trWithdrawMoney = ref.tr('withdraw_money');
    final trAll = ref.tr('all');
    final trTransferTo = ref.tr('transfer_to');
    final trAddPaymentFirst = ref.tr('add_payment_method_first');
    final trWithdraw = ref.tr('withdraw');
    final trWithdrawalInitiated = ref.tr('withdrawal_initiated');
    final trAvailableLine = _localizedTemplate('withdraw_available_line', {
      'amount': availableBalance.toStringAsFixed(2),
    });
    final trMinWithdrawLine =
        _localizedTemplate('minimum_withdrawal_line', {
      'amount': minimumWithdrawal.toStringAsFixed(0),
    });
    final trInsufficientBalance = ref.tr('withdraw_insufficient_balance');
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
                  FigmaSquareBackButton(
  onPressed: () => Navigator.pop(context),
),
                  Text(
                    trWithdrawMoney,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Available Balance
              Text(
                trAvailableLine,
                style: const TextStyle(fontSize: 16, color: Color(0xFF666666)),
              ),
              const SizedBox(height: 16),

              // Amount Input
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w600),
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
                  _buildQuickAmountButton('₹500', 500, amountController,
                      setModalState, availableBalance),
                  const SizedBox(width: 8),
                  _buildQuickAmountButton('₹1000', 1000, amountController,
                      setModalState, availableBalance),
                  const SizedBox(width: 8),
                  _buildQuickAmountButton('₹2000', 2000, amountController,
                      setModalState, availableBalance),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        amountController.text =
                            availableBalance.toStringAsFixed(0);
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(trAll),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Transfer To Section
              if (accounts.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      trTransferTo,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _showManagePaymentMethodsSheet();
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add New'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF1A73E8),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...accounts.map((account) => RadioListTile<String>(
                      value: account['id'],
                      groupValue: selectedAccountId,
                      onChanged: (value) =>
                          setModalState(() => selectedAccountId = value),
                      title: Text(
                        account['accountType'] == 'UPI'
                            ? 'UPI: ${account['upiId']}'
                            : '${account['bankName']} ****${_maskAccountNumber(account['accountNumber'])}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        account['accountType'] == 'UPI'
                            ? 'Instant transfer'
                            : '1-2 business days',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF888888)),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.warning_amber, color: Color(0xFFFF9800)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(trAddPaymentFirst),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                _showAddUpiSheet();
                              },
                              icon: const Icon(Icons.account_balance_wallet, size: 18),
                              label: const Text('Add UPI'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1A1A1A),
                                padding: const EdgeInsets.symmetric(vertical: 12),
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
                              icon: const Icon(Icons.account_balance, size: 18),
                              label: const Text('Add Bank'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1A1A1A),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
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
                          final amount =
                              double.tryParse(amountController.text) ?? 0;

                          if (minimumWithdrawal > 0 &&
                              amount < minimumWithdrawal) {
                            setModalState(() =>
                                errorMessage = trMinWithdrawLine);
                            return;
                          }

                          if (amount > availableBalance) {
                            setModalState(() =>
                                errorMessage = trInsufficientBalance);
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
                                  content: Text(
                                      trWithdrawalInitiated.replaceAll(
                                          '{amount}',
                                          amount.toStringAsFixed(0))),
                                  backgroundColor: const Color(0xFF4CAF50),
                                ),
                              );
                            } else {
                              setModalState(() {
                                errorMessage =
                                    result['message'] ?? 'Withdrawal failed';
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
                      ? const UberShimmer(
                          baseColor: Color(0x88FFFFFF),
                          highlightColor: Color(0xFFFFFFFF),
                          child: UberShimmerBox(
                            width: 140,
                            height: 14,
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                        )
                      : Text(
                          trWithdraw,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickAmountButton(
      String label,
      double amount,
      TextEditingController controller,
      StateSetter setModalState,
      double maxAmount) {
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
  void _showPaymentMethodsSheet({BuildContext? overlayContext}) {
    List<Map<String, dynamic>> accounts = [];
    bool isLoading = true;

    final sheetContextForModal = overlayContext ?? context;

    // Pre-capture translations for StatefulBuilder
    final trPaymentMethods = ref.tr('payment_methods');
    final trNoPaymentMethods = ref.tr('no_payment_methods');
    final trAddPaymentDesc = ref.tr('add_payment_desc');
    final trSetAsPrimary = ref.tr('set_as_primary');
    final trDelete = ref.tr('delete');
    final trAddUpi = ref.tr('add_upi');
    final trAddBank = ref.tr('add_bank');

    showModalBottomSheet(
      context: sheetContextForModal,
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
                  accounts = List<Map<String, dynamic>>.from(
                      data['data']?['accounts'] ?? []);
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
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewPaddingOf(context).bottom,
            ),
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
                      trPaymentMethods,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600),
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
                  const UberShimmer(
                    child: Column(
                      children: [
                        UberShimmerBox(width: double.infinity, height: 54),
                        SizedBox(height: 12),
                        UberShimmerBox(width: double.infinity, height: 54),
                        SizedBox(height: 12),
                        UberShimmerBox(width: double.infinity, height: 54),
                      ],
                    ),
                  )
                else ...[
                  // Existing Accounts
                  if (accounts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.account_balance_wallet_outlined,
                              size: 48, color: Color(0xFF888888)),
                          const SizedBox(height: 12),
                          Text(
                            trNoPaymentMethods,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            trAddPaymentDesc,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF888888)),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        account['accountType'] == 'UPI'
                                            ? account['upiId'] ?? 'UPI'
                                            : '${account['bankName']} ${account['accountNumber']}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      if (account['isPrimary'] == true)
                                        const Text(
                                          'Primary',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF4CAF50)),
                                        ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) async {
                                    if (value == 'primary') {
                                      try {
                                        await apiClient.setPrimaryPayoutAccount(
                                            account['id']);
                                        setModalState(() => isLoading = true);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                                content: Text('Error: $e')),
                                          );
                                        }
                                      }
                                    } else if (value == 'delete') {
                                      try {
                                        await apiClient
                                            .deletePayoutAccount(account['id']);
                                        setModalState(() => isLoading = true);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                                content: Text('Error: $e')),
                                          );
                                        }
                                      }
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (account['isPrimary'] != true)
                                      PopupMenuItem(
                                        value: 'primary',
                                        child: Text(trSetAsPrimary),
                                      ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text(trDelete,
                                          style: const TextStyle(
                                              color: Colors.red)),
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
                          label: Text(trAddUpi),
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
                          label: Text(trAddBank),
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

  // Helper to mask account number (show last 4 digits)
  String _maskAccountNumber(String? accountNumber) {
    if (accountNumber == null || accountNumber.length < 4) {
      return accountNumber ?? '';
    }
    return accountNumber.substring(accountNumber.length - 4);
  }

  // Manage Payment Methods Sheet
  void _showManagePaymentMethodsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewPaddingOf(context).bottom,
          ),
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
                  FigmaSquareBackButton(
  onPressed: () => Navigator.pop(context),
),
                  const Text(
                    'Payment Methods',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              
              // Add Payment Method Options
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Add a new payment method',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF666666),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildPaymentMethodCard(
                            icon: Icons.account_balance_wallet,
                            title: 'UPI ID',
                            subtitle: 'Instant transfer',
                            onTap: () {
                              Navigator.pop(context);
                              _showAddUpiSheet();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildPaymentMethodCard(
                            icon: Icons.account_balance,
                            title: 'Bank Account',
                            subtitle: '1-2 business days',
                            onTap: () {
                              Navigator.pop(context);
                              _showAddBankSheet();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              
              const Text(
                'Your saved methods',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF666666),
                ),
              ),
              const SizedBox(height: 12),
              
              // List of saved accounts will be fetched
              Expanded(
                child: FutureBuilder<Map<String, dynamic>>(
                  future: apiClient.getPayoutAccounts(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    
                    if (!snapshot.hasData || snapshot.data?['success'] != true) {
                      return const Center(
                        child: Text('Failed to load payment methods'),
                      );
                    }
                    
                    final accounts = List<Map<String, dynamic>>.from(
                      snapshot.data?['data']?['accounts'] ?? [],
                    );
                    
                    if (accounts.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 48,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No payment methods added yet',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    
                    return ListView.builder(
                      controller: scrollController,
                      itemCount: accounts.length,
                      itemBuilder: (context, index) {
                        final account = accounts[index];
                        final isUpi = account['accountType'] == 'UPI';
                        final isPrimary = account['isPrimary'] == true;
                        
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isPrimary 
                                  ? const Color(0xFF4CAF50) 
                                  : const Color(0xFFE0E0E0),
                              width: isPrimary ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isUpi 
                                      ? const Color(0xFFE3F2FD) 
                                      : const Color(0xFFF3E5F5),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  isUpi 
                                      ? Icons.account_balance_wallet 
                                      : Icons.account_balance,
                                  color: isUpi 
                                      ? const Color(0xFF1976D2) 
                                      : const Color(0xFF7B1FA2),
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          isUpi 
                                              ? account['upiId'] ?? 'UPI' 
                                              : account['bankName'] ?? 'Bank',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (isPrimary) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFE8F5E9),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              'Primary',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Color(0xFF4CAF50),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      isUpi 
                                          ? 'Instant transfer' 
                                          : '****${_maskAccountNumber(account['accountNumber'])}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF888888),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!isPrimary)
                                TextButton(
                                  onPressed: () async {
                                    try {
                                      await apiClient.setPrimaryPayoutAccount(
                                        account['id'],
                                      );
                                      if (context.mounted) {
                                        Navigator.pop(context);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Primary account updated'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        AppMessenger.showDriverErrorBanner(context, 'Failed: $e');
                                      }
                                    }
                                  },
                                  child: const Text(
                                    'Set Primary',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Payment method card widget
  Widget _buildPaymentMethodCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 28, color: const Color(0xFF1A1A1A)),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF888888),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _looksLikeTechnicalPayoutMessage(String text) {
    final l = text.toLowerCase();
    return l.contains('dioexception') ||
        (l.contains('dio') && l.contains('exception')) ||
        l.contains('bad response') ||
        l.contains('socketexception') ||
        l.contains('xmlhttprequest') ||
        text.length > 220;
  }

  /// User-facing inline error when saving UPI (no Dio stack traces).
  String _driverUpiSaveUserMessage({
    Map<String, dynamic>? apiResult,
    Object? caught,
  }) {
    if (apiResult != null) {
      for (final key in ['message', 'error', 'msg']) {
        final v = apiResult[key];
        if (v != null) {
          final t = v.toString().trim();
          if (t.isNotEmpty && !_looksLikeTechnicalPayoutMessage(t)) {
            return t;
          }
        }
      }
    }
    if (caught != null) {
      final ls = caught.toString().toLowerCase();
      if (ls.contains('connection') ||
          ls.contains('socket') ||
          ls.contains('timed out') ||
          ls.contains('network is unreachable')) {
        return ref.tr('network_error_retry');
      }
    }
    return ref.tr('enter_valid_upi');
  }

  // Add UPI Sheet
  void _showAddUpiSheet() {
    final TextEditingController upiController = TextEditingController();
    bool isAdding = false;
    String? errorMessage;

    // Pre-capture translations
    final trAddUpiId = ref.tr('add_upi_id');
    final trUpiId = ref.tr('upi_id');
    final trUpiHint = ref.tr('upi_hint');
    final trUpiExample = ref.tr('upi_example');
    final trUpiAdded = ref.tr('upi_added');

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
              Text(
                trAddUpiId,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: upiController,
                decoration: InputDecoration(
                  labelText: trUpiId,
                  hintText: trUpiHint,
                  prefixIcon: const Icon(Icons.account_balance_wallet),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  errorText: errorMessage,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                trUpiExample,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
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
                            setModalState(
                                () =>
                                    errorMessage = ref.tr('invalid_upi_format'));
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
                                SnackBar(
                                  content: Text(trUpiAdded),
                                  backgroundColor: const Color(0xFF4CAF50),
                                ),
                              );
                            } else {
                              setModalState(() {
                                errorMessage = _driverUpiSaveUserMessage(
                                  apiResult: result,
                                  caught: null,
                                );
                                isAdding = false;
                              });
                            }
                          } catch (e) {
                            setModalState(() {
                              errorMessage = _driverUpiSaveUserMessage(
                                apiResult: null,
                                caught: e,
                              );
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
                      ? const UberShimmer(
                          baseColor: Color(0x88FFFFFF),
                          highlightColor: Color(0xFFFFFFFF),
                          child: UberShimmerBox(
                            width: 120,
                            height: 14,
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                        )
                      : Text(
                          trAddUpiId,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white),
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

    // Pre-capture translations
    final trAddBankAccount = ref.tr('add_bank_account');
    final trAccountHolderName = ref.tr('account_holder_name');
    final trBankName = ref.tr('bank_name');
    final trAccountNumber = ref.tr('account_number');
    final trIfscCode = ref.tr('ifsc_code');
    final trAddBankBtn = ref.tr('add_bank_account');
    final trBankAdded = ref.tr('bank_added');

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
                Text(
                  trAddBankAccount,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600),
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
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(errorMessage!,
                                style: const TextStyle(color: Colors.red))),
                      ],
                    ),
                  ),
                TextField(
                  controller: holderNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: trAccountHolderName,
                    prefixIcon: const Icon(Icons.person),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: bankNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: trBankName,
                    hintText: 'e.g., HDFC Bank',
                    prefixIcon: const Icon(Icons.account_balance),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: accountNumberController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: trAccountNumber,
                    prefixIcon: const Icon(Icons.numbers),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ifscController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: trIfscCode,
                    hintText: 'e.g., HDFC0001234',
                    prefixIcon: const Icon(Icons.code),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
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
                              setModalState(() =>
                                  errorMessage = 'Please fill all fields');
                              return;
                            }

                            final ifsc =
                                ifscController.text.trim().toUpperCase();
                            if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$')
                                .hasMatch(ifsc)) {
                              setModalState(() =>
                                  errorMessage = 'Invalid IFSC code format');
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
                                accountNumber:
                                    accountNumberController.text.trim(),
                                ifscCode: ifsc,
                                accountHolderName:
                                    holderNameController.text.trim(),
                              );

                              if (result['success'] == true &&
                                  context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(trBankAdded),
                                    backgroundColor: const Color(0xFF4CAF50),
                                  ),
                                );
                              } else {
                                setModalState(() {
                                  errorMessage = result['message'] ??
                                      'Failed to add bank account';
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
                        ? const UberShimmer(
                            baseColor: Color(0x88FFFFFF),
                            highlightColor: Color(0xFFFFFFFF),
                            child: UberShimmerBox(
                              width: 120,
                              height: 14,
                              borderRadius:
                                  BorderRadius.all(Radius.circular(8)),
                            ),
                          )
                        : Text(
                            trAddBankBtn,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white),
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
  void _showTransactionHistory({BuildContext? overlayContext}) {
    List<Map<String, dynamic>> transactions = [];
    bool isLoading = true;
    int currentPage = 1;
    bool hasMore = true;

    final sheetContextForModal = overlayContext ?? context;

    // Pre-capture translations
    final trTransactionHistory = ref.tr('transaction_history');
    final trNoTransactions = ref.tr('no_transactions_yet');

    showModalBottomSheet(
      context: sheetContextForModal,
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
                  hasMore = pagination != null &&
                      currentPage < (pagination['totalPages'] ?? 1);
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
                    Text(
                      trTransactionHistory,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600),
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
                  const Expanded(
                    child: Center(
                      child: UberShimmer(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            UberShimmerBox(width: 180, height: 14),
                            SizedBox(height: 10),
                            UberShimmerBox(width: 140, height: 12),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (transactions.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.receipt_long_outlined,
                              size: 64, color: Color(0xFF888888)),
                          const SizedBox(height: 16),
                          Text(trNoTransactions,
                              style: const TextStyle(
                                  fontSize: 16, color: Color(0xFF888888))),
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
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: UberShimmer(
                                child: UberShimmerBox(
                                  width: 120,
                                  height: 12,
                                  borderRadius:
                                      BorderRadius.all(Radius.circular(8)),
                                ),
                              ),
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
                                      tx['description'] ??
                                          type.replaceAll('_', ' '),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      _formatDate(tx['createdAt']),
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF888888)),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '${isCredit ? '+' : ''}₹${amount.abs().toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: isCredit
                                      ? const Color(0xFF4CAF50)
                                      : Colors.red,
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          final settings = ref.watch(settingsProvider);
          final settingsNotifier = ref.read(settingsProvider.notifier);
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final bottomSafe = MediaQuery.viewPaddingOf(sheetContext).bottom;
          final h = MediaQuery.sizeOf(sheetContext).height * 0.7;

          return Padding(
            padding: EdgeInsets.only(bottom: bottomSafe),
            child: SizedBox(
              height: h,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF444444)
                              : const Color(0xFFE0E0E0),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          settingsNotifier.tr('settings'),
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                              (value) =>
                                  settingsNotifier.setLocationSharing(value),
                              isDark,
                            ),
                            // Language selector
                            _buildSettingsTileWithAction(
                              Icons.language,
                              settingsNotifier.tr('language'),
                              resolveAppLanguage(settings.languageCode)
                                  .nativeName,
                              () => _showLanguageSelector(),
                              isDark,
                            ),
                            _buildSettingsTileWithAction(
                              Icons.description_outlined,
                              settingsNotifier.tr('update_documents'),
                              settingsNotifier.tr('update_documents_desc'),
                              () {
                                Navigator.pop(sheetContext);
                                context.push(
                                  '${AppRoutes.driverOnboarding}?isUpdateMode=true&returnToProfile=true',
                                );
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
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
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
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSettingsToggle(IconData icon, String title, String subtitle,
      bool value, Function(bool) onChanged, bool isDark) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF666666),
            size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(
              fontSize: 12,
              color:
                  isDark ? const Color(0xFF888888) : const Color(0xFF888888))),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFFD4956A),
      ),
    );
  }

  Widget _buildSettingsTileWithAction(IconData icon, String title,
      String subtitle, VoidCallback onTap, bool isDark) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF666666),
            size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(
              fontSize: 12,
              color:
                  isDark ? const Color(0xFF888888) : const Color(0xFF888888))),
      trailing: Icon(Icons.chevron_right,
          color: isDark ? const Color(0xFF666666) : const Color(0xFFCCCCCC)),
      onTap: onTap,
    );
  }

  void _showLanguageSelector() {
    final hostContext = context;
    showDialog(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (_, ref, __) {
          final settings = ref.watch(settingsProvider);
          final settingsNotifier = ref.read(settingsProvider.notifier);

          return AlertDialog(
            title: Text(settingsNotifier.tr('language')),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: supportedLanguages.length,
                itemBuilder: (_, index) {
                  final lang = supportedLanguages[index];
                  final isSelected = settings.languageCode == lang.code;
                  return ListTile(
                    title: Text(lang.name),
                    subtitle: Text(
                      lang.nativeName,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: Color(0xFFD4956A))
                        : null,
                    onTap: () async {
                      if (isSelected) {
                        Navigator.of(dialogContext).pop();
                        return;
                      }

                      await settingsNotifier.setLanguage(lang.code, lang.name);
                      await ref
                          .read(driverOnboardingProvider.notifier)
                          .setLanguage(lang.code)
                          .catchError((_) => false);

                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }

                      if (!hostContext.mounted) return;

                      final messenger =
                          ScaffoldMessenger.maybeOf(hostContext);
                      messenger?.hideCurrentSnackBar();
                      messenger?.showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                          backgroundColor:
                              Colors.black.withValues(alpha: 0.82),
                          content: Text(
                            settingsNotifier.tr('language_saved'),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      );
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
    final trRaahiDriver = ref.tr('raahi_driver');
    final trVersion = ref.tr('version');
    final trAppDescription = ref.tr('app_description');
    final trCopyright = ref.tr('copyright');
    final trClose = ref.tr('close');
    final trTermsPrivacy = ref.tr('terms_privacy');
    final trOpeningTerms = ref.tr('opening_terms');

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
                child: Text('R',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20)),
              ),
            ),
            const SizedBox(width: 12),
            Text(trRaahiDriver),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(trVersion),
            const SizedBox(height: 8),
            Text(trAppDescription,
                style: const TextStyle(color: Color(0xFF888888))),
            const SizedBox(height: 16),
            Text(trCopyright,
                style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(trClose),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              AppMessenger.showDriverErrorBanner(context, trOpeningTerms);
            },
            child: Text(trTermsPrivacy),
          ),
        ],
      ),
    );
  }

  void _showHelpSupport() {
    final trHelpSupport = ref.tr('help_support');
    final trContactSupport = ref.tr('contact_support');
    final trGetHelp = ref.tr('get_help');
    final trFaqs = ref.tr('faqs');
    final trFindAnswers = ref.tr('find_answers');
    final trReportIssue = ref.tr('report_issue');
    final trLetUsKnow = ref.tr('let_us_know');
    final trSendFeedback = ref.tr('send_feedback');
    final trHelpImprove = ref.tr('help_improve');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final h = MediaQuery.sizeOf(sheetContext).height * 0.62;
        final bottomSafe = MediaQuery.viewPaddingOf(sheetContext).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottomSafe),
          child: SizedBox(
            height: h,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
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
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          trHelpSupport,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHelpTileWithAction(
                            Icons.headset_mic,
                            trContactSupport,
                            trGetHelp,
                            _showContactSupport,
                          ),
                          _buildHelpTileWithAction(
                            Icons.article_outlined,
                            trFaqs,
                            trFindAnswers,
                            _showFAQs,
                          ),
                          _buildHelpTileWithAction(
                            Icons.report_problem_outlined,
                            trReportIssue,
                            trLetUsKnow,
                            _showReportIssue,
                          ),
                          _buildHelpTileWithAction(
                            Icons.feedback_outlined,
                            trSendFeedback,
                            trHelpImprove,
                            _showFeedback,
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHelpTileWithAction(
      IconData icon, String title, String subtitle, VoidCallback onTap) {
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
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
      onTap: onTap,
    );
  }

  void _showContactSupport() {
    final trContactSupport = ref.tr('contact_support');
    final trLiveChat = ref.tr('live_chat');
    final trChatWithAgent = ref.tr('chat_with_agent');
    final trOpeningChat = ref.tr('opening_chat');
    final trEmailSupport = ref.tr('email_support');
    final trOpeningEmail = ref.tr('opening_email');
    final trCallSupport = ref.tr('call_support');
    final trDialingSupport = ref.tr('dialing_support');
    final trClose = ref.tr('close');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trContactSupport),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat, color: Color(0xFFD4956A)),
              title: Text(trLiveChat),
              subtitle: Text(trChatWithAgent),
              onTap: () {
                Navigator.pop(context);
                AppMessenger.showDriverErrorBanner(context, trOpeningChat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.email, color: Color(0xFFD4956A)),
              title: Text(trEmailSupport),
              subtitle: const Text('support@raahi.com'),
              onTap: () {
                Navigator.pop(context);
                AppMessenger.showDriverErrorBanner(context, trOpeningEmail);
              },
            ),
            ListTile(
              leading: const Icon(Icons.phone, color: Color(0xFFD4956A)),
              title: Text(trCallSupport),
              subtitle: const Text('1800-123-4567'),
              onTap: () {
                Navigator.pop(context);
                AppMessenger.showDriverErrorBanner(context, trDialingSupport);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(trClose)),
        ],
      ),
    );
  }

  void _showFAQs() {
    final faqs = [
      {
        'q': 'How do I start accepting rides?',
        'a': 'Tap "Start Ride" to go online and accept ride requests.'
      },
      {
        'q': 'How are earnings calculated?',
        'a': 'Earnings include base fare + distance + time charges.'
      },
      {
        'q': 'What if a rider cancels?',
        'a':
            'You may receive a cancellation fee depending on the circumstances.'
      },
      {
        'q': 'How do I update my documents?',
        'a':
            'Open menu > Update Documents, or go to Settings > Update Documents.'
      },
      {
        'q': 'When are payments credited?',
        'a': 'Payments are credited to your account within 24-48 hours.'
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
              decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Frequently Asked Questions',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: faqs.length,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemBuilder: (context, index) {
                  return ExpansionTile(
                    title: Text(faqs[index]['q']!,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    children: [
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(faqs[index]['a']!))
                    ],
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

    // Pre-capture translations
    final trReportIssue = ref.tr('report_issue');
    final trCategory = ref.tr('category');
    final trDescribeIssue = ref.tr('describe_issue');
    final trDescribePlaceholder = ref.tr('describe_issue_placeholder');
    final trCancel = ref.tr('cancel');
    final trSubmit = ref.tr('submit');
    final trIssueReported = ref.tr('issue_reported');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(trReportIssue),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(trCategory,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: [
                    'App Issue',
                    'Payment Issue',
                    'Ride Issue',
                    'Account Issue',
                    'Other'
                  ]
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => selectedCategory = v!),
                ),
                const SizedBox(height: 16),
                Text(trDescribeIssue,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                TextField(
                  controller: issueController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: trDescribePlaceholder,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: Text(trCancel)),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                AppMessenger.showDriverErrorBanner(context, trIssueReported);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD4956A)),
              child:
                  Text(trSubmit, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showFeedback() {
    int rating = 0;
    final TextEditingController feedbackController = TextEditingController();

    // Pre-capture translations
    final trSendFeedback = ref.tr('send_feedback');
    final trRateExperience = ref.tr('rate_experience');
    final trTellUsMore = ref.tr('tell_us_more');
    final trCancel = ref.tr('cancel');
    final trSubmit = ref.tr('submit');
    final trFeedbackThanks = ref.tr('feedback_thanks');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(trSendFeedback),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(trRateExperience),
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
                    hintText: trTellUsMore,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: Text(trCancel)),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                AppMessenger.showDriverErrorBanner(context, trFeedbackThanks);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD4956A)),
              child:
                  Text(trSubmit, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogoutConfirmation() {
    final trLogout = ref.tr('logout');
    final trLogoutConfirm = ref.tr('logout_confirm');
    final trCancel = ref.tr('cancel');

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(trLogout),
        content: Text(trLogoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(trCancel),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await ref.read(authStateProvider.notifier).signOut();
              if (!mounted) return;
              context.go(AppRoutes.login);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(trLogout, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _DriverDrawerMenuItem extends StatelessWidget {
  const _DriverDrawerMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailingValue,
    this.isLoadingTrailing = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? trailingValue;
  final bool isLoadingTrailing;

  static const _iconTone = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.black12,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F5F0),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color:
                        const Color(0xFFE8E0D4).withValues(alpha: 0.8),
                    width: 0.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: _iconTone, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        height: 1.2,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isLoadingTrailing)
                const SizedBox(
                  width: 28,
                  height: 24,
                  child: UberShimmer(
                    child: UberShimmerBox(width: 28, height: 18),
                  ),
                )
              else if (trailingValue != null)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Text(
                    trailingValue!,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
              Icon(
                Icons.chevron_right_rounded,
                color: const Color(0xFF1A1A1A).withValues(alpha: 0.45),
                size: 22,
              ),
            ],
          ),
        ),
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
  final bool isPenalty;
  /// When true, call penalty status API and show wallet/UPI flow if a penalty exists.
  final bool offerPenaltyResolution;

  const _BackendError({
    required this.title,
    required this.body,
    required this.cta,
    required this.allowRetry,
    required this.affectsEligibility,
    this.isPenalty = false,
    this.offerPenaltyResolution = false,
  });
}
