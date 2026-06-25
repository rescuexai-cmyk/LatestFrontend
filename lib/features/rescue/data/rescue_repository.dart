import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/services/api_client.dart';
import '../models/rescue_models.dart';

class RescueRepository {
  RescueRepository(this._api);

  final ApiClient _api;

  /// Get fare estimate using the dedicated /api/rescue/estimate endpoint.
  Future<RescueFareEstimate> getFareEstimate({
    required LatLng pickup,
    required LatLng userDrop,
    required bool hasVehicle,
    LatLng? vehicleDrop,
    bool vehicleDropSameAsDrop = true,
  }) async {
    try {
      final response = await _api.getRescueFareEstimate(
        pickupLat: pickup.latitude,
        pickupLng: pickup.longitude,
        dropLat: userDrop.latitude,
        dropLng: userDrop.longitude,
        hasVehicle: hasVehicle,
        vehicleDropLat: vehicleDrop?.latitude,
        vehicleDropLng: vehicleDrop?.longitude,
        vehicleDropSameAsDrop: hasVehicle ? vehicleDropSameAsDrop : null,
      );
      final data = response['data'] as Map<String, dynamic>? ?? response;
      return RescueFareEstimate.fromJson(data);
    } catch (e) {
      debugPrint('⚠️ Rescue estimate failed, using fallback: $e');
      return RescueFareEstimate.staticFallback(hasVehicle: hasVehicle);
    }
  }

  /// Get user's current active rescue (if any).
  Future<RescueRequestSummary?> getActiveRescue() async {
    try {
      final response = await _api.getActiveRescue();
      final data = response['data'];
      if (data == null) return null;
      return RescueRequestSummary.fromJson(data as Map<String, dynamic>);
    } catch (e) {
      debugPrint('⚠️ Failed to get active rescue: $e');
      return null;
    }
  }

  /// Verify vehicle delivery (accept or report issue).
  Future<RescueRequestSummary> verifyVehicleDelivery(
    String rescueId, {
    required bool accepted,
    String? notes,
    String? issue,
    List<String>? conditionPhotos,
  }) async {
    final response = await _api.verifyVehicleDelivery(
      rescueId,
      status: accepted ? 'ACCEPTED' : 'ISSUE_REPORTED',
      conditionPhotos: conditionPhotos,
      notes: notes,
      issue: issue,
    );
    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueRequestSummary.fromJson(data);
  }

  /// Submit multi-party rescue ratings.
  Future<void> submitRating({
    required String rescueId,
    required RescueRatingInput input,
    required bool hasVehicle,
  }) async {
    await _api.submitRescueRating(
      rescueId,
      ratings: input.toApiRatings(hasVehicle: hasVehicle),
      problemSolved: input.problemSolved,
    );
  }

  /// Create rescue request with full Figma flow fields.
  Future<RescueRequestSummary> createRescue({
    required RescuePlace pickup,
    required RescuePlace userDrop,
    required String paymentMethod,
    required bool hasVehicle,
    bool vehicleDropSameAsDrop = true,
    RescuePlace? vehicleDrop,
    // Screen ①
    RescueServiceType? serviceType,
    // Screen ②
    RescueReason? reason,
    String? reasonDetails,
    // Screen ③
    bool? isVehicleWithUser,
    // Screen ④
    RescueVehicleDetails? vehicleDetails,
  }) async {
    final vDrop =
        hasVehicle ? (vehicleDropSameAsDrop ? userDrop : vehicleDrop) : null;

    final response = await _api.createRescueRequest(
      pickupLat: pickup.location.latitude,
      pickupLng: pickup.location.longitude,
      pickupAddress: pickup.address,
      dropLat: userDrop.location.latitude,
      dropLng: userDrop.location.longitude,
      dropAddress: userDrop.address,
      paymentMethod: paymentMethod,
      hasVehicle: hasVehicle,
      rescueServiceType: _serviceTypeToApi(serviceType),
      reason: _reasonToApi(reason),
      reasonDetails: reasonDetails,
      isVehicleWithUser: isVehicleWithUser,
      vehicleType: hasVehicle && vehicleDetails != null
          ? vehicleDetails.category.apiType.apiValue
          : (hasVehicle ? 'TWO_WHEELER' : null),
      vehicleSubType: hasVehicle ? _vehicleSubTypeToApi(vehicleDetails) : null,
      vehicleRegistrationNumber:
          hasVehicle ? vehicleDetails?.registrationNumber : null,
      vehicleTransmission:
          hasVehicle ? _transmissionToApi(vehicleDetails?.transmission) : null,
      vehicleIssues: hasVehicle && vehicleDetails?.issuesNote.isNotEmpty == true
          ? [vehicleDetails!.issuesNote]
          : null,
      vehicleDropSameAsDrop: hasVehicle ? vehicleDropSameAsDrop : null,
      vehicleDropAddress: vDrop?.address,
      vehicleDropLat: vDrop?.location.latitude,
      vehicleDropLng: vDrop?.location.longitude,
    );

    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueRequestSummary.fromJson(data);
  }

  Future<RescueRequestSummary> getRescue(String rescueId) async {
    final response = await _api.getRescueRequest(rescueId);
    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueRequestSummary.fromJson(data);
  }

  Future<RescueProgressSnapshot> getProgress(String rescueId) async {
    final response = await _api.getRescueProgress(rescueId);
    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueProgressSnapshot.fromJson(data);
  }

  /// Get timeline events for Journey Hub.
  Future<List<RescueTimelineEvent>> getTimeline(String rescueId) async {
    final response = await _api.getRescueTimeline(rescueId);
    final data = response['data'];
    if (data == null) return [];
    if (data is List) {
      return data
          .map((e) => RescueTimelineEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Trigger SOS emergency.
  Future<RescueRequestSummary> triggerSOS(
    String rescueId, {
    String? notes,
  }) async {
    final response = await _api.triggerRescueSOS(rescueId, notes: notes);
    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueRequestSummary.fromJson(data);
  }

  /// Report an issue with the rescue.
  Future<void> reportIssue(
    String rescueId, {
    required RescueIssueType issueType,
    required String description,
    List<String>? photos,
  }) async {
    await _api.reportRescueIssue(
      rescueId,
      issueType: issueType.apiValue,
      description: description,
      photos: photos,
    );
  }

  /// Get presigned upload URL for photos.
  Future<RescueUploadUrl> getUploadUrl({
    required String fileName,
    required String contentType,
    String? rescueId,
    String? photoType,
  }) async {
    final response = await _api.getRescueUploadUrl(
      fileName: fileName,
      contentType: contentType,
      rescueId: rescueId,
      photoType: photoType,
    );
    final data = response['data'] as Map<String, dynamic>? ?? response;
    return RescueUploadUrl(
      uploadUrl: data['uploadUrl'] as String? ?? '',
      downloadUrl: data['downloadUrl'] as String? ?? '',
      key: data['key'] as String? ?? '',
    );
  }

  Future<void> cancelRescue(String rescueId, {String? reason}) async {
    await _api.cancelRescueRequest(rescueId, reason: reason);
  }

  Future<List<RescueRequestSummary>> getHistory({
    int page = 1,
    int limit = 20,
  }) async {
    final response = await _api.getRescueHistory(page: page, limit: limit);
    final data = response['data'] as Map<String, dynamic>? ?? {};
    final list = data['rescues'] as List<dynamic>? ?? [];
    return list
        .map((e) => RescueRequestSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  String? _serviceTypeToApi(RescueServiceType? type) {
    if (type == null) return null;
    switch (type) {
      case RescueServiceType.traffic:
        return 'TRAFFIC_RESCUE';
      case RescueServiceType.vehicle:
        return 'VEHICLE_RESCUE';
      case RescueServiceType.passengerAndVehicle:
        return 'PASSENGER_VEHICLE_RESCUE';
      case RescueServiceType.breakdown:
        return 'BREAKDOWN_RESCUE';
      case RescueServiceType.emergency:
        return 'EMERGENCY_ASSISTANCE';
    }
  }

  String? _reasonToApi(RescueReason? reason) {
    if (reason == null) return null;
    switch (reason) {
      case RescueReason.stuckInTraffic:
        return 'stuck_in_traffic';
      case RescueReason.needVehicleDelivered:
        return 'need_vehicle_delivered';
      case RescueReason.feelingUnsafe:
        return 'feeling_unsafe';
      case RescueReason.driverUnavailable:
        return 'driver_unavailable';
      case RescueReason.longParkingWalk:
        return 'long_parking_walk';
      case RescueReason.vehicleNotStarting:
        return 'vehicle_not_starting';
      case RescueReason.other:
        return 'other';
    }
  }

  String? _vehicleSubTypeToApi(RescueVehicleDetails? details) {
    if (details == null) return null;
    switch (details.category) {
      case RescueVehicleCategory.bike:
        return 'BIKE';
      case RescueVehicleCategory.scooter:
        return 'SCOOTER';
      case RescueVehicleCategory.hatchback:
        return 'HATCHBACK';
      case RescueVehicleCategory.sedan:
        return 'SEDAN';
      case RescueVehicleCategory.suv:
        return 'SUV';
    }
  }

  String? _transmissionToApi(RescueTransmission? transmission) {
    if (transmission == null) return null;
    return transmission == RescueTransmission.manual ? 'MANUAL' : 'AUTOMATIC';
  }
}

/// Presigned upload URL response.
class RescueUploadUrl {
  const RescueUploadUrl({
    required this.uploadUrl,
    required this.downloadUrl,
    required this.key,
  });

  final String uploadUrl;
  final String downloadUrl;
  final String key;
}

final rescueRepositoryProvider = Provider<RescueRepository>((ref) {
  return RescueRepository(ref.watch(apiClientProvider));
});
