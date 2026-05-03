import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../providers/auth_provider.dart';

class OTPVerificationScreen extends ConsumerStatefulWidget {
  final String phone;
  final bool isNewUser;
  final bool isPhoneLinkMode;

  OTPVerificationScreen({
    super.key,
    required this.phone,
    this.isNewUser = false,
    this.isPhoneLinkMode = false,
  }) {
    debugPrint(
        '📱 OTPVerificationScreen created: phone=$phone, isNewUser=$isNewUser, isPhoneLinkMode=$isPhoneLinkMode');
  }

  @override
  ConsumerState<OTPVerificationScreen> createState() => _OTPVerificationScreenState();
}

class _OTPVerificationScreenState extends ConsumerState<OTPVerificationScreen> {
  final List<TextEditingController> _controllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  int _resendTimer = 30;
  Timer? _timer;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    debugPrint('📱 OTPVerificationScreen initState called');
    _startResendTimer();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    _timer?.cancel();
    super.dispose();
  }

  void _startResendTimer() {
    _resendTimer = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendTimer > 0) {
        if (mounted) setState(() => _resendTimer--);
      } else {
        timer.cancel();
      }
    });
  }

  String get _otp => _controllers.map((c) => c.text).join();

  /// Returns the 10-digit phone number without country code
  String get _cleanPhone {
    String phone = widget.phone;
    // Remove +91 prefix if present
    if (phone.startsWith('+91')) {
      phone = phone.substring(3);
    }
    // Remove 91 prefix if present and length > 10
    else if (phone.startsWith('91') && phone.length > 10) {
      phone = phone.substring(2);
    }
    // Remove any non-digits
    phone = phone.replaceAll(RegExp(r'[^\d]'), '');
    // Take only last 10 digits if somehow longer
    if (phone.length > 10) {
      phone = phone.substring(phone.length - 10);
    }
    return phone;
  }

  /// Returns formatted phone number for display (XXXXX XXXXX)
  String get _formattedPhone {
    final phone = _cleanPhone;
    if (phone.length == 10) {
      return '${phone.substring(0, 5)} ${phone.substring(5)}';
    }
    return phone;
  }

  Future<void> _verifyOTP() async {
    if (_otp.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('enter_complete_otp'))),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      // Use clean 10-digit phone number for API call
      final phoneForApi = _cleanPhone;
      final result = widget.isPhoneLinkMode
          ? await authNotifier.verifyOtpForPhoneLink(_otp)
          : await authNotifier.verifyOTP(
              phoneForApi,
              _otp,
              isNewUser: widget.isNewUser,
            );

      if (mounted) {
        setState(() => _isLoading = false);

        if (result.success) {
          // OTP verified successfully
          if (widget.isPhoneLinkMode) {
            if (result.isNewUser) {
              context.go('${AppRoutes.nameEntry}?phone=$phoneForApi');
            } else {
              context.go(AppRoutes.home);
            }
          } else if (result.isNewUser) {
            // New user → collect name first, then terms
            context.push('${AppRoutes.nameEntry}?phone=$phoneForApi');
          } else {
            context.go(AppRoutes.home);
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.error ?? 'Invalid OTP')),
          );
          _clearOTP();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _clearOTP() {
    for (final controller in _controllers) {
      controller.clear();
    }
    _focusNodes[0].requestFocus();
  }

  void _onOTPChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isNotEmpty && index == 5) {
      _focusNodes[index].unfocus();
      // Auto-verify when OTP is complete
      _verifyOTP();
    }
  }

  void _showResendOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Resend by SMS button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _resendOTP();
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFE0E0E0)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: const Text(
                  'Resend code by SMS',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Cancel button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _resendOTP() async {
    final authNotifier = ref.read(authStateProvider.notifier);
    // Use clean 10-digit phone number for API call
    final result = widget.isPhoneLinkMode
        ? await authNotifier.requestOTP(_cleanPhone)
        : await authNotifier.resendOTP(_cleanPhone);
    
    if (mounted) {
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ref.tr('otp_sent')),
            backgroundColor: Colors.green,
          ),
        );
        _startResendTimer();
        _clearOTP();
      } else {
        final error = result.error ?? '';
        // Handle rate limiting (429)
        if (error.contains('429') || error.toLowerCase().contains('too many') || error.toLowerCase().contains('rate limit')) {
          // Extend cooldown on rate limit
          _resendTimer = 60; // Force 60 second wait
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.tr('too_many_requests_60')),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'Failed to resend OTP'),
              backgroundColor: Colors.red,
            ),
          );
        }
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
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF1A1A1A),
                    height: 1.3,
                  ),
                  children: [
                    const TextSpan(text: 'Enter the 6-digit code sent to you at\n'),
                    TextSpan(
                      text: '+91 $_formattedPhone',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              
              
              const SizedBox(height: 32),
              
              // OTP Input boxes (6 digits)
              // Note: Do NOT use the same FocusNode for both a parent listener and TextField -
              // that causes "Tried to make a child into a parent of itself" (focus tree conflict).
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (index) {
                  return SizedBox(
                    width: 48,
                    height: 56,
                    child: TextField(
                      controller: _controllers[index],
                      focusNode: _focusNodes[index],
                      textAlign: TextAlign.center,
                      textAlignVertical: TextAlignVertical.center,
                      keyboardType: TextInputType.number,
                      maxLength: 1,
                      enabled: !_isLoading,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        filled: true,
                        fillColor: const Color(0xFFF5F5F5),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF1A1A1A), width: 2),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (value) => _onOTPChanged(value, index),
                    ),
                  );
                }),
              ),
              
              const SizedBox(height: 24),
              
              // Haven't received code button
              GestureDetector(
                onTap: _resendTimer > 0 || _isLoading ? null : _showResendOptions,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(
                    _resendTimer > 0
                        ? "I haven't received a code  (0:${_resendTimer.toString().padLeft(2, '0')})"
                        : "I haven't received a code",
                    style: TextStyle(
                      fontSize: 14,
                      color: _resendTimer > 0 ? const Color(0xFFBDBDBD) : const Color(0xFF1A1A1A),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
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
                    onTap: (_otp.length == 6 && !_isLoading) ? _verifyOTP : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: _isLoading ? const Color(0xFFE0E0E0) : Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: _otp.length == 6 ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
                        ),
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
                          : Row(
                              children: [
                                Text(
                                  'Next',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: _otp.length == 6 ? const Color(0xFF1A1A1A) : const Color(0xFFBDBDBD),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward,
                                  size: 20,
                                  color: _otp.length == 6 ? const Color(0xFF1A1A1A) : const Color(0xFFBDBDBD),
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
