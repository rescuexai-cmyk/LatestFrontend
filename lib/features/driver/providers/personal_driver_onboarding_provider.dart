import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight onboarding for rescue personal drivers (passenger leg).
/// Backend integration will replace local persistence later.
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
  });

  final String type;
  final String? frontPath;
  final String? backPath;
  final PersonalDocStatus status;

  bool get isComplete =>
      frontPath != null &&
      frontPath!.isNotEmpty &&
      (type != 'aadhaar_card' || (backPath != null && backPath!.isNotEmpty));

  PersonalDriverDocument copyWith({
    String? frontPath,
    String? backPath,
    PersonalDocStatus? status,
  }) {
    return PersonalDriverDocument(
      type: type,
      frontPath: frontPath ?? this.frontPath,
      backPath: backPath ?? this.backPath,
      status: status ?? this.status,
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
    this.fullName = '',
    this.email = '',
    this.driverAppMode = 'ride_share',
    this.isLoading = false,
    this.error,
  });

  static const vehicleTypeId = 'personal_driver';

  final PersonalDriverOnboardingStatus status;
  final PersonalDriverDocument drivingLicense;
  final PersonalDriverDocument aadhaar;
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
      aadhaar.isComplete;

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
    if (docType == 'driving_license') {
      doc = state.drivingLicense.copyWith(
        frontPath: isFront ? path : state.drivingLicense.frontPath,
        status: PersonalDocStatus.uploaded,
      );
      state = state.copyWith(drivingLicense: doc);
    } else {
      doc = state.aadhaar.copyWith(
        frontPath: isFront ? path : state.aadhaar.frontPath,
        backPath: !isFront ? path : state.aadhaar.backPath,
        status: PersonalDocStatus.uploaded,
      );
      state = state.copyWith(aadhaar: doc);
    }
    final prefs = await SharedPreferences.getInstance();
    await doc.saveToPrefs(prefs);
  }

  /// Stub submit — marks docs under review until backend is wired.
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
    try {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final dl = state.drivingLicense.copyWith(status: PersonalDocStatus.inReview);
      final ad = state.aadhaar.copyWith(status: PersonalDocStatus.inReview);
      state = state.copyWith(
        drivingLicense: dl,
        aadhaar: ad,
        status: PersonalDriverOnboardingStatus.documentsSubmitted,
        isLoading: false,
      );
      final prefs = await SharedPreferences.getInstance();
      await dl.saveToPrefs(prefs);
      await ad.saveToPrefs(prefs);
      await _persistStatus(PersonalDriverOnboardingStatus.documentsSubmitted);
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Could not submit documents. Try again.',
      );
      return false;
    }
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
