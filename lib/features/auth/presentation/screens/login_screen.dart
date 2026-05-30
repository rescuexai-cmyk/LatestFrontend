import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:truecaller_sdk/truecaller_sdk.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/firebase_phone_auth_service.dart';
import '../../providers/auth_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import 'signup_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const Color _brandGold = Color(0xFFCF923D);
  /// Warm cream panel (matches reference ~#FFFBF5 / #FEF9F3)
  static const Color _cardCreamBg = Color(0xFFFFF9F5);
  static const String _termsUrl = 'https://www.raahionrescue.com/terms';
  static const String _privacyUrl = 'https://www.raahionrescue.com/privacy';

  bool _isSocialLoading = false;
  bool _isOtpLoading = false;
  bool _isVerifyLoading = false;
  bool _otpStepVisible = false;
  String? _pendingPhone;
  final TextEditingController _phoneController = TextEditingController();
  final List<TextEditingController> _otpControllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());
  int _resendTimer = 0;
  Timer? _resendCountdownTimer;
  bool _termsAccepted = false;

  void _onPhoneTextChanged() {
    if (mounted) setState(() {});
  }

  bool get _isPhoneValid {
    final phone = _normalizeIndianPhone(_phoneController.text);
    return RegExp(r'^[6-9]\d{9}$').hasMatch(phone);
  }

  bool get _canPressGetOtp =>
      _termsAccepted &&
      _isPhoneValid &&
      !_otpStepVisible &&
      !_isSocialLoading &&
      !_isOtpLoading &&
      !_isVerifyLoading;

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_onPhoneTextChanged);
  }

  @override
  void dispose() {
    _phoneController.removeListener(_onPhoneTextChanged);
    _resendCountdownTimer?.cancel();
    _phoneController.dispose();
    for (final c in _otpControllers) {
      c.dispose();
    }
    for (final n in _otpFocusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  String _normalizeIndianPhone(String raw) {
    var phone = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    if (phone.startsWith('+91')) {
      phone = phone.substring(3);
    } else if (phone.startsWith('91') && phone.length > 10) {
      phone = phone.substring(2);
    }
    return phone;
  }

  String _formatDisplayPhone(String phone) {
    if (phone.length == 10) {
      return '${phone.substring(0, 5)} ${phone.substring(5)}';
    }
    return phone;
  }

  void _startInlineResendTimer([int seconds = 30]) {
    _resendTimer = seconds;
    _resendCountdownTimer?.cancel();
    _resendCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendTimer > 0) {
        setState(() => _resendTimer--);
      } else {
        timer.cancel();
      }
    });
    if (mounted) setState(() {});
  }

  void _collapseOtpStep() {
    _resendCountdownTimer?.cancel();
    setState(() {
      _otpStepVisible = false;
      _pendingPhone = null;
      _resendTimer = 0;
      _isVerifyLoading = false;
    });
    for (final c in _otpControllers) {
      c.clear();
    }
  }

  String get _inlineOtpDigits => _otpControllers.map((c) => c.text).join();

  void _clearInlineOtp() {
    for (final c in _otpControllers) {
      c.clear();
    }
    if (mounted) _otpFocusNodes[0].requestFocus();
  }

  void _onInlineOtpChanged(String value, int index) {
    if (_isVerifyLoading) return;
    if (value.isNotEmpty && index < 5) {
      _otpFocusNodes[index + 1].requestFocus();
    } else if (value.isNotEmpty && index == 5) {
      _otpFocusNodes[index].unfocus();
      _verifyInlineOtp();
    }
  }

  void _beginOtpStep(String phone) {
    setState(() {
      _otpStepVisible = true;
      _pendingPhone = phone;
    });
    _clearInlineOtp();
    _startInlineResendTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _otpFocusNodes[0].requestFocus();
    });
  }

  Future<void> _verifyInlineOtp() async {
    if (_inlineOtpDigits.length != 6) {
      AppMessenger.showErrorBanner(context, ref.tr('enter_complete_otp'));
      return;
    }
    final phone = _pendingPhone;
    if (phone == null) return;

    setState(() => _isVerifyLoading = true);

    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      final result = await authNotifier.verifyOTP(
        phone,
        _inlineOtpDigits,
        isNewUser: true,
      );

      if (!mounted) return;
      setState(() => _isVerifyLoading = false);

      if (result.success) {
        if (result.isNewUser) {
          context.push('${AppRoutes.nameEntry}?phone=$phone');
        } else {
          context.go(AppRoutes.home);
        }
      } else {
        AppMessenger.showErrorBanner(context, result.error ?? 'Invalid OTP');
        _clearInlineOtp();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVerifyLoading = false);
        AppMessenger.showErrorBanner(context, 'Error: $e');
      }
    }
  }

  void _showInlineResendOptions() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _resendInlineOtp();
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

  Future<void> _resendInlineOtp() async {
    final phone = _pendingPhone;
    if (phone == null) return;

    final authNotifier = ref.read(authStateProvider.notifier);
    final result = await authNotifier.resendOTP(phone);

    if (!mounted) return;
    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('otp_sent')),
          backgroundColor: Colors.green,
        ),
      );
      _startInlineResendTimer();
      _clearInlineOtp();
    } else {
      final error = result.error ?? '';
      if (error.contains('429') ||
          error.toLowerCase().contains('too many') ||
          error.toLowerCase().contains('rate limit')) {
        _startInlineResendTimer(60);
        AppMessenger.showErrorBanner(context, ref.tr('too_many_requests_60'));
      } else {
        AppMessenger.showErrorBanner(
            context, result.error ?? 'Failed to resend OTP');
      }
    }
  }

  Future<void> _openLegalUri(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await canLaunchUrl(uri);
      if (ok) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else if (mounted) {
        AppMessenger.showErrorBanner(context, 'Could not open link');
      }
    } catch (e) {
      if (mounted) {
        AppMessenger.showErrorBanner(context, 'Could not open link');
      }
    }
  }

  Future<void> _handleGetOtp() async {
    if (_isOtpLoading || _isSocialLoading || _otpStepVisible) return;
    if (!_termsAccepted) {
      AppMessenger.showErrorBanner(
        context,
        'Please agree to the Terms of Use and Privacy Policy',
      );
      return;
    }

    final phone = _normalizeIndianPhone(_phoneController.text);
    if (phone.isEmpty ||
        phone.length != 10 ||
        !RegExp(r'^[6-9]\d{9}$').hasMatch(phone)) {
      AppMessenger.showErrorBanner(
          context, 'Please enter a valid 10-digit mobile number');
      return;
    }

    _isOtpLoading = true;
    setState(() {});

    try {
      debugPrint('📱 LoginScreen: Requesting OTP for $phone');
      final authNotifier = ref.read(authStateProvider.notifier);
      final result = await authNotifier.requestOTP(phone);

      if (!mounted) return;

      if (result.success) {
        debugPrint('📱 LoginScreen: OTP sent — showing inline OTP entry');
        _beginOtpStep(phone);
      } else {
        if (firebasePhoneAuth.hasValidSession) {
          debugPrint(
              '📱 LoginScreen: session exists after failure — inline OTP');
          _beginOtpStep(phone);
          return;
        }
        if (authNotifier.hasActiveOtpSession()) {
          _beginOtpStep(phone);
          return;
        }
        AppMessenger.showErrorBanner(
            context, result.error ?? 'Failed to send OTP. Please try again.');
      }
    } catch (e) {
      if (mounted) {
        if (firebasePhoneAuth.hasValidSession) {
          _beginOtpStep(phone);
        } else {
          AppMessenger.showErrorBanner(
              context, 'Something went wrong: ${e.toString()}');
        }
      }
    } finally {
      _isOtpLoading = false;
      if (mounted) setState(() {});
    }
  }

  // ignore: unused_element
  Future<void> _handleTruecallerLogin() async {
    if (_isSocialLoading) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      AppMessenger.showErrorBanner(context, 'Truecaller login is available on Android only.');
      return;
    }
    final phone = await _askPhoneNumber(
      title: 'Login with Truecaller',
      hint: 'Enter 10-digit mobile number',
    );
    if (!mounted || phone == null) return;

    setState(() => _isSocialLoading = true);
    final tcPayload = await _runTruecallerFlow(phone);
    if (!mounted) return;
    if (!tcPayload.success) {
      setState(() => _isSocialLoading = false);
      AppMessenger.showErrorBanner(context, tcPayload.error ?? 'Truecaller verification failed');
      return;
    }

    final result = await ref.read(authStateProvider.notifier).signInWithTruecaller(
          phone: tcPayload.phone,
          profile: tcPayload.profile,
          accessToken: tcPayload.accessToken,
          truecallerToken: tcPayload.truecallerToken,
        );
    if (!mounted) return;
    setState(() => _isSocialLoading = false);

    if (!result.success) {
      AppMessenger.showErrorBanner(context, result.error ?? 'Truecaller login failed');
      return;
    }

    if (result.requiresPhone) {
      context.go('${AppRoutes.phoneNumber}?mode=linkPhone');
      return;
    }

    if (result.isNewUser) {
      final phoneValue = ref.read(currentUserProvider)?.phone ?? '';
      context.go('${AppRoutes.nameEntry}?phone=$phoneValue');
    } else {
      context.go(AppRoutes.home);
    }
  }

  Future<_TruecallerPayloadResult> _runTruecallerFlow(String phone) async {
    StreamSubscription<TcSdkCallback>? subscription;
    Completer<_TruecallerPayloadResult>? completer;

    void completeOnce(_TruecallerPayloadResult value) {
      final c = completer;
      if (c != null && !c.isCompleted) {
        c.complete(value);
      }
    }

    try {
      await TcSdk.initializeSDK(
        sdkOption: TcSdkOptions.OPTION_VERIFY_ALL_USERS,
      );

      completer = Completer<_TruecallerPayloadResult>();
      final state = DateTime.now().millisecondsSinceEpoch.toString();

      subscription = TcSdk.streamCallbackData.listen((callback) async {
        switch (callback.result) {
          case TcSdkCallbackResult.verifiedBefore:
            final profile = callback.profile;
            if (profile != null) {
              completeOnce(_TruecallerPayloadResult(
                success: true,
                phone: profile.phoneNumber,
                accessToken: profile.accessToken,
                profile: {
                  'firstName': profile.firstName,
                  'lastName': profile.lastName,
                  'phoneNumber': profile.phoneNumber,
                  'email': profile.email,
                  'avatarUrl': profile.avatarUrl,
                },
              ));
            } else {
              completeOnce(const _TruecallerPayloadResult(
                success: false,
                error: 'Truecaller profile not available',
              ));
            }
            break;
          case TcSdkCallbackResult.verificationComplete:
            completeOnce(_TruecallerPayloadResult(
              success: true,
              phone: phone,
              accessToken: callback.accessToken,
            ));
            break;
          case TcSdkCallbackResult.otpReceived:
          case TcSdkCallbackResult.imOtpReceived:
            final otp = callback.otp;
            if (otp != null && otp.isNotEmpty) {
              await TcSdk.verifyOtp(
                firstName: 'Raahi',
                lastName: 'User',
                otp: otp,
              );
            }
            break;
          case TcSdkCallbackResult.otpInitiated:
          case TcSdkCallbackResult.imOtpInitiated:
            final otp = await _askOtpCode();
            if (otp == null) {
              completeOnce(const _TruecallerPayloadResult(
                success: false,
                error: 'OTP verification cancelled',
              ));
              break;
            }
            await TcSdk.verifyOtp(
              firstName: 'Raahi',
              lastName: 'User',
              otp: otp,
            );
            break;
          case TcSdkCallbackResult.missedCallReceived:
            await TcSdk.verifyMissedCall(
              firstName: 'Raahi',
              lastName: 'User',
            );
            break;
          case TcSdkCallbackResult.verification:
            await TcSdk.requestVerification(phoneNumber: phone);
            break;
          case TcSdkCallbackResult.success:
            final authCode = callback.tcOAuthData?.authorizationCode;
            if (authCode == null || authCode.isEmpty) {
              completeOnce(const _TruecallerPayloadResult(
                success: false,
                error: 'Truecaller authorization code missing',
              ));
              break;
            }
            completeOnce(_TruecallerPayloadResult(
              success: true,
              phone: phone,
              truecallerToken: authCode,
            ));
            break;
          case TcSdkCallbackResult.failure:
            completeOnce(_TruecallerPayloadResult(
              success: false,
              error: callback.error?.message ?? 'Truecaller verification failed',
            ));
            break;
          case TcSdkCallbackResult.exception:
            completeOnce(_TruecallerPayloadResult(
              success: false,
              error: callback.exception?.message ??
                  'Truecaller verification exception',
            ));
            break;
          case TcSdkCallbackResult.missedCallInitiated:
            // Waiting for call verification callback.
            break;
        }
      });

      final isUsable = (await TcSdk.isOAuthFlowUsable) == true;
      if (isUsable) {
        await TcSdk.setOAuthState(state);
        await TcSdk.setOAuthScopes(['profile', 'phone', 'openid']);
        final verifier = await TcSdk.generateRandomCodeVerifier as String?;
        if (verifier != null && verifier.isNotEmpty) {
          final challenge = await TcSdk.generateCodeChallenge(verifier) as String?;
          if (challenge != null && challenge.isNotEmpty) {
            await TcSdk.setCodeChallenge(challenge);
          }
        }
        await TcSdk.getAuthorizationCode;
      } else {
        await TcSdk.requestVerification(phoneNumber: phone);
      }

      return await completer.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => const _TruecallerPayloadResult(
          success: false,
          error: 'Truecaller verification timed out. Please try again.',
        ),
      );
    } catch (e) {
      return _TruecallerPayloadResult(success: false, error: e.toString());
    } finally {
      await subscription?.cancel();
    }
  }

  Future<String?> _askOtpCode() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter Truecaller OTP'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              hintText: '6-digit OTP',
              counterText: '',
            ),
            validator: (value) {
              final digits = (value ?? '').replaceAll(RegExp(r'[^\d]'), '');
              if (digits.length != 6) return 'Enter a valid 6-digit OTP';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              final digits = controller.text.replaceAll(RegExp(r'[^\d]'), '');
              Navigator.of(context).pop(digits);
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _handleGoogleLogin() async {
    if (_isSocialLoading || _isVerifyLoading) return;
    setState(() => _isSocialLoading = true);
    final result = await ref.read(authStateProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _isSocialLoading = false);

    if (!result.success) {
      final raw = result.error ?? 'Google login failed';
      final message = raw.contains('GOOGLE_SERVER_CLIENT_ID')
          ? 'Google login not configured. Please set GOOGLE_SERVER_CLIENT_ID (Web client ID) in build settings.'
          : raw;
      AppMessenger.showErrorBanner(context, message);
      return;
    }

    if (result.requiresPhone) {
      context.go('${AppRoutes.phoneNumber}?mode=linkPhone');
      return;
    }

    if (result.isNewUser) {
      final phoneValue = ref.read(currentUserProvider)?.phone ?? '';
      context.go('${AppRoutes.nameEntry}?phone=$phoneValue');
    } else {
      context.go(AppRoutes.home);
    }
  }

  Future<String?> _askPhoneNumber({
    required String title,
    required String hint,
  }) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              validator: (value) {
                final normalized = (value ?? '').replaceAll(RegExp(r'[^\d]'), '');
                if (!RegExp(r'^[6-9]\d{9}$').hasMatch(normalized)) {
                  return 'Enter a valid 10-digit mobile number';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                final normalized =
                    controller.text.replaceAll(RegExp(r'[^\d]'), '');
                Navigator.of(context).pop(normalized);
              },
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboardInset = mq.viewInsets.bottom;
    final showApple = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final blocked = _isSocialLoading || _isOtpLoading || _isVerifyLoading;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/images/home_traffic_hero.png',
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.12),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.35),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 24, right: 24, top: 8),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: math.max(28, mq.size.height * 0.085),
                        ),
                        child: Image.asset(
                          'assets/images/raahi_logo_tagline.png',
                          width: 200,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.56,
            minChildSize: 0.38,
            maxChildSize: 0.80,
            snap: true,
            snapSizes: const [0.38, 0.56, 0.80],
            builder: (context, scrollController) {
              return Transform.translate(
                offset: const Offset(0, -24),
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                  child: Material(
                    color: _cardCreamBg,
                    elevation: 12,
                    shadowColor: Colors.black26,
                    child: CustomScrollView(
                      controller: scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: const ClampingScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 8),
                            child: Center(
                              child: Container(
                                width: 49,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF424242),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SliverSafeArea(
                          top: false,
                          bottom: true,
                          sliver: SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                                24, 8, 24, keyboardInset + 16),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                      const Text(
                                        'Welcome to Raahi 👋',
                                        style: TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF1A1A1A),
                                          height: 1.2,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Get started in seconds',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.grey.shade600,
                                          height: 1.35,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      _buildPhoneField(enabled: !blocked),
                                      if (_otpStepVisible)
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: TextButton(
                                            onPressed: blocked
                                                ? null
                                                : () => _collapseOtpStep(),
                                            child: Text(
                                              'Change number',
                                              style: TextStyle(
                                                color: _brandGold,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      AnimatedSize(
                                        duration: const Duration(
                                            milliseconds: 280),
                                        curve: Curves.easeOutCubic,
                                        alignment: Alignment.topCenter,
                                        child: _otpStepVisible
                                            ? Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 16),
                                                child:
                                                    _buildInlineOtpSection(
                                                        interactionBlocked:
                                                            blocked),
                                              )
                                            : const SizedBox.shrink(),
                                      ),
                                      if (!_otpStepVisible) ...[
                                        const SizedBox(height: 12),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Icon(Icons.shield_outlined,
                                                size: 18,
                                                color: _brandGold),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                "We'll send you a 6-digit OTP",
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.grey.shade700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const SizedBox(height: 22),
                                      _buildTermsRow(),
                                      const SizedBox(height: 20),
                                      if (!_otpStepVisible)
                                        SizedBox(
                                          width: double.infinity,
                                          height: 54,
                                          child: FilledButton(
                                            style: FilledButton.styleFrom(
                                              backgroundColor: _brandGold,
                                              foregroundColor: Colors.white,
                                              disabledBackgroundColor:
                                                  Colors.grey.shade300,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                              elevation: 0,
                                            ),
                                            onPressed: !_canPressGetOtp
                                                ? null
                                                : _handleGetOtp,
                                            child: _isOtpLoading
                                                ? const SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                                  )
                                                : const Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Text(
                                                        'Get OTP',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                      SizedBox(width: 8),
                                                      Icon(
                                                        Icons
                                                            .arrow_forward_rounded,
                                                        size: 20,
                                                      ),
                                                    ],
                                                  ),
                                          ),
                                        ),
                                      const SizedBox(height: 24),
                                      _buildOrDivider(),
                                      const SizedBox(height: 20),
                                      _buildContinueGoogle(
                                        enabled: !_isSocialLoading &&
                                            !_isOtpLoading &&
                                            !_isVerifyLoading,
                                      ),
                                      if (showApple) ...[
                                        const SizedBox(height: 14),
                                        _buildContinueApple(
                                          enabled: !_isSocialLoading &&
                                              !_isOtpLoading &&
                                              !_isVerifyLoading,
                                        ),
                                      ],
                                    ],
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneField({required bool enabled}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300, width: 1),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            PopupMenuButton<String>(
              enabled: enabled,
              offset: const Offset(0, 48),
              onSelected: (_) {},
              itemBuilder: (context) => const [
                PopupMenuItem(value: '+91', child: Text('India (+91)')),
              ],
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🇮🇳', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    const Text(
                      '+91',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        size: 22, color: Colors.grey.shade600),
                  ],
                ),
              ),
            ),
            Container(width: 1, height: 44, color: const Color(0xFFE8E8E8)),
            Expanded(
              child: TextField(
                controller: _phoneController,
                enabled: enabled,
                keyboardType: TextInputType.phone,
                inputFormatters: [IndianPhoneInputFormatter()],
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
                decoration: InputDecoration(
                  hintText: 'Enter mobile number',
                  hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineOtpSection({required bool interactionBlocked}) {
    final otpDisabled = interactionBlocked || _isVerifyLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter the code sent to +91 ${_formatDisplayPhone(_pendingPhone ?? '')}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: Colors.grey.shade700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            for (var index = 0; index < 6; index++) ...[
              if (index > 0) const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: TextField(
                    controller: _otpControllers[index],
                    focusNode: _otpFocusNodes[index],
                    textAlign: TextAlign.center,
                    textAlignVertical: TextAlignVertical.center,
                    keyboardType: TextInputType.number,
                    maxLength: 1,
                    enabled: !otpDisabled,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xFFF5F5F5),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFF1A1A1A),
                          width: 2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (value) => _onInlineOtpChanged(value, index),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Center(
          child: GestureDetector(
            onTap: _resendTimer > 0 || otpDisabled ? null : _showInlineResendOptions,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                _resendTimer > 0
                    ? "I haven't received a code  (${_resendTimer ~/ 60}:${(_resendTimer % 60).toString().padLeft(2, '0')})"
                    : "I haven't received a code",
                style: TextStyle(
                  fontSize: 14,
                  color: _resendTimer > 0
                      ? const Color(0xFFBDBDBD)
                      : const Color(0xFF1A1A1A),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
        if (_isVerifyLoading) ...[
          const SizedBox(height: 14),
          Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _brandGold,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTermsRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 24,
          width: 24,
          child: Checkbox(
            value: _termsAccepted,
            onChanged:
                (_isSocialLoading || _isOtpLoading || _isVerifyLoading)
                    ? null
                    : (v) {
                        setState(() => _termsAccepted = v ?? false);
                      },
            activeColor: _brandGold,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: Colors.grey.shade800,
              ),
              children: [
                const TextSpan(text: 'I agree to the '),
                TextSpan(
                  text: 'Terms of Use',
                  style: TextStyle(
                    color: _brandGold,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => _openLegalUri(_termsUrl),
                ),
                const TextSpan(text: ' and '),
                TextSpan(
                  text: 'Privacy Policy',
                  style: TextStyle(
                    color: _brandGold,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => _openLegalUri(_privacyUrl),
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrDivider() {
    return Row(
      children: [
        Expanded(child: Divider(color: Colors.grey.shade300, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'OR',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(child: Divider(color: Colors.grey.shade300, height: 1)),
      ],
    );
  }

  Widget _buildContinueGoogle({required bool enabled}) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF2C2C2C),
          backgroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFE8E0D4)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: enabled ? _handleGoogleLogin : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isSocialLoading && !_isOtpLoading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              SvgPicture.asset(
                'assets/images/google_signin_g.svg',
                width: 22,
                height: 22,
              ),
              const SizedBox(width: 12),
              const Text(
                'Continue with Google',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContinueApple({required bool enabled}) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF2C2C2C),
          backgroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFE8E0D4)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: enabled ? _handleAppleLogin : null,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.apple, size: 26, color: Color(0xFF1A1A1A)),
            SizedBox(width: 10),
            Text(
              'Continue with Apple',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  void _handleAppleLogin() {
    if (_isSocialLoading || _isOtpLoading || _isVerifyLoading) return;
    AppMessenger.showErrorBanner(
      context,
      'Sign in with Apple is coming soon.',
    );
  }
}

class _TruecallerPayloadResult {
  final bool success;
  final String? phone;
  final String? accessToken;
  final String? truecallerToken;
  final Map<String, dynamic>? profile;
  final String? error;

  const _TruecallerPayloadResult({
    required this.success,
    this.phone,
    this.accessToken,
    this.truecallerToken,
    this.profile,
    this.error,
  });
}

