import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Firebase Phone Authentication Service
///
/// Designed to use Play Integrity (native) verification on Android,
/// avoiding the browser-based reCAPTCHA flow entirely. If Play Integrity
/// is unavailable, falls back to reCAPTCHA but handles errors such as
/// "missing initial state" (Brave browser blocks sessionStorage) gracefully
/// with an automatic retry without the stale resend token.
class FirebasePhoneAuthService {
  static final FirebasePhoneAuthService _instance =
      FirebasePhoneAuthService._internal();
  factory FirebasePhoneAuthService() => _instance;
  FirebasePhoneAuthService._internal();

  FirebaseAuth get _auth => FirebaseAuth.instance;

  String? _verificationId;
  int? _resendToken;
  String? _pendingPhoneNumber;
  DateTime? _verificationStartTime;
  Completer<PhoneAuthResult>? _verificationCompleter;
  bool _isVerificationInProgress = false;

  String? get verificationId => _verificationId;
  bool get isVerificationInProgress => _isVerificationInProgress;
  String? get pendingPhoneNumber => _pendingPhoneNumber;

  bool get hasValidSession {
    if (_verificationId == null || _verificationStartTime == null) return false;
    final elapsed = DateTime.now().difference(_verificationStartTime!);
    return elapsed.inMinutes < 10;
  }

  /// Ensure Firebase auth state is clean before starting phone verification.
  /// A leftover Firebase user (e.g. from Google Sign-In) can corrupt the
  /// reCAPTCHA / Play Integrity handshake.
  Future<void> _ensureCleanAuthState() async {
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      debugPrint(
          '🔥 Firebase: Signing out stale user (${currentUser.uid}) before phone verification');
      try {
        await _auth.signOut();
      } catch (e) {
        debugPrint('🔥 Firebase: Stale user sign-out error (non-fatal): $e');
      }
    }

    // Tell Firebase to prefer native (Play Integrity / SafetyNet) over
    // browser-based reCAPTCHA. This is critical on browsers like Brave that
    // block sessionStorage and cause the "missing initial state" error.
    if (Platform.isAndroid) {
      try {
        await _auth.setSettings(
          forceRecaptchaFlow: false,
          appVerificationDisabledForTesting: false,
        );
        debugPrint('🔥 Firebase: forceRecaptchaFlow=false (prefer Play Integrity)');
      } catch (e) {
        debugPrint('🔥 Firebase: setSettings error (non-fatal): $e');
      }
    }
  }

  /// Send OTP using native verification. If the initial attempt fails with a
  /// reCAPTCHA / session-state error, automatically retries once without the
  /// cached [_resendToken] to force a fresh verification handshake.
  Future<PhoneAuthResult> sendOTP(String phoneNumber) async {
    if (_isVerificationInProgress) {
      debugPrint('🔥 Firebase: Verification already in progress, ignoring');
      return PhoneAuthResult(
        success: false,
        error: 'Verification already in progress. Please wait.',
        code: 'verification-in-progress',
      );
    }

    final digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    final localDigits =
        digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    final formattedPhone = '+91$localDigits';

    debugPrint('🔥 Firebase: sendOTP → $formattedPhone');

    // Clean up any leftover Firebase user / reCAPTCHA state
    await _ensureCleanAuthState();

    final result = await _doVerifyPhone(formattedPhone, _resendToken);

    // Auto-retry: if reCAPTCHA / browser state failed, try once more with a
    // fresh session (no resend token → forces Play Integrity re-negotiation).
    if (!result.success && _isRecaptchaStateError(result)) {
      debugPrint(
          '🔥 Firebase: reCAPTCHA state error detected — retrying without resend token');
      _resendToken = null;
      return _doVerifyPhone(formattedPhone, null);
    }

    return result;
  }

  bool _isRecaptchaStateError(PhoneAuthResult result) {
    final msg = (result.error ?? '').toLowerCase();
    final code = result.code ?? '';
    return code == 'captcha-check-failed' ||
        code == 'web-context-cancelled' ||
        code == 'missing-initial-state' ||
        msg.contains('missing initial state') ||
        msg.contains('sessionstorage') ||
        msg.contains('recaptcha');
  }

  Future<PhoneAuthResult> _doVerifyPhone(
      String formattedPhone, int? resendToken) async {
    _isVerificationInProgress = true;
    _pendingPhoneNumber = formattedPhone;
    _verificationStartTime = DateTime.now();
    _verificationCompleter = Completer<PhoneAuthResult>();

    try {
      debugPrint(
          '🔥 Firebase: verifyPhoneNumber (resendToken=${resendToken != null})');
      await _auth.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('🔥 Firebase: Auto-verification (SMS auto-read)');
          _isVerificationInProgress = false;
          try {
            final userCredential =
                await _auth.signInWithCredential(credential);
            final idToken = await userCredential.user?.getIdToken();
            _completeVerification(PhoneAuthResult(
              success: true,
              autoVerified: true,
              idToken: idToken,
              user: userCredential.user,
              message: 'Auto-verified successfully',
            ));
          } catch (e) {
            debugPrint('🔥 Firebase: Auto sign-in failed: $e');
            _completeVerification(PhoneAuthResult(
              success: false,
              error: 'Auto verification failed: $e',
            ));
          }
        },
        codeSent: (String verificationId, int? newResendToken) {
          debugPrint('🔥 Firebase: codeSent → verificationId=${verificationId.substring(0, 20)}...');
          _verificationId = verificationId;
          _resendToken = newResendToken;
          _isVerificationInProgress = false;
          _completeVerification(PhoneAuthResult(
            success: true,
            verificationId: verificationId,
            message: 'OTP sent successfully',
          ));
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('🔥 Firebase: verificationFailed → ${e.code}: ${e.message}');
          _isVerificationInProgress = false;

          if (e.code == 'captcha-check-failed' ||
              (e.message?.contains('reCAPTCHA') ?? false) ||
              (e.message?.contains('missing initial state') ?? false)) {
            debugPrint(
                '⚠️ Firebase: reCAPTCHA / browser state error — check SHA-256 + App Check');
          }

          String errorMessage;
          String errorCode = e.code;
          switch (e.code) {
            case 'invalid-phone-number':
              errorMessage =
                  'Invalid phone number format. Please check and try again.';
              break;
            case 'too-many-requests':
              errorMessage =
                  'Too many OTP requests. Please wait a few minutes.';
              break;
            case 'quota-exceeded':
              errorMessage =
                  'SMS service temporarily unavailable. Please try later.';
              break;
            case 'app-not-authorized':
              errorMessage =
                  'App configuration error. Please update the app.';
              break;
            case 'captcha-check-failed':
              errorMessage = 'Verification check failed. Retrying...';
              break;
            case 'network-request-failed':
              errorMessage =
                  'Network error. Please check your connection.';
              break;
            case 'web-context-cancelled':
              errorMessage = 'Verification cancelled. Please try again.';
              break;
            default:
              // Detect "missing initial state" from the message text
              if (e.message?.contains('missing initial state') ?? false) {
                errorMessage =
                    'Browser verification failed. Retrying with native flow...';
                errorCode = 'missing-initial-state';
              } else {
                errorMessage =
                    e.message ?? 'Failed to send OTP. Please try again.';
              }
          }

          _completeVerification(PhoneAuthResult(
            success: false,
            error: errorMessage,
            code: errorCode,
          ));
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint('🔥 Firebase: Auto-retrieval timeout');
          _verificationId = verificationId;
        },
      );

      debugPrint('🔥 Firebase: verifyPhoneNumber returned, awaiting completer');
      return await _verificationCompleter!.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          debugPrint('🔥 Firebase: Completer timed out');
          _isVerificationInProgress = false;
          return PhoneAuthResult(
            success: false,
            error: 'Verification timed out. Please try again.',
            code: 'timeout',
          );
        },
      );
    } catch (e) {
      debugPrint('🔥 Firebase: sendOTP error: $e');
      _isVerificationInProgress = false;

      final errStr = e.toString().toLowerCase();
      if (errStr.contains('missing initial state') ||
          errStr.contains('sessionstorage')) {
        return PhoneAuthResult(
          success: false,
          error: 'Browser verification failed. Retrying with native flow...',
          code: 'missing-initial-state',
        );
      }

      return PhoneAuthResult(
        success: false,
        error: 'Failed to send OTP. Please check your connection.',
      );
    }
  }

  void _completeVerification(PhoneAuthResult result) {
    if (_verificationCompleter != null &&
        !_verificationCompleter!.isCompleted) {
      _verificationCompleter!.complete(result);
    }
  }

  Future<PhoneAuthResult> verifyOTP(String otp) async {
    final cleanOtp = otp.replaceAll(RegExp(r'[^\d]'), '');
    if (cleanOtp.length != 6) {
      return PhoneAuthResult(
        success: false,
        error: 'Please enter a valid 6-digit OTP.',
        code: 'invalid-otp-format',
      );
    }

    if (_verificationId == null) {
      debugPrint('🔥 Firebase: No verification ID found');
      return PhoneAuthResult(
        success: false,
        error: 'Verification session not found. Please request OTP again.',
        code: 'no-verification-session',
      );
    }

    if (_verificationStartTime != null) {
      final elapsed = DateTime.now().difference(_verificationStartTime!);
      if (elapsed.inMinutes > 10) {
        debugPrint(
            '🔥 Firebase: Session likely expired (${elapsed.inMinutes} min)');
      }
    }

    debugPrint('🔥 Firebase: Verifying OTP ${cleanOtp.substring(0, 2)}****');

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: cleanOtp,
      );

      final userCredential =
          await _auth.signInWithCredential(credential).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('OTP verification timed out'),
      );

      final idToken = await userCredential.user?.getIdToken();

      debugPrint('🔥 Firebase: OTP verified — UID ${userCredential.user?.uid}');

      _pendingPhoneNumber = null;
      _verificationStartTime = null;

      return PhoneAuthResult(
        success: true,
        idToken: idToken,
        user: userCredential.user,
        message: 'OTP verified successfully',
      );
    } on TimeoutException {
      debugPrint('🔥 Firebase: OTP verification timed out');
      return PhoneAuthResult(
        success: false,
        error:
            'Verification timed out. Please check your connection and try again.',
        code: 'timeout',
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('🔥 Firebase: OTP failed — ${e.code}: ${e.message}');

      String errorMessage;
      bool shouldRequestNewOtp = false;

      switch (e.code) {
        case 'invalid-verification-code':
          errorMessage = 'Incorrect OTP. Please check and try again.';
          break;
        case 'session-expired':
          errorMessage = 'OTP has expired. Please request a new one.';
          shouldRequestNewOtp = true;
          break;
        case 'invalid-verification-id':
          errorMessage = 'Session expired. Please request a new OTP.';
          shouldRequestNewOtp = true;
          break;
        case 'credential-already-in-use':
          errorMessage =
              'This phone number is already linked to another account.';
          break;
        case 'user-disabled':
          errorMessage =
              'This account has been disabled. Please contact support.';
          break;
        default:
          errorMessage =
              e.message ?? 'Verification failed. Please try again.';
      }

      if (shouldRequestNewOtp) {
        _verificationId = null;
        _verificationStartTime = null;
      }

      return PhoneAuthResult(
        success: false,
        error: errorMessage,
        code: e.code,
      );
    } catch (e) {
      debugPrint('🔥 Firebase: Error verifying OTP: $e');
      return PhoneAuthResult(
        success: false,
        error: 'Failed to verify OTP. Please try again.',
      );
    }
  }

  Future<PhoneAuthResult> resendOTP(String phoneNumber) async {
    debugPrint(
        '🔥 Firebase: Resending OTP (resendToken=${_resendToken != null})');
    _isVerificationInProgress = false;
    return sendOTP(phoneNumber);
  }

  /// Full sign-out: clears Firebase user, resets verification state, and
  /// ensures forceRecaptchaFlow is off for the next phone verification.
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      clearVerification();

      if (Platform.isAndroid) {
        try {
          await _auth.setSettings(forceRecaptchaFlow: false);
        } catch (_) {}
      }

      debugPrint('🔥 Firebase: Signed out and settings reset');
    } catch (e) {
      debugPrint('🔥 Firebase: Sign out error: $e');
    }
  }

  User? get currentUser => _auth.currentUser;

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return await _auth.currentUser?.getIdToken(forceRefresh);
  }

  void clearVerification() {
    _verificationId = null;
    _resendToken = null;
    _pendingPhoneNumber = null;
    _verificationStartTime = null;
    _isVerificationInProgress = false;
    _verificationCompleter = null;
  }

  bool canRestoreSession() {
    return _verificationId != null && hasValidSession;
  }
}

class PhoneAuthResult {
  final bool success;
  final String? verificationId;
  final String? idToken;
  final User? user;
  final String? error;
  final String? code;
  final String? message;
  final bool autoVerified;

  PhoneAuthResult({
    required this.success,
    this.verificationId,
    this.idToken,
    this.user,
    this.error,
    this.code,
    this.message,
    this.autoVerified = false,
  });
}

final firebasePhoneAuth = FirebasePhoneAuthService();
