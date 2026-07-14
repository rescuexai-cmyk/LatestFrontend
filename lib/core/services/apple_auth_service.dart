import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class AppleAuthResult {
  final bool success;
  final bool cancelled;
  final String? identityToken;
  final String? nonce;
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? error;

  const AppleAuthResult({
    required this.success,
    this.cancelled = false,
    this.identityToken,
    this.nonce,
    this.email,
    this.firstName,
    this.lastName,
    this.error,
  });
}

class AppleAuthService {
  AppleAuthService._();

  static String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  static String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    return sha256.convert(bytes).toString();
  }

  static Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return false;
    }
    try {
      return await SignInWithApple.isAvailable();
    } catch (_) {
      return false;
    }
  }

  static Future<AppleAuthResult> signIn() async {
    try {
      final available = await isAvailable();
      if (!available) {
        return const AppleAuthResult(
          success: false,
          error: 'Sign in with Apple is not available on this device.',
        );
      }

      final rawNonce = _generateNonce();
      final hashedNonce = _sha256ofString(rawNonce);

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final identityToken = credential.identityToken;
      if (identityToken == null || identityToken.isEmpty) {
        return const AppleAuthResult(
          success: false,
          error: 'Apple identity token not available',
        );
      }

      final given = credential.givenName?.trim();
      final family = credential.familyName?.trim();

      return AppleAuthResult(
        success: true,
        identityToken: identityToken,
        // JWT nonce claim matches the hashed nonce we passed to Apple.
        nonce: hashedNonce,
        email: credential.email,
        firstName: (given != null && given.isNotEmpty) ? given : null,
        lastName: (family != null && family.isNotEmpty) ? family : null,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return const AppleAuthResult(success: false, cancelled: true);
      }
      return AppleAuthResult(
        success: false,
        error: e.message.isNotEmpty
            ? e.message
            : 'Unable to sign in with Apple. Please try again.',
      );
    } catch (e) {
      final raw = e.toString();
      if (raw.toLowerCase().contains('cancel')) {
        return const AppleAuthResult(success: false, cancelled: true);
      }
      return const AppleAuthResult(
        success: false,
        error: 'Unable to sign in with Apple. Please try again.',
      );
    }
  }
}
