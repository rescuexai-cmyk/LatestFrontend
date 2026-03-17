import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Firebase Phone Authentication Service
/// Handles phone number verification using Firebase Auth
class FirebasePhoneAuthService {
  static final FirebasePhoneAuthService _instance = FirebasePhoneAuthService._internal();
  factory FirebasePhoneAuthService() => _instance;
  FirebasePhoneAuthService._internal();

  /// Lazy: avoid accessing Firebase before Firebase.initializeApp() runs.
  FirebaseAuth get _auth => FirebaseAuth.instance;
  
  String? _verificationId;
  int? _resendToken;
  Completer<PhoneAuthResult>? _verificationCompleter;

  /// Current verification ID (needed for OTP verification)
  String? get verificationId => _verificationId;

  /// Send OTP to phone number using Firebase
  /// Returns a result with verificationId or error
  Future<PhoneAuthResult> sendOTP(String phoneNumber) async {
    // Ensure phone number has country code
    String formattedPhone = phoneNumber;
    if (!phoneNumber.startsWith('+')) {
      formattedPhone = '+91$phoneNumber'; // Default to India
    }

    debugPrint('🔥 Firebase: Sending OTP to $formattedPhone');

    _verificationCompleter = Completer<PhoneAuthResult>();

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        
        // Called when verification is completed automatically (Android only)
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('🔥 Firebase: Auto-verification completed');
          // Auto sign-in (Android SMS auto-retrieval)
          try {
            final userCredential = await _auth.signInWithCredential(credential);
            final idToken = await userCredential.user?.getIdToken();
            
            if (!_verificationCompleter!.isCompleted) {
              _verificationCompleter!.complete(PhoneAuthResult(
                success: true,
                autoVerified: true,
                idToken: idToken,
                user: userCredential.user,
              ));
            }
          } catch (e) {
            debugPrint('🔥 Firebase: Auto sign-in failed: $e');
            if (!_verificationCompleter!.isCompleted) {
              _verificationCompleter!.complete(PhoneAuthResult(
                success: false,
                error: 'Auto verification failed: $e',
              ));
            }
          }
        },
        
        // Called when SMS code is sent
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('🔥 Firebase: OTP sent, verificationId: $verificationId');
          _verificationId = verificationId;
          _resendToken = resendToken;
          
          if (!_verificationCompleter!.isCompleted) {
            _verificationCompleter!.complete(PhoneAuthResult(
              success: true,
              verificationId: verificationId,
              message: 'OTP sent successfully',
            ));
          }
        },
        
        // Called when verification fails
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('🔥 Firebase: Verification failed: ${e.code} - ${e.message}');
          
          String errorMessage;
          switch (e.code) {
            case 'invalid-phone-number':
              errorMessage = 'Invalid phone number format';
              break;
            case 'too-many-requests':
              errorMessage = 'Too many requests. Please try again later.';
              break;
            case 'quota-exceeded':
              errorMessage = 'SMS quota exceeded. Please try again later.';
              break;
            case 'app-not-authorized':
              errorMessage = 'App not authorized for phone auth. Check Firebase console.';
              break;
            case 'captcha-check-failed':
              errorMessage = 'reCAPTCHA verification failed. Please try again.';
              break;
            default:
              errorMessage = e.message ?? 'Verification failed';
          }
          
          if (!_verificationCompleter!.isCompleted) {
            _verificationCompleter!.complete(PhoneAuthResult(
              success: false,
              error: errorMessage,
              code: e.code,
            ));
          }
        },
        
        // Called when code auto-retrieval times out
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint('🔥 Firebase: Code auto-retrieval timeout');
          _verificationId = verificationId;
        },
      );

      return await _verificationCompleter!.future;
    } catch (e) {
      debugPrint('🔥 Firebase: Error sending OTP: $e');
      return PhoneAuthResult(
        success: false,
        error: 'Failed to send OTP: $e',
      );
    }
  }

  /// Verify OTP and get Firebase ID token
  Future<PhoneAuthResult> verifyOTP(String otp) async {
    if (_verificationId == null) {
      return PhoneAuthResult(
        success: false,
        error: 'No verification in progress. Please request OTP first.',
      );
    }

    debugPrint('🔥 Firebase: Verifying OTP');

    try {
      // Create credential from verification ID and OTP
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: otp,
      );

      // Sign in with credential
      final userCredential = await _auth.signInWithCredential(credential);
      
      // Get ID token for backend verification
      final idToken = await userCredential.user?.getIdToken();
      
      debugPrint('🔥 Firebase: OTP verified successfully');
      debugPrint('🔥 Firebase: User UID: ${userCredential.user?.uid}');
      debugPrint('🔥 Firebase: ID Token length: ${idToken?.length ?? 0}');

      return PhoneAuthResult(
        success: true,
        idToken: idToken,
        user: userCredential.user,
        message: 'OTP verified successfully',
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('🔥 Firebase: OTP verification failed: ${e.code} - ${e.message}');
      
      String errorMessage;
      switch (e.code) {
        case 'invalid-verification-code':
          errorMessage = 'Invalid OTP. Please check and try again.';
          break;
        case 'session-expired':
          errorMessage = 'OTP expired. Please request a new one.';
          break;
        case 'invalid-verification-id':
          errorMessage = 'Verification session expired. Please request OTP again.';
          break;
        default:
          errorMessage = e.message ?? 'Verification failed';
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
        error: 'Failed to verify OTP: $e',
      );
    }
  }

  /// Resend OTP to the same phone number
  Future<PhoneAuthResult> resendOTP(String phoneNumber) async {
    debugPrint('🔥 Firebase: Resending OTP');
    return sendOTP(phoneNumber);
  }

  /// Sign out from Firebase
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      _verificationId = null;
      _resendToken = null;
      debugPrint('🔥 Firebase: Signed out');
    } catch (e) {
      debugPrint('🔥 Firebase: Sign out error: $e');
    }
  }

  /// Get current Firebase user
  User? get currentUser => _auth.currentUser;

  /// Get current ID token (for backend API calls)
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return await _auth.currentUser?.getIdToken(forceRefresh);
  }

  /// Clear verification state
  void clearVerification() {
    _verificationId = null;
    _resendToken = null;
  }
}

/// Result of phone authentication operations
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

/// Global instance
final firebasePhoneAuth = FirebasePhoneAuthService();
