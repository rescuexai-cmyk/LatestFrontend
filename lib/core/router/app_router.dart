import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/signup_screen.dart';
import '../../features/auth/presentation/screens/otp_verification_screen.dart';
import '../../features/auth/presentation/screens/terms_screen.dart';
import '../../features/auth/presentation/screens/name_entry_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/home/presentation/screens/home_screen.dart';
import '../../features/home/presentation/screens/services_screen.dart';
import '../../features/history/presentation/screens/history_screen.dart';
import '../../features/profile/presentation/screens/profile_screen.dart';
import '../../features/ride/presentation/screens/ride_details_screen.dart';
import '../../features/ride/presentation/screens/ride_tracking_screen.dart';
import '../../features/chat/presentation/screens/ride_chat_screen.dart';
import '../../features/ride/presentation/screens/find_trip_screen.dart';
import '../../features/ride/presentation/screens/payment_screen.dart';
import '../../features/ride/presentation/screens/searching_drivers_screen.dart';
import '../../features/ride/presentation/screens/driver_assigned_screen.dart';
import '../../features/driver/presentation/screens/driver_home_screen.dart';
import '../../features/driver/presentation/screens/driver_active_ride_screen.dart';
import '../../features/driver/presentation/screens/driver_onboarding_screen.dart';
import '../../features/driver/presentation/screens/driver_welcome_screen.dart';
import '../../features/driver/presentation/screens/driver_document_management_screen.dart';
import '../../features/driver/presentation/screens/driver_subscription_payment_screen.dart';
import '../../features/driver/presentation/screens/driver_penalty_payment_screen.dart';
import '../../features/settings/presentation/screens/server_config_screen.dart';
import '../services/server_config_service.dart';
import 'app_routes.dart';

// Provider that only exposes whether the user is authenticated (to prevent unnecessary rebuilds)
final isAuthenticatedProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateProvider);
  return authState.user != null;
});

final appRouterProvider = Provider<GoRouter>((ref) {
  // Watch auth status AND onboarding flag so redirects re-evaluate when either changes
  final isAuthenticated = ref.watch(isAuthenticatedProvider);
  final pendingOnboarding = ref.watch(pendingOnboardingProvider);
  final pendingPhoneLink = ref.watch(pendingPhoneLinkProvider);
  
  // Determine initial location based on server config state
  final initialLocation = ServerConfigService.isConfigured
      ? AppRoutes.login
      : AppRoutes.serverConfig;

  return GoRouter(
    initialLocation: initialLocation,
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final currentLocation = state.matchedLocation;
      
      // Always allow access to the server config screen
      if (currentLocation == AppRoutes.serverConfig) {
        return null;
      }

      // Routes that require login (redirect to login if not authenticated)
      final isLoginRoute = currentLocation == AppRoutes.login ||
          currentLocation == AppRoutes.signup ||
          currentLocation.startsWith(AppRoutes.otpVerification);
      final isOtpPhoneLinkRoute =
          currentLocation.startsWith(AppRoutes.otpVerification) &&
              (state.uri.queryParameters['mode'] == 'linkPhone' ||
                  pendingPhoneLink);
      final isPhoneLinkRoute = currentLocation == AppRoutes.phoneNumber ||
          (currentLocation == AppRoutes.signup &&
              state.uri.queryParameters['mode'] == 'linkPhone') ||
          isOtpPhoneLinkRoute;

      // Onboarding routes (name entry + terms) — part of new-user flow post-auth
      final isOnboardingRoute =
          currentLocation.startsWith(AppRoutes.nameEntry) ||
          currentLocation.startsWith(AppRoutes.terms);

      final isAuthRoute = isLoginRoute || isOnboardingRoute;

      debugPrint('🔀 Router redirect: location=$currentLocation, isAuthenticated=$isAuthenticated, pendingOnboarding=$pendingOnboarding, pendingPhoneLink=$pendingPhoneLink, isAuthRoute=$isAuthRoute');

      // For demo purposes, allow navigation to home, ride booking, driver, and ride tracking routes without authentication
      // Remove this check in production
      if (currentLocation == AppRoutes.home ||
          currentLocation == AppRoutes.services ||
          currentLocation.startsWith('/booking') ||
          currentLocation.startsWith('/driver') ||
          currentLocation.startsWith('/ride/') ||
          currentLocation.startsWith('/settings')) {
        return null;
      }

      // Always allow onboarding screens (name entry, terms) when authenticated
      if (isOnboardingRoute && isAuthenticated) {
        return null;
      }

      // If not authenticated and trying to access protected routes, go to login
      if (!isAuthenticated && !isAuthRoute) {
        debugPrint('🔀 Redirecting to login (not authenticated)');
        return AppRoutes.login;
      }

      if (isAuthenticated && pendingPhoneLink && !isPhoneLinkRoute) {
        debugPrint('🔀 Redirecting to phone number link flow');
        return '${AppRoutes.phoneNumber}?mode=linkPhone';
      }

      // If authenticated and on a login route, decide where to go:
      // - New user with pending onboarding → name entry
      // - Returning user → home
      if (isAuthenticated && isLoginRoute && !isPhoneLinkRoute) {
        if (pendingPhoneLink) {
          debugPrint('🔀 Redirecting to phone link screen');
          return '${AppRoutes.phoneNumber}?mode=linkPhone';
        }
        if (pendingOnboarding) {
          debugPrint('🔀 Redirecting to name entry (new user onboarding)');
          return AppRoutes.nameEntry;
        }
        debugPrint('🔀 Redirecting to home (already authenticated)');
        return AppRoutes.home;
      }

      return null;
    },
    routes: [
      // Auth routes
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.signup,
        name: 'signup',
        builder: (context, state) {
          final isPhoneLinkMode =
              state.uri.queryParameters['mode'] == 'linkPhone';
          return SignUpScreen(isPhoneLinkMode: isPhoneLinkMode);
        },
      ),
      GoRoute(
        path: AppRoutes.phoneNumber,
        name: 'phoneNumber',
        builder: (context, state) {
          final isPhoneLinkMode =
              state.uri.queryParameters['mode'] != 'normal';
          return SignUpScreen(isPhoneLinkMode: isPhoneLinkMode);
        },
      ),
      GoRoute(
        path: AppRoutes.otpVerification,
        name: 'otpVerification',
        builder: (context, state) {
          final phone = state.uri.queryParameters['phone'] ?? '';
          final isNewUser = state.uri.queryParameters['isNewUser'] == 'true';
          final isPhoneLinkMode =
              state.uri.queryParameters['mode'] == 'linkPhone';
          debugPrint('🔀 Building OTPVerificationScreen: phone=$phone, isNewUser=$isNewUser');
          return OTPVerificationScreen(
            phone: phone,
            isNewUser: isNewUser,
            isPhoneLinkMode: isPhoneLinkMode,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.nameEntry,
        name: 'nameEntry',
        builder: (context, state) {
          final phone = state.uri.queryParameters['phone'] ?? '';
          return NameEntryScreen(phone: phone);
        },
      ),
      GoRoute(
        path: AppRoutes.terms,
        name: 'terms',
        builder: (context, state) {
          final phone = state.uri.queryParameters['phone'] ?? '';
          return TermsScreen(phone: phone);
        },
      ),
      
      // Home screen (direct access for demo)
      GoRoute(
        path: AppRoutes.home,
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      
      // Services screen (ride selection hub)
      GoRoute(
        path: AppRoutes.services,
        name: 'services',
        builder: (context, state) => const ServicesScreen(),
      ),
      
      // History screen
      GoRoute(
        path: AppRoutes.history,
        name: 'history',
        builder: (context, state) => const HistoryScreen(),
      ),
      
      // Profile screen
      GoRoute(
        path: AppRoutes.profile,
        name: 'profile',
        builder: (context, state) => const ProfileScreen(),
      ),
      
      // Ride details (outside bottom nav)
      GoRoute(
        path: AppRoutes.rideDetails,
        name: 'rideDetails',
        builder: (context, state) {
          final rideId = state.pathParameters['rideId'] ?? '';
          return RideDetailsScreen(rideId: rideId);
        },
      ),
      
      // Ride tracking
      GoRoute(
        path: AppRoutes.rideTracking,
        name: 'rideTracking',
        builder: (context, state) {
          final rideId = state.pathParameters['rideId'] ?? '';
          final autoOpenChat = state.uri.queryParameters['openChat'] == 'true';
          return RideTrackingScreen(
            rideId: rideId,
            autoOpenChat: autoOpenChat,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.rideChat,
        name: 'rideChat',
        builder: (context, state) {
          final rideId = state.pathParameters['rideId'] ?? '';
          final authUserId = ref.read(authStateProvider).user?.id ?? '';
          final currentUserId = state.uri.queryParameters['currentUserId'] ?? authUserId;
          final otherUserName = state.uri.queryParameters['otherUserName'] ?? 'Ride Chat';
          final otherUserPhoto = state.uri.queryParameters['otherUserPhoto'];
          final otherUserPhone = state.uri.queryParameters['otherUserPhone'];
          final passengerId = state.uri.queryParameters['passengerId'];
          final isDriver = state.uri.queryParameters['isDriver'] == 'true';

          return RideChatScreen(
            rideId: rideId,
            currentUserId: currentUserId,
            passengerId: passengerId,
            otherUserName: otherUserName,
            otherUserPhoto: otherUserPhoto,
            otherUserPhone: otherUserPhone,
            isDriver: isDriver,
          );
        },
      ),
      
      // Driver routes
      GoRoute(
        path: AppRoutes.driverOnboarding,
        name: 'driverOnboarding',
        builder: (context, state) {
          final isUpdateMode =
              state.uri.queryParameters['isUpdateMode'] == 'true';
          final returnToProfile =
              state.uri.queryParameters['returnToProfile'] == 'true';
          return DriverOnboardingScreen(
            isUpdateMode: isUpdateMode,
            returnToProfileOnBack: returnToProfile,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.driverWelcome,
        name: 'driverWelcome',
        builder: (context, state) => const DriverWelcomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.driverDocuments,
        name: 'driverDocuments',
        builder: (context, state) {
          final returnToProfile =
              state.uri.queryParameters['returnToProfile'] == 'true';
          return DriverDocumentManagementScreen(
            returnToProfileOnBack: returnToProfile,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.driverHome,
        name: 'driverHome',
        builder: (context, state) => const DriverHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.driverActiveRide,
        name: 'driverActiveRide',
        builder: (context, state) {
          final rideId = state.uri.queryParameters['rideId'];
          final autoOpenChat = state.uri.queryParameters['openChat'] == 'true';
          return DriverActiveRideScreen(
            initialRideId: rideId,
            autoOpenChat: autoOpenChat,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.driverSubscriptionPayment,
        name: 'driverSubscriptionPayment',
        builder: (context, state) => const DriverSubscriptionPaymentScreen(),
      ),
      GoRoute(
        path: AppRoutes.driverPenaltyPayment,
        name: 'driverPenaltyPayment',
        builder: (context, state) => const DriverPenaltyPaymentScreen(),
      ),

      // Ride booking flow
      GoRoute(
        path: AppRoutes.findTrip,
        name: 'findTrip',
        builder: (context, state) {
          final autoOpen = state.uri.queryParameters['autoSearch'] == 'true';
          final serviceType = state.uri.queryParameters['serviceType'];
          final scheduledTimeStr = state.uri.queryParameters['scheduledTime'];
          DateTime? scheduledTime;
          if (scheduledTimeStr != null && scheduledTimeStr.isNotEmpty) {
            try {
              scheduledTime = DateTime.parse(scheduledTimeStr);
            } catch (_) {}
          }
          return FindTripScreen(
            autoOpenSearch: autoOpen, 
            initialServiceType: serviceType,
            scheduledTime: scheduledTime,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.ridePayment,
        name: 'ridePayment',
        builder: (context, state) => const PaymentScreen(),
      ),
      GoRoute(
        path: AppRoutes.searchingDrivers,
        name: 'searchingDrivers',
        builder: (context, state) => const SearchingDriversScreen(),
      ),
      GoRoute(
        path: AppRoutes.driverAssigned,
        name: 'driverAssigned',
        builder: (context, state) {
          final rideId = state.uri.queryParameters['rideId'];
          final autoOpenChat = state.uri.queryParameters['openChat'] == 'true';
          return DriverAssignedScreen(
            initialRideId: rideId,
            autoOpenChat: autoOpenChat,
          );
        },
      ),
      
      // Server configuration
      GoRoute(
        path: AppRoutes.serverConfig,
        name: 'serverConfig',
        builder: (context, state) {
          final isInitial = state.uri.queryParameters['initial'] != 'false';
          return ServerConfigScreen(isInitialSetup: isInitial);
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Page not found',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              state.matchedLocation,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go(AppRoutes.home),
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    ),
  );
});
