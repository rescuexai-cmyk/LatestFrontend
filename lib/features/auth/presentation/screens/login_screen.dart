import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/providers/settings_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  void _navigateToMobileOTP() {
    context.push(AppRoutes.signup);
  }

  void _handleTruecallerLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.tr('truecaller_coming'))),
    );
  }

  void _handleGoogleLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.tr('google_coming'))),
    );
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
                    _buildTruecallerButton(),
                    const SizedBox(height: 14),
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
          onTap: _handleTruecallerLogin,
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
          onTap: _handleGoogleLogin,
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

