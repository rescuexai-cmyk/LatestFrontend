import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/models/user.dart';
import 'auth_provider.dart';

/// Represents a saved account with its credentials
class SavedAccount {
  final String id;
  final String phone;
  final String name;
  final String? avatarUrl;
  final UserType userType;
  final String token;
  final String? refreshToken;
  final DateTime savedAt;

  const SavedAccount({
    required this.id,
    required this.phone,
    required this.name,
    this.avatarUrl,
    required this.userType,
    required this.token,
    this.refreshToken,
    required this.savedAt,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    return SavedAccount(
      id: json['id'] as String,
      phone: json['phone'] as String,
      name: json['name'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      userType: _parseUserType(json['userType'] as String?),
      token: json['token'] as String,
      refreshToken: json['refreshToken'] as String?,
      savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'phone': phone,
      'name': name,
      'avatarUrl': avatarUrl,
      'userType': userType.name,
      'token': token,
      'refreshToken': refreshToken,
      'savedAt': savedAt.toIso8601String(),
    };
  }

  static UserType _parseUserType(String? type) {
    switch (type) {
      case 'driver':
        return UserType.driver;
      case 'both':
        return UserType.both;
      default:
        return UserType.rider;
    }
  }

  /// Create a SavedAccount from a User and tokens
  factory SavedAccount.fromUserAndTokens({
    required User user,
    required String token,
    String? refreshToken,
  }) {
    return SavedAccount(
      id: user.id,
      phone: user.phone ?? '',
      name: user.name,
      avatarUrl: user.avatarUrl,
      userType: user.userType,
      token: token,
      refreshToken: refreshToken,
      savedAt: DateTime.now(),
    );
  }

  /// Convert to User model
  User toUser() {
    return User(
      id: id,
      email: '',
      phone: phone,
      name: name,
      avatarUrl: avatarUrl,
      userType: userType,
      createdAt: savedAt,
      updatedAt: savedAt,
    );
  }

  String get displayName => name.isNotEmpty ? name : phone;
  String get maskedPhone => phone.length >= 10 
      ? '${phone.substring(0, 3)}****${phone.substring(phone.length - 3)}'
      : phone;
}

/// State for saved accounts
class SavedAccountsState {
  final List<SavedAccount> accounts;
  final bool isLoading;
  final String? error;

  const SavedAccountsState({
    this.accounts = const [],
    this.isLoading = false,
    this.error,
  });

  SavedAccountsState copyWith({
    List<SavedAccount>? accounts,
    bool? isLoading,
    String? error,
  }) {
    return SavedAccountsState(
      accounts: accounts ?? this.accounts,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool get hasAccounts => accounts.isNotEmpty;
  bool get canAddMore => accounts.length < 2;
  int get accountCount => accounts.length;
}

/// Manages saved accounts - allows up to 2 accounts per device
class SavedAccountsNotifier extends StateNotifier<SavedAccountsState> {
  final FlutterSecureStorage _secureStorage;
  static const _savedAccountsKey = 'saved_accounts';
  static const int maxAccounts = 2;

  SavedAccountsNotifier(this._secureStorage) : super(const SavedAccountsState(isLoading: true)) {
    // Defer loading to next microtask to avoid blocking constructor
    Future.microtask(() => _loadSavedAccounts());
  }

  Future<void> _loadSavedAccounts() async {
    try {
      // Add timeout to prevent blocking if secure storage is slow
      final savedJson = await _secureStorage.read(key: _savedAccountsKey).timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (savedJson != null && savedJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(savedJson);
        final accounts = decoded
            .map((e) => SavedAccount.fromJson(e as Map<String, dynamic>))
            .toList();
        state = SavedAccountsState(accounts: accounts);
        debugPrint('📱 Loaded ${accounts.length} saved accounts');
      } else {
        state = const SavedAccountsState();
      }
    } catch (e) {
      debugPrint('❌ Failed to load saved accounts: $e');
      state = SavedAccountsState(error: e.toString());
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final json = jsonEncode(state.accounts.map((a) => a.toJson()).toList());
      await _secureStorage.write(key: _savedAccountsKey, value: json);
    } catch (e) {
      debugPrint('❌ Failed to save accounts to disk: $e');
    }
  }

  /// Save the current account session
  Future<bool> saveAccount(SavedAccount account) async {
    // Check if account already exists (by ID)
    final existingIndex = state.accounts.indexWhere((a) => a.id == account.id);
    
    if (existingIndex >= 0) {
      // Update existing account
      final updatedAccounts = List<SavedAccount>.from(state.accounts);
      updatedAccounts[existingIndex] = account;
      state = state.copyWith(accounts: updatedAccounts);
      await _saveToDisk();
      debugPrint('📱 Updated existing account: ${account.displayName}');
      return true;
    }

    // Check if we can add more
    if (!state.canAddMore) {
      debugPrint('❌ Cannot add more accounts (max $maxAccounts reached)');
      return false;
    }

    // Add new account
    final updatedAccounts = [...state.accounts, account];
    state = state.copyWith(accounts: updatedAccounts);
    await _saveToDisk();
    debugPrint('📱 Saved new account: ${account.displayName}');
    return true;
  }

  /// Remove a saved account by ID
  Future<void> removeAccount(String accountId) async {
    final updatedAccounts = state.accounts.where((a) => a.id != accountId).toList();
    state = state.copyWith(accounts: updatedAccounts);
    await _saveToDisk();
    debugPrint('📱 Removed account: $accountId');
  }

  /// Get a saved account by ID
  SavedAccount? getAccount(String accountId) {
    try {
      return state.accounts.firstWhere((a) => a.id == accountId);
    } catch (_) {
      return null;
    }
  }

  /// Clear all saved accounts
  Future<void> clearAll() async {
    state = const SavedAccountsState();
    await _secureStorage.delete(key: _savedAccountsKey);
    debugPrint('📱 Cleared all saved accounts');
  }

  /// Check if an account is already saved
  bool isAccountSaved(String accountId) {
    return state.accounts.any((a) => a.id == accountId);
  }
}

/// Provider for saved accounts
final savedAccountsProvider = StateNotifierProvider<SavedAccountsNotifier, SavedAccountsState>((ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  return SavedAccountsNotifier(secureStorage);
});

/// Convenience providers
final savedAccountsListProvider = Provider<List<SavedAccount>>((ref) {
  return ref.watch(savedAccountsProvider).accounts;
});

final canAddMoreAccountsProvider = Provider<bool>((ref) {
  return ref.watch(savedAccountsProvider).canAddMore;
});
