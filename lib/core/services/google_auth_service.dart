import 'package:google_sign_in/google_sign_in.dart';
import '../config/app_config.dart';

class GoogleAuthResult {
  final bool success;
  final bool cancelled;
  final String? idToken;
  final String? error;

  const GoogleAuthResult({
    required this.success,
    this.cancelled = false,
    this.idToken,
    this.error,
  });
}

class GoogleAuthService {
  GoogleAuthService._();

  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (AppConfig.googleServerClientId.isEmpty) {
      throw Exception(
        'Google Sign-In is not configured: missing GOOGLE_SERVER_CLIENT_ID.',
      );
    }
    await _googleSignIn.initialize(
      serverClientId: AppConfig.googleServerClientId,
    );
    _initialized = true;
  }

  static Future<GoogleAuthResult> signIn() async {
    try {
      await _ensureInitialized();
      final account = await _googleSignIn.authenticate();

      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        return const GoogleAuthResult(
          success: false,
          error: 'Google ID token not available',
        );
      }

      return GoogleAuthResult(success: true, idToken: idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const GoogleAuthResult(success: false, cancelled: true);
      }
      return const GoogleAuthResult(
        success: false,
        error: 'Unable to sign in with Google. Please try again.',
      );
    } catch (e) {
      final raw = e.toString();
      if (_isUserCancelled(raw)) {
        return const GoogleAuthResult(success: false, cancelled: true);
      }
      return const GoogleAuthResult(
        success: false,
        error: 'Unable to sign in with Google. Please try again.',
      );
    }
  }

  static bool _isUserCancelled(String raw) {
    return raw.contains('GoogleSignInExceptionCode.canceled') ||
        raw.contains('Cancelled by user') ||
        raw.contains('sign_in_canceled') ||
        raw.contains('SignInCanceledException');
  }
}
