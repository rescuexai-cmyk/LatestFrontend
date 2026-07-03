import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/api_client.dart';
import 'driver_onboarding_provider.dart'
    show BackendOnboardingStatus, DocumentStatus;

/// Onboarding for independent / personal-rescue drivers (no vehicle).
/// Maps to the backend `independent_driver` category (service types
/// personal_driver + bike_rescue). Documents required: LICENSE, PAN_CARD,
/// AADHAAR_CARD, PROFILE_PHOTO (no RC / Insurance).
enum PersonalDriverOnboardingStatus {
  notStarted,
  inProgress,
  documentsSubmitted,
  underReview,
  verified,
  rejected,
}

enum PersonalDocStatus {
  notUploaded,
  uploaded,
  inReview,
  verified,
  rejected,
}

class PersonalDriverDocument {
  const PersonalDriverDocument({
    required this.type,
    this.frontPath,
    this.backPath,
    this.status = PersonalDocStatus.notUploaded,
    this.aiVerified,
    this.aiConfidence,
    this.verificationReason,
  });

  final String type;
  final String? frontPath;
  final String? backPath;
  final PersonalDocStatus status;

  /// Backend AI/Cloud-Vision verdict for this document (null = not evaluated yet).
  final bool? aiVerified;

  /// Cloud-Vision confidence score (0–1), when the backend returns one.
  final double? aiConfidence;

  /// Human-readable reason a document was flagged/rejected by verification.
  final String? verificationReason;

  bool get isComplete =>
      frontPath != null &&
      frontPath!.isNotEmpty &&
      (type != 'aadhaar_card' || (backPath != null && backPath!.isNotEmpty));

  PersonalDriverDocument copyWith({
    String? frontPath,
    String? backPath,
    PersonalDocStatus? status,
    bool? aiVerified,
    double? aiConfidence,
    String? verificationReason,
  }) {
    return PersonalDriverDocument(
      type: type,
      frontPath: frontPath ?? this.frontPath,
      backPath: backPath ?? this.backPath,
      status: status ?? this.status,
      aiVerified: aiVerified ?? this.aiVerified,
      aiConfidence: aiConfidence ?? this.aiConfidence,
      verificationReason: verificationReason ?? this.verificationReason,
    );
  }

  static PersonalDocStatus _parseStatus(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'uploaded':
        return PersonalDocStatus.uploaded;
      case 'in_review':
      case 'inreview':
        return PersonalDocStatus.inReview;
      case 'verified':
        return PersonalDocStatus.verified;
      case 'rejected':
        return PersonalDocStatus.rejected;
      default:
        return PersonalDocStatus.notUploaded;
    }
  }

  static PersonalDriverDocument fromPrefs(
    String type,
    SharedPreferences prefs,
  ) {
    return PersonalDriverDocument(
      type: type,
      frontPath: prefs.getString('pd_${type}_front'),
      backPath: prefs.getString('pd_${type}_back'),
      status: _parseStatus(prefs.getString('pd_${type}_status')),
    );
  }

  Future<void> saveToPrefs(SharedPreferences prefs) async {
    if (frontPath != null) {
      await prefs.setString('pd_${type}_front', frontPath!);
    }
    if (backPath != null) {
      await prefs.setString('pd_${type}_back', backPath!);
    }
    await prefs.setString('pd_${type}_status', status.name);
  }
}

class PersonalDriverOnboardingState {
  const PersonalDriverOnboardingState({
    this.status = PersonalDriverOnboardingStatus.notStarted,
    this.drivingLicense = const PersonalDriverDocument(type: 'driving_license'),
    this.aadhaar = const PersonalDriverDocument(type: 'aadhaar_card'),
    this.pan = const PersonalDriverDocument(type: 'pan_card'),
    this.profilePhoto = const PersonalDriverDocument(type: 'profile_photo'),
    this.fullName = '',
    this.email = '',
    this.driverAppMode = 'ride_share',
    this.isLoading = false,
    this.error,
  });

  /// Rider-facing product type this driver serves.
  static const vehicleTypeId = 'personal_driver';

  /// Backend onboarding category / vehicleType for independent drivers.
  static const onboardingVehicleType = 'independent_driver';

  /// Service types an independent driver can fulfil.
  static const serviceTypes = ['personal_driver', 'bike_rescue'];

  final PersonalDriverOnboardingStatus status;
  final PersonalDriverDocument drivingLicense;
  final PersonalDriverDocument aadhaar;
  final PersonalDriverDocument pan;
  final PersonalDriverDocument profilePhoto;
  final String fullName;
  final String? email;
  final String driverAppMode;
  final bool isLoading;
  final String? error;

  bool get isPersonalDriverActive =>
      status != PersonalDriverOnboardingStatus.notStarted;

  bool get documentsReady =>
      fullName.trim().isNotEmpty &&
      drivingLicense.isComplete &&
      aadhaar.isComplete &&
      pan.isComplete &&
      profilePhoto.isComplete;

  bool get canStartRescueJobs =>
      status == PersonalDriverOnboardingStatus.verified ||
      status == PersonalDriverOnboardingStatus.documentsSubmitted ||
      status == PersonalDriverOnboardingStatus.underReview;

  bool get shouldShowOnboarding =>
      status == PersonalDriverOnboardingStatus.notStarted ||
      status == PersonalDriverOnboardingStatus.inProgress;

  bool get shouldShowWelcome =>
      status == PersonalDriverOnboardingStatus.documentsSubmitted ||
      status == PersonalDriverOnboardingStatus.underReview ||
      status == PersonalDriverOnboardingStatus.rejected;

  PersonalDriverOnboardingState copyWith({
    PersonalDriverOnboardingStatus? status,
    PersonalDriverDocument? drivingLicense,
    PersonalDriverDocument? aadhaar,
    PersonalDriverDocument? pan,
    PersonalDriverDocument? profilePhoto,
    String? fullName,
    String? email,
    String? driverAppMode,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return PersonalDriverOnboardingState(
      status: status ?? this.status,
      drivingLicense: drivingLicense ?? this.drivingLicense,
      aadhaar: aadhaar ?? this.aadhaar,
      pan: pan ?? this.pan,
      profilePhoto: profilePhoto ?? this.profilePhoto,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      driverAppMode: driverAppMode ?? this.driverAppMode,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PersonalDriverOnboardingNotifier
    extends StateNotifier<PersonalDriverOnboardingState> {
  PersonalDriverOnboardingNotifier() : super(const PersonalDriverOnboardingState()) {
    _loadFuture = _loadFromPrefs();
  }

  Future<void>? _loadFuture;

  /// Await prefs hydration before routing / driver-home mode detection.
  Future<void> ensureLoaded() => _loadFuture ?? Future.value();

  static const _statusKey = 'personal_driver_onboarding_status';
  static const _fullNameKey = 'personal_driver_full_name';
  static const _emailKey = 'personal_driver_email';
  static const _modeKey = 'driver_app_mode';
  static const modePersonalRescue = 'personal_rescue';
  static const modeRideShare = 'ride_share';

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statusRaw = prefs.getString(_statusKey);
      final status = _parseStatus(statusRaw);
      state = state.copyWith(
        status: status,
        fullName: prefs.getString(_fullNameKey) ?? '',
        email: prefs.getString(_emailKey) ?? '',
        driverAppMode:
            prefs.getString(_modeKey) ?? PersonalDriverOnboardingNotifier.modeRideShare,
        drivingLicense:
            PersonalDriverDocument.fromPrefs('driving_license', prefs),
        aadhaar: PersonalDriverDocument.fromPrefs('aadhaar_card', prefs),
        pan: PersonalDriverDocument.fromPrefs('pan_card', prefs),
        profilePhoto: PersonalDriverDocument.fromPrefs('profile_photo', prefs),
      );
    } catch (e) {
      debugPrint('⚠️ Failed to load personal driver prefs: $e');
    }
  }

  PersonalDriverOnboardingStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'inProgress':
        return PersonalDriverOnboardingStatus.inProgress;
      case 'documentsSubmitted':
        return PersonalDriverOnboardingStatus.documentsSubmitted;
      case 'underReview':
        return PersonalDriverOnboardingStatus.underReview;
      case 'verified':
        return PersonalDriverOnboardingStatus.verified;
      case 'rejected':
        return PersonalDriverOnboardingStatus.rejected;
      default:
        return PersonalDriverOnboardingStatus.notStarted;
    }
  }

  Future<void> _persistStatus(PersonalDriverOnboardingStatus status) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statusKey, status.name);
    if (status != PersonalDriverOnboardingStatus.notStarted) {
      await prefs.setString(_modeKey, modePersonalRescue);
    }
  }

  Future<void> setDriverAppMode(String mode) async {
    state = state.copyWith(driverAppMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode);
  }

  Future<void> startOnboarding() async {
    state = state.copyWith(
      status: PersonalDriverOnboardingStatus.inProgress,
      clearError: true,
    );
    await _persistStatus(PersonalDriverOnboardingStatus.inProgress);
  }

  Future<void> setFullName(String fullName) async {
    final trimmed = fullName.trim();
    state = state.copyWith(fullName: trimmed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fullNameKey, trimmed);
  }

  Future<void> setEmail(String email) async {
    state = state.copyWith(email: email.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, email.trim());
  }

  Future<void> saveDocumentPath({
    required String docType,
    required String path,
    required bool isFront,
  }) async {
    PersonalDriverDocument doc;
    switch (docType) {
      case 'driving_license':
        doc = state.drivingLicense.copyWith(
          frontPath: isFront ? path : state.drivingLicense.frontPath,
          status: PersonalDocStatus.uploaded,
        );
        state = state.copyWith(drivingLicense: doc);
        break;
      case 'pan_card':
        doc = state.pan.copyWith(
          frontPath: isFront ? path : state.pan.frontPath,
          status: PersonalDocStatus.uploaded,
        );
        state = state.copyWith(pan: doc);
        break;
      case 'profile_photo':
        doc = state.profilePhoto.copyWith(
          frontPath: isFront ? path : state.profilePhoto.frontPath,
          status: PersonalDocStatus.uploaded,
        );
        state = state.copyWith(profilePhoto: doc);
        break;
      case 'aadhaar_card':
      default:
        doc = state.aadhaar.copyWith(
          frontPath: isFront ? path : state.aadhaar.frontPath,
          backPath: !isFront ? path : state.aadhaar.backPath,
          status: PersonalDocStatus.uploaded,
        );
        state = state.copyWith(aadhaar: doc);
        break;
    }
    final prefs = await SharedPreferences.getInstance();
    await doc.saveToPrefs(prefs);
  }

  /// Submit onboarding to the backend as an `independent_driver`.
  ///
  /// Sequence (all under /api/driver/onboarding/*):
  /// start → email → language → vehicle(independent_driver) → personal-info →
  /// document uploads (LICENSE, AADHAAR front+back, PAN, PROFILE_PHOTO) →
  /// documents/submit.
  Future<bool> submitDocuments() async {
    if (state.fullName.trim().isEmpty) {
      state = state.copyWith(error: 'Please enter your full name');
      return false;
    }
    if (!state.documentsReady) {
      state = state.copyWith(error: 'Please upload all required documents');
      return false;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    final email = state.email?.trim() ?? '';
    try {
      // Non-critical steps: keep going even if the backend rejects a repeat
      // (e.g. onboarding already started).
      try {
        await apiClient.startDriverOnboarding();
      } catch (e) {
        debugPrint('ℹ️ startDriverOnboarding skipped: $e');
      }
      if (email.isNotEmpty) {
        try {
          await apiClient.updateDriverEmail(email);
        } catch (e) {
          debugPrint('ℹ️ updateDriverEmail skipped: $e');
        }
      }
      try {
        await apiClient.updateDriverLanguage('en');
      } catch (e) {
        debugPrint('ℹ️ updateDriverLanguage skipped: $e');
      }

      // Critical steps.
      await apiClient.updateDriverVehicle(
        vehicleType: PersonalDriverOnboardingState.onboardingVehicleType,
        serviceTypes: PersonalDriverOnboardingState.serviceTypes,
      );
      await apiClient.updateDriverPersonalInfo(
        fullName: state.fullName.trim(),
        email: email.isNotEmpty ? email : null,
      );

      await _uploadDoc('driving_license', state.drivingLicense.frontPath,
          isFront: true);
      await _uploadDoc('aadhaar_card', state.aadhaar.frontPath, isFront: true);
      await _uploadDoc('aadhaar_card', state.aadhaar.backPath, isFront: false);
      await _uploadDoc('pan_card', state.pan.frontPath, isFront: true);
      await _uploadDoc('profile_photo', state.profilePhoto.frontPath,
          isFront: true);

      await apiClient.submitDriverDocuments();

      final dl =
          state.drivingLicense.copyWith(status: PersonalDocStatus.inReview);
      final ad = state.aadhaar.copyWith(status: PersonalDocStatus.inReview);
      final pn = state.pan.copyWith(status: PersonalDocStatus.inReview);
      final ph = state.profilePhoto.copyWith(status: PersonalDocStatus.inReview);
      state = state.copyWith(
        drivingLicense: dl,
        aadhaar: ad,
        pan: pn,
        profilePhoto: ph,
        status: PersonalDriverOnboardingStatus.documentsSubmitted,
        isLoading: false,
      );
      final prefs = await SharedPreferences.getInstance();
      await dl.saveToPrefs(prefs);
      await ad.saveToPrefs(prefs);
      await pn.saveToPrefs(prefs);
      await ph.saveToPrefs(prefs);
      await _persistStatus(PersonalDriverOnboardingStatus.documentsSubmitted);

      // Pull the backend's Cloud-Vision/AI verification verdict so the UI can
      // show verified/flagged results per ID document instead of a generic
      // "in review" state. Best-effort: verification may still be processing.
      await refreshVerificationStatus();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e),
      );
      return false;
    }
  }

  /// Fetch the backend onboarding status and fold the Cloud-Vision/AI
  /// verification verdict into each ID document (LICENSE, AADHAAR, PAN) and the
  /// profile photo. Safe to call repeatedly (e.g. on the status screen).
  Future<void> refreshVerificationStatus() async {
    try {
      final resp = await apiClient.getDriverOnboardingStatus();
      final backend = BackendOnboardingStatus.fromJson(resp);

      final dl = _applyVerification(state.drivingLicense, backend, 'LICENSE');
      final ad = _applyVerification(state.aadhaar, backend, 'AADHAAR_CARD');
      final pn = _applyVerification(state.pan, backend, 'PAN_CARD');
      final ph =
          _applyVerification(state.profilePhoto, backend, 'PROFILE_PHOTO');

      PersonalDriverOnboardingStatus overall;
      if (backend.hasRejectedDocuments) {
        overall = PersonalDriverOnboardingStatus.rejected;
      } else if (backend.canStartRides || backend.documentsVerified) {
        overall = PersonalDriverOnboardingStatus.verified;
      } else {
        overall = PersonalDriverOnboardingStatus.underReview;
      }

      state = state.copyWith(
        drivingLicense: dl,
        aadhaar: ad,
        pan: pn,
        profilePhoto: ph,
        status: overall,
      );

      final prefs = await SharedPreferences.getInstance();
      await dl.saveToPrefs(prefs);
      await ad.saveToPrefs(prefs);
      await pn.saveToPrefs(prefs);
      await ph.saveToPrefs(prefs);
      await _persistStatus(overall);
    } catch (e) {
      debugPrint('ℹ️ refreshVerificationStatus skipped: $e');
    }
  }

  /// Merge a backend document detail (Cloud-Vision verdict) into a local doc.
  PersonalDriverDocument _applyVerification(
    PersonalDriverDocument doc,
    BackendOnboardingStatus backend,
    String backendType,
  ) {
    bool? aiVerified;
    double? aiConfidence;
    for (final detail in backend.documentDetails) {
      if (detail.type.toUpperCase() == backendType) {
        aiVerified = detail.aiVerified;
        aiConfidence = detail.aiConfidence;
        break;
      }
    }
    return PersonalDriverDocument(
      type: doc.type,
      frontPath: doc.frontPath,
      backPath: doc.backPath,
      status: _mapBackendDocStatus(backend.getDocumentStatus(backendType)),
      aiVerified: aiVerified,
      aiConfidence: aiConfidence,
      verificationReason: backend.getRejectionReason(backendType),
    );
  }

  PersonalDocStatus _mapBackendDocStatus(DocumentStatus s) {
    switch (s) {
      case DocumentStatus.verified:
        return PersonalDocStatus.verified;
      case DocumentStatus.rejected:
        return PersonalDocStatus.rejected;
      case DocumentStatus.inReview:
        return PersonalDocStatus.inReview;
      case DocumentStatus.uploaded:
      case DocumentStatus.uploading:
        return PersonalDocStatus.uploaded;
      case DocumentStatus.notUploaded:
        return PersonalDocStatus.notUploaded;
    }
  }

  Future<void> _uploadDoc(
    String docType,
    String? path, {
    required bool isFront,
  }) async {
    if (path == null || path.isEmpty) {
      throw Exception('Missing document: $docType');
    }
    await apiClient.uploadDriverDocument(
      documentType: docType,
      filePath: path,
      isFront: isFront,
    );
  }

  String _friendlyError(Object e) {
    final msg = e.toString().replaceFirst('Exception: ', '').trim();
    if (msg.isEmpty) return 'Could not submit documents. Please try again.';
    return msg;
  }

  Future<void> markVerifiedLocally() async {
    state = state.copyWith(status: PersonalDriverOnboardingStatus.verified);
    await _persistStatus(PersonalDriverOnboardingStatus.verified);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_statusKey);
    await prefs.remove(_fullNameKey);
    await prefs.remove(_emailKey);
    await prefs.remove('pd_driving_license_front');
    await prefs.remove('pd_driving_license_back');
    await prefs.remove('pd_driving_license_status');
    await prefs.remove('pd_aadhaar_card_front');
    await prefs.remove('pd_aadhaar_card_back');
    await prefs.remove('pd_aadhaar_card_status');
    await prefs.remove('pd_pan_card_front');
    await prefs.remove('pd_pan_card_back');
    await prefs.remove('pd_pan_card_status');
    await prefs.remove('pd_profile_photo_front');
    await prefs.remove('pd_profile_photo_back');
    await prefs.remove('pd_profile_photo_status');
    await prefs.setString(_modeKey, modeRideShare);
    state = const PersonalDriverOnboardingState();
  }
}

final personalDriverOnboardingProvider = StateNotifierProvider<
    PersonalDriverOnboardingNotifier, PersonalDriverOnboardingState>(
  (ref) => PersonalDriverOnboardingNotifier(),
);

/// Whether driver home should run in personal rescue mode (passenger leg only).
final isPersonalRescueDriverModeProvider = Provider<bool>((ref) {
  return ref.watch(personalDriverOnboardingProvider).driverAppMode ==
      PersonalDriverOnboardingNotifier.modePersonalRescue;
});

/// Whether the app is in personal rescue driver mode vs standard ride-share driver.
final isPersonalRescueDriverProvider = Provider<bool>((ref) {
  final pd = ref.watch(personalDriverOnboardingProvider);
  return pd.driverAppMode == PersonalDriverOnboardingNotifier.modePersonalRescue &&
      pd.isPersonalDriverActive &&
      pd.canStartRescueJobs;
});
