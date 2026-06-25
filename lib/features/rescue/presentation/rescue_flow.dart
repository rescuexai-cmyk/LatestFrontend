import '../../../core/router/app_routes.dart';
import '../models/rescue_models.dart';
import '../providers/rescue_booking_provider.dart';

/// Central navigation rules for the 11-screen Figma rescue flow.
abstract final class RescueFlow {
  static String afterLocation(RescueBookingState s) {
    if (s.needsVehicleDetailsScreen) return AppRoutes.rescueVehicleDetails;
    return AppRoutes.rescueDestination;
  }

  static bool canProceedFromLocation(RescueBookingState s) =>
      s.pickup != null && s.pickup!.isValid;

  static bool canProceedFromVehicleDetails(RescueBookingState s) =>
      s.vehicleDetails.isValid;

  static bool canProceedFromDestination(RescueBookingState s) {
    if (s.userDrop == null || !s.userDrop!.isValid) return false;
    if (!s.hasVehicle) return true;
    if (s.vehicleDropSameAsDrop) return true;
    return s.vehicleDrop != null && s.vehicleDrop!.isValid;
  }
}
