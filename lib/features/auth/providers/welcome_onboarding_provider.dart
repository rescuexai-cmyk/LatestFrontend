import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WelcomeOnboardingNotifier extends StateNotifier<bool> {
  WelcomeOnboardingNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('has_seen_welcome_onboarding') ?? false;
  }

  Future<void> complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_welcome_onboarding', true);
    state = true;
  }
}

final welcomeOnboardingProvider = StateNotifierProvider<WelcomeOnboardingNotifier, bool>((ref) {
  return WelcomeOnboardingNotifier();
});
