import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:truecaller_sdk/truecaller_sdk.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _isSocialLoading = false;

  void _navigateToMobileOTP() {
    context.push(AppRoutes.signup);
  }

  Future<void> _handleTruecallerLogin() async {
    if (_isSocialLoading) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Truecaller login is available on Android only.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tcPayload.error ?? 'Truecaller verification failed')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Truecaller login failed')),
      );
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
      if (completer != null && !completer!.isCompleted) {
        completer!.complete(value);
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
    if (_isSocialLoading) return;
    setState(() => _isSocialLoading = true);
    final result = await ref.read(authStateProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _isSocialLoading = false);

    if (!result.success) {
      final raw = result.error ?? 'Google login failed';
      final message = raw.contains('GOOGLE_SERVER_CLIENT_ID')
          ? 'Google login not configured. Please set GOOGLE_SERVER_CLIENT_ID (Web client ID) in build settings.'
          : raw;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFF6EFE4),
        child: Stack(
          children: [
            // Server config button (top-right corner)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: GestureDetector(
                onTap: () => context.push('${AppRoutes.serverConfig}?initial=false'),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.dns_outlined, size: 20, color: Colors.grey[600]),
                ),
              ),
            ),
            // Mandala pattern
            Positioned(
              top: -225,
              left: 0,
              right: 0,
              child: Center(
                child: Image.asset(
                  'assets/images/mandala_art.png',
                  width: 450,
                  height: 450,
                  fit: BoxFit.contain,
                  color: const Color(0xFFF6EFE4),
                  colorBlendMode: BlendMode.screen,
                ),
              ),
            ),
            
            // Main content
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Column(
                  children: [
                    SizedBox(height: MediaQuery.of(context).size.height * 0.18),
                    
                    // Logo with tagline
                    _buildRaahiLogo(),
                    
                    const Spacer(),
                    
                    // Buttons
                    _buildGoogleButton(),
                    const SizedBox(height: 24),
                    _buildMobileOTPButton(),
                    
                    SizedBox(height: MediaQuery.of(context).size.height * 0.08),
                    
                    // Footer
                    _buildFooter(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRaahiLogo() {
    return Image.asset(
      'assets/images/raahi_logo.png',
      width: 280,
      fit: BoxFit.contain,
    );
  }

  Widget _buildTruecallerButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: _isSocialLoading ? null : _handleTruecallerLogin,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFF29B6F6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.phone,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Login Via OTP on truecaller',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: const Color(0xFFDFD4C0),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: _isSocialLoading ? null : _handleGoogleLogin,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: CustomPaint(
                      size: const Size(22, 22),
                      painter: _GoogleLogoPainter(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Login with Google',
                  style: TextStyle(
                    color: Color(0xFF2C2C2C),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileOTPButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: const Color(0xFFFBF8F3),
        borderRadius: BorderRadius.circular(28),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: const Color(0xFFE8E0D4),
              width: 1,
            ),
          ),
          child: InkWell(
            onTap: _navigateToMobileOTP,
            borderRadius: BorderRadius.circular(28),
            child: Center(
              child: RichText(
                text: const TextSpan(
                  style: TextStyle(
                    color: Color(0xFF5C5C5C),
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                  children: [
                    TextSpan(text: 'Login with '),
                    TextSpan(
                      text: 'Mobile OTP',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Text(
          'Curated with love in Delhi, NCR ',
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFFB8AFA0),
            fontWeight: FontWeight.w400,
          ),
        ),
        Text('💛', style: TextStyle(fontSize: 13)),
      ],
    );
  }
}

// Google Logo Painter
class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    
    // Blue arc (right side)
    final bluePaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.18;
    canvas.drawArc(rect, -0.6, 1.8, false, bluePaint);
    
    // Green arc (bottom right)
    final greenPaint = Paint()
      ..color = const Color(0xFF34A853)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.18;
    canvas.drawArc(rect, 1.2, 0.9, false, greenPaint);
    
    // Yellow arc (bottom left)
    final yellowPaint = Paint()
      ..color = const Color(0xFFFBBC05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.18;
    canvas.drawArc(rect, 2.1, 0.8, false, yellowPaint);
    
    // Red arc (top left)
    final redPaint = Paint()
      ..color = const Color(0xFFEA4335)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.18;
    canvas.drawArc(rect, 2.9, 0.9, false, redPaint);
    
    // Blue horizontal bar
    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.5,
        size.height * 0.4,
        size.width * 0.5,
        size.height * 0.2,
      ),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

