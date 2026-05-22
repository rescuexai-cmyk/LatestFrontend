import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/driver_penalty.dart';
import '../../../core/services/api_client.dart';

class DriverPenaltyState {
  final bool isLoading;
  final String? error;
  final PenaltyStatusResponse? penaltyStatus;
  final bool isClearing;

  const DriverPenaltyState({
    this.isLoading = false,
    this.error,
    this.penaltyStatus,
    this.isClearing = false,
  });

  DriverPenaltyState copyWith({
    bool? isLoading,
    String? error,
    PenaltyStatusResponse? penaltyStatus,
    bool? isClearing,
    bool clearError = false,
  }) {
    return DriverPenaltyState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      penaltyStatus: penaltyStatus ?? this.penaltyStatus,
      isClearing: isClearing ?? this.isClearing,
    );
  }

  bool get hasPendingPenalty => penaltyStatus?.hasPendingPenalty ?? false;
  double get penaltyAmount => penaltyStatus?.penaltyAmount ?? 0;
  double get walletBalance => penaltyStatus?.walletBalance ?? 0;
  bool get canPayFromWallet => penaltyStatus?.canPayFromWallet ?? false;
  String? get penaltyReason => penaltyStatus?.penaltyReason;
  String? get penaltyId => penaltyStatus?.penaltyId;
}

class DriverPenaltyNotifier extends StateNotifier<DriverPenaltyState> {
  final ApiClient _apiClient;

  DriverPenaltyNotifier(this._apiClient) : super(const DriverPenaltyState());

  Future<bool> checkPenaltyStatus() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      debugPrint('🔍 Checking driver penalty status...');
      final response = await _apiClient.getDriverPenaltyStatus();
      
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>? ?? response;
        final penaltyStatus = PenaltyStatusResponse.fromJson(data);
        
        debugPrint('✅ Penalty status: hasPending=${penaltyStatus.hasPendingPenalty}, '
            'amount=${penaltyStatus.penaltyAmount}, wallet=${penaltyStatus.walletBalance}');
        
        state = state.copyWith(
          isLoading: false,
          penaltyStatus: penaltyStatus,
        );
        return penaltyStatus.hasPendingPenalty;
      } else {
        final message = response['message'] as String? ?? 'Failed to check penalty status';
        debugPrint('❌ Penalty status check failed: $message');
        state = state.copyWith(
          isLoading: false,
          error: message,
          penaltyStatus: PenaltyStatusResponse.none(),
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Penalty status error: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to check penalty status',
        penaltyStatus: PenaltyStatusResponse.none(),
      );
      return false;
    }
  }

  Future<bool> clearPenaltyWithWallet() async {
    if (state.isClearing) return false;
    
    state = state.copyWith(isClearing: true, clearError: true);

    try {
      debugPrint('💳 Clearing penalty with wallet...');
      final response = await _apiClient.clearPenaltyWithWallet(
        penaltyId: state.penaltyId,
      );
      
      if (response['success'] == true) {
        debugPrint('✅ Penalty cleared with wallet');
        
        // Update state to reflect cleared penalty
        state = state.copyWith(
          isClearing: false,
          penaltyStatus: PenaltyStatusResponse(
            hasPendingPenalty: false,
            penaltyAmount: 0,
            walletBalance: (response['newWalletBalance'] as num?)?.toDouble() ?? 
                (state.walletBalance - state.penaltyAmount),
            canPayFromWallet: false,
          ),
        );
        return true;
      } else {
        final message = response['message'] as String? ?? 'Failed to clear penalty';
        debugPrint('❌ Clear penalty failed: $message');
        state = state.copyWith(
          isClearing: false,
          error: message,
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Clear penalty error: $e');
      state = state.copyWith(
        isClearing: false,
        error: 'Failed to clear penalty. Please try again.',
      );
      return false;
    }
  }

  Future<bool> clearPenaltyWithUpi({String? transactionId}) async {
    if (state.isClearing) return false;
    
    state = state.copyWith(isClearing: true, clearError: true);

    try {
      debugPrint('💳 Clearing penalty with UPI payment...');
      final response = await _apiClient.clearPenaltyWithUpi(
        penaltyId: state.penaltyId,
        transactionId: transactionId,
      );
      
      if (response['success'] == true) {
        debugPrint('✅ Penalty cleared with UPI');
        
        // Update state to reflect cleared penalty
        state = state.copyWith(
          isClearing: false,
          penaltyStatus: PenaltyStatusResponse(
            hasPendingPenalty: false,
            penaltyAmount: 0,
            walletBalance: state.walletBalance,
            canPayFromWallet: false,
          ),
        );
        return true;
      } else {
        final message = response['message'] as String? ?? 'Failed to clear penalty';
        debugPrint('❌ Clear penalty with UPI failed: $message');
        state = state.copyWith(
          isClearing: false,
          error: message,
        );
        return false;
      }
    } catch (e) {
      debugPrint('❌ Clear penalty with UPI error: $e');
      state = state.copyWith(
        isClearing: false,
        error: 'Failed to clear penalty. Please try again.',
      );
      return false;
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void reset() {
    state = const DriverPenaltyState();
  }
}

final driverPenaltyProvider =
    StateNotifierProvider<DriverPenaltyNotifier, DriverPenaltyState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DriverPenaltyNotifier(apiClient);
});

// Convenience providers
final hasPendingPenaltyProvider = Provider<bool>((ref) {
  return ref.watch(driverPenaltyProvider).hasPendingPenalty;
});

final penaltyAmountProvider = Provider<double>((ref) {
  return ref.watch(driverPenaltyProvider).penaltyAmount;
});

final canPayPenaltyFromWalletProvider = Provider<bool>((ref) {
  return ref.watch(driverPenaltyProvider).canPayFromWallet;
});
