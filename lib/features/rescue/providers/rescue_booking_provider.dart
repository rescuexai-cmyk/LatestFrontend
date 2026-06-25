import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../ride/providers/ride_booking_provider.dart';
import '../data/rescue_repository.dart' show RescueRepository, RescueUploadUrl, rescueRepositoryProvider;
import '../models/rescue_models.dart';

class RescueBookingState {
  const RescueBookingState({
    this.serviceType = RescueServiceType.passengerAndVehicle,
    this.reason,
    this.otherReasonNote = '',
    this.pickup,
    this.vehicleWithYou = true,
    this.userDrop,
    this.vehicleDrop,
    this.vehicleDropSameAsDrop = true,
    this.vehicleDetails = const RescueVehicleDetails(),
    this.estimate,
    this.isLoadingEstimate = false,
    this.rescueId,
    this.summary,
    this.paymentMethod = 'CASH',
    this.handoverCompleted = false,
    this.deliveryCompleted = false,
    this.deliveryIssueNote = '',
  });

  final RescueServiceType serviceType;
  final RescueReason? reason;
  final String otherReasonNote;
  final RescuePlace? pickup;
  final bool vehicleWithYou;
  final RescuePlace? userDrop;
  final RescuePlace? vehicleDrop;
  final bool vehicleDropSameAsDrop;
  final RescueVehicleDetails vehicleDetails;
  final RescueFareEstimate? estimate;
  final bool isLoadingEstimate;
  final String? rescueId;
  final RescueRequestSummary? summary;
  final String paymentMethod;
  final bool handoverCompleted;
  final bool deliveryCompleted;
  final String deliveryIssueNote;

  bool get hasVehicle =>
      vehicleWithYou &&
      (serviceType == RescueServiceType.passengerAndVehicle ||
          serviceType == RescueServiceType.vehicle ||
          serviceType == RescueServiceType.breakdown);

  bool get needsVehicleDetailsScreen => hasVehicle;

  RescuePlace? get effectiveVehicleDrop =>
      !hasVehicle ? null : (vehicleDropSameAsDrop ? userDrop : vehicleDrop);

  RescueBookingState copyWith({
    RescueServiceType? serviceType,
    RescueReason? reason,
    String? otherReasonNote,
    RescuePlace? pickup,
    bool? vehicleWithYou,
    RescuePlace? userDrop,
    RescuePlace? vehicleDrop,
    bool? vehicleDropSameAsDrop,
    RescueVehicleDetails? vehicleDetails,
    RescueFareEstimate? estimate,
    bool? isLoadingEstimate,
    String? rescueId,
    RescueRequestSummary? summary,
    String? paymentMethod,
    bool? handoverCompleted,
    bool? deliveryCompleted,
    String? deliveryIssueNote,
    bool clearEstimate = false,
  }) {
    return RescueBookingState(
      serviceType: serviceType ?? this.serviceType,
      reason: reason ?? this.reason,
      otherReasonNote: otherReasonNote ?? this.otherReasonNote,
      pickup: pickup ?? this.pickup,
      vehicleWithYou: vehicleWithYou ?? this.vehicleWithYou,
      userDrop: userDrop ?? this.userDrop,
      vehicleDrop: vehicleDrop ?? this.vehicleDrop,
      vehicleDropSameAsDrop:
          vehicleDropSameAsDrop ?? this.vehicleDropSameAsDrop,
      vehicleDetails: vehicleDetails ?? this.vehicleDetails,
      estimate: clearEstimate ? null : (estimate ?? this.estimate),
      isLoadingEstimate: isLoadingEstimate ?? this.isLoadingEstimate,
      rescueId: rescueId ?? this.rescueId,
      summary: summary ?? this.summary,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      handoverCompleted: handoverCompleted ?? this.handoverCompleted,
      deliveryCompleted: deliveryCompleted ?? this.deliveryCompleted,
      deliveryIssueNote: deliveryIssueNote ?? this.deliveryIssueNote,
    );
  }
}

class RescueBookingNotifier extends Notifier<RescueBookingState> {
  @override
  RescueBookingState build() => const RescueBookingState();

  RescueRepository get _repo => ref.read(rescueRepositoryProvider);

  void reset() => state = const RescueBookingState();

  void prefillFromRideBooking() {
    final b = ref.read(rideBookingProvider);
    if (b.pickupLocation != null && b.pickupAddress != null) {
      state = state.copyWith(
        pickup: RescuePlace(
          address: b.pickupAddress!,
          location: b.pickupLocation!,
        ),
      );
    }
    if (b.destinationLocation != null && b.destinationAddress != null) {
      state = state.copyWith(
        userDrop: RescuePlace(
          address: b.destinationAddress!,
          location: b.destinationLocation!,
        ),
      );
    }
  }

  void setServiceType(RescueServiceType type) =>
      state = state.copyWith(serviceType: type, clearEstimate: true);

  void setReason(RescueReason reason, {String? note}) =>
      state = state.copyWith(reason: reason, otherReasonNote: note ?? '');

  void setPickup(RescuePlace place) =>
      state = state.copyWith(pickup: place, clearEstimate: true);

  void setVehicleWithYou(bool value) => state = state.copyWith(
        vehicleWithYou: value,
        clearEstimate: true,
      );

  void setUserDrop(RescuePlace place) =>
      state = state.copyWith(userDrop: place, clearEstimate: true);

  void setVehicleDrop(RescuePlace place) =>
      state = state.copyWith(vehicleDrop: place, clearEstimate: true);

  void setVehicleDropSameAsDrop(bool value) => state = state.copyWith(
        vehicleDropSameAsDrop: value,
        clearEstimate: true,
      );

  void setVehicleDetails(RescueVehicleDetails details) =>
      state = state.copyWith(vehicleDetails: details);

  void setPaymentMethod(String method) =>
      state = state.copyWith(paymentMethod: method);

  void setRescueId(String id) => state = state.copyWith(rescueId: id);

  void setHandoverCompleted(bool v) => state = state.copyWith(handoverCompleted: v);

  void setDeliveryCompleted(bool v, {String? note}) => state = state.copyWith(
        deliveryCompleted: v,
        deliveryIssueNote: note ?? state.deliveryIssueNote,
      );

  Future<RescueFareEstimate> loadEstimate() async {
    state = state.copyWith(isLoadingEstimate: true);
    try {
      final pickup = state.pickup;
      final userDrop = state.userDrop;
      if (pickup == null || userDrop == null) {
        final fb =
            RescueFareEstimate.staticFallback(hasVehicle: state.hasVehicle);
        state = state.copyWith(estimate: fb, isLoadingEstimate: false);
        return fb;
      }
      final estimate = await _repo.getFareEstimate(
        pickup: pickup.location,
        userDrop: userDrop.location,
        hasVehicle: state.hasVehicle,
        vehicleDrop: state.effectiveVehicleDrop?.location,
        vehicleDropSameAsDrop: state.vehicleDropSameAsDrop,
      );
      state = state.copyWith(estimate: estimate, isLoadingEstimate: false);
      return estimate;
    } catch (_) {
      final fb =
          RescueFareEstimate.staticFallback(hasVehicle: state.hasVehicle);
      state = state.copyWith(estimate: fb, isLoadingEstimate: false);
      return fb;
    }
  }

  Future<RescueRequestSummary> createRescueRequest() async {
    final pickup = state.pickup!;
    final userDrop = state.userDrop!;

    final summary = await _repo.createRescue(
      pickup: pickup,
      userDrop: userDrop,
      paymentMethod: state.paymentMethod,
      hasVehicle: state.hasVehicle,
      vehicleDropSameAsDrop: state.vehicleDropSameAsDrop,
      vehicleDrop: state.effectiveVehicleDrop,
      serviceType: state.serviceType,
      reason: state.reason,
      reasonDetails: state.reason == RescueReason.other
          ? state.otherReasonNote
          : null,
      isVehicleWithUser: state.vehicleWithYou,
      vehicleDetails: state.hasVehicle ? state.vehicleDetails : null,
    );

    state = state.copyWith(rescueId: summary.id, summary: summary);
    return summary;
  }

  Future<RescueRequestSummary> refreshRescue() async {
    final id = state.rescueId;
    if (id == null) throw StateError('No rescue id');
    final summary = await _repo.getRescue(id);
    state = state.copyWith(summary: summary);
    return summary;
  }

  Future<RescueProgressSnapshot> fetchProgress() async {
    final id = state.rescueId;
    if (id == null) throw StateError('No rescue id');
    return _repo.getProgress(id);
  }

  Future<void> cancelRescue({String? reason}) async {
    final id = state.rescueId;
    if (id == null) return;
    await _repo.cancelRescue(id, reason: reason);
    await refreshRescue();
  }

  Future<void> submitRating(RescueRatingInput input) async {
    final id = state.rescueId;
    if (id == null) return;
    await _repo.submitRating(
      rescueId: id,
      input: input,
      hasVehicle: state.hasVehicle,
    );
  }

  /// Confirm vehicle delivery - accept or report issue.
  Future<void> confirmVehicleDelivery({
    required bool accepted,
    String? notes,
    String? issue,
    List<String>? conditionPhotos,
  }) async {
    final id = state.rescueId;
    if (id == null) return;
    final summary = await _repo.verifyVehicleDelivery(
      id,
      accepted: accepted,
      notes: notes,
      issue: issue,
      conditionPhotos: conditionPhotos,
    );
    state = state.copyWith(
      summary: summary,
      deliveryCompleted: accepted,
      deliveryIssueNote: notes ?? issue,
    );
  }

  /// Trigger SOS emergency.
  Future<void> triggerSOS({String? notes}) async {
    final id = state.rescueId;
    if (id == null) return;
    final summary = await _repo.triggerSOS(id, notes: notes);
    state = state.copyWith(summary: summary);
  }

  /// Get rescue timeline events.
  Future<List<RescueTimelineEvent>> getTimeline() async {
    final id = state.rescueId;
    if (id == null) return [];
    return _repo.getTimeline(id);
  }

  /// Report an issue with the rescue.
  Future<void> reportIssue({
    required RescueIssueType issueType,
    required String description,
    List<String>? photos,
  }) async {
    final id = state.rescueId;
    if (id == null) return;
    await _repo.reportIssue(
      id,
      issueType: issueType,
      description: description,
      photos: photos,
    );
  }

  /// Get presigned upload URL for photos.
  Future<RescueUploadUrl> getUploadUrl({
    required String fileName,
    required String contentType,
    String? photoType,
  }) async {
    return _repo.getUploadUrl(
      fileName: fileName,
      contentType: contentType,
      rescueId: state.rescueId,
      photoType: photoType,
    );
  }
}

final rescueBookingProvider =
    NotifierProvider<RescueBookingNotifier, RescueBookingState>(
  RescueBookingNotifier.new,
);
