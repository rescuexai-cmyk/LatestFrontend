import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/primary_cta_styles.dart';
import 'otp_input_field.dart';

/// Modal sheet: send + enter 6-digit email OTP.
/// Returns `true` if verified, `false` if dismissed without verifying.
class EmailVerificationSheet extends ConsumerStatefulWidget {
  const EmailVerificationSheet({
    super.key,
    this.initialEmail,
    this.allowDismiss = true,
    this.title = 'Verify your email',
    this.subtitle =
        'We will send a 6-digit code to your email. You need this before going online.',
  });

  final String? initialEmail;
  final bool allowDismiss;
  final String title;
  final String subtitle;

  static Future<bool?> show(
    BuildContext context, {
    String? initialEmail,
    bool allowDismiss = true,
    String? title,
    String? subtitle,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: allowDismiss,
      enableDrag: allowDismiss,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EmailVerificationSheet(
        initialEmail: initialEmail,
        allowDismiss: allowDismiss,
        title: title ?? 'Verify your email',
        subtitle: subtitle ??
            'We will send a 6-digit code to your email. You need this before going online.',
      ),
    );
  }

  @override
  ConsumerState<EmailVerificationSheet> createState() =>
      _EmailVerificationSheetState();
}

class _EmailVerificationSheetState
    extends ConsumerState<EmailVerificationSheet> {
  late final TextEditingController _emailController;
  final TextEditingController _otpController = TextEditingController();
  bool _sending = false;
  bool _verifying = false;
  bool _codeSent = false;
  String? _error;
  String? _info;
  String? _devOtp;
  String? _smtpMessage;

  @override
  void initState() {
    super.initState();
    _emailController =
        TextEditingController(text: widget.initialEmail?.trim() ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.getEmailVerificationStatus();
      final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? {};
      final email = (data['email'] as String?)?.trim();
      final verified = data['emailVerified'] == true;
      final smtp = (data['smtp'] as Map?)?.cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        if (email != null &&
            email.isNotEmpty &&
            _emailController.text.trim().isEmpty) {
          _emailController.text = email;
        }
        _smtpMessage = smtp?['message']?.toString();
      });
      if (verified) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      // Non-fatal — user can still try send.
    }
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
      _devOtp = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.sendEmailVerification(email: email);
      final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? {};
      if (!mounted) return;
      setState(() {
        _sending = false;
        _codeSent = true;
        _info = (data['message'] ?? res['message'] ?? 'Code sent').toString();
        _devOtp = data['devOtp']?.toString();
        final smtp = (data['smtp'] as Map?)?.cast<String, dynamic>();
        _smtpMessage = smtp?['message']?.toString() ?? _smtpMessage;
        if (_devOtp != null && _devOtp!.isNotEmpty) {
          _otpController.text = _devOtp!;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _verifyCode() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _error = 'Enter the 6-digit code');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.verifyEmailOtp(otp);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['message'] != null) {
        return data['message'].toString();
      }
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            widget.title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.subtitle,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
          if (_smtpMessage != null && _smtpMessage!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _smtpMessage!,
              style: TextStyle(
                fontSize: 12,
                color: _smtpMessage!.toLowerCase().contains('ready')
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFFEF6C00),
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            enabled: !_sending && !_verifying,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_codeSent) ...[
            OtpInputField(
              controller: _otpController,
              enabled: !_verifying,
              onCompleted: (_) => _verifyCode(),
            ),
            if (_devOtp != null) ...[
              const SizedBox(height: 8),
              Text(
                'Dev OTP: $_devOtp',
                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ],
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _info!,
                style: const TextStyle(color: Color(0xFF2E7D32), fontSize: 13),
              ),
            ),
          FilledButton(
            style: PrimaryCtaStyles.filled(),
            onPressed: (_sending || _verifying)
                ? null
                : (_codeSent ? _verifyCode : _sendCode),
            child: (_sending || _verifying)
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_codeSent ? 'Verify' : 'Send code'),
          ),
          if (_codeSent)
            TextButton(
              onPressed: (_sending || _verifying) ? null : _sendCode,
              child: const Text('Resend code'),
            ),
          if (widget.allowDismiss)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Later'),
            ),
        ],
      ),
    );
  }
}
