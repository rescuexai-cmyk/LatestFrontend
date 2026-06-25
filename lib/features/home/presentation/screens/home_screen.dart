import 'dart:math';

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
import '../../../driver/providers/personal_driver_onboarding_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';

/// Figma: Select frame 390×848, background #F6EFD8
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  bool _isCheckingDriver = false;

  /// User chip "peek": animate in, stay ~2–2.5s, animate out, then remove from tree.
  late final AnimationController _userChipRevealController;
  late final Animation<double> _userChipRevealOpacity;
  late final Animation<Offset> _userChipRevealSlide;
  bool _userChipRemoved = false;

  /// Extra space below status bar so the header isn’t cramped against the notch.
  static const _topContentInset = 14.0;
  static const _designW = 390.0;
  static const _designH = 848.0;

  // Figma tokens
  static const _cream = Color(0xFFF6EFD8);
  static const _primaryBtn = Color(0xFFCF923D);
  static const _secondaryFill = Color(0xFFEEE5CA);
  static const _borderBrown = Color(0xFFA89C8A);
  static const _textDark = Color(0xFF353535);
  static const _textSwitch = Color(0xFF353330);
  Future<void> _openDriversApp() async {
    if (_isCheckingDriver) return;
    setState(() => _isCheckingDriver = true);

    try {
      await ref.read(personalDriverOnboardingProvider.notifier).ensureLoaded();
      final pd = ref.read(personalDriverOnboardingProvider);

      if (!mounted) return;

      // Rescue driver path — chosen on driver onboarding step 2 (vehicle type).
      if (pd.driverAppMode == PersonalDriverOnboardingNotifier.modePersonalRescue) {
        if (pd.canStartRescueJobs) {
          context.push(AppRoutes.driverHome);
          return;
        }
        if (pd.shouldShowWelcome && !pd.canStartRescueJobs) {
          context.push(AppRoutes.personalDriverWelcome);
          return;
        }
        if (pd.shouldShowOnboarding || pd.isPersonalDriverActive) {
          context.push(AppRoutes.personalDriverOnboarding);
          return;
        }
      }

      final notifier = ref.read(driverOnboardingProvider.notifier);
      final status = await notifier.fetchOnboardingStatus();

      if (!mounted) return;

      debugPrint('📋 Driver onboarding status: ${status.onboardingStatus.name}');

      if (status.shouldRouteToDriverOnboardingStepper) {
        context.push(AppRoutes.driverOnboarding);
        return;
      }

      switch (status.onboardingStatus) {
        case OnboardingStatus.completed:
          if (status.canStartRides) {
            await ref
                .read(personalDriverOnboardingProvider.notifier)
                .setDriverAppMode(PersonalDriverOnboardingNotifier.modeRideShare);
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
        AppMessenger.showErrorBanner(context, '${ref.tr('driver_status_error')}: ${e.toString().replaceAll('Exception: ', '')}',);
      }
    } finally {
      if (mounted) setState(() => _isCheckingDriver = false);
    }
  }

  void _showVerificationBanner(String message) {
    AppMessenger.showErrorBanner(context, message);
  }

  @override
  void initState() {
    super.initState();
    _userChipRevealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 320),
    );
    final curve = CurvedAnimation(
      parent: _userChipRevealController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _userChipRevealOpacity = curve;
    _userChipRevealSlide = Tween<Offset>(
      begin: const Offset(0, -0.22),
      end: Offset.zero,
    ).animate(curve);

    WidgetsBinding.instance.addPostFrameCallback((_) => _runUserChipPeekAnimation());
  }

  Future<void> _runUserChipPeekAnimation() async {
    if (!mounted || _userChipRemoved) return;
    await _userChipRevealController.forward();
    if (!mounted || _userChipRemoved) return;
    final dwellMs = 2000 + Random().nextInt(501); // 2000–2500 ms inclusive
    await Future<void>.delayed(Duration(milliseconds: dwellMs));
    if (!mounted || _userChipRemoved) return;
    await _userChipRevealController.reverse();
    if (!mounted) return;
    setState(() => _userChipRemoved = true);
  }

  @override
  void dispose() {
    _userChipRevealController.dispose();
    super.dispose();
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
    final bottomSafe = mq.viewPadding.bottom;

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
            padding: EdgeInsets.only(
              top: pt + _topContentInset,
              left: pl,
              right: pr,
            ),
            child: SizedBox(
              width: w - pl - pr,
              height: h - pt - _topContentInset - bottomSafe,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (!_userChipRemoved)
                    Positioned(
                      top: y(70),
                      left: 16,
                      right: 16,
                      child: Center(
                        child: FadeTransition(
                          opacity: _userChipRevealOpacity,
                          child: SlideTransition(
                            position: _userChipRevealSlide,
                            child: _buildUserChip(
                              context,
                              user,
                              vx,
                              max(
                                120.0,
                                (w - pl - pr) - 32,
                              ),
                            ),
                          ),
                        ),
                      ),
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

  Widget _buildUserChip(
    BuildContext context,
    User? user,
    double vx,
    double maxChipOuterWidth,
  ) {
    final trimmedName = (user?.name ?? '').trim();
    final trimmedEmail = (user?.email ?? '').trim();
    final label = trimmedName.isNotEmpty
        ? trimmedName
        : (trimmedEmail.isNotEmpty ? trimmedEmail : 'User');
    final initial = label.isNotEmpty ? label[0].toUpperCase() : 'U';

    /// Horizontal chrome: paddings + avatar + gaps + chevron (pill grows/shrinks with label).
    final hPadChip = (5.5 + 10) * vx;
    final rowFixed =
        (24.3 + 11 + 4 + 18) * vx; // avatar, gap text↔arrow, spacer, arrow
    final maxLabelWidth = max(
      40.0,
      maxChipOuterWidth - hPadChip - rowFixed,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxChipOuterWidth),
      child: Material(
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
              mainAxisSize: MainAxisSize.min,
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
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabelWidth),
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
                SizedBox(width: 4 * vx),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18 * vx,
                  color: _borderBrown,
                ),
              ],
            ),
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
}
