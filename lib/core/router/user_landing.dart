import '../models/user.dart';
import 'app_routes.dart';

/// Resolves the post-login / cold-start landing route from the user's role.
///
/// Always lands on the dual-choice home screen ("Find a Ride Now!" /
/// "Open Driver's App") so the user picks passenger vs driver after login
/// or name entry. Pure role auto-skips were confusing new users.
String landingRouteForUser(User? user) {
  if (user == null) return AppRoutes.login;
  return AppRoutes.home;
}

/// True when the dual-choice home screen should be shown as-is (no auto-skip).
bool shouldShowRolePicker(User? user) => user != null;

/// Driver-only auto-open is disabled — always let the user tap a choice.
bool shouldAutoOpenDriverApp(User? user) => false;

/// Never skip the dual-choice home screen for rider-only accounts.
bool shouldSkipHomeSelection(User? user) => false;
