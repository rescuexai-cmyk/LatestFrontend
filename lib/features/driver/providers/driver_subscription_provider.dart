import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/driver_subscription.dart';
import '../../../core/services/api_client.dart';

class DriverSubscriptionState {
  final DriverSubscription? subscription;
  final bool isLoading;
  final String? error;

  const DriverSubscriptionState({
    this.subscription,
    this.isLoading = false,
    this.error,
  });

  DriverSubscriptionState copyWith({
    DriverSubscription? subscription,
    bool? isLoading,
    String? error,
  }) {
    return DriverSubscriptionState(
      subscription: subscription ?? this.subscription,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool get canGoOnline => subscription?.canGoOnline ?? false;
  bool get isActive => subscription?.isActive ?? false;
  DateTime? get validTill => subscription?.validTill;
  String get remainingTimeFormatted =>
      subscription?.remainingTimeFormatted ?? 'Not purchased';
  String get validTillFormatted =>
      subscription?.validTillFormatted ?? 'Not purchased';
}

class DriverSubscriptionNotifier extends StateNotifier<DriverSubscriptionState> {
  final ApiClient _apiClient;

  DriverSubscriptionNotifier(this._apiClient)
      : super(const DriverSubscriptionState());

  Future<bool> checkSubscriptionStatus() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.getDriverSubscriptionStatus();
      debugPrint('📅 Subscription status response: $response');

      final subscription = DriverSubscription.fromJson(response);
      state = state.copyWith(
        subscription: subscription,
        isLoading: false,
      );

      return subscription.canGoOnline;
    } catch (e) {
      debugPrint('❌ Failed to check subscription status: $e');
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
      return false;
    }
  }

  Future<bool> activateSubscription({String? transactionId}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _apiClient.activateDriverSubscription(
        transactionId: transactionId,
        paymentMethod: 'UPI',
      );
      debugPrint('📅 Subscription activation response: $response');

      final activationResponse =
          SubscriptionActivationResponse.fromJson(response);

      if (activationResponse.success) {
        await checkSubscriptionStatus();
        return true;
      } else {
        state = state.copyWith(
          isLoading: false,
          error: activationResponse.message ?? 'Activation failed',
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Failed to activate subscription: $e');
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
      return false;
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  void reset() {
    state = const DriverSubscriptionState();
  }
}

final driverSubscriptionProvider =
    StateNotifierProvider<DriverSubscriptionNotifier, DriverSubscriptionState>(
  (ref) => DriverSubscriptionNotifier(ref.watch(apiClientProvider)),
);

final canDriverGoOnlineProvider = Provider<bool>((ref) {
  return ref.watch(driverSubscriptionProvider).canGoOnline;
});

final subscriptionValidTillProvider = Provider<DateTime?>((ref) {
  return ref.watch(driverSubscriptionProvider).validTill;
});
