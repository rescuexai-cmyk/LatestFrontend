import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/settings_provider.dart';
import 'core/models/user.dart';
import 'core/services/server_config_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/router/app_routes.dart';
import 'features/auth/providers/auth_provider.dart';
import 'features/driver/providers/driver_rides_provider.dart';
import 'features/ride/providers/ride_booking_provider.dart';
// supportedLanguages is already exported from settings_provider.dart

/// Handle background messages (must be top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📬 Background message: ${message.messageId}');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase must be initialized before any Firebase API (including background handler).
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e, st) {
    debugPrint('❌ Firebase init in main failed: $e\n$st');
  }

  // Catch widget build errors (prevents blank screen from uncaught exceptions)
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                details.exceptionAsString(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  };

  // ProviderScope at top so every widget in the tree can access Riverpod providers.
  // Firebase init happens asynchronously in _AppInitializer.
  runApp(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: const Color(0xFFF6EFE4),
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD4956A)),
        ),
        home: _AppInitializer(),
      ),
    ),
  );
}

/// Shows splash during init, then the real app or error screen.
class _AppInitializer extends StatefulWidget {
  @override
  State<_AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<_AppInitializer> {
  String? _initError;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  /// Initialize Firebase App Check for seamless phone authentication
  /// This enables Play Integrity on Android to avoid reCAPTCHA fallback
  Future<void> _initializeAppCheck() async {
    try {
      // Check if running on emulator (App Check may not work properly)
      final isEmulator = Platform.isAndroid && await _isRunningOnEmulator();
      if (isEmulator) {
        debugPrint('⚠️ Running on emulator - App Check may trigger reCAPTCHA fallback');
      }
      
      // Activate App Check with Play Integrity (Android) or Device Check (iOS)
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
        appleProvider: AppleProvider.deviceCheck,
      );
      debugPrint('✅ Firebase App Check activated (Play Integrity)');
      
      // Listen for token changes (useful for debugging)
      FirebaseAppCheck.instance.onTokenChange.listen((token) {
        if (token != null) {
          debugPrint('🔐 App Check token refreshed (length: ${token.length})');
        }
      });
    } catch (e) {
      // App Check failure should not block the app - phone auth will fall back to reCAPTCHA
      debugPrint('⚠️ Firebase App Check activation failed: $e');
      debugPrint('⚠️ Phone auth will use reCAPTCHA fallback');
    }
  }
  
  /// Check if running on Android emulator
  Future<bool> _isRunningOnEmulator() async {
    if (!Platform.isAndroid) return false;
    try {
      // Common emulator indicators
      final brand = Platform.environment['BRAND'] ?? '';
      final device = Platform.environment['DEVICE'] ?? '';
      final model = Platform.environment['MODEL'] ?? '';
      final product = Platform.environment['PRODUCT'] ?? '';
      
      return brand.contains('generic') ||
             device.contains('generic') ||
             model.contains('sdk') ||
             model.contains('Emulator') ||
             product.contains('sdk') ||
             product.contains('emulator');
    } catch (e) {
      return false;
    }
  }

  Future<void> _initialize() async {
    try {
      // Background handler is registered once in main(); avoid duplicate registration here.
      // Run init with 12s timeout to prevent blank screen if push/server hangs
      await _runInitWithTimeout();
    } catch (e, stack) {
      debugPrint('❌ App init error: $e');
      debugPrint('$stack');
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _ready = true;
        });
      }
    }
  }

  Future<void> _runInitWithTimeout() async {
    const timeout = Duration(seconds: 12);
    try {
      await _doInit().timeout(timeout);
    } on TimeoutException {
      debugPrint('⚠️ Init timed out after 12s, showing app anyway');
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _doInit() async {
    // Firebase is initialized in main(); ensure app is ready if init was deferred
    if (Firebase.apps.isEmpty) {
      try {
        await Firebase.initializeApp().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('Firebase init timed out'),
        );
        debugPrint('✅ Firebase initialized (fallback in _doInit)');
      } catch (e) {
        debugPrint('❌ Firebase init failed: $e');
        rethrow;
      }
    } else {
      debugPrint('✅ Firebase already initialized');
    }

    // App Check + Auth settings (from main): improve phone auth on real devices
    try {
      await _initializeAppCheck();
    } catch (e) {
      debugPrint('⚠️ App Check in _doInit: $e');
    }
    if (Platform.isAndroid) {
      try {
        await FirebaseAuth.instance.setSettings(
          forceRecaptchaFlow: false,
          appVerificationDisabledForTesting: false,
        );
        debugPrint('✅ Firebase Auth: forceRecaptchaFlow=false (native preferred)');
      } catch (e) {
        debugPrint('⚠️ Firebase Auth setSettings failed (non-fatal): $e');
      }
    }

    // Push notification (can block on iOS permission dialog)
    try {
      await pushNotificationService.initialize().timeout(
            const Duration(seconds: 8),
            onTimeout: () => debugPrint('⚠️ Push init timed out'),
          );
    } catch (e) {
      debugPrint('⚠️ Push init failed: $e');
    }

    // Server config (health check can block if backend unreachable)
    try {
      await ServerConfigService.init().timeout(
        const Duration(seconds: 8),
        onTimeout: () => debugPrint('⚠️ Server config timed out'),
      );
    } catch (e) {
      debugPrint('⚠️ Server config failed: $e');
    }

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const _SplashScreen();
    }
    if (_initError != null) {
      return _InitErrorScreen(error: _initError!);
    }
    return const RideHailingApp();
  }
}

/// Splash screen shown during initialization.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Image.asset(
            'assets/images/splash_logo.png',
            width: screenWidth * 0.85,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

/// Shown when initialization fails.
class _InitErrorScreen extends StatelessWidget {
  final String error;

  const _InitErrorScreen({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 24),
              const Text(
                'Failed to start',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RideHailingApp extends ConsumerStatefulWidget {
  const RideHailingApp({super.key});

  @override
  ConsumerState<RideHailingApp> createState() => _RideHailingAppState();
}

class _RideHailingAppState extends ConsumerState<RideHailingApp> {
  bool _pendingRideReplayStarted = false;

  @override
  void initState() {
    super.initState();
    // Set up notification tap handler
    _setupNotificationHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _replayPendingRideAcceptActions();
    });
  }

  double _parseFare(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    final raw = value.toString();
    final clean = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(clean) ?? 0;
  }

  RideOffer _rideOfferFromPendingAction(Map<String, dynamic> data) {
    return RideOffer(
      id: (data['rideId'] ?? data['id'] ?? '').toString(),
      type: (data['vehicleType'] ?? data['serviceType'] ?? 'bike_rescue')
          .toString(),
      earning: _parseFare(data['fare'] ?? data['estimatedFare']),
      pickupDistance:
          (data['distance'] ?? data['pickupDistance'] ?? '0 km').toString(),
      pickupTime: (data['pickupTime'] ?? 'Now').toString(),
      dropDistance:
          (data['dropDistance'] ?? data['distance'] ?? '0 km').toString(),
      dropTime: (data['dropTime'] ?? '').toString(),
      pickupAddress:
          (data['pickup'] ?? data['pickupAddress'] ?? 'Pickup').toString(),
      dropAddress: (data['drop'] ?? data['dropAddress'] ?? 'Drop').toString(),
      riderName:
          data['riderName']?.toString() ?? data['passengerName']?.toString(),
      riderPhone:
          data['riderPhone']?.toString() ?? data['passengerPhone']?.toString(),
      riderId: data['riderId']?.toString() ?? data['passengerId']?.toString(),
      paymentMethod: (data['paymentMethod'] ?? 'cash').toString(),
      createdAt: DateTime.now(),
    );
  }

  Future<void> _replayPendingRideAcceptActions() async {
    if (_pendingRideReplayStarted) return;
    _pendingRideReplayStarted = true;

    // Allow auth restoration to complete during cold start.
    for (int i = 0; i < 6; i++) {
      if (!mounted) return;
      final user = ref.read(authStateProvider).user;
      if (user != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final pendingActions =
        await pushNotificationService.consumePendingRideActions();
    if (pendingActions.isEmpty || !mounted) return;

    final user = ref.read(authStateProvider).user;
    if (user?.userType != UserType.driver) return;

    final router = ref.read(appRouterProvider);
    for (final action in pendingActions.reversed) {
      final actionId = (action['action'] ?? '').toString();
      final accepted = action['accepted'] == true;
      final data = action['data'];
      if (actionId != NotificationActions.acceptRide ||
          !accepted ||
          data is! Map<String, dynamic>) {
        continue;
      }

      final offer = _rideOfferFromPendingAction(data);
      ref.read(driverRidesProvider.notifier).setAcceptedRide(offer);

      // Preserve existing post-accept path: home -> active ride screen.
      router.go(AppRoutes.driverHome);
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        router.push(AppRoutes.driverActiveRide);
      });
      break;
    }
  }

  void _setupNotificationHandler() {
    pushNotificationService.onNotificationTap = (data) {
      final router = ref.read(appRouterProvider);
      final type = data['type'] as String?;
      final event = data['event'] as String?;
      final status = data['status'] as String?;
      final messageType = data['messageType'] as String?;
      final rideId = data['rideId'] as String?;
      final senderId = data['senderId'] as String?;
      final authUserType = ref.read(authStateProvider).user?.userType;
      final senderRole = (data['senderRole'] as String?)?.toUpperCase();
      // Payload fallback for cold-start timing windows where auth state may not be restored yet.
      // If sender is PASSENGER, recipient is DRIVER; if sender is DRIVER, recipient is PASSENGER.
      final bool? roleFromSender = senderRole == 'PASSENGER'
          ? true
          : (senderRole == 'DRIVER' ? false : null);
      final isDriver =
          authUserType == UserType.driver || roleFromSender == true;
      final currentUri = router.routeInformationProvider.value.uri;
      final currentRoute = currentUri.toString();

      debugPrint(
          'Notification tapped type=$type rideId=$rideId currentRoute=$currentRoute');

      bool isSameActiveRideScreen() {
        if (rideId == null || rideId.isEmpty) return false;
        final bookingRideId = ref.read(rideBookingProvider).rideId;
        final driverAcceptedRideId =
            ref.read(driverRidesProvider).acceptedRide?.id;

        // Rider active ride host: /ride/:rideId/tracking
        final segments = currentUri.pathSegments;
        if (segments.length >= 3 &&
            segments[0] == 'ride' &&
            segments[2] == 'tracking' &&
            segments[1] == rideId) {
          return true;
        }

        // Rider pre-pickup host: /booking/driver-assigned
        final isDriverAssignedPath =
            currentUri.path == AppRoutes.driverAssigned;
        if (isDriverAssignedPath && bookingRideId == rideId) {
          return true;
        }

        // Driver active ride host: /driver/active-ride?rideId=...
        final isDriverActivePath =
            currentUri.path == AppRoutes.driverActiveRide;
        final currentRideId =
            currentUri.queryParameters['rideId'] ?? driverAcceptedRideId;
        if (isDriverActivePath && currentRideId == rideId) {
          return true;
        }

        return false;
      }

      void openChatFromNotification() {
        if (rideId == null || rideId.isEmpty) {
          router.go('/services');
          return;
        }

        // Case A: already on the same active ride host screen -> open chat in-place.
        if (isSameActiveRideScreen()) {
          pushNotificationService.requestInAppChatOpen(
            rideId: rideId,
            senderId: senderId,
          );
          return;
        }

        // Case B: elsewhere in app -> open ride host screen and auto-open chat panel.
        if (isDriver) {
          router
              .go('${AppRoutes.driverActiveRide}?rideId=$rideId&openChat=true');
        } else {
          router.go('${AppRoutes.driverAssigned}?rideId=$rideId&openChat=true');
        }
      }

      // Navigate based on notification type
      if (type == 'RIDE_UPDATE') {
        final rideEvent = event ?? status;
        // Backward compatibility: older chat pushes used RIDE_UPDATE + messageType.
        if (messageType == 'RIDE_CHAT') {
          openChatFromNotification();
          return;
        }
        switch (rideEvent) {
          case 'NEW_RIDE_REQUEST':
            // Driver: go to driver home to see the ride request
            router.go('/driver/home');
            break;
          case 'DRIVER_ASSIGNED':
          case 'DRIVER_ARRIVING':
          case 'DRIVER_ARRIVED':
          case 'RIDE_STARTED':
            // Rider: go to driver assigned screen
            router.go('/booking/driver-assigned');
            break;
          case 'RIDE_COMPLETED_PASSENGER':
          case 'RIDE_COMPLETED_DRIVER':
            // Route to active ride host so completion sync can show rating flow.
            if (rideId != null && rideId.isNotEmpty) {
              ref
                  .read(rideBookingProvider.notifier)
                  .setRideDetails(rideId: rideId);
              if (!isSameActiveRideScreen()) {
                router.go('${AppRoutes.driverAssigned}?rideId=$rideId');
              }
            } else {
              router.go(AppRoutes.home);
            }
            break;
          case 'RIDE_CANCELLED':
            // Go back to home
            router.go('/services');
            break;
          default:
            // Default: go to home
            router.go('/services');
        }
      } else if (type == 'CHAT_MESSAGE') {
        openChatFromNotification();
      } else if (type == NotificationTypes.newRide) {
        router.go(AppRoutes.driverHome);
      } else if (type == 'PAYMENT') {
        router.go('/history');
      } else if (type == 'DRIVER_ONBOARDING') {
        final onboardingEvent = event ?? status;
        if (onboardingEvent == 'VERIFIED' || onboardingEvent == 'COMPLETED') {
          router.go(AppRoutes.driverHome);
        } else {
          router.go(AppRoutes.driverWelcome);
        }
      } else {
        // Default navigation
        router.go('/services');
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final settings = ref.watch(settingsProvider);

    // Update system UI based on theme
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            settings.isDarkMode ? Brightness.light : Brightness.dark,
        systemNavigationBarColor:
            settings.isDarkMode ? const Color(0xFF1A1A1A) : Colors.white,
        systemNavigationBarIconBrightness:
            settings.isDarkMode ? Brightness.light : Brightness.dark,
      ),
    );

    // If backend is unreachable, show a connection error screen
    if (!ServerConfigService.isHealthy) {
      return MaterialApp(
        title: 'Raahi',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        locale: const Locale('en', 'IN'),
        supportedLocales: supportedLanguages.map((l) => l.locale),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const _ConnectionErrorScreen(),
      );
    }

    // Find the locale from settings
    final locale = supportedLanguages
            .where((l) => l.code == settings.languageCode)
            .map((l) => l.locale)
            .firstOrNull ??
        const Locale('en', 'IN');

    return MaterialApp.router(
      title: 'Raahi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      locale: locale,
      supportedLocales: supportedLanguages.map((l) => l.locale),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}

/// Shown when the backend is unreachable on app startup.
class _ConnectionErrorScreen extends StatefulWidget {
  const _ConnectionErrorScreen();

  @override
  State<_ConnectionErrorScreen> createState() => _ConnectionErrorScreenState();
}

class _ConnectionErrorScreenState extends State<_ConnectionErrorScreen> {
  bool _retrying = false;
  final _urlController =
      TextEditingController(text: ServerConfigService.apiUrl);

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    final ok = await ServerConfigService.revalidate();
    if (ok && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RideHailingApp()),
        (_) => false,
      );
    } else if (mounted) {
      setState(() => _retrying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Still unreachable: ${ServerConfigService.apiUrl}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _saveAndRetry() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _retrying = true);
    await ServerConfigService.save(
      apiUrl: url,
      wsUrl: ServerConfigService.deriveWsUrl(url),
    );
    final ok = await ServerConfigService.revalidate();
    if (ok && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RideHailingApp()),
        (_) => false,
      );
    } else if (mounted) {
      setState(() => _retrying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cannot reach this server. Check IP and port.'),
            backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 80, color: Color(0xFFD4956A)),
              const SizedBox(height: 24),
              const Text(
                'Cannot reach server',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'The app could not connect to the backend.\nMake sure your device and server are on the same network.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              const SizedBox(height: 32),
              // Editable URL field
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'API URL',
                  hintText: 'http://192.168.x.x:3000/api',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.link),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              Text(
                'Build default: ${ServerConfigService.buildDefault}',
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _retrying ? null : _retry,
                      child: const Text('Retry'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: _retrying ? null : _saveAndRetry,
                        icon: _retrying
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.refresh),
                        label: Text(_retrying ? 'Connecting...' : 'Connect'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD4956A),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
