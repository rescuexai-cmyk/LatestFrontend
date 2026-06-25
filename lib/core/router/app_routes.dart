class AppRoutes {
  AppRoutes._();

  // Auth routes
  static const String welcomeOnboarding = '/welcome-onboarding';
  static const String login = '/login';
  static const String signup = '/signup';
  static const String otpVerification = '/otp-verification';
  static const String nameEntry = '/otp-verification/name';
  static const String phoneNumber = '/phone-number';

  // Main app routes
  static const String home = '/';
  static const String services = '/services';
  static const String history = '/history';
  static const String profile = '/profile';

  // Ride routes
  static const String rideDetails = '/ride/:rideId';
  static const String rideTracking = '/ride/:rideId/tracking';
  static const String rideChat = '/ride/:rideId/chat';
  static const String rideBooking = '/booking';
  static const String findTrip = '/booking/find-trip';
  static const String ridePayment = '/booking/payment';
  static const String searchingDrivers = '/booking/searching';
  static const String driverAssigned = '/booking/driver-assigned';

  // Rescue flow — full Figma 11-screen journey
  static const String rescueLanding = '/booking/rescue';
  static const String rescueReason = '/booking/rescue/reason';
  static const String rescueLocation = '/booking/rescue/location';
  static const String rescueVehicleDetails = '/booking/rescue/vehicle-details';
  static const String rescueDestination = '/booking/rescue/destination';
  static const String rescueReview = '/booking/rescue/review';
  static const String rescueTracking = '/booking/rescue/tracking';
  static const String rescueHandover = '/booking/rescue/handover';
  static const String rescueJourneyHub = '/booking/rescue/journey-hub';
  static const String rescueDelivery = '/booking/rescue/delivery';
  static const String rescueComplete = '/booking/rescue/complete';

  /// Legacy alias — journey hub is the live hub; kept for history deep links.
  static const String rescueSearching = '/booking/rescue/searching';
  static const String rescueJourney = '/booking/rescue/journey';

  static String rescueJourneyPath(String rescueId) =>
      '/booking/rescue/journey-hub?rescueId=$rescueId';

  // Driver routes
  static const String driverHome = '/driver';
  static const String driverOnboarding = '/driver/onboarding';
  static const String driverWelcome = '/driver/welcome';
  static const String personalDriverOnboarding = '/driver/personal/onboarding';
  static const String personalDriverWelcome = '/driver/personal/welcome';
  static const String driverDocuments = '/driver/documents';  // Update/manage documents
  static const String driverProfile = '/driver/profile';
  static const String driverActiveRide = '/driver/active-ride';
  static const String driverRescueJob = '/driver/rescue-job';
  static const String driverSubscriptionPayment = '/driver/subscription-payment';
  static const String driverPenaltyPayment = '/driver/penalty-payment';

  // Payment routes
  static const String payment = '/payment';
  static const String paymentMethods = '/payment/methods';

  // Settings
  static const String settings = '/settings';
  static const String notifications = '/settings/notifications';
  static const String serverConfig = '/settings/server';

  // Helper methods for dynamic routes
  static String rideDetailsPath(String rideId) => '/ride/$rideId';
  static String rideTrackingPath(String rideId) => '/ride/$rideId/tracking';
  static String rideChatPath(String rideId) => '/ride/$rideId/chat';
}
