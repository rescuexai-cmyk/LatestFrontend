import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/driver_onboarding_provider.dart';

/// Screen for Aadhaar card number verification with OTP
class AadhaarVerificationScreen extends ConsumerStatefulWidget {
  const AadhaarVerificationScreen({super.key});

  @override
  ConsumerState<AadhaarVerificationScreen> createState() => _AadhaarVerificationScreenState();
}

class _AadhaarVerificationScreenState extends ConsumerState<AadhaarVerificationScreen> {
  final _aadhaarController = TextEditingController();
  bool _isOtpSent = false;
  bool _isLoading = false;
  final List<TextEditingController> _otpControllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());

  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);

  @override
  void dispose() {
    _aadhaarController.dispose();
    for (var controller in _otpControllers) {
      controller.dispose();
    }
    for (var node in _otpFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _sendOtp() async {
    if (_aadhaarController.text.length != 12) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter valid 12-digit Aadhaar number')),
      );
      return;
    }

    setState(() => _isLoading = true);
    
    // Simulate OTP sending
    await Future.delayed(const Duration(seconds: 2));
    
    setState(() {
      _isLoading = false;
      _isOtpSent = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('OTP sent to your registered mobile number')),
    );
  }

  void _verifyOtp() async {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter 6-digit OTP')),
      );
      return;
    }

    setState(() => _isLoading = true);

    // Simulate OTP verification
    await Future.delayed(const Duration(seconds: 2));

    // Update provider
    await ref.read(driverOnboardingProvider.notifier).uploadDocument(
      'aadhaar',
      'aadhaar_verified',
      documentNumber: _aadhaarController.text,
    );

    setState(() => _isLoading = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aadhaar verified successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _beige,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _isOtpSent ? _buildOtpForm() : _buildAadhaarForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _inputBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded, color: _textPrimary, size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.asset('assets/images/raahi_logo.png', height: 28),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text('Support', style: TextStyle(fontSize: 12, color: _textSecondary)),
                    Icon(Icons.keyboard_arrow_down, size: 16, color: _textSecondary),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAadhaarForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Aadhaar Card icon
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.credit_card, color: _accent, size: 24),
        ),
        const SizedBox(height: 8),
        const Text(
          'Aadhaar Card',
          style: TextStyle(fontSize: 14, color: _textSecondary),
        ),
        const SizedBox(height: 24),

        const Text(
          "We couldn't verify your\nAadhaar Number",
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: _textPrimary,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the correct number number so we can verify your\nprofile and link to other profiles.',
          style: TextStyle(fontSize: 13, color: _textSecondary, height: 1.5),
        ),
        const SizedBox(height: 32),

        // Aadhaar number input
        const Text('Aadhar number', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        TextField(
          controller: _aadhaarController,
          keyboardType: TextInputType.number,
          maxLength: 12,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(
            hintText: '0210-2345-6657-2003',
            counterText: '',
            filled: true,
            fillColor: _inputBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _border),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Upload document option
        GestureDetector(
          onTap: () {
            // Navigate to document upload
          },
          child: Text(
            'Upload Document Instead',
            style: TextStyle(
              fontSize: 14,
              color: _accent,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.underline,
            ),
          ),
        ),

        const SizedBox(height: 40),

        // Send OTP button
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _sendOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: _textPrimary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[400],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Text('Send OTP', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  Widget _buildOtpForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Enter the six-digit code sent\nto your phone',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: _textPrimary,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 32),

        // 6-digit OTP input
        const Text('6-digit code', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (index) {
            return SizedBox(
              width: 50,
              height: 56,
              child: TextField(
                controller: _otpControllers[index],
                focusNode: _otpFocusNodes[index],
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                maxLength: 1,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: _inputBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _accent, width: 2),
                  ),
                ),
                onChanged: (value) {
                  if (value.isNotEmpty && index < 5) {
                    _otpFocusNodes[index + 1].requestFocus();
                  }
                  if (value.isEmpty && index > 0) {
                    _otpFocusNodes[index - 1].requestFocus();
                  }
                },
              ),
            );
          }),
        ),
        const SizedBox(height: 16),

        // Resend SMS link
        GestureDetector(
          onTap: _sendOtp,
          child: Text(
            'Resend SMS',
            style: TextStyle(
              fontSize: 14,
              color: _accent,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Upload Document Instead',
          style: TextStyle(
            fontSize: 14,
            color: _accent,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
          ),
        ),

        const SizedBox(height: 40),

        // Verify button
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _verifyOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: _textPrimary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[400],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Text('Upload Document', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}
