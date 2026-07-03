import '../models/user.dart';
import 'app_routes.dart';

/// Resolves the post-login / cold-start landing route from the user's role.
///
/// - [UserType.rider]  → rider hub (Services), skip the dual-choice screen.
/// - [UserType.driver] → home acts as a gateway; [HomeScreen] auto-opens driver.
/// - [UserType.both]   → dual-choice home screen (Find a Ride / Open Driver's App).
String landingRouteForUser(User? user) {
  if (user == null) return AppRoutes.login;

  switch (user.userType) {
    case UserType.rider:
      return AppRoutes.services;
    case UserType.driver:
    case UserType.both:
      return AppRoutes.home;
  }
}

/// True when the dual-choice home screen should be shown as-is (no auto-skip).
bool shouldShowRolePicker(User? user) =>
    user?.userType == UserType.both;

/// True when [HomeScreen] should immediately open the driver gateway on load.
bool shouldAutoOpenDriverApp(User? user) =>
    user?.userType == UserType.driver;

/// True when an authenticated user hitting `/` should be redirected away.
bool shouldSkipHomeSelection(User? user) =>
    user?.userType == UserType.rider;
