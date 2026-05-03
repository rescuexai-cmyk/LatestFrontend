import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/firebase_phone_auth_service.dart';
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
  final bool isPhoneLinkMode;

  const SignUpScreen({
    super.key,
    this.isPhoneLinkMode = false,
  });

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen>
    with WidgetsBindingObserver {
  final _phoneController = TextEditingController();
  bool _isLoading = false;
  bool _isVerifying = false;
  bool _hasNavigatedToOtp = false;
  int _cooldownSeconds = 0;
  Timer? _cooldownTimer;
  int _retryCount = 0;
  static const int _maxRetries = 3;
  static const int _baseCooldown = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndNavigateIfSessionExists();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phoneController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    super.didChangeAppLifecycleState(lifecycleState);
    if (lifecycleState == AppLifecycleState.resumed) {
      debugPrint('📱 SignUpScreen: App resumed from background');
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted && !_hasNavigatedToOtp) {
          _checkAndNavigateIfSessionExists();
        }
      });
    }
  }

  void _checkAndNavigateIfSessionExists() {
    if (_hasNavigatedToOtp || !mounted) return;
    final service = firebasePhoneAuth;
    if (service.hasValidSession && service.pendingPhoneNumber != null) {
      final phone = service.pendingPhoneNumber!
          .replaceAll('+91', '')
          .replaceAll(RegExp(r'[^\d]'), '');
      debugPrint('📱 SignUpScreen: Found valid OTP session for $phone, auto-navigating');
      _navigateToOtp(phone);
    }
  }

  void _navigateToOtp(String phone) {
    if (_hasNavigatedToOtp || !mounted) return;
    _hasNavigatedToOtp = true;
    final modeQuery = widget.isPhoneLinkMode ? '&mode=linkPhone' : '';
    final otpPath =
        '${AppRoutes.otpVerification}?phone=$phone&isNewUser=true$modeQuery';
    debugPrint('📱 SignUpScreen: Navigating to OTP screen → $otpPath');
    if (widget.isPhoneLinkMode) {
      context.go(otpPath);
    } else {
      context.push(otpPath);
    }
  }

  void _startCooldown(int seconds) {
    _cooldownSeconds = seconds;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cooldownSeconds > 0) {
        if (mounted) setState(() => _cooldownSeconds--);
      } else {
        timer.cancel();
      }
    });
  }

  int _getCooldownDuration() {
    return _baseCooldown * (1 << _retryCount.clamp(0, 3));
  }

  Future<void> _handleContinue() async {
    if (_isVerifying) {
      debugPrint('📱 SignUpScreen: _handleContinue blocked — already verifying');
      return;
    }

    if (_cooldownSeconds > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please wait $_cooldownSeconds seconds before requesting OTP again'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    String phone = _phoneController.text.trim();
    phone = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (phone.startsWith('+91')) {
      phone = phone.substring(3);
    } else if (phone.startsWith('91') && phone.length > 10) {
      phone = phone.substring(2);
    }

    if (phone.isEmpty || phone.length != 10 || !RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid 10-digit mobile number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    _isVerifying = true;
    setState(() => _isLoading = true);
    await Future.delayed(Duration.zero);

    try {
      debugPrint('📱 SignUpScreen: Requesting OTP for $phone (attempt ${_retryCount + 1})');

      final authNotifier = ref.read(authStateProvider.notifier);
      final result = await authNotifier.requestOTP(phone);

      debugPrint('📱 SignUpScreen: OTP result success=${result.success}, error=${result.error}');

      if (!mounted) {
        debugPrint('📱 SignUpScreen: Widget no longer mounted after requestOTP');
        _isVerifying = false;
        return;
      }

      setState(() => _isLoading = false);

      if (result.success) {
        _retryCount = 0;
        _navigateToOtp(phone);
      } else {
        if (firebasePhoneAuth.hasValidSession) {
          debugPrint('📱 SignUpScreen: Request returned failure but session exists — navigating anyway');
          _navigateToOtp(phone);
          return;
        }

        if (authNotifier.hasActiveOtpSession()) {
          debugPrint('📱 SignUpScreen: Active OTP session found — navigating');
          _navigateToOtp(phone);
          return;
        }

        final error = result.error ?? '';
        if (error.contains('429') || error.toLowerCase().contains('too many') || error.toLowerCase().contains('rate limit')) {
          _retryCount++;
          final cooldown = _getCooldownDuration();
          _startCooldown(cooldown);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Too many requests. Please wait $cooldown seconds and try again.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'Failed to send OTP. Please try again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('📱 SignUpScreen: OTP request exception: $e');

      if (mounted) {
        setState(() => _isLoading = false);

        if (firebasePhoneAuth.hasValidSession) {
          debugPrint('📱 SignUpScreen: Exception but session exists — navigating');
          _navigateToOtp(phone);
          return;
        }

        final errorStr = e.toString();
        if (errorStr.contains('429') || errorStr.toLowerCase().contains('too many')) {
          _retryCount++;
          final cooldown = _getCooldownDuration();
          _startCooldown(cooldown);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Too many requests. Please wait $cooldown seconds and try again.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Network error: ${errorStr.split(':').last.trim()}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      _isVerifying = false;
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
              Text(
                widget.isPhoneLinkMode
                    ? 'Add your mobile number'
                    : "What's your number?",
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
                    onTap: (_isLoading || _cooldownSeconds > 0) ? null : _handleContinue,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: (_isLoading || _cooldownSeconds > 0) ? const Color(0xFFE0E0E0) : Colors.white,
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
                          : _cooldownSeconds > 0
                              ? Text(
                                  'Wait ${_cooldownSeconds}s',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF9E9E9E),
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
