import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/push_notification_service.dart';
import '../../auth/providers/auth_provider.dart';

/// Document verification status
enum DocumentStatus {
  notUploaded,
  uploading,
  uploaded,
  inReview,
  verified,
  rejected,
}

/// Backend onboarding status values
enum OnboardingStatus {
  notStarted,
  started,
  documentsUploaded,
  documentVerification,
  completed,
  rejected,
}

OnboardingStatus _parseOnboardingStatus(String? raw) {
  debugPrint('📋 _parseOnboardingStatus raw value: "$raw"');
  switch (raw?.toUpperCase()) {
    case 'NOT_STARTED':
      return OnboardingStatus.notStarted;
    case 'STARTED':
    case 'LICENSE_UPLOAD':
    case 'RC_UPLOAD':
    case 'INSURANCE_UPLOAD':
    case 'PAN_CARD_UPLOAD':
    case 'AADHAAR_CARD_UPLOAD':
    case 'PROFILE_PHOTO_UPLOAD':
    case 'VEHICLE_DETAILS':
    case 'PERSONAL_INFO':
      return OnboardingStatus.started;
    case 'DOCUMENTS_UPLOADED':
      return OnboardingStatus.documentsUploaded;
    case 'DOCUMENT_VERIFICATION':
    case 'UNDER_REVIEW':
    case 'PENDING_VERIFICATION':
    case 'PENDING':
    case 'IN_REVIEW':
      return OnboardingStatus.documentVerification;
    case 'COMPLETED':
    case 'APPROVED':
    case 'VERIFIED':
    case 'ACTIVE':
      return OnboardingStatus.completed;
    case 'REJECTED':
      return OnboardingStatus.rejected;
    default:
      debugPrint('⚠️ Unknown onboarding status: "$raw", defaulting to notStarted');
      return OnboardingStatus.notStarted;
  }
}

/// Driver document model
class DriverDocument {
  final String type;
  final String? documentNumber;
  final String? frontImagePath;
  final String? backImagePath;
  final DocumentStatus status;
  final String? rejectionReason;

  const DriverDocument({
    required this.type,
    this.documentNumber,
    this.frontImagePath,
    this.backImagePath,
    this.status = DocumentStatus.notUploaded,
    this.rejectionReason,
  });

  DriverDocument copyWith({
    String? type,
    String? documentNumber,
    String? frontImagePath,
    String? backImagePath,
    DocumentStatus? status,
    String? rejectionReason,
  }) {
    return DriverDocument(
      type: type ?? this.type,
      documentNumber: documentNumber ?? this.documentNumber,
      frontImagePath: frontImagePath ?? this.frontImagePath,
      backImagePath: backImagePath ?? this.backImagePath,
      status: status ?? this.status,
      rejectionReason: rejectionReason ?? this.rejectionReason,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'documentNumber': documentNumber,
    'frontImagePath': frontImagePath,
    'backImagePath': backImagePath,
    'status': status.name,
    'rejectionReason': rejectionReason,
  };

  factory DriverDocument.fromJson(Map<String, dynamic> json) => DriverDocument(
    type: json['type'] as String,
    documentNumber: json['documentNumber'] as String?,
    frontImagePath: json['frontImagePath'] as String?,
    backImagePath: json['backImagePath'] as String?,
    status: DocumentStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => DocumentStatus.notUploaded,
    ),
    rejectionReason: json['rejectionReason'] as String?,
  );
}

/// Backend document info from documents.details[]
class BackendDocumentInfo {
  final String type;
  final String status;
  final String? url;
  final String? rejectionReason;
  final String? aiMismatchReason;
  final double? aiConfidence;
  final bool? aiVerified;

  const BackendDocumentInfo({
    required this.type,
    required this.status,
    this.url,
    this.rejectionReason,
    this.aiMismatchReason,
    this.aiConfidence,
    this.aiVerified,
  });

  /// True if this document needs attention (rejected, failed, or flagged by AI)
  bool get isFlaggedOrRejected {
    final s = status.toUpperCase();
    return s == 'REJECTED' || s == 'FAILED' || s == 'FLAGGED' ||
        (rejectionReason != null && rejectionReason!.isNotEmpty) ||
        (aiMismatchReason != null && aiMismatchReason!.isNotEmpty);
  }

  /// The display reason: prefers explicit rejection, falls back to AI mismatch
  String? get displayReason {
    if (rejectionReason != null && rejectionReason!.isNotEmpty) return rejectionReason;
    if (aiMismatchReason != null && aiMismatchReason!.isNotEmpty) return aiMismatchReason;
    return null;
  }

  factory BackendDocumentInfo.fromJson(Map<String, dynamic> json) {
    // Parse status from multiple possible field names
    final rawStatus = json['status'] as String? ??
        json['verificationStatus'] as String? ??
        json['verification_status'] as String?;
    final isVerified = json['is_verified'] as bool? ?? json['isVerified'] as bool?;

    // Parse rejection reason
    final reason = json['rejectionReason'] as String? ??
        json['rejection_reason'] as String?;

    // Parse AI mismatch reason
    final aiReason = json['aiMismatchReason'] as String? ??
        json['ai_mismatch_reason'] as String?;

    final hasIssue = (reason != null && reason.isNotEmpty) ||
        (aiReason != null && aiReason.isNotEmpty);

    // Derive canonical status
    String status;
    final upper = rawStatus?.toUpperCase() ?? '';
    if (upper == 'VERIFIED') {
      status = 'VERIFIED';
    } else if (upper == 'REJECTED' || upper == 'FAILED') {
      status = 'REJECTED';
    } else if (upper == 'FLAGGED') {
      status = 'FLAGGED';
    } else if (rawStatus != null && rawStatus.isNotEmpty) {
      status = rawStatus.toUpperCase();
    } else if (hasIssue) {
      status = 'FLAGGED';
    } else if (isVerified == true) {
      status = 'VERIFIED';
    } else if (isVerified == false) {
      status = 'PENDING';
    } else {
      status = 'NOT_UPLOADED';
    }

    return BackendDocumentInfo(
      type: json['type'] as String? ?? json['documentType'] as String? ?? '',
      status: status,
      url: json['url'] as String? ?? json['documentUrl'] as String?,
      rejectionReason: reason,
      aiMismatchReason: aiReason,
      aiConfidence: (json['aiConfidence'] as num?)?.toDouble() ??
          (json['ai_confidence'] as num?)?.toDouble(),
      aiVerified: json['aiVerified'] as bool? ?? json['ai_verified'] as bool?,
    );
  }
}

/// Backend-driven onboarding status snapshot.
/// Fetched from GET /api/driver/onboarding/status.
class BackendOnboardingStatus {
  final OnboardingStatus onboardingStatus;
  final bool canStartRides;
  final String? message;
  final bool isVerified;
  final bool isOnboardingComplete;
  final bool documentsSubmitted;
  final bool documentsVerified;
  final double verificationProgress;
  
  // Document status lists from backend
  final List<String> requiredDocuments;
  final List<String> uploadedDocuments;
  final List<String> verifiedDocuments;
  final List<String> pendingDocuments;
  final List<String> rejectedDocuments;
  final List<BackendDocumentInfo> documentDetails;

  const BackendOnboardingStatus({
    this.onboardingStatus = OnboardingStatus.notStarted,
    this.canStartRides = false,
    this.message,
    this.isVerified = false,
    this.isOnboardingComplete = false,
    this.documentsSubmitted = false,
    this.documentsVerified = false,
    this.verificationProgress = 0.0,
    this.requiredDocuments = const [],
    this.uploadedDocuments = const [],
    this.verifiedDocuments = const [],
    this.pendingDocuments = const [],
    this.rejectedDocuments = const [],
    this.documentDetails = const [],
  });

  factory BackendOnboardingStatus.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final docs = data['documents'] as Map<String, dynamic>? ?? {};
    
    // Parse document arrays
    final required = (docs['required'] as List?)?.cast<String>() ?? [];
    final uploaded = (docs['uploaded'] as List?)?.cast<String>() ?? [];
    final verified = (docs['verified'] as List?)?.cast<String>() ?? [];
    final pending = (docs['pending'] as List?)?.map((item) {
      if (item is String) return item;
      if (item is Map<String, dynamic>) return item['type'] as String? ?? '';
      return '';
    }).where((s) => s.isNotEmpty).toList() ?? [];
    final details = (docs['details'] as List?)
        ?.map((d) => BackendDocumentInfo.fromJson(d as Map<String, dynamic>))
        .toList() ?? [];

    // Parse rejected documents from explicit 'rejected' list
    final rejectedRaw = (docs['rejected'] as List?)?.map((item) {
      if (item is String) return item;
      if (item is Map<String, dynamic>) return item['type'] as String? ?? '';
      return '';
    }).where((s) => s.isNotEmpty).toList() ?? <String>[];

    // Parse flagged documents from backend's new 'flagged' array
    final flaggedList = docs['flagged'] as List? ?? [];
    for (final item in flaggedList) {
      final type = item is String ? item : (item is Map<String, dynamic> ? item['type'] as String? ?? '' : '');
      if (type.isNotEmpty && !rejectedRaw.contains(type)) {
        rejectedRaw.add(type);
      }
    }

    // Check details for rejected/failed/flagged docs
    for (final detail in details) {
      if (detail.isFlaggedOrRejected && !rejectedRaw.contains(detail.type)) {
        rejectedRaw.add(detail.type);
        debugPrint('📋 Document ${detail.type} flagged/rejected: '
            'status=${detail.status}, reason=${detail.displayReason}, '
            'aiConfidence=${detail.aiConfidence}');
      }
    }

    // Check pending items for rejection/AI mismatch reasons
    final pendingRaw = docs['pending'] as List? ?? [];
    for (final item in pendingRaw) {
      if (item is Map<String, dynamic>) {
        final type = item['type'] as String? ?? '';
        final reason = item['rejection_reason'] as String? ??
            item['rejectionReason'] as String?;
        final aiReason = item['aiMismatchReason'] as String? ??
            item['ai_mismatch_reason'] as String?;
        if (type.isNotEmpty && !rejectedRaw.contains(type) &&
            ((reason != null && reason.isNotEmpty) || (aiReason != null && aiReason.isNotEmpty))) {
          rejectedRaw.add(type);
        }
      }
    }

    // Remove rejected docs from pending list
    final cleanPending = pending.where((t) => !rejectedRaw.contains(t)).toList();
    
    debugPrint('📋 Backend documents: required=$required, uploaded=$uploaded, verified=$verified, pending=$cleanPending, rejected=$rejectedRaw');
    debugPrint('📋 Document details count: ${details.length}');
    
    // Parse the raw status first
    var parsedStatus = _parseOnboardingStatus(
      data['onboarding_status'] as String? ?? data['onboardingStatus'] as String?,
    );
    
    // Smart derivation: if the raw status maps to "started" but all required
    // docs are already uploaded, upgrade the status based on actual doc state.
    if (parsedStatus == OnboardingStatus.started ||
        parsedStatus == OnboardingStatus.notStarted) {
      final allRequiredUploaded = required.isNotEmpty &&
          required.every((doc) => uploaded.contains(doc));
      if (allRequiredUploaded) {
        if (rejectedRaw.isNotEmpty) {
          parsedStatus = OnboardingStatus.rejected;
        } else if (cleanPending.isNotEmpty) {
          parsedStatus = OnboardingStatus.documentVerification;
        } else if (verified.length == required.length) {
          parsedStatus = OnboardingStatus.completed;
        } else {
          parsedStatus = OnboardingStatus.documentsUploaded;
        }
        debugPrint('📋 Overrode onboarding status to ${parsedStatus.name} '
            '(all ${required.length} docs uploaded, ${cleanPending.length} pending, '
            '${verified.length} verified, ${rejectedRaw.length} rejected)');
      }
    }
    
    final canStartRaw =
        data['can_start_rides'] as bool? ?? data['canStartRides'] as bool?;
    final derivedCanStart = parsedStatus == OnboardingStatus.completed &&
        rejectedRaw.isEmpty;

    return BackendOnboardingStatus(
      onboardingStatus: parsedStatus,
      // Some backend responses occasionally omit can_start_rides.
      // In that case, derive eligibility from onboarding completion state
      // to avoid falsely blocking verified drivers.
      canStartRides: canStartRaw ?? derivedCanStart,
      message: data['message'] as String?,
      isVerified: data['is_verified'] as bool? ?? data['isVerified'] as bool? ?? false,
      isOnboardingComplete: data['is_onboarding_complete'] as bool? ?? data['isOnboardingComplete'] as bool? ?? false,
      documentsSubmitted: data['documents_submitted'] as bool? ?? data['documentsSubmitted'] as bool? ?? false,
      documentsVerified: data['documents_verified'] as bool? ?? data['documentsVerified'] as bool? ?? false,
      verificationProgress: (data['verification_progress'] as num?)?.toDouble() ?? 
                           (data['verificationProgress'] as num?)?.toDouble() ?? 0.0,
      requiredDocuments: required,
      uploadedDocuments: uploaded,
      verifiedDocuments: verified,
      pendingDocuments: cleanPending,
      rejectedDocuments: rejectedRaw,
      documentDetails: details,
    );
  }
  
  /// Check if a document type is uploaded (by backend type name: LICENSE, RC, etc.)
  bool isDocumentUploaded(String backendType) => uploadedDocuments.contains(backendType);
  
  /// Check if a document type is verified
  bool isDocumentVerified(String backendType) => verifiedDocuments.contains(backendType);
  
  /// Check if a document type is pending verification
  bool isDocumentPending(String backendType) => pendingDocuments.contains(backendType);
  
  /// Get document status for a backend type
  DocumentStatus getDocumentStatus(String backendType) {
    if (rejectedDocuments.contains(backendType)) return DocumentStatus.rejected;
    if (verifiedDocuments.contains(backendType)) return DocumentStatus.verified;
    if (pendingDocuments.contains(backendType)) return DocumentStatus.inReview;
    if (uploadedDocuments.contains(backendType)) return DocumentStatus.uploaded;
    return DocumentStatus.notUploaded;
  }

  /// Get the reason a document was flagged or rejected.
  /// Checks rejectionReason first, then aiMismatchReason from details.
  String? getRejectionReason(String backendType) {
    for (final detail in documentDetails) {
      if (detail.type == backendType) {
        final reason = detail.displayReason;
        if (reason != null && reason.isNotEmpty) return reason;
      }
    }
    return null;
  }

  /// Get AI confidence score for a document, if available
  double? getAiConfidence(String backendType) {
    for (final detail in documentDetails) {
      if (detail.type == backendType) return detail.aiConfidence;
    }
    return null;
  }

  /// True if any required document was rejected
  bool get hasRejectedDocuments => rejectedDocuments.isNotEmpty;
}

/// Driver onboarding state
class DriverOnboardingState {
  final bool isLoading;
  final String? error;

  // Step 1: Basic info
  final String? selectedLanguage;
  final String? selectedVehicleType;
  final String? referralCode;

  // Step 2: Personal info
  final String? fullName;
  final String? email;

  // Step 3: Documents
  final DriverDocument drivingLicense;
  final DriverDocument vehicleRC;
  final DriverDocument vehicleInsurance;
  final DriverDocument aadhaarCard;
  final DriverDocument panCard;
  final String? profilePhotoPath;

  // Step 4: Location
  final String? registeredLocation;
  final String? registeredState;

  // Backend-driven status (single source of truth)
  final BackendOnboardingStatus backendStatus;
  final bool hasFetchedBackendStatus;

  // UI step tracking
  final int currentStep;

  const DriverOnboardingState({
    this.isLoading = false,
    this.error,
    this.selectedLanguage,
    this.selectedVehicleType,
    this.referralCode,
    this.fullName,
    this.email,
    this.drivingLicense = const DriverDocument(type: 'driving_license'),
    this.vehicleRC = const DriverDocument(type: 'vehicle_rc'),
    this.vehicleInsurance = const DriverDocument(type: 'vehicle_insurance'),
    this.aadhaarCard = const DriverDocument(type: 'aadhaar'),
    this.panCard = const DriverDocument(type: 'pan'),
    this.profilePhotoPath,
    this.registeredLocation,
    this.registeredState,
    this.backendStatus = const BackendOnboardingStatus(),
    this.hasFetchedBackendStatus = false,
    this.currentStep = 0,
  });

  /// Derived from backend status — true only when backend says COMPLETED.
  bool get isOnboardingComplete =>
      backendStatus.onboardingStatus == OnboardingStatus.completed;

  /// Derived from backend — can the driver start rides?
  bool get canStartRides => backendStatus.canStartRides;

  /// True when docs are submitted and awaiting verification.
  bool get isUnderReview =>
      backendStatus.onboardingStatus == OnboardingStatus.documentVerification ||
      backendStatus.onboardingStatus == OnboardingStatus.documentsUploaded;

  /// True if any docs were rejected.
  bool get isRejected =>
      backendStatus.onboardingStatus == OnboardingStatus.rejected ||
      backendStatus.hasRejectedDocuments;

  /// True if onboarding hasn't been started or is in early stages.
  bool get needsOnboarding =>
      backendStatus.onboardingStatus == OnboardingStatus.notStarted ||
      backendStatus.onboardingStatus == OnboardingStatus.started;

  /// Kept for backward compat with UI — but driven by backend.
  bool get isVerified => canStartRides;

  DriverOnboardingState copyWith({
    bool? isLoading,
    String? error,
    String? selectedLanguage,
    String? selectedVehicleType,
    String? referralCode,
    String? fullName,
    String? email,
    DriverDocument? drivingLicense,
    DriverDocument? vehicleRC,
    DriverDocument? vehicleInsurance,
    DriverDocument? aadhaarCard,
    DriverDocument? panCard,
    String? profilePhotoPath,
    String? registeredLocation,
    String? registeredState,
    BackendOnboardingStatus? backendStatus,
    bool? hasFetchedBackendStatus,
    int? currentStep,
  }) {
    return DriverOnboardingState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      selectedLanguage: selectedLanguage ?? this.selectedLanguage,
      selectedVehicleType: selectedVehicleType ?? this.selectedVehicleType,
      referralCode: referralCode ?? this.referralCode,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      drivingLicense: drivingLicense ?? this.drivingLicense,
      vehicleRC: vehicleRC ?? this.vehicleRC,
      vehicleInsurance: vehicleInsurance ?? this.vehicleInsurance,
      aadhaarCard: aadhaarCard ?? this.aadhaarCard,
      panCard: panCard ?? this.panCard,
      profilePhotoPath: profilePhotoPath ?? this.profilePhotoPath,
      registeredLocation: registeredLocation ?? this.registeredLocation,
      registeredState: registeredState ?? this.registeredState,
      backendStatus: backendStatus ?? this.backendStatus,
      hasFetchedBackendStatus: hasFetchedBackendStatus ?? this.hasFetchedBackendStatus,
      currentStep: currentStep ?? this.currentStep,
    );
  }

  /// Check if all required documents are uploaded
  bool get allDocumentsUploaded {
    return drivingLicense.status != DocumentStatus.notUploaded &&
           vehicleRC.status != DocumentStatus.notUploaded &&
           aadhaarCard.status != DocumentStatus.notUploaded &&
           profilePhotoPath != null;
  }

  /// Check if all documents are verified
  bool get allDocumentsVerified {
    return drivingLicense.status == DocumentStatus.verified &&
           vehicleRC.status == DocumentStatus.verified &&
           aadhaarCard.status == DocumentStatus.verified;
  }

  /// Get overall verification progress (0.0 - 1.0)
  double get verificationProgress {
    // Use backend progress if we've fetched it and it's > 0
    if (hasFetchedBackendStatus && backendStatus.verificationProgress > 0) {
      return backendStatus.verificationProgress / 100.0; // Backend returns 0-100, we need 0-1
    }
    
    // Fallback: compute locally based on document states
    int total = 5;
    int completed = 0;

    if (drivingLicense.status != DocumentStatus.notUploaded) completed++;
    if (vehicleRC.status != DocumentStatus.notUploaded) completed++;
    if (aadhaarCard.status != DocumentStatus.notUploaded) completed++;
    if (profilePhotoPath != null) completed++;
    if (selectedVehicleType != null) completed++;

    return completed / total;
  }
}

/// Driver onboarding notifier — backend is the single source of truth.
class DriverOnboardingNotifier extends StateNotifier<DriverOnboardingState> {
  final ApiClient _apiClient;
  final Ref _ref;
  bool _completionNotificationShown = false;
  static const _completionNotifSentKeyPrefix = 'driver_completion_notif_sent_user_';

  DriverOnboardingNotifier(this._apiClient, this._ref) : super(const DriverOnboardingState()) {
    _loadMinimalPrefs();
  }

  /// Load only lightweight UI preferences (language, vehicle type) for the
  /// onboarding form.  Verification state comes from the backend.
  Future<void> _loadMinimalPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = state.copyWith(
        selectedVehicleType: prefs.getString('driver_vehicle_type'),
        selectedLanguage: prefs.getString('driver_language'),
      );
    } catch (e) {
      debugPrint('Failed to load driver prefs: $e');
    }
  }

  /// Save only lightweight UI preferences.
  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state.selectedVehicleType != null) {
        await prefs.setString('driver_vehicle_type', state.selectedVehicleType!);
      }
      if (state.selectedLanguage != null) {
        await prefs.setString('driver_language', state.selectedLanguage!);
      }
    } catch (e) {
      debugPrint('Failed to save driver prefs: $e');
    }
  }

  // ─── Backend queries ────────────────────────────────────────────────

  /// Fetch the canonical onboarding status from backend.
  /// Returns the [BackendOnboardingStatus] and updates state, including document statuses.
  /// 
  /// IMPORTANT: If backend returns 404 (driver not found), this method will
  /// automatically call POST /start to create the driver profile, then retry.
  Future<BackendOnboardingStatus> fetchOnboardingStatus() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.getDriverOnboardingStatus();
      debugPrint('📋 Raw backend response: $response');
      return _processOnboardingStatusResponse(response);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      
      // If 404, driver doesn't exist yet - call /start first, then retry
      if (statusCode == 404) {
        debugPrint('📋 Driver not found (404) - starting onboarding first...');
        final started = await _startOnboardingAndRetry();
        if (started != null) {
          return started;
        }
        // If start failed, return default state
        state = state.copyWith(isLoading: false, hasFetchedBackendStatus: true);
        return const BackendOnboardingStatus(onboardingStatus: OnboardingStatus.notStarted);
      }
      
      final msg = e.response?.data?['message']?.toString() ?? 'Failed to check onboarding status';
      debugPrint('❌ fetchOnboardingStatus failed: $msg');
      state = state.copyWith(isLoading: false, error: msg);
      return const BackendOnboardingStatus();
    } catch (e) {
      debugPrint('❌ fetchOnboardingStatus error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return const BackendOnboardingStatus();
    }
  }
  
  /// Helper: Start onboarding and retry fetching status
  Future<BackendOnboardingStatus?> _startOnboardingAndRetry() async {
    try {
      final startResponse = await _apiClient.startDriverOnboarding();
      debugPrint('📋 Start onboarding response: $startResponse');
      
      if (startResponse['success'] == true) {
        // Now fetch the status again
        debugPrint('📋 Onboarding started, fetching status...');
        final statusResponse = await _apiClient.getDriverOnboardingStatus();
        return _processOnboardingStatusResponse(statusResponse);
      }
    } catch (e) {
      debugPrint('❌ _startOnboardingAndRetry error: $e');
    }
    return null;
  }
  
  /// Process the onboarding status response and update state
  BackendOnboardingStatus _processOnboardingStatusResponse(Map<String, dynamic> response) {
    final previousStatus = state.backendStatus;
    final wasCompletedAndRideable = previousStatus.onboardingStatus == OnboardingStatus.completed &&
        previousStatus.canStartRides;

    final status = BackendOnboardingStatus.fromJson(response);
    
    // Update document states based on backend data
    // Backend uses: LICENSE, RC, INSURANCE, PAN_CARD, AADHAAR_CARD, PROFILE_PHOTO
    final updatedDrivingLicense = state.drivingLicense.copyWith(
      status: status.getDocumentStatus('LICENSE'),
      rejectionReason: status.getRejectionReason('LICENSE'),
    );
    final updatedVehicleRC = state.vehicleRC.copyWith(
      status: status.getDocumentStatus('RC'),
      rejectionReason: status.getRejectionReason('RC'),
    );
    final updatedVehicleInsurance = state.vehicleInsurance.copyWith(
      status: status.getDocumentStatus('INSURANCE'),
      rejectionReason: status.getRejectionReason('INSURANCE'),
    );
    final updatedAadhaarCard = state.aadhaarCard.copyWith(
      status: status.getDocumentStatus('AADHAAR_CARD'),
      rejectionReason: status.getRejectionReason('AADHAAR_CARD'),
    );
    final updatedPanCard = state.panCard.copyWith(
      status: status.getDocumentStatus('PAN_CARD'),
      rejectionReason: status.getRejectionReason('PAN_CARD'),
    );
    
    // Check if profile photo is uploaded
    final profilePhotoUploaded = status.isDocumentUploaded('PROFILE_PHOTO');
    
    state = state.copyWith(
      isLoading: false,
      backendStatus: status,
      hasFetchedBackendStatus: true,
      drivingLicense: updatedDrivingLicense,
      vehicleRC: updatedVehicleRC,
      vehicleInsurance: updatedVehicleInsurance,
      aadhaarCard: updatedAadhaarCard,
      panCard: updatedPanCard,
      profilePhotoPath: profilePhotoUploaded ? (state.profilePhotoPath ?? 'uploaded') : state.profilePhotoPath,
    );

    final isCompletedAndRideable = status.onboardingStatus == OnboardingStatus.completed &&
        status.canStartRides;
    if (isCompletedAndRideable && !wasCompletedAndRideable && !_completionNotificationShown) {
      _completionNotificationShown = true;
      _maybeNotifyCompletionOnce(status).catchError((e) {
        debugPrint('❌ Failed to handle onboarding completion notification: $e');
      });
    }
    
    debugPrint('📋 Backend onboarding status: ${status.onboardingStatus.name}, canStartRides=${status.canStartRides}');
    debugPrint('📋 Documents - LICENSE: ${updatedDrivingLicense.status}, RC: ${updatedVehicleRC.status}, AADHAAR: ${updatedAadhaarCard.status}');
    debugPrint('📋 Verification progress: ${status.verificationProgress}, isVerified: ${status.isVerified}');
    return status;
  }

  // ─── Onboarding steps (calls backend) ────────────────────────────

  /// Start driver onboarding - creates driver profile on backend
  /// POST /api/driver/onboarding/start
  Future<bool> startOnboarding() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.startDriverOnboarding();
      debugPrint('📋 Start onboarding response: $response');
      state = state.copyWith(isLoading: false);
      return response['success'] == true;
    } catch (e) {
      debugPrint('❌ startOnboarding error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Update email on backend
  /// PUT /api/driver/onboarding/email
  Future<bool> updateEmail(String email) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.updateDriverEmail(email);
      debugPrint('📋 Update email response: $response');
      state = state.copyWith(isLoading: false, email: email);
      return response['success'] == true;
    } catch (e) {
      debugPrint('❌ updateEmail error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Update language preference on backend
  /// PUT /api/driver/onboarding/language
  Future<bool> setLanguage(String language) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.updateDriverLanguage(language);
      debugPrint('📋 Update language response: $response');
      state = state.copyWith(selectedLanguage: language, isLoading: false);
      _savePrefs();
      return response['success'] == true;
    } catch (e) {
      debugPrint('❌ setLanguage error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      // Still save locally for UI
      state = state.copyWith(selectedLanguage: language);
      _savePrefs();
      return false;
    }
  }

  /// Update vehicle type and service types on backend
  /// PUT /api/driver/onboarding/vehicle
  /// 
  /// If backend returns 404, will auto-start onboarding first.
  Future<bool> setVehicleType(String vehicleType, {List<String>? serviceTypes, String? referralCode}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.updateDriverVehicle(
        vehicleType: vehicleType,
        serviceTypes: serviceTypes ?? [vehicleType],
      );
      debugPrint('📋 Update vehicle response: $response');
      state = state.copyWith(
        selectedVehicleType: vehicleType,
        referralCode: referralCode,
        isLoading: false,
      );
      _savePrefs();
      return response['success'] == true;
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      
      // If 404, driver doesn't exist - start onboarding first, then retry
      if (statusCode == 404) {
        debugPrint('📋 Driver not found (404) - starting onboarding first...');
        final started = await startOnboarding();
        if (started) {
          // Retry the vehicle update
          try {
            final retryResponse = await _apiClient.updateDriverVehicle(
              vehicleType: vehicleType,
              serviceTypes: serviceTypes ?? [vehicleType],
            );
            debugPrint('📋 Retry update vehicle response: $retryResponse');
            state = state.copyWith(
              selectedVehicleType: vehicleType,
              referralCode: referralCode,
              isLoading: false,
            );
            _savePrefs();
            return retryResponse['success'] == true;
          } catch (retryError) {
            debugPrint('❌ Retry setVehicleType error: $retryError');
          }
        }
      }
      
      debugPrint('❌ setVehicleType error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      // Still save locally for UI
      state = state.copyWith(selectedVehicleType: vehicleType);
      _savePrefs();
      return false;
    } catch (e) {
      debugPrint('❌ setVehicleType error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      // Still save locally for UI
      state = state.copyWith(selectedVehicleType: vehicleType);
      _savePrefs();
      return false;
    }
  }

  void setReferralCode(String code) {
    state = state.copyWith(referralCode: code);
  }

  /// Update personal info on backend
  /// PUT /api/driver/onboarding/personal-info
  /// 
  /// If backend returns 404, will auto-start onboarding first.
  Future<bool> setPersonalInfo({
    String? fullName, 
    String? email,
    String? aadhaarNumber,
    String? panNumber,
    String? vehicleNumber,
    String? vehicleModel,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.updateDriverPersonalInfo(
        fullName: fullName,
        email: email,
        aadhaarNumber: aadhaarNumber,
        panNumber: panNumber,
        vehicleNumber: vehicleNumber,
        vehicleModel: vehicleModel,
      );
      debugPrint('📋 Update personal info response: $response');
      state = state.copyWith(
        fullName: fullName ?? state.fullName,
        email: email ?? state.email,
        isLoading: false,
      );
      return response['success'] == true;
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      
      // If 404, driver doesn't exist - start onboarding first, then retry
      if (statusCode == 404) {
        debugPrint('📋 Driver not found (404) - starting onboarding first...');
        final started = await startOnboarding();
        if (started) {
          // Retry the personal info update
          try {
            final retryResponse = await _apiClient.updateDriverPersonalInfo(
              fullName: fullName,
              email: email,
              aadhaarNumber: aadhaarNumber,
              panNumber: panNumber,
              vehicleNumber: vehicleNumber,
              vehicleModel: vehicleModel,
            );
            debugPrint('📋 Retry update personal info response: $retryResponse');
            state = state.copyWith(
              fullName: fullName ?? state.fullName,
              email: email ?? state.email,
              isLoading: false,
            );
            return retryResponse['success'] == true;
          } catch (retryError) {
            debugPrint('❌ Retry setPersonalInfo error: $retryError');
          }
        }
      }
      
      debugPrint('❌ setPersonalInfo error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      // Still save locally for UI
      state = state.copyWith(fullName: fullName, email: email);
      return false;
    } catch (e) {
      debugPrint('❌ setPersonalInfo error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      // Still save locally for UI
      state = state.copyWith(fullName: fullName, email: email);
      return false;
    }
  }

  void setRegisteredLocation(String location, String stateCode) {
    state = state.copyWith(
      registeredLocation: location,
      registeredState: stateCode,
    );
  }

  // ─── Document upload (now calls backend) ────────────────────────────

  /// Upload a single document to backend.
  /// POST /api/driver/onboarding/document/upload
  /// Upload a document and return result with next_step info.
  /// Returns a map with 'success', 'next_step', and optionally 'is_complete'.
  Future<Map<String, dynamic>> uploadDocument(String documentType, String filePath, {String? documentNumber, bool isFront = true}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await _apiClient.uploadDriverDocument(
        documentType: documentType,
        filePath: filePath,
        documentNumber: documentNumber,
        isFront: isFront,
      );
      
      // Extract next_step and completion info from response
      final data = response['data'] as Map<String, dynamic>? ?? {};
      final nextStep = data['next_step'] as String?;
      final isComplete = nextStep == 'COMPLETED';
      
      debugPrint('📤 Document uploaded: $documentType, next_step=$nextStep, isComplete=$isComplete');

      DriverDocument updatedDoc;
      final docTypeLower = documentType.toLowerCase();
      switch (docTypeLower) {
        case 'driving_license':
        case 'license':
          updatedDoc = state.drivingLicense.copyWith(
            frontImagePath: isFront ? filePath : state.drivingLicense.frontImagePath,
            backImagePath: !isFront ? filePath : state.drivingLicense.backImagePath,
            documentNumber: documentNumber ?? state.drivingLicense.documentNumber,
            status: DocumentStatus.uploaded,
          );
          state = state.copyWith(drivingLicense: updatedDoc, isLoading: false);
          break;
        case 'vehicle_rc':
        case 'rc':
          updatedDoc = state.vehicleRC.copyWith(
            frontImagePath: isFront ? filePath : state.vehicleRC.frontImagePath,
            backImagePath: !isFront ? filePath : state.vehicleRC.backImagePath,
            documentNumber: documentNumber ?? state.vehicleRC.documentNumber,
            status: DocumentStatus.uploaded,
          );
          state = state.copyWith(vehicleRC: updatedDoc, isLoading: false);
          break;
        case 'vehicle_insurance':
        case 'insurance':
          updatedDoc = state.vehicleInsurance.copyWith(
            frontImagePath: filePath,
            status: DocumentStatus.uploaded,
          );
          state = state.copyWith(vehicleInsurance: updatedDoc, isLoading: false);
          break;
        case 'aadhaar':
        case 'aadhaar_card':
          updatedDoc = state.aadhaarCard.copyWith(
            frontImagePath: isFront ? filePath : state.aadhaarCard.frontImagePath,
            backImagePath: !isFront ? filePath : state.aadhaarCard.backImagePath,
            documentNumber: documentNumber ?? state.aadhaarCard.documentNumber,
            status: DocumentStatus.uploaded,
          );
          state = state.copyWith(aadhaarCard: updatedDoc, isLoading: false);
          break;
        case 'pan':
        case 'pan_card':
          updatedDoc = state.panCard.copyWith(
            frontImagePath: filePath,
            documentNumber: documentNumber ?? state.panCard.documentNumber,
            status: DocumentStatus.uploaded,
          );
          state = state.copyWith(panCard: updatedDoc, isLoading: false);
          break;
        case 'profile_photo':
        case 'photo':
          state = state.copyWith(profilePhotoPath: filePath, isLoading: false);
          break;
        default:
          debugPrint('⚠️ Unknown document type: $documentType, treating as generic upload');
          state = state.copyWith(isLoading: false);
      }
      
      return {
        'success': true,
        'next_step': nextStep,
        'is_complete': isComplete,
        'data': data,
      };
    } catch (e) {
      debugPrint('❌ Document upload failed: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  void setProfilePhoto(String path) {
    state = state.copyWith(profilePhotoPath: path);
  }

  /// Submit all uploaded documents for backend review.
  /// POST /api/driver/onboarding/documents/submit
  Future<bool> submitForVerification() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _apiClient.submitDriverDocuments();

      state = state.copyWith(
        drivingLicense: state.drivingLicense.copyWith(status: DocumentStatus.inReview),
        vehicleRC: state.vehicleRC.copyWith(status: DocumentStatus.inReview),
        aadhaarCard: state.aadhaarCard.copyWith(status: DocumentStatus.inReview),
        isLoading: false,
      );

      // Refresh backend status after submission
      await fetchOnboardingStatus();
      return true;
    } catch (e) {
      debugPrint('❌ submitForVerification failed: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Reset onboarding state
  Future<void> reset() async {
    state = const DriverOnboardingState();
    _completionNotificationShown = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('driver_vehicle_type');
    await prefs.remove('driver_language');
  }

  Future<void> _maybeNotifyCompletionOnce(BackendOnboardingStatus status) async {
    if (!(status.onboardingStatus == OnboardingStatus.completed && status.canStartRides)) {
      return;
    }

    final keySuffix = _buildCompletionDedupSuffix(status);
    final sentKey = '$_completionNotifSentKeyPrefix$keySuffix';

    final prefs = await SharedPreferences.getInstance();
    final alreadySent = prefs.getBool(sentKey) ?? false;
    if (alreadySent) return;

    await pushNotificationService.showDriverOnboardingCompletedNotification();
    await prefs.setBool(sentKey, true);
  }

  String _buildCompletionDedupSuffix(BackendOnboardingStatus status) {
    final userId = _ref.read(authStateProvider).user?.id;
    if (userId != null && userId.isNotEmpty) {
      return userId;
    }
    // Fallback identity bucket if user id is temporarily unavailable.
    return 'default';
  }

  void nextStep() {
    state = state.copyWith(currentStep: state.currentStep + 1);
  }

  void previousStep() {
    if (state.currentStep > 0) {
      state = state.copyWith(currentStep: state.currentStep - 1);
    }
  }

  void setStep(int step) {
    state = state.copyWith(currentStep: step);
  }
}

/// Provider for driver onboarding state
final driverOnboardingProvider = StateNotifierProvider<DriverOnboardingNotifier, DriverOnboardingState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DriverOnboardingNotifier(apiClient, ref);
});

/// Async provider that fetches the canonical onboarding status from backend.
/// Use this wherever you need to gate navigation or UI on verification.
final driverOnboardingStatusProvider = FutureProvider<BackendOnboardingStatus>((ref) async {
  final notifier = ref.read(driverOnboardingProvider.notifier);
  return notifier.fetchOnboardingStatus();
});
