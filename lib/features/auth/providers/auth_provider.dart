import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/models/user.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/websocket_service.dart';
import '../../../core/services/realtime_service.dart';
import '../../../core/services/firebase_phone_auth_service.dart';
import '../../../core/services/google_auth_service.dart';
import '../../../core/services/push_notification_service.dart';
import '../../driver/providers/driver_rides_provider.dart';

// Auth state
class AuthState {
  final User? user;
  final bool isLoading;
  final String? error;
  final String? currentSessionId; // Store phone for OTP verification
  final bool pendingOnboarding; // True when new user needs name entry + terms
  final bool pendingPhoneLink; // True when social login must add phone
  final bool onboardingAfterPhoneLink; // Preserve onboarding requirement until phone is linked
  final bool isLoggingOut;

  const AuthState({
    this.user,
    this.isLoading = false,
    this.error,
    this.currentSessionId,
    this.pendingOnboarding = false,
    this.pendingPhoneLink = false,
    this.onboardingAfterPhoneLink = false,
    this.isLoggingOut = false,
  });

  AuthState copyWith({
    User? user,
    bool? isLoading,
    String? error,
    String? currentSessionId,
    bool? pendingOnboarding,
    bool? pendingPhoneLink,
    bool? onboardingAfterPhoneLink,
    bool? isLoggingOut,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      pendingOnboarding: pendingOnboarding ?? this.pendingOnboarding,
      pendingPhoneLink: pendingPhoneLink ?? this.pendingPhoneLink,
      onboardingAfterPhoneLink:
          onboardingAfterPhoneLink ?? this.onboardingAfterPhoneLink,
      isLoggingOut: isLoggingOut ?? this.isLoggingOut,
    );
  }
}

// OTP Result
class OTPResult {
  final bool success;
  final String? sessionId;
  final String? error;
  final int? expiresIn;

  const OTPResult({
    required this.success,
    this.sessionId,
    this.error,
    this.expiresIn,
  });
}

// Verify OTP Result
class VerifyOTPResult {
  final bool success;
  final User? user;
  final String? token;
  final String? error;
  final bool isNewUser;

  const VerifyOTPResult({
    required this.success,
    this.user,
    this.token,
    this.error,
    this.isNewUser = false,
  });
}

class SocialSignInResult {
  final bool success;
  final bool requiresPhone;
  final bool isNewUser;
  final String? error;

  const SocialSignInResult({
    required this.success,
    this.requiresPhone = false,
    this.isNewUser = false,
    this.error,
  });
}

// Auth notifier
class AuthNotifier extends StateNotifier<AuthState> {
  final FlutterSecureStorage _secureStorage;
  final Ref _ref;
  bool _handlingAuthError = false;
  static const _tokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userKey = 'user_data';
  static const _testOtp = '123456';
  static const bool _allowTestOtpBypass = true; // Always allow test OTP for dev builds
  
  // Test phone numbers that bypass Firebase and use direct backend auth
  // NOTE: These are for LOCAL DEV ONLY when Firebase is not configured.
  // For Firebase Console test numbers, use the normal Firebase flow - they work automatically.
  static const List<String> _testPhoneNumbers = [
    '9794696252',
    '1234567890',
    '9999999999',
  ];

  AuthNotifier(this._secureStorage, this._ref)
      : super(const AuthState(isLoading: true)) {
    // Set up auth error callback for automatic logout on 401/403
    apiClient.setOnAuthError(_handleAuthError);
    // Defer initialization to next microtask to avoid blocking constructor
    Future.microtask(() => _initializeAuth());
  }
  
  /// Handle auth errors (401 after refresh fails, 403 deactivated user)
  void _handleAuthError() {
    if (_handlingAuthError || state.isLoggingOut) return;
    _handlingAuthError = true;
    debugPrint('🔐 Auth error detected, forcing local sign out once...');
    _forceLocalSignOutFromAuthError();
  }

  Future<void> _forceLocalSignOutFromAuthError() async {
    state = state.copyWith(isLoading: true, isLoggingOut: true);
    try {
      await realtimeService.stop(reason: RealtimeStopReason.logout);
      realtimeService.cancelReconnectTimer();
      realtimeService.resetConnectionStateSilently();
      webSocketService.disconnect();
      await pushNotificationService.unregisterToken();
      await firebasePhoneAuth.signOut();
    } catch (e) {
      debugPrint('Forced local sign out cleanup error: $e');
    } finally {
      _handlingAuthError = false;
    }

    await _clearAuthData();
    state = const AuthState();
  }

  void _registerPushTokenSilently() {
    pushNotificationService.registerToken().catchError((e) {
      debugPrint('FCM token registration (session restore) failed: $e');
    });
  }

  Future<void> _initializeAuth() async {
    try {
      final token = await _secureStorage.read(key: _tokenKey).timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey).timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      
      // Also try to load cached user data
      final cachedUserJson = await _secureStorage.read(key: _userKey).timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );

      if (token != null) {
        // Validate token format - JWT tokens start with "eyJ" (base64 encoded "{")
        if (!token.startsWith('eyJ')) {
          debugPrint('⚠️ Invalid token format detected (mock token?): ${token.substring(0, 20)}...');
          debugPrint('🧹 Clearing invalid session - user needs to log in again');
          await _clearAuthData();
          state = const AuthState();
          return;
        }
        
        debugPrint('🔐 Restoring session with token: ${token.substring(0, 30)}...');
        apiClient.setAuthToken(token);
        apiClient.setRefreshToken(refreshToken);

        try {
          // Add timeout to prevent blocking if server is slow
          final response = await apiClient.getCurrentUser().timeout(
            const Duration(seconds: 10),
            onTimeout: () => {'success': false, 'message': 'Request timeout'},
          );

          // Backend returns: { success: true, data: { user: { ... } } }
          if (response['success'] == true) {
            final data = response['data'] as Map<String, dynamic>?;
            final userJson = data?['user'] as Map<String, dynamic>?;

            if (userJson != null) {
              // Check if user is active - backend may deactivate users
              final isActive = userJson['isActive'] as bool? ?? true;
              if (!isActive) {
                debugPrint('🚫 User account is deactivated');
                await _clearAuthData();
                state = const AuthState(error: 'Your account has been deactivated. Please contact support.');
                return;
              }
              
              final user = _mapUserFromBackend(userJson);
              final requiresPhoneLink = _requiresPhoneLink(user.phone);
              
              // Cache user data for offline session persistence
              await _secureStorage.write(key: _userKey, value: _encodeUser(user));

              // Fresh auth session: do not carry old driver offer cards.
              _ref.read(driverRidesProvider.notifier).resetForNewSession();

              // Connect to Socket.io (non-blocking - fire and forget)
              // Don't await to prevent UI freeze if server is unreachable
              webSocketService.connect(token: token).catchError((e) {
                debugPrint('Socket.io connection failed: $e');
              });

              state = AuthState(
                user: user,
                pendingPhoneLink: requiresPhoneLink,
                pendingOnboarding: false,
              );
              _registerPushTokenSilently();
              return;
            }
          }
          
          // Invalid token response - clear auth only for explicit auth errors
          final message = response['message'] as String? ?? '';
          if (message.contains('Invalid') || message.contains('expired') || message.contains('Unauthorized')) {
            debugPrint('🔐 Token invalid/expired, clearing auth');
            await _clearAuthData();
            state = const AuthState();
          } else {
            // Server error but token might still be valid - use cached user
            debugPrint('⚠️ Server error but keeping session');
            if (cachedUserJson != null) {
              final user = _decodeUser(cachedUserJson);
              if (user != null) {
                state = AuthState(
                  user: user,
                  pendingPhoneLink: _requiresPhoneLink(user.phone),
                  pendingOnboarding: false,
                );
                _registerPushTokenSilently();
                return;
              }
            }
            state = const AuthState();
          }
        } catch (e) {
          debugPrint('Failed to get current user: $e');
          
          // Check if it's a network error vs auth error
          final isNetworkError = e.toString().contains('SocketException') ||
              e.toString().contains('Connection refused') ||
              e.toString().contains('Failed host lookup') ||
              e.toString().contains('timeout') ||
              e.toString().contains('Network is unreachable');
          
          if (isNetworkError && cachedUserJson != null) {
            // Network issue - keep user logged in with cached data
            debugPrint('📴 Network error but keeping session with cached user');
            final user = _decodeUser(cachedUserJson);
            if (user != null) {
              state = AuthState(
                user: user,
                pendingPhoneLink: _requiresPhoneLink(user.phone),
                pendingOnboarding: false,
              );
              _registerPushTokenSilently();
              return;
            }
          }
          
          // Auth error or no cached user - clear and require login
          await _clearAuthData();
          state = const AuthState();
        }
      } else {
        state = const AuthState();
      }
    } catch (e) {
      debugPrint('Auth initialization error: $e');
      state = AuthState(error: e.toString());
    }
  }
  
  /// Encode user to JSON string for caching
  String _encodeUser(User user) {
    return '{"id":"${user.id}","phone":"${user.phone ?? ''}","name":"${user.name}","email":"${user.email}","avatarUrl":"${user.avatarUrl ?? ''}","userType":"${user.userType.name}"}';
  }
  
  /// Decode user from cached JSON string
  User? _decodeUser(String json) {
    try {
      final map = Map<String, dynamic>.from(
        (json.startsWith('{') ? _parseJson(json) : null) ?? {},
      );
      if (map['id'] == null) return null;
      return User(
        id: map['id'] as String,
        email: map['email'] as String? ?? '',
        phone: map['phone'] as String?,
        name: map['name'] as String? ?? 'User',
        avatarUrl: map['avatarUrl'] as String?,
        userType: _parseUserType(map['userType'] as String?),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('Failed to decode cached user: $e');
      return null;
    }
  }
  
  /// Parse user type from string
  UserType _parseUserType(String? type) {
    switch (type) {
      case 'driver':
        return UserType.driver;
      case 'both':
        return UserType.both;
      default:
        return UserType.rider;
    }
  }
  
  /// Simple JSON parser for cached user
  Map<String, dynamic>? _parseJson(String json) {
    try {
      // Remove braces and split by comma
      final content = json.substring(1, json.length - 1);
      final pairs = <String, dynamic>{};
      final regex = RegExp(r'"(\w+)":"([^"]*)"');
      for (final match in regex.allMatches(content)) {
        pairs[match.group(1)!] = match.group(2)!.isEmpty ? null : match.group(2);
      }
      return pairs;
    } catch (e) {
      return null;
    }
  }
  
  Future<void> _clearAuthData() async {
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _refreshTokenKey);
    await _secureStorage.delete(key: _userKey);
    apiClient.setAuthToken(null);
    apiClient.setRefreshToken(null);
  }

  /// Check if phone is a test number that bypasses Firebase
  bool _isTestPhone(String phone) {
    final normalized = _normalizePhoneDigits(phone);
    return _allowTestOtpBypass && _testPhoneNumbers.contains(normalized);
  }

  /// Request OTP for phone number.
  /// Uses Firebase directly. For test numbers: skip Firebase, use test OTP.
  Future<OTPResult> requestOTP(String phone) async {
    debugPrint('📱 AuthNotifier.requestOTP called for $phone');
    state = state.copyWith(isLoading: true, error: null);

    try {
      final normalizedPhone = _normalizePhoneDigits(phone);
      if (normalizedPhone.length != 10) {
        const msg = 'Please enter a valid 10-digit mobile number.';
        state = state.copyWith(isLoading: false, error: msg);
        return const OTPResult(success: false, error: msg);
      }

      final isTest = _isTestPhone(normalizedPhone);
      debugPrint('📱 Request OTP for $normalizedPhone (isTestPhone: $isTest)');

      // For test numbers, skip Firebase entirely
      if (isTest) {
        debugPrint('🔓 TEST MODE: Skipping Firebase OTP, use OTP $_testOtp');
        state = state.copyWith(
          isLoading: false,
          currentSessionId: 'TEST_$normalizedPhone',
        );
        return OTPResult(
          success: true,
          sessionId: 'TEST_$normalizedPhone',
          expiresIn: 300,
        );
      }

      // For real numbers: Firebase OTP dispatch DIRECTLY (no backend call)
      debugPrint('🔥 Sending OTP via Firebase directly (no backend dependency)');
      final firebaseResult = await firebasePhoneAuth.sendOTP(normalizedPhone);
      
      if (!firebaseResult.success) {
        final errorMsg = firebaseResult.error ?? 'Failed to send OTP';
        debugPrint('❌ Firebase OTP send failed: $errorMsg (code: ${firebaseResult.code})');
        
        // Provide user-friendly error messages
        String userMessage;
        switch (firebaseResult.code) {
          case 'too-many-requests':
            userMessage = 'Too many OTP requests. Please wait a few minutes and try again.';
            break;
          case 'invalid-phone-number':
            userMessage = 'Invalid phone number. Please check and try again.';
            break;
          case 'quota-exceeded':
            userMessage = 'SMS service temporarily unavailable. Please try again later.';
            break;
          case 'app-not-authorized':
            userMessage = 'App configuration error. Please contact support.';
            break;
          case 'captcha-check-failed':
            userMessage = 'Verification failed. Please try again.';
            break;
          default:
            userMessage = errorMsg;
        }
        
        state = state.copyWith(isLoading: false, error: userMessage);
        return OTPResult(success: false, error: userMessage);
      }

      debugPrint('✅ Firebase OTP sent successfully');
      state = state.copyWith(
        isLoading: false,
        currentSessionId: normalizedPhone,
      );

      return OTPResult(
        success: true,
        sessionId: normalizedPhone,
        expiresIn: 120,
      );
    } catch (e) {
      debugPrint('📱 Request OTP error: $e');
      
      String errorMessage;
      if (e.toString().contains('network')) {
        errorMessage = 'Network error. Please check your internet connection.';
      } else if (e.toString().contains('timeout')) {
        errorMessage = 'Request timed out. Please try again.';
      } else {
        errorMessage = 'Failed to send OTP. Please try again.';
      }
      
      state = state.copyWith(isLoading: false, error: errorMessage);
      return OTPResult(success: false, error: errorMessage);
    }
  }

  /// Verify OTP.
  /// For test sessions: use direct backend verify-otp endpoint.
  /// For real sessions: verify via Firebase then authenticate with backend using Firebase idToken.
  Future<VerifyOTPResult> verifyOTP(String phone, String otp, {bool isNewUser = false}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final sessionPhone = state.currentSessionId;
      if (sessionPhone == null) {
        state = state.copyWith(isLoading: false);
        return const VerifyOTPResult(
          success: false,
          error: 'No active OTP session. Please request OTP again.',
        );
      }

      debugPrint('📱 Verify OTP: session=$sessionPhone, otp=$otp');

      // Check if this is a test session (marked with TEST_ prefix)
      final isTestSession = sessionPhone.startsWith('TEST_');
      final actualPhone = isTestSession ? sessionPhone.substring(5) : sessionPhone;

      // For test sessions with test OTP: use direct backend verification
      if (isTestSession && otp == _testOtp) {
        // Build E.164 formatted phone for backend (e.g., +919794696252)
        final e164Phone = '+91$actualPhone';
        debugPrint('🔓 TEST MODE: Trying backend authentication for test phone $actualPhone (E.164: $e164Phone)');
        
        // Try 1: phone endpoint (direct phone auth for dev/test mode) - send E.164 format
        try {
          debugPrint('🔓 Attempt 1: /auth/phone with E.164 format');
          final phoneResponse = await apiClient.authenticateWithPhone(e164Phone);
          debugPrint('🔓 phone auth response: $phoneResponse');
          if (phoneResponse['success'] == true) {
            return await _handleBackendAuthResponse(phoneResponse);
          }
          final msg = phoneResponse['message'] as String? ?? '';
          debugPrint('🔓 phone auth failed: $msg');
        } catch (e) {
          debugPrint('🔓 phone auth exception: $e');
        }
        
        // Try 2: verify-otp endpoint with E.164 format
        try {
          debugPrint('🔓 Attempt 2: /auth/verify-otp with E.164 format');
          final verifyResponse = await apiClient.verifyOTP(e164Phone, otp, countryCode: '+91');
          debugPrint('🔓 verify-otp response: $verifyResponse');
          if (verifyResponse['success'] == true) {
            return await _handleBackendAuthResponse(verifyResponse);
          }
          final msg = verifyResponse['message'] as String? ?? '';
          debugPrint('🔓 verify-otp failed: $msg');
        } catch (e) {
          debugPrint('🔓 verify-otp exception: $e');
        }

        // All attempts failed
        state = state.copyWith(isLoading: false, error: 'Backend does not support test OTP. Configure Firebase test numbers.');
        return const VerifyOTPResult(
          success: false, 
          error: 'Backend requires Firebase auth. Add +919794696252 as test phone in Firebase Console with OTP 123456.',
        );
      }

      // For test sessions with wrong OTP
      if (isTestSession && otp != _testOtp) {
        state = state.copyWith(isLoading: false, error: 'Invalid OTP. For test numbers use $_testOtp');
        return VerifyOTPResult(success: false, error: 'Invalid OTP. For test numbers use $_testOtp');
      }

      // For real sessions: Firebase verification
      debugPrint('🔥 Verifying OTP via Firebase for phone: $actualPhone');
      final firebaseVerify = await firebasePhoneAuth.verifyOTP(otp);
      debugPrint('🔥 Firebase verify result: success=${firebaseVerify.success}, hasToken=${firebaseVerify.idToken != null}, error=${firebaseVerify.error}');
      
      if (!firebaseVerify.success || firebaseVerify.idToken == null || firebaseVerify.idToken!.isEmpty) {
        final msg = firebaseVerify.error ?? 'Firebase OTP verification failed.';
        debugPrint('🔥 Firebase verification failed: $msg');
        state = state.copyWith(isLoading: false, error: msg);
        return VerifyOTPResult(success: false, error: msg);
      }

      debugPrint('🔥 Firebase verification successful, calling backend /auth/firebase-phone');
      final backendResponse = await apiClient.authenticateWithFirebase(firebaseVerify.idToken!);
      debugPrint('🔥 Backend firebase-phone response: $backendResponse');
      return await _handleBackendAuthResponse(backendResponse);
    } catch (e) {
      debugPrint('📱 Verify OTP error: $e');

      String errorMessage;
      if (e.toString().contains('Connection refused') || e.toString().contains('Failed host lookup')) {
        errorMessage = 'Unable to connect to server. Please check your internet connection.';
      } else if (e.toString().contains('timeout')) {
        errorMessage = 'Request timed out. Please try again.';
      } else {
        errorMessage = e.toString();
      }

      state = state.copyWith(isLoading: false, error: errorMessage);
      return VerifyOTPResult(success: false, error: errorMessage);
    }
  }

  String _normalizePhoneDigits(String phone) {
    var normalized = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (normalized.startsWith('91') && normalized.length > 10) {
      normalized = normalized.substring(normalized.length - 10);
    } else if (normalized.length > 10) {
      normalized = normalized.substring(normalized.length - 10);
    }
    return normalized;
  }

  bool _requiresPhoneLink(String? phone) {
    final value = (phone ?? '').trim();
    return value.isEmpty || value.startsWith('google_');
  }

  Future<OTPResult> resendOTP(String phone) async {
    state = state.copyWith(currentSessionId: null);
    return requestOTP(phone);
  }

  /// True when Firebase has an active verification session.
  bool hasActiveOtpSession() => firebasePhoneAuth.hasValidSession;

  Future<SocialSignInResult> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final googleResult = await GoogleAuthService.signIn();
      if (!googleResult.success || googleResult.idToken == null) {
        state = state.copyWith(isLoading: false);
        return SocialSignInResult(
          success: false,
          error: googleResult.error ?? 'Google sign-in failed',
        );
      }

      final backendResponse =
          await apiClient.authenticateWithGoogle(googleResult.idToken!);
      return await _handleSocialAuthResponse(backendResponse);
    } catch (e) {
      state = state.copyWith(isLoading: false);
      return SocialSignInResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  Future<SocialSignInResult> signInWithTruecaller({
    String? phone,
    Map<String, dynamic>? profile,
    String? accessToken,
    String? truecallerToken,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      String? normalizedE164Phone;
      if (phone != null && phone.isNotEmpty) {
        final normalizedPhone = _normalizePhoneDigits(phone);
        if (normalizedPhone.length != 10) {
          state = state.copyWith(isLoading: false);
          return const SocialSignInResult(
            success: false,
            error: 'Please enter a valid 10-digit mobile number.',
          );
        }
        normalizedE164Phone = '+91$normalizedPhone';
      }

      final backendResponse = await apiClient.authenticateWithTruecaller(
        phone: normalizedE164Phone,
        profile: profile,
        accessToken: accessToken,
        truecallerToken: truecallerToken,
      );
      return await _handleSocialAuthResponse(backendResponse);
    } catch (e) {
      state = state.copyWith(isLoading: false);
      return SocialSignInResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  Future<VerifyOTPResult> verifyOtpForPhoneLink(String otp) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final firebaseVerify = await firebasePhoneAuth.verifyOTP(otp);
      if (!firebaseVerify.success ||
          firebaseVerify.idToken == null ||
          firebaseVerify.idToken!.isEmpty) {
        final msg = firebaseVerify.error ?? 'OTP verification failed';
        state = state.copyWith(isLoading: false, error: msg);
        return VerifyOTPResult(success: false, error: msg);
      }

      final response =
          await apiClient.addPhoneWithFirebase(firebaseVerify.idToken!);
      final success = response['success'] as bool? ?? false;
      if (!success) {
        final msg =
            response['message'] as String? ?? 'Failed to link phone number';
        state = state.copyWith(isLoading: false, error: msg);
        return VerifyOTPResult(success: false, error: msg);
      }

      final data = response['data'] as Map<String, dynamic>?;
      final userJson = data?['user'] as Map<String, dynamic>?;
      if (userJson == null) {
        state = state.copyWith(isLoading: false);
        return const VerifyOTPResult(
          success: false,
          error: 'Invalid response from server',
        );
      }

      final user = _mapUserFromBackend(userJson);
      await _secureStorage.write(key: _userKey, value: _encodeUser(user));
      state = state.copyWith(
        user: user,
        isLoading: false,
        pendingPhoneLink: false,
        pendingOnboarding: state.onboardingAfterPhoneLink,
        onboardingAfterPhoneLink: false,
      );

      return VerifyOTPResult(
        success: true,
        user: user,
        isNewUser: state.pendingOnboarding,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return VerifyOTPResult(success: false, error: e.toString());
    }
  }

  Future<SocialSignInResult> _handleSocialAuthResponse(
      Map<String, dynamic> response) async {
    final success = response['success'] as bool? ?? false;
    if (!success) {
      state = state.copyWith(isLoading: false);
      return SocialSignInResult(
        success: false,
        error: response['message'] as String? ?? 'Authentication failed',
      );
    }

    final data = response['data'] as Map<String, dynamic>?;
    final userJson = data?['user'] as Map<String, dynamic>?;
    final tokens = data?['tokens'] as Map<String, dynamic>?;
    final accessToken = tokens?['accessToken'] as String?;
    final refreshToken = tokens?['refreshToken'] as String?;
    final requiresPhone = data?['requiresPhone'] as bool? ?? false;
    final isNewUser = data?['isNewUser'] as bool? ?? false;

    if (userJson == null || accessToken == null) {
      state = state.copyWith(isLoading: false);
      return const SocialSignInResult(
        success: false,
        error: 'Invalid response from server',
      );
    }

    final user = _mapUserFromBackend(userJson);
    await _secureStorage.write(key: _tokenKey, value: accessToken);
    if (refreshToken != null) {
      await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
    }
    await _secureStorage.write(key: _userKey, value: _encodeUser(user));

    apiClient.setAuthToken(accessToken);
    apiClient.setRefreshToken(refreshToken);
    _ref.read(driverRidesProvider.notifier).resetForNewSession();
    webSocketService.connect(token: accessToken).catchError((e) {
      debugPrint('Socket.io connection failed: $e');
    });
    pushNotificationService.registerToken().catchError((e) {
      debugPrint('FCM token registration failed: $e');
    });

    state = AuthState(
      user: user,
      pendingPhoneLink: requiresPhone,
      onboardingAfterPhoneLink: requiresPhone ? isNewUser : false,
      pendingOnboarding: requiresPhone ? false : isNewUser,
    );

    return SocialSignInResult(
      success: true,
      requiresPhone: requiresPhone,
      isNewUser: isNewUser,
    );
  }

  /// Helper method to handle backend auth response
  Future<VerifyOTPResult> _handleBackendAuthResponse(Map<String, dynamic> response) async {
    debugPrint('🔐 _handleBackendAuthResponse called');
    final success = response['success'] as bool? ?? false;

    if (!success) {
      debugPrint('❌ Backend returned success=false: ${response['message']}');
      state = state.copyWith(isLoading: false);
      return VerifyOTPResult(
        success: false,
        error: response['message'] as String? ?? 'Authentication failed',
      );
    }

    final data = response['data'] as Map<String, dynamic>?;
    if (data == null) {
      debugPrint('❌ Backend response missing "data" field');
      state = state.copyWith(isLoading: false);
      return const VerifyOTPResult(success: false, error: 'Invalid response from server');
    }

    final userJson = data['user'] as Map<String, dynamic>?;
    final tokens = data['tokens'] as Map<String, dynamic>?;
    final accessToken = tokens?['accessToken'] as String?;
    final refreshToken = tokens?['refreshToken'] as String?;
    
    debugPrint('🔐 Extracted tokens object: ${tokens?.keys.toList()}');
    if (accessToken != null) {
      debugPrint('🔐 accessToken (first 40 chars): ${accessToken.substring(0, accessToken.length > 40 ? 40 : accessToken.length)}...');
      debugPrint('🔐 accessToken starts with "eyJ": ${accessToken.startsWith('eyJ')}');
    } else {
      debugPrint('❌ accessToken is null!');
    }

    if (userJson == null || accessToken == null) {
      debugPrint('❌ userJson=$userJson, accessToken=$accessToken');
      state = state.copyWith(isLoading: false);
      return const VerifyOTPResult(success: false, error: 'Invalid response from server');
    }

    final user = _mapUserFromBackend(userJson);

    final isActive = userJson['isActive'] as bool? ?? true;
    if (!isActive) {
      state = state.copyWith(isLoading: false);
      return const VerifyOTPResult(
        success: false,
        error: 'Your account has been deactivated. Please contact support.',
      );
    }
    
    await _secureStorage.write(key: _tokenKey, value: accessToken);
    if (refreshToken != null) {
      await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
    }
    await _secureStorage.write(key: _userKey, value: _encodeUser(user));
    
    apiClient.setAuthToken(accessToken);
    apiClient.setRefreshToken(refreshToken);

    // Fresh auth session: do not carry old driver offer cards.
    _ref.read(driverRidesProvider.notifier).resetForNewSession();

    // Connect to Socket.io (non-blocking)
    webSocketService.connect(token: accessToken).catchError((e) {
      debugPrint('Socket.io connection failed: $e');
    });
    
    // Register FCM token for push notifications (non-blocking)
    pushNotificationService.registerToken().catchError((e) {
      debugPrint('FCM token registration failed: $e');
    });

    // Trust backend's isNewUser flag - only show onboarding for truly new users
    final backendIsNewUser = data['isNewUser'] as bool? ?? false;
    final firstName = userJson['firstName'] as String? ?? '';
    final lastName = userJson['lastName'] as String? ?? '';
    
    debugPrint('🔍 Backend isNewUser: $backendIsNewUser');
    debugPrint('🔍 User data: firstName="$firstName", lastName="$lastName"');
    
    // Only require onboarding if backend explicitly says this is a new user
    // Don't second-guess based on name fields - user may have completed onboarding
    // but just has no name set (which is fine)
    final needsOnboarding = backendIsNewUser;
    debugPrint('🔍 needsOnboarding=$needsOnboarding');

    state = AuthState(user: user, pendingOnboarding: needsOnboarding);

    return VerifyOTPResult(
      success: true,
      user: user,
      token: accessToken,
      isNewUser: needsOnboarding,
    );
  }

  Future<void> signOut() async {
    if (state.isLoggingOut) return;
    state = state.copyWith(isLoading: true, isLoggingOut: true);

    try {
      // Intentional logout: stop realtime first to avoid disconnect snackbars/reconnects.
      await realtimeService.stop(reason: RealtimeStopReason.logout);
      realtimeService.cancelReconnectTimer();
      realtimeService.resetConnectionStateSilently();
      webSocketService.disconnect();
      // Unregister FCM token to stop push notifications
      await pushNotificationService.unregisterToken();
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
      await apiClient.signOut(refreshToken: refreshToken);
      await firebasePhoneAuth.signOut();
    } catch (e) {
      debugPrint('Sign out API error: $e');
    }

    await _clearAuthData();
    state = const AuthState();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        state = state.copyWith(isLoggingOut: false);
      }
    });
  }

  /// Get current auth token (for saving account)
  Future<String?> getCurrentToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  /// Get current refresh token (for saving account)
  Future<String?> getCurrentRefreshToken() async {
    return await _secureStorage.read(key: _refreshTokenKey);
  }

  /// Switch to a saved account using its stored credentials
  Future<bool> switchToAccount({
    required String token,
    String? refreshToken,
    required User user,
  }) async {
    state = state.copyWith(isLoading: true);

    try {
      // Disconnect current socket
      webSocketService.disconnect();

      // Validate token format
      if (!token.startsWith('eyJ')) {
        debugPrint('⚠️ Invalid saved token format');
        state = state.copyWith(isLoading: false, error: 'Invalid saved session');
        return false;
      }

      // Set new credentials
      await _secureStorage.write(key: _tokenKey, value: token);
      if (refreshToken != null) {
        await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
      }
      await _secureStorage.write(key: _userKey, value: _encodeUser(user));

      apiClient.setAuthToken(token);
      apiClient.setRefreshToken(refreshToken);

      // Validate token by fetching current user
      try {
        final response = await apiClient.getCurrentUser();
        
        if (response['success'] == true) {
          final data = response['data'] as Map<String, dynamic>?;
          final userJson = data?['user'] as Map<String, dynamic>?;

          if (userJson != null) {
            final isActive = userJson['isActive'] as bool? ?? true;
            if (!isActive) {
              debugPrint('🚫 Saved account is deactivated');
              await _clearAuthData();
              state = state.copyWith(isLoading: false, error: 'This account has been deactivated');
              return false;
            }

            final freshUser = _mapUserFromBackend(userJson);
            await _secureStorage.write(key: _userKey, value: _encodeUser(freshUser));

            // Account switch should never show stale offer cards from prior session.
            _ref.read(driverRidesProvider.notifier).resetForNewSession();

            // Reconnect socket (non-blocking)
            webSocketService.connect(token: token).catchError((e) {
              debugPrint('Socket.io connection failed: $e');
            });

            state = AuthState(
              user: freshUser,
              pendingPhoneLink: _requiresPhoneLink(freshUser.phone),
              pendingOnboarding: false,
            );
            debugPrint('📱 Switched to account: ${freshUser.name}');
            return true;
          }
        }

        // Token validation failed
        debugPrint('❌ Saved token is no longer valid');
        await _clearAuthData();
        state = state.copyWith(isLoading: false, error: 'Saved session has expired. Please login again.');
        return false;
      } catch (e) {
        debugPrint('❌ Failed to validate saved token: $e');
        await _clearAuthData();
        state = state.copyWith(isLoading: false, error: 'Failed to switch account: $e');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Switch account error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<void> updateUser(User user) async {
    state = state.copyWith(user: user);
  }

  /// Mark onboarding as complete.
  void completeOnboarding() {
    state = state.copyWith(pendingOnboarding: false);
  }

  /// Update just the user's name (used after name entry for new users).
  void updateUserName(String name) {
    final current = state.user;
    if (current != null) {
      // Also update on backend
      try {
        apiClient.updateUser({
          'firstName': name.split(' ').first,
          'lastName': name.split(' ').length > 1 ? name.split(' ').sublist(1).join(' ') : null,
        });
      } catch (e) {
        debugPrint('Failed to update name on backend: $e');
      }

      state = state.copyWith(
        user: User(
          id: current.id,
          email: current.email,
          phone: current.phone,
          name: name,
          avatarUrl: current.avatarUrl,
          userType: current.userType,
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
          userMetadata: {...?current.userMetadata, 'name': name},
        ),
      );
    }
  }

  /// Map user from backend response format.
  /// Backend user shape: { id, email, phone, firstName, lastName, profileImage,
  ///   isVerified, isActive, createdAt, lastLoginAt }
  User _mapUserFromBackend(Map<String, dynamic> json) {
    final firstName = json['firstName'] as String? ?? '';
    final lastName = json['lastName'] as String? ?? '';
    final fullName = '$firstName${lastName.isNotEmpty ? ' $lastName' : ''}'.trim();

    return User(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      name: fullName.isNotEmpty ? fullName : 'User',
      avatarUrl: json['profileImage'] as String? ?? json['profile_image'] as String?,
      userType: UserType.rider, // Default; backend doesn't have user_type field yet
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] is String
              ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
              : DateTime.now())
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? (json['updatedAt'] is String
              ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
              : DateTime.now())
          : DateTime.now(),
      userMetadata: {
        'firstName': firstName,
        'lastName': lastName,
        'isVerified': json['isVerified'] ?? false,
        'isActive': json['isActive'] ?? true,
      },
    );
  }
}

// Providers
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
});

final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  return AuthNotifier(secureStorage, ref);
});

// Convenience providers
final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authStateProvider).user;
});

final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).user != null;
});

final isLoadingAuthProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).isLoading;
});

final pendingOnboardingProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).pendingOnboarding;
});

final pendingPhoneLinkProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).pendingPhoneLink;
});

final currentSessionIdProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).currentSessionId;
});
