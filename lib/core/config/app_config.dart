import '../services/server_config_service.dart';

class AppConfig {
  AppConfig._();

  // API Configuration — resolved at runtime via ServerConfigService.
  // On first launch the app shows a server configuration screen
  // where the user enters their backend URL. The URL is persisted
  // in SharedPreferences so the APK works with any backend.
  //
  // MICROSERVICES ARCHITECTURE:
  // - API Gateway runs on port 3000 (entry point for all requests)
  // - Auth Service: port 5001
  // - User Service: port 5002
  // - Driver Service: port 5003
  // - Ride Service: port 5004
  // - Pricing Service: port 5005
  // - Notification Service: port 5006
  // - Realtime/WebSocket Service: port 5007
  // - Admin Service: port 5008
  static String get apiUrl => ServerConfigService.apiUrl;

  // WebSocket Configuration (connects directly to realtime service on port 5007)
  // 
  // Production DigitalOcean setup:
  // - Realtime service runs on port 5007 and is publicly exposed
  // - App connects directly to ws://host:5007 for Socket.io
  //
  static String get wsUrl => ServerConfigService.wsUrl;

  // Google Maps API Key
  static const String googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
    defaultValue: 'AIzaSyAaTuhvB_WuJosSUXfgMyhMxAD-6sEmfVc',
  );

  // Google Sign-In server client id (Web OAuth client ID from Firebase).
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '877632727493-drmcekkvc4ui34cb09a0oq7538ildj0r.apps.googleusercontent.com',
  );

  // Razorpay Configuration
  static const String razorpayKeyId = String.fromEnvironment(
    'RAZORPAY_KEY_ID',
    defaultValue: '',
  );

  // App Information
  static const String appName = 'RideApp';
  static const String appVersion = '1.0.0';

  // Default Location (Bangalore, India)
  static const double defaultLatitude = 12.9716;
  static const double defaultLongitude = 77.5946;

  // Ride Configuration
  static const int driverSearchRadius = 10000; // 10km in meters
  static const int driverRefreshInterval = 30; // seconds
  static const int maxRideRequestAttempts = 5;
  static const int rideRequestTimeout = 30; // seconds

  // Map Configuration
  static const double defaultZoom = 15.0;
  static const double minZoom = 10.0;
  static const double maxZoom = 20.0;

  // Cache Configuration
  static const int cacheMaxAge = 86400; // 24 hours in seconds
  static const int maxCacheSize = 100; // MB

  // Timeouts
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // Driver Subscription (Daily Platform Fee)
  static const double dailyPlatformFee = 39.0;
  
  // Company UPI Details (used for all payments)
  static const String companyUpiId =
      'MSRAAHICABSERVICESPRIVATELIMITED.eazypay@icici';
  static const String companyName = 'Raahi Cab Services';
  static const String companyDisplayName = 'Raahi Cab Services';
}
