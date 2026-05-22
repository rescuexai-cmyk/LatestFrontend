import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../providers/auth_provider.dart';
import '../../providers/saved_accounts_provider.dart';

/// Bottom sheet to display saved accounts and allow switching
class SwitchAccountSheet extends ConsumerStatefulWidget {
  const SwitchAccountSheet({super.key});

  @override
  ConsumerState<SwitchAccountSheet> createState() => _SwitchAccountSheetState();
}

class _SwitchAccountSheetState extends ConsumerState<SwitchAccountSheet> {
  bool _isLoading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final savedAccountsState = ref.watch(savedAccountsProvider);
    final currentUser = ref.watch(currentUserProvider);
    final savedAccounts = savedAccountsState.accounts;

    // Filter out the current user from saved accounts
    final otherAccounts = savedAccounts.where((a) => a.id != currentUser?.id).toList();
    final currentSavedAccount = savedAccounts.where((a) => a.id == currentUser?.id).firstOrNull;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          
          // Title
          const Text(
            'Switch Account',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You can save up to 2 accounts on this device',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),

          // Error message
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Colors.red[700], fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Loading indicator
          if (_isLoading) ...[
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          ] else ...[
            // Current account section
            if (currentUser != null) ...[
              const Text(
                'Current Account',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF666666),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              _buildAccountTile(
                name: currentUser.name,
                phone: currentUser.phone ?? '',
                avatarUrl: currentUser.avatarUrl,
                isCurrent: true,
                onTap: null,
                onSave: currentSavedAccount == null ? () => _saveCurrentAccount() : null,
                isSaved: currentSavedAccount != null,
              ),
              const SizedBox(height: 24),
            ],

            // Saved accounts section
            if (otherAccounts.isNotEmpty) ...[
              const Text(
                'Saved Accounts',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF666666),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              ...otherAccounts.map((account) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildAccountTile(
                  name: account.name,
                  phone: account.phone,
                  avatarUrl: account.avatarUrl,
                  isCurrent: false,
                  onTap: () => _switchToAccount(account),
                  onRemove: () => _removeAccount(account),
                  isSaved: true,
                ),
              )),
              const SizedBox(height: 8),
            ],

            // Add new account button (only if can add more)
            if (savedAccountsState.canAddMore || otherAccounts.isEmpty) ...[
              const Divider(height: 32),
              _buildAddAccountButton(),
            ] else ...[
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Maximum 2 accounts reached',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAccountTile({
    required String name,
    required String phone,
    String? avatarUrl,
    required bool isCurrent,
    VoidCallback? onTap,
    VoidCallback? onSave,
    VoidCallback? onRemove,
    bool isSaved = false,
  }) {
    final maskedPhone = phone.length >= 10
        ? '${phone.substring(0, 3)}****${phone.substring(phone.length - 3)}'
        : phone;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isCurrent ? const Color(0xFFF5F0E6) : Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCurrent ? const Color(0xFFBEB09A) : Colors.grey[200]!,
            width: isCurrent ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            // Avatar
            CircleAvatar(
              radius: 24,
              backgroundColor: isCurrent ? const Color(0xFFBEB09A) : Colors.grey[300],
              backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
              child: avatarUrl == null
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.grey[700],
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            
            // Name and phone
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    maskedPhone,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),

            // Action buttons
            if (onSave != null)
              IconButton(
                onPressed: onSave,
                icon: const Icon(Icons.bookmark_add_outlined),
                tooltip: 'Save this account',
                color: const Color(0xFFBEB09A),
              ),
            if (isSaved && !isCurrent)
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove saved account',
                color: Colors.grey[400],
              ),
            if (!isCurrent && onTap != null)
              const Icon(
                Icons.chevron_right,
                color: Color(0xFFBEB09A),
                size: 28,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddAccountButton() {
    return InkWell(
      onTap: _addNewAccount,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[300]!, style: BorderStyle.solid),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, color: Colors.grey[700]),
            const SizedBox(width: 12),
            Text(
              'Login with different number',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveCurrentAccount() async {
    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) return;

    setState(() => _isLoading = true);

    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      final token = await authNotifier.getCurrentToken();
      final refreshToken = await authNotifier.getCurrentRefreshToken();

      if (token == null) {
        setState(() {
          _isLoading = false;
          _error = 'Failed to get current session';
        });
        return;
      }

      final savedAccount = SavedAccount.fromUserAndTokens(
        user: currentUser,
        token: token,
        refreshToken: refreshToken,
      );

      final savedAccountsNotifier = ref.read(savedAccountsProvider.notifier);
      final success = await savedAccountsNotifier.saveAccount(savedAccount);

      if (!success) {
        setState(() {
          _isLoading = false;
          _error = 'Maximum 2 accounts allowed';
        });
        return;
      }

      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account saved successfully'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to save account: $e';
      });
    }
  }

  Future<void> _switchToAccount(SavedAccount account) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // First save current account if not already saved
      await _saveCurrentAccountSilently();

      final authNotifier = ref.read(authStateProvider.notifier);
      final success = await authNotifier.switchToAccount(
        token: account.token,
        refreshToken: account.refreshToken,
        user: account.toUser(),
      );

      if (success) {
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Switched to ${account.displayName}'),
              backgroundColor: const Color(0xFF4CAF50),
            ),
          );
        }
      } else {
        // Token expired - remove the saved account
        final savedAccountsNotifier = ref.read(savedAccountsProvider.notifier);
        await savedAccountsNotifier.removeAccount(account.id);
        
        setState(() {
          _isLoading = false;
          _error = 'Session expired. Account removed. Please login again.';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to switch account: $e';
      });
    }
  }

  Future<void> _saveCurrentAccountSilently() async {
    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) return;

    final savedAccountsNotifier = ref.read(savedAccountsProvider.notifier);
    if (savedAccountsNotifier.isAccountSaved(currentUser.id)) return;

    final authNotifier = ref.read(authStateProvider.notifier);
    final token = await authNotifier.getCurrentToken();
    final refreshToken = await authNotifier.getCurrentRefreshToken();

    if (token == null) return;

    final savedAccount = SavedAccount.fromUserAndTokens(
      user: currentUser,
      token: token,
      refreshToken: refreshToken,
    );

    await savedAccountsNotifier.saveAccount(savedAccount);
  }

  Future<void> _removeAccount(SavedAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Account'),
        content: Text('Remove "${account.displayName}" from saved accounts?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final savedAccountsNotifier = ref.read(savedAccountsProvider.notifier);
      await savedAccountsNotifier.removeAccount(account.id);
    }
  }

  void _addNewAccount() {
    // Save current account first, then sign out and go to login
    _saveCurrentAccountSilently().then((_) async {
      final authNotifier = ref.read(authStateProvider.notifier);
      await authNotifier.signOut();
      if (mounted) {
        Navigator.of(context).pop();
        context.go(AppRoutes.login);
      }
    });
  }
}

/// Show the switch account bottom sheet
Future<void> showSwitchAccountSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const SwitchAccountSheet(),
  );
}
