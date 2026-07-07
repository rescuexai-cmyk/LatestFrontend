import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../core/models/user.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/router/user_landing.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/widgets/draggable_active_ride_banner.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../auth/presentation/widgets/switch_account_sheet.dart';
import '../../../driver/providers/driver_onboarding_provider.dart';
import '../../../driver/providers/personal_driver_onboarding_provider.dart';
import '../../../ride/providers/ride_booking_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';

/// Figma: App selection op1 — 390×848, background #FBF2E8
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isCheckingDriver = false;
  bool _autoOpeningDriver = false;

  static const _designW = 390.0;

  // Figma frame height reference: 848px (positions scale uniformly by width).
  static const _cream = Color(0xFFFBF2E8);
  static const _primaryBtn = Color(0xFFCB9C5E);
  static const _secondaryFill = Color(0xFFF9EEDE);
  static const _iconCircleFill = Color(0xFFFAEEDC);
  static const _borderBrown = Color(0xFFA89C8A);
  static const _brownIcon = Color(0xFF6F5131);
  static const _textDark = Color(0xFF353535);
  static const _headline = Color(0xFF231409);
  static const _subhead = Color(0xFF545052);
  static const _secondarySubtitle = Color(0xFF898989);
  static const _switchLink = Color(0xFF78572A);
  static const _footerText = Color(0xFF606060);

  @override
  void initState() {
    super.initState();
    // Driver-only accounts skip the dual-choice screen and open the driver app.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoRouteByRole());
  }

  Future<void> _maybeAutoRouteByRole() async {
    final user = ref.read(currentUserProvider);
    if (!shouldAutoOpenDriverApp(user)) return;
    if (_autoOpeningDriver || _isCheckingDriver) return;

    setState(() {
      _autoOpeningDriver = true;
      _isCheckingDriver = true;
    });
    await _openDriversApp();
    if (mounted) setState(() => _autoOpeningDriver = false);
  }

  Future<void> _openDriversApp() async {
    if (_isCheckingDriver) return;
    setState(() => _isCheckingDriver = true);

    try {
      await ref.read(personalDriverOnboardingProvider.notifier).ensureLoaded();
      final pd = ref.read(personalDriverOnboardingProvider);

      if (!mounted) return;

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
        AppMessenger.showErrorBanner(
          context,
          '${ref.tr('driver_status_error')}: ${e.toString().replaceAll('Exception: ', '')}',
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingDriver = false);
    }
  }

  void _showVerificationBanner(String message) {
    AppMessenger.showErrorBanner(context, message);
  }

  bool _hasActiveRideBanner(BuildContext context) {
    final booking = ref.watch(rideBookingProvider);
    final rideId = booking.rideId;
    if (rideId == null || rideId.isEmpty) return false;

    final route = GoRouterState.of(context).matchedLocation;
    if (route == AppRoutes.searchingDrivers ||
        route == AppRoutes.scheduledRide ||
        route == AppRoutes.driverAssigned ||
        route.startsWith('/ride/')) {
      return false;
    }
    return true;
  }

  double _figma(double width, double v) => v * (width / _designW);

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final bottomSafe = mq.viewPadding.bottom;
    final s = w / _designW;
    final showRideBanner = _hasActiveRideBanner(context);
    final userType = user?.userType ?? UserType.rider;

    // Driver-only: show a minimal loading state while the gateway runs.
    if (_autoOpeningDriver && userType == UserType.driver) {
      return Scaffold(
        backgroundColor: _cream,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: _primaryBtn),
              SizedBox(height: 16 * s),
              Text(
                'Opening Driver\'s App…',
                style: GoogleFonts.poppins(
                  fontSize: 14 * s,
                  color: _subhead,
                ),
              ),
            ],
          ),
        ),
      );
    }

    double figma(double v) => _figma(w, v);

    // Hero zoom-out + vertical crop tuned to Figma wide street framing.
    const heroImageWidthFactor = 0.68;
    const heroImageAlignY = 0.82;

    return Scaffold(
      backgroundColor: _cream,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(child: ColoredBox(color: _cream)),

          // Layer 1 — hero 688×627 at (-119, -21)
          Positioned(
            left: figma(-119),
            top: figma(-21),
            width: figma(688),
            height: figma(627),
            child: ClipRect(
              child: ColoredBox(
                color: const Color(0xFFB8C5D0),
                child: Align(
                  alignment: Alignment(0, heroImageAlignY),
                  child: Image.asset(
                    'assets/images/home_selection_hero_bg.png',
                    width: figma(688) * heroImageWidthFactor,
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
                  ),
                ),
              ),
            ),
          ),

          // Layer 2 — gradient fade top 396, height 210
          Positioned(
            top: figma(396),
            left: 0,
            right: 0,
            height: figma(210),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _cream.withValues(alpha: 0),
                    _cream.withValues(alpha: 0.6548),
                    _cream,
                  ],
                  stops: const [0.0, 0.6548, 1.0],
                ),
              ),
            ),
          ),

          // Layer 3 — profile chip top 70
          Positioned(
            top: figma(70),
            left: 0,
            right: 0,
            child: Center(child: _buildUserChip(context, user, s)),
          ),

          // Layer 4 — headline top 506
          Positioned(
            top: figma(506),
            left: 0,
            right: 0,
            child: _buildHeadlineBlock(s),
          ),

          // Layer 5 — buttons + switch top 603, left 22
          Positioned(
            top: figma(603),
            left: figma(22),
            width: figma(346),
            child: _buildActionColumn(context, s),
          ),

          // Layer 6 — footer top 815
          Positioned(
            top: figma(815),
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: bottomSafe + (showRideBanner ? 72 : 0),
              ),
              child: _buildFooter(s),
            ),
          ),

          const Positioned.fill(
            child: DraggableActiveRideBanner(wrapSafeArea: true),
          ),
        ],
      ),
    );
  }

  Widget _buildHeadlineBlock(double s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Move Better. Stress Less',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 23 * s,
            fontWeight: FontWeight.w600,
            height: 34 / 23,
            letterSpacing: -0.23 * s,
            color: _headline,
          ),
        ),
        SizedBox(height: 4 * s),
        Text(
          'Reliable rides, Everytime',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 14 * s,
            fontWeight: FontWeight.w500,
            height: 21 / 14,
            letterSpacing: -0.14 * s,
            color: _subhead,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(double s) {
    return Text(
      'Curated with love in Delhi, NCR 💛',
      textAlign: TextAlign.center,
      style: GoogleFonts.poppins(
        fontSize: 10 * s,
        fontWeight: FontWeight.w300,
        height: 15 / 10,
        color: _footerText,
      ),
    );
  }

  Widget _buildUserChip(BuildContext context, User? user, double s) {
    final trimmedName = (user?.name ?? '').trim();
    final trimmedEmail = (user?.email ?? '').trim();
    final label = trimmedName.isNotEmpty
        ? trimmedName
        : (trimmedEmail.isNotEmpty ? trimmedEmail : 'User');
    final initial = label.isNotEmpty ? label[0].toUpperCase() : 'U';
    final avatarUrl = user?.avatarUrl?.trim();

    // Figma: Frame 1410081555 — radius 14, border 0.361px #A89C8A.
    // Width hugs the email (dynamic) but is capped so very long emails ellipsize.
    return SizedBox(
      height: 38 * s,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(color: _borderBrown, width: 0.361285 * s),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => showSwitchAccountSheet(context),
            borderRadius: BorderRadius.circular(14 * s),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                5.52279 * s,
                0,
                6 * s,
                0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Ellipse 299 — 24.3×24.3
                  Container(
                    width: 24.3 * s,
                    height: 24.3 * s,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDD9797),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 0.552279 * s),
                      image: avatarUrl != null && avatarUrl.isNotEmpty
                          ? DecorationImage(
                              image: NetworkImage(avatarUrl),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: avatarUrl == null || avatarUrl.isEmpty
                        ? Text(
                            initial,
                            style: GoogleFonts.poppins(
                              fontSize: 10 * s,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 8 * s),
                  // Email hugs content; ellipsize only when truly long.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 200 * s),
                    child: Text(
                      trimmedEmail.isNotEmpty ? trimmedEmail : label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 12 * s,
                        fontWeight: FontWeight.w500,
                        height: 18 / 12,
                        color: _textDark,
                      ),
                    ),
                  ),
                  SizedBox(width: 4 * s),
                  // icon_back — chevron down, tight to ellipsis
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 12.15 * s,
                    color: _borderBrown,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionColumn(BuildContext context, double s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFindRideButton(context, s),
            SizedBox(height: 20 * s),
            _buildDriversAppButton(context, s),
          ],
        ),
        SizedBox(height: 23 * s),
        _buildSwitchAccountLink(context, s),
      ],
    );
  }

  Widget _buildLineArrow({required double s, required Color color}) {
    return SizedBox(
      width: 20 * s,
      height: 20 * s,
      child: CustomPaint(
        painter: _ChevronArrowPainter(color: color, strokeWidth: 1.8 * s),
      ),
    );
  }

  Widget _buildActionButton({
    required double s,
    required VoidCallback? onTap,
    required Color backgroundColor,
    required Color borderColor,
    required Widget leadingIcon,
    required String title,
    required String subtitle,
    required Color titleColor,
    required Color subtitleColor,
    required Color arrowColor,
    Widget? trailing,
  }) {
    return SizedBox(
      width: 346 * s,
      height: 60 * s,
      child: Material(
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13 * s),
          side: BorderSide(color: borderColor, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13 * s),
          child: Padding(
            padding: EdgeInsets.only(left: 23 * s, right: 31 * s),
            child: Row(
              children: [
                leadingIcon,
                SizedBox(width: 20 * s),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.poppins(
                          fontSize: 16 * s,
                          fontWeight: FontWeight.w600,
                          height: 24 / 16,
                          color: titleColor,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          fontSize: 10 * s,
                          fontWeight: FontWeight.w400,
                          height: 15 / 10,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing ?? _buildLineArrow(s: s, color: arrowColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconBadge({
    required double s,
    required String assetPath,
    required bool bordered,
    required double iconW,
    required double iconH,
  }) {
    // Figma Ellipse 375 — 39×39
    return Container(
      width: 39 * s,
      height: 39 * s,
      decoration: BoxDecoration(
        color: _iconCircleFill,
        shape: BoxShape.circle,
        border: bordered ? Border.all(color: _brownIcon, width: 0.5) : null,
      ),
      alignment: Alignment.center,
      child: Image.asset(
        assetPath,
        width: iconW * s,
        height: iconH * s,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }

  Widget _buildFindRideButton(BuildContext context, double s) {
    return _buildActionButton(
      s: s,
      onTap: () => context.push(AppRoutes.services),
      backgroundColor: _primaryBtn,
      borderColor: Colors.transparent,
      leadingIcon: _buildIconBadge(
        s: s,
        assetPath: 'assets/images/home_icon_ride_car.png',
        bordered: false,
        iconW: 32,
        iconH: 26,
      ),
      title: 'Find a Ride Now!',
      subtitle: 'Get a ride in just a few steps',
      titleColor: Colors.white,
      subtitleColor: Colors.white,
      arrowColor: Colors.white,
    );
  }

  Widget _buildDriversAppButton(BuildContext context, double s) {
    return _buildActionButton(
      s: s,
      onTap: _isCheckingDriver ? null : _openDriversApp,
      backgroundColor: _secondaryFill,
      borderColor: const Color(0xB3898989),
      leadingIcon: _buildIconBadge(
        s: s,
        assetPath: 'assets/images/home_icon_steering.png',
        bordered: true,
        iconW: 28,
        iconH: 28,
      ),
      title: "Open Driver's App",
      subtitle: 'Go online and start earning',
      titleColor: _brownIcon,
      subtitleColor: _secondarySubtitle,
      arrowColor: _secondarySubtitle,
      trailing: _isCheckingDriver
          ? SizedBox(
              width: 22 * s,
              height: 22 * s,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _brownIcon.withValues(alpha: 0.7),
              ),
            )
          : null,
    );
  }

  Widget _buildSwitchAccountLink(BuildContext context, double s) {
    return GestureDetector(
      onTap: () => showSwitchAccountSheet(context),
      child: Text(
        'Switch Account?',
        textAlign: TextAlign.center,
        style: GoogleFonts.poppins(
          fontSize: 14 * s,
          fontWeight: FontWeight.w400,
          height: 21 / 14,
          color: _switchLink,
          decoration: TextDecoration.underline,
          decorationColor: _switchLink,
        ),
      ),
    );
  }
}

/// Thin right-arrow with an open V (chevron) head and rounded caps — matches the
/// Figma "→" glyph used on the action cards.
class _ChevronArrowPainter extends CustomPainter {
  _ChevronArrowPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cy = size.height / 2;
    // Keep the round caps inside the box so the tip isn't clipped.
    final tipX = size.width - strokeWidth;
    final startX = strokeWidth;
    final headBackX = tipX - size.width * 0.34;
    final headSpread = size.height * 0.26;

    // Shaft.
    canvas.drawLine(Offset(startX, cy), Offset(tipX, cy), paint);
    // Open chevron head.
    final head = Path()
      ..moveTo(headBackX, cy - headSpread)
      ..lineTo(tipX, cy)
      ..lineTo(headBackX, cy + headSpread);
    canvas.drawPath(head, paint);
  }

  @override
  bool shouldRepaint(covariant _ChevronArrowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
