import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../providers/auth_provider.dart';

/// Input formatter for names.
/// - Only allows letters (a-z, A-Z) and spaces
/// - Maximum specified length
class NameInputFormatter extends TextInputFormatter {
  final int maxLength;
  
  NameInputFormatter({this.maxLength = 10});
  
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Allow empty
    if (newValue.text.isEmpty) {
      return newValue;
    }
    
    // Only allow letters and spaces (no special characters or numbers)
    final lettersOnly = newValue.text.replaceAll(RegExp(r'[^a-zA-Z\s]'), '');
    
    // Limit to maxLength characters
    final limited = lettersOnly.length > maxLength 
        ? lettersOnly.substring(0, maxLength) 
        : lettersOnly;
    
    // Calculate cursor position
    int cursorPos = newValue.selection.end;
    // Adjust cursor if text was truncated
    if (cursorPos > limited.length) {
      cursorPos = limited.length;
    }
    
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: cursorPos),
    );
  }
}

/// Screen shown to first-time users after OTP verification.
/// Collects first and last name before proceeding to terms.
class NameEntryScreen extends ConsumerStatefulWidget {
  final String phone;

  const NameEntryScreen({super.key, required this.phone});

  @override
  ConsumerState<NameEntryScreen> createState() => _NameEntryScreenState();
}

class _NameEntryScreenState extends ConsumerState<NameEntryScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _firstNameFocus = FocusNode();
  final _lastNameFocus = FocusNode();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _firstNameFocus.requestFocus();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _firstNameFocus.dispose();
    _lastNameFocus.dispose();
    super.dispose();
  }

  bool get _isValid =>
      _firstNameController.text.trim().isNotEmpty &&
      _lastNameController.text.trim().isNotEmpty;

  String get _fullName =>
      '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}';

  Future<void> _saveName() async {
    if (!_isValid) return;
    setState(() => _isLoading = true);

    try {
      final user = ref.read(currentUserProvider);
      if (user != null) {
        // Update name on the backend (PUT /api/auth/profile)
        final nameParts = _fullName.split(' ');
        await apiClient.updateUser({
          'firstName': nameParts.first,
          'lastName': nameParts.length > 1 ? nameParts.sublist(1).join(' ') : null,
        });

        // Update local auth state with the new name
        final authNotifier = ref.read(authStateProvider.notifier);
        authNotifier.updateUserName(_fullName);
      }

      if (mounted) {
        context.push('${AppRoutes.terms}?phone=${widget.phone}');
      }
    } catch (e) {
      debugPrint('Error saving name: $e');
      // Still proceed even if backend update fails — name can be set later
      if (mounted) {
        context.push('${AppRoutes.terms}?phone=${widget.phone}');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),

              // Title
              const Text(
                "What's your name?",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A1A),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Let us know how to address you',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey[600],
                  height: 1.4,
                ),
              ),

              const SizedBox(height: 40),

              // First Name
              TextField(
                controller: _firstNameController,
                focusNode: _firstNameFocus,
                textCapitalization: TextCapitalization.words,
                enabled: !_isLoading,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                inputFormatters: [
                  NameInputFormatter(maxLength: 10),
                ],
                decoration: InputDecoration(
                  labelText: 'First name',
                  labelStyle: TextStyle(color: Colors.grey[500]),
                  hintText: 'Max 10 letters',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF1A1A1A), width: 2),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _lastNameFocus.requestFocus(),
              ),

              const SizedBox(height: 16),

              // Last Name
              TextField(
                controller: _lastNameController,
                focusNode: _lastNameFocus,
                textCapitalization: TextCapitalization.words,
                enabled: !_isLoading,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                inputFormatters: [
                  NameInputFormatter(maxLength: 10),
                ],
                decoration: InputDecoration(
                  labelText: 'Last name',
                  labelStyle: TextStyle(color: Colors.grey[500]),
                  hintText: 'Max 10 letters',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF1A1A1A), width: 2),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_isValid) _saveName();
                },
              ),

              const Spacer(),

              // Back and Next buttons
              Row(
                children: [
                  // Back button
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: IconButton(
                      onPressed: _isLoading ? null : () => context.pop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                  ),

                  const Spacer(),

                  // Next button
                  GestureDetector(
                    onTap: (_isValid && !_isLoading) ? _saveName : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 16),
                      decoration: BoxDecoration(
                        color: _isValid
                            ? const Color(0xFFD4956A)
                            : const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Row(
                              children: [
                                Text(
                                  'Next',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: _isValid
                                        ? Colors.white
                                        : const Color(0xFFBDBDBD),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward,
                                  size: 20,
                                  color: _isValid
                                      ? Colors.white
                                      : const Color(0xFFBDBDBD),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
