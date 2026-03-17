import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../providers/auth_provider.dart';

/// Input formatter for Indian phone numbers.
/// - Only allows digits
/// - First digit must be 6, 7, 8, or 9 (valid Indian mobile numbers)
/// - Maximum 10 digits
class IndianPhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Allow empty
    if (newValue.text.isEmpty) {
      return newValue;
    }
    
    // Only allow digits
    final digitsOnly = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    
    // If empty after filtering, allow
    if (digitsOnly.isEmpty) {
      return const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    }
    
    // First digit must be 6, 7, 8, or 9 for Indian mobile numbers
    if (!RegExp(r'^[6-9]').hasMatch(digitsOnly)) {
      return oldValue;
    }
    
    // Limit to 10 digits
    final limited = digitsOnly.length > 10 ? digitsOnly.substring(0, 10) : digitsOnly;
    
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: limited.length),
    );
  }
}

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _phoneController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleContinue() async {
    String phone = _phoneController.text.trim();
    
    // Remove any spaces, dashes, or parentheses
    phone = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    
    // Strip country code if user included it
    if (phone.startsWith('+91')) {
      phone = phone.substring(3);
    } else if (phone.startsWith('91') && phone.length > 10) {
      phone = phone.substring(2);
    }
    
    // Validate: must be exactly 10 digits starting with 6-9
    if (phone.isEmpty || phone.length != 10 || !RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid 10-digit mobile number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    
    // Yield to UI thread to show loading indicator immediately
    await Future.delayed(Duration.zero);

    try {
      debugPrint('📱 Attempting to request OTP for phone: $phone');

      // Get the notifier - wrap in microtask to avoid blocking
      final authNotifier = ref.read(authStateProvider.notifier);
      
      // Add timeout to prevent indefinite blocking
      final result = await authNotifier.requestOTP(phone).timeout(
        const Duration(seconds: 10),
        onTimeout: () => OTPResult(success: false, error: 'Request timed out. Please try again.'),
      );

      debugPrint('📱 OTP request result: success=${result.success}, error=${result.error}');

      if (mounted) {
        setState(() => _isLoading = false);

        if (result.success) {
          debugPrint('✅ OTP requested successfully, navigating to OTP screen');
          // Navigate to OTP screen with phone number (without +91 prefix - will be added in display)
          context.push(
            '${AppRoutes.otpVerification}?phone=$phone&isNewUser=true',
          );
        } else {
          debugPrint('❌ OTP request failed: ${result.error}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'Failed to send OTP. Please try again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ OTP request exception: $e');

      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Network error: ${e.toString().split(':').last.trim()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
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
                "What's your number?",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              
              const SizedBox(height: 40),
              
              // Phone input
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    // Country code
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                      decoration: const BoxDecoration(
                        border: Border(
                          right: BorderSide(color: Color(0xFFE0E0E0)),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Text('🇮🇳', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 8),
                          const Text(
                            '+91',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Phone number input
                    Expanded(
                      child: TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        enabled: !_isLoading,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 1,
                        ),
                        inputFormatters: [
                          IndianPhoneInputFormatter(),
                        ],
                        decoration: const InputDecoration(
                          hintText: '98765 43210',
                          hintStyle: TextStyle(
                            color: Color(0xFFBDBDBD),
                            letterSpacing: 1,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                        ),
                      ),
                    ),
                  ],
                ),
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
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  
                  const Spacer(),
                  
                  // Next button
                  GestureDetector(
                    onTap: _isLoading ? null : _handleContinue,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: _isLoading ? const Color(0xFFE0E0E0) : Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1A1A1A)),
                              ),
                            )
                          : const Row(
                              children: [
                                Text(
                                  'Next',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF1A1A1A),
                                  ),
                                ),
                                SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward,
                                  size: 20,
                                  color: Color(0xFF1A1A1A),
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
