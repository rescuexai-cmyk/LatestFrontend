import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_transliterator/flutter_transliterator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import '../providers/settings_provider.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/driver/providers/driver_onboarding_provider.dart';

/// Single entry-point for changing app language everywhere (rider + driver).
class AppLanguageService {
  AppLanguageService._();

  static final FlutterTransliterator _transliterator = FlutterTransliterator();

  /// Language codes supported by [flutter_transliterator] for name/script conversion.
  static const transliterableCodes = {'hi', 'ta', 'te', 'kn', 'ml'};

  /// Apply [code] as the app UI language and optionally sync driver backend preference.
  static Future<AppLanguage> apply(
    WidgetRef ref,
    String code, {
    bool syncDriverPreference = true,
  }) async {
    final lang = resolveAppLanguage(code);
    await ref.read(settingsProvider.notifier).ensureLoaded();
    await ref.read(settingsProvider.notifier).setLanguage(lang.code, lang.name);

    if (syncDriverPreference) {
      final user = ref.read(currentUserProvider);
      final isDriver = user?.userType == UserType.driver ||
          user?.userType == UserType.both;
      if (isDriver) {
        try {
          await ref
              .read(driverOnboardingProvider.notifier)
              .setLanguage(lang.code);
        } catch (e) {
          debugPrint('⚠️ Driver language API sync failed (UI still updated): $e');
        }
      }
    }

    return lang;
  }

  /// On driver home open: if app locale is still default English but the driver
  /// previously saved a non-English preference, hydrate the app locale from it.
  /// Never overwrite a deliberate app language choice with English.
  static Future<void> hydrateFromDriverPreference(WidgetRef ref) async {
    await ref.read(settingsProvider.notifier).ensureLoaded();
    final settings = ref.read(settingsProvider);
    final onboarding = ref.read(driverOnboardingProvider);

    String? driverLang = onboarding.selectedLanguage;
    if (driverLang == null || driverLang.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      driverLang = prefs.getString('driver_language');
    }
    if (driverLang == null || driverLang.isEmpty) return;

    final resolvedDriver = resolveAppLanguage(driverLang);
    if (resolvedDriver.code == 'en') return;
    if (settings.languageCode == resolvedDriver.code) return;

    // Only auto-hydrate when app is still on English (first open after onboarding).
    if (settings.languageCode != 'en') return;

    debugPrint(
      '🌐 Hydrating app language from driver preference: ${resolvedDriver.code}',
    );
    await ref
        .read(settingsProvider.notifier)
        .setLanguage(resolvedDriver.code, resolvedDriver.name);
  }

  /// Transliterate a Latin name/place into the active Indian script when possible.
  /// Returns [text] unchanged for English or unsupported codes.
  static String transliterateName(String text, String languageCode) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;
    if (!transliterableCodes.contains(languageCode)) return text;
    try {
      return _transliterator.transliterate(
        text: trimmed,
        toLanguageCode: languageCode,
      );
    } catch (e) {
      debugPrint('⚠️ Transliteration failed for "$trimmed" → $languageCode: $e');
      return text;
    }
  }

  /// Convenience: transliterate using the current settings language.
  static String displayName(WidgetRef ref, String text) {
    final code = ref.read(settingsProvider).languageCode;
    return transliterateName(text, code);
  }
}
