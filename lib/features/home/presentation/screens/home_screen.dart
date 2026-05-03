import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../core/models/user.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../auth/presentation/widgets/switch_account_sheet.dart';
import '../../../driver/providers/driver_onboarding_provider.dart';

/// Figma: Select frame 390×848, background #F6EFD8
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isCheckingDriver = false;

  static const _designW = 390.0;
  static const _designH = 848.0;

  // Figma tokens
  static const _cream = Color(0xFFF6EFD8);
  static const _primaryBtn = Color(0xFFCF923D);
  static const _secondaryFill = Color(0xFFEEE5CA);
  static const _borderBrown = Color(0xFFA89C8A);
  static const _textDark = Color(0xFF353535);
  static const _textSwitch = Color(0xFF353330);
  static const _textFooter = Color(0xFF606060);

  Future<void> _openDriversApp() async {
    if (_isCheckingDriver) return;
    setState(() => _isCheckingDriver = true);

    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      final status = await notifier.fetchOnboardingStatus();

      if (!mounted) return;

      debugPrint('📋 Driver onboarding status: ${status.onboardingStatus.name}');

      switch (status.onboardingStatus) {
        case OnboardingStatus.completed:
          if (status.canStartRides) {
            context.push(AppRoutes.driverHome);
          } else {
            _showVerificationBanner(
              'Your account setup is complete but rides are temporarily disabled. Please contact support.',
            );
          }
          break;

        case OnboardingStatus.documentVerification:
        case OnboardingStatus.documentsUploaded:
          context.push(AppRoutes.driverWelcome);
          break;

        case OnboardingStatus.notStarted:
        case OnboardingStatus.started:
          context.push(AppRoutes.driverOnboarding);
          break;

        case OnboardingStatus.rejected:
          context.push(AppRoutes.driverWelcome);
          break;
      }
    } catch (e) {
      debugPrint('❌ _openDriversApp error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${ref.tr('driver_status_error')}: ${e.toString().replaceAll('Exception: ', '')}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingDriver = false);
    }
  }

  void _showVerificationBanner(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: _primaryBtn,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final vx = w / _designW;
    final vy = h / _designH;
    final pt = mq.padding.top;
    final pl = mq.padding.left;
    final pr = mq.padding.right;

    /// Figma tops are from frame top; overlay is laid out below status bar.
    double y(double figmaTop) => (figmaTop * vy - pt).clamp(0.0, double.infinity);

    final contentW = 346 * vx;
    final heroH = 587 * vy;
    final heroTop = -31 * vy;
    final gradTop = 129 * vy;
    final gradH = 427 * vy;

    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(child: ColoredBox(color: _cream)),

          // ChatGPT hero: 391×587, top -31
          Positioned(
            top: heroTop,
            left: 0,
            right: 0,
            height: heroH,
            child: Image.asset(
              'assets/images/home_traffic_hero.png',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),

          // Rectangle 4072: gradient 390×427, top 129
          Positioned(
            top: gradTop,
            left: 0,
            right: 0,
            height: gradH,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _cream.withValues(alpha: 0),
                    _cream,
                  ],
                ),
              ),
            ),
          ),

          // Foreground: positions match Figma after subtracting status-bar inset.
          Padding(
            padding: EdgeInsets.only(top: pt, left: pl, right: pr),
            child: SizedBox(
              width: w - pl - pr,
              height: h - pt,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: (w - 236 * vx) / 2 - pl,
                    top: y(70),
                    width: 236 * vx,
                    height: 38 * vx,
                    child: _buildUserChip(context, user, vx),
                  ),
                  Positioned(
                    left: (w - 311 * vx) / 2 - pl,
                    top: y(264),
                    width: 311 * vx,
                    child: _buildRaahiLogo(vx),
                  ),
                  Positioned(
                    left: (w - contentW) / 2 - pl,
                    top: y(583),
                    width: contentW,
                    child: _buildActionColumn(context, vx),
                  ),
                  Positioned(
                    left: -pl,
                    right: -pr,
                    top: y(808.34),
                    child: _buildFooter(),
                  ),
                ],
              ),
            ),
          ),

          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(child: ActiveRideBanner()),
          ),
        ],
      ),
    );
  }

  Widget _buildUserChip(BuildContext context, User? user, double vx) {
    final label = (user != null && user.email.isNotEmpty)
        ? user.email
        : (user?.name ?? 'User');
    final initial = label.isNotEmpty ? label[0].toUpperCase() : 'U';

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(38),
        side: const BorderSide(color: _borderBrown, width: 0.36),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showSwitchAccountSheet(context),
        borderRadius: BorderRadius.circular(38),
        child: Padding(
          padding: EdgeInsets.only(
            left: 5.5 * vx,
            right: 10 * vx,
            top: 9.75 * vx,
            bottom: 9.75 * vx,
          ),
          child: Row(
            children: [
              Container(
                width: 24.3 * vx,
                height: 24.3 * vx,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4956A),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 0.55),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: GoogleFonts.poppins(
                    fontSize: 11 * vx,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: 11 * vx),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 18 / 12,
                    color: _textDark,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18 * vx,
                color: _borderBrown,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRaahiLogo(double vx) {
    return Image.asset(
      'assets/images/raahi_logo_tagline.png',
      width: 237.86 * vx,
      fit: BoxFit.contain,
    );
  }

  Widget _buildActionColumn(BuildContext context, double vx) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildFindRideButton(context, vx),
        SizedBox(height: 20 * vx),
        _buildDriversAppButton(context, vx),
        SizedBox(height: 23 * vx),
        _buildSwitchAccountLink(context, vx),
      ],
    );
  }

  Widget _buildFindRideButton(BuildContext context, double vx) {
    final h = 60 * vx;
    return SizedBox(
      width: 346 * vx,
      height: h,
      child: Material(
        color: _primaryBtn,
        borderRadius: BorderRadius.circular(50),
        child: InkWell(
          onTap: () => context.push(AppRoutes.services),
          borderRadius: BorderRadius.circular(50),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Find a Ride Now!',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 24 / 16,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 14 * vx),
              Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18 * vx),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriversAppButton(BuildContext context, double vx) {
    final h = 60 * vx;
    return SizedBox(
      width: 346 * vx,
      height: h,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isCheckingDriver ? null : _openDriversApp,
          borderRadius: BorderRadius.circular(50),
          child: Ink(
            height: h,
            decoration: BoxDecoration(
              color: _secondaryFill,
              borderRadius: BorderRadius.circular(50),
              border: Border.all(color: _borderBrown, width: 0.59),
            ),
            child: Center(
              child: _isCheckingDriver
                  ? SizedBox(
                      width: 22 * vx,
                      height: 22 * vx,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _textDark.withValues(alpha: 0.7),
                      ),
                    )
                  : Text(
                      ref.tr('open_drivers_app'),
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        height: 24 / 16,
                        color: _textDark,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchAccountLink(BuildContext context, double vx) {
    return GestureDetector(
      onTap: () => showSwitchAccountSheet(context),
      child: Text(
        ref.tr('switch_account'),
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          height: 24 / 16,
          color: _textSwitch,
          decoration: TextDecoration.underline,
          decorationColor: _textSwitch,
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        'Curated with love in Delhi, NCR 💛',
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontSize: 14,
          fontWeight: FontWeight.w300,
          height: 21 / 14,
          color: _textFooter,
        ),
      ),
    );
  }
}
