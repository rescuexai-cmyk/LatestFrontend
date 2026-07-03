import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../core/router/app_routes.dart';
import '../../providers/welcome_onboarding_provider.dart';

/// A single onboarding slide's copy. The road image + cream background stay
/// fixed across all pages — only this text changes (with a smooth slide).
class _OnbSlide {
  const _OnbSlide({
    required this.image,
    required this.titleTop,
    required this.titleBottom,
    this.description = '',
    this.descriptionBold,
    this.descWidth = 240,
    this.eyebrow,
    this.isFinal = false,
    this.cardHeight = 399,
  });

  /// Hero card image for this slide.
  final String image;

  /// First title line. Black by default, gold on the final slide.
  final String titleTop;

  /// Second title line. Gold by default, black on the final slide.
  final String titleBottom;
  final String description;

  /// Optional emphasised tail rendered bold on its own line.
  final String? descriptionBold;

  /// Design width (at 390pt) the description wraps within.
  final double descWidth;

  /// Optional small bold label shown above the title (final slide).
  final String? eyebrow;

  /// Final slide uses an inverted title palette + full-width CTA, no dots/skip.
  final bool isFinal;

  /// Design height (at 390pt) of the hero card image.
  final double cardHeight;
}

class WelcomeOnboardingScreen extends ConsumerStatefulWidget {
  const WelcomeOnboardingScreen({super.key});

  @override
  ConsumerState<WelcomeOnboardingScreen> createState() =>
      _WelcomeOnboardingScreenState();
}

class _WelcomeOnboardingScreenState
    extends ConsumerState<WelcomeOnboardingScreen> {
  int _currentPage = 0;

  static const Color _bg = Color(0xFFFBF2E8);
  static const Color _gold = Color(0xFFCB9C5E);
  static const Color _ink = Color(0xFF231409);

  // TODO: Replace pages 3–4 image + copy with the final Figma assets/text.
  static const List<_OnbSlide> _slides = [
    _OnbSlide(
      image: 'assets/images/onboarding_road.png',
      titleTop: 'ONE APP',
      titleBottom: 'ONE ROAD',
      description:
          'Raahi brings both together on one platform. Whether you drive or ride',
    ),
    _OnbSlide(
      image: 'assets/images/onboarding_road_2.png',
      titleTop: 'BUILT ON',
      titleBottom: 'CLARITY',
      description:
          'No hidden charges. No hidden cuts. Just clear numbers for everyone.',
      descWidth: 300,
    ),
    _OnbSlide(
      image: 'assets/images/onboarding_road_3.png',
      titleTop: 'SAME ROADS',
      titleBottom: 'BETTER SYSTEM',
      description:
          'Because everyday movement deserved better than \u201CTHIS IS HOW IT WORKS\u201D',
      descriptionBold: 'That\u2019s Raahi.',
      descWidth: 352,
    ),
    _OnbSlide(
      image: 'assets/images/onboarding_road_4.png',
      eyebrow: 'BUILT ON CLARITY AND TRUST',
      titleTop: 'INDIA\u2019s',
      titleBottom: 'Own Mobility Ecosystem',
      isFinal: true,
      cardHeight: 470,
    ),
  ];

  Future<void> _completeOnboarding() async {
    await ref.read(welcomeOnboardingProvider.notifier).complete();
    if (mounted) {
      Future.microtask(() {
        if (mounted) context.go(AppRoutes.login);
      });
    }
  }

  void _nextPage() {
    if (_currentPage < _slides.length - 1) {
      setState(() => _currentPage++);
    } else {
      _completeOnboarding();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      setState(() => _currentPage--);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final s = width / 390.0;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            // Each page (hero card + copy) slides together over the fixed
            // cream background; only the background stays put.
            Expanded(
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v < -100) {
                    _nextPage();
                  } else if (v > 100) {
                    _prevPage();
                  }
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  // Pure crossfade — content is replaced in place, no sliding.
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.topCenter,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey<int>(_currentPage),
                    child: _buildPage(_slides[_currentPage], s),
                  ),
                ),
              ),
            ),
            if (_slides[_currentPage].isFinal)
              Padding(
                padding: EdgeInsets.fromLTRB(22 * s, 8 * s, 22 * s, 24 * s),
                child: _buildGetStartedButton(s),
              )
            else ...[
              _buildDots(s),
              Padding(
                padding: EdgeInsets.fromLTRB(28 * s, 24 * s, 22 * s, 24 * s),
                child: _buildButtonsRow(s),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPage(_OnbSlide slide, double s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 24 * s),
        _buildHeroCard(slide.image, slide.cardHeight, s),
        SizedBox(height: 26 * s),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 22 * s),
          child: slide.isFinal
              ? _buildFinalSlideText(slide, s)
              : _buildSlideText(slide, s),
        ),
      ],
    );
  }

  Widget _buildFinalSlideText(_OnbSlide slide, double s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (slide.eyebrow != null)
          Text(
            slide.eyebrow!,
            style: GoogleFonts.poppins(
              fontSize: 14 * s,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2 * s,
              color: Colors.black,
            ),
          ),
        SizedBox(height: 6 * s),
        Text(
          slide.titleTop,
          style: GoogleFonts.barlowSemiCondensed(
            fontSize: 56 * s,
            height: 50 / 56,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.56 * s,
            color: _gold,
          ),
        ),
        SizedBox(height: 4 * s),
        Text(
          slide.titleBottom,
          style: GoogleFonts.poppins(
            fontSize: 27 * s,
            height: 1.1,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.27 * s,
            color: Colors.black,
          ),
        ),
      ],
    );
  }

  Widget _buildGetStartedButton(double s) {
    return Material(
      color: Colors.black,
      borderRadius: BorderRadius.circular(16 * s),
      child: InkWell(
        borderRadius: BorderRadius.circular(16 * s),
        onTap: _completeOnboarding,
        child: SizedBox(
          width: double.infinity,
          height: 60 * s,
          child: Center(
            child: Text(
              'Get Started',
              style: GoogleFonts.poppins(
                fontSize: 18 * s,
                height: 27 / 18,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.18 * s,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroCard(String image, double height, double s) {
    return Center(
      child: SizedBox(
        width: 345 * s,
        height: height * s,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28 * s),
                child: Image.asset(
                  image,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            // "raahi — Butter to your जाम" wordmark, tinted white over the road.
            Align(
              alignment: const Alignment(0, 0.86),
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
                child: Image.asset(
                  'assets/images/raahi_login_logo.png',
                  width: 108 * s,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlideText(_OnbSlide slide, double s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            style: GoogleFonts.barlowSemiCondensed(
              fontSize: 53 * s,
              height: 50 / 53,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.53 * s,
            ),
            children: [
              TextSpan(
                text: '${slide.titleTop}\n',
                style: const TextStyle(color: Colors.black),
              ),
              TextSpan(
                text: slide.titleBottom,
                style: const TextStyle(color: _gold),
              ),
            ],
          ),
        ),
        SizedBox(height: 17 * s),
        SizedBox(
          width: slide.descWidth * s,
          child: RichText(
            text: TextSpan(
              style: GoogleFonts.poppins(
                fontSize: 15 * s,
                height: 22 / 15,
                fontWeight: FontWeight.w400,
                letterSpacing: -0.15 * s,
                color: _ink,
              ),
              children: [
                TextSpan(text: slide.description),
                if (slide.descriptionBold != null)
                  TextSpan(
                    text: '\n${slide.descriptionBold}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDots(double s) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 28 * s),
      child: Row(
        children: List.generate(_slides.length, (index) {
          final active = index == _currentPage;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            margin: EdgeInsets.only(right: 5 * s),
            width: (active ? 24 : 8) * s,
            height: 7 * s,
            decoration: BoxDecoration(
              color: active ? _gold : const Color(0xFFD9D9D9),
              borderRadius: BorderRadius.circular(50),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildButtonsRow(double s) {
    final isLast = _currentPage == _slides.length - 1;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        TextButton(
          onPressed: _completeOnboarding,
          style: TextButton.styleFrom(
            foregroundColor: _ink,
            padding: EdgeInsets.zero,
            minimumSize: Size(50 * s, 48 * s),
            alignment: Alignment.centerLeft,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            'Skip',
            style: GoogleFonts.poppins(
              fontSize: 18 * s,
              height: 27 / 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.18 * s,
              color: _ink,
            ),
          ),
        ),
        Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16 * s),
          child: InkWell(
            borderRadius: BorderRadius.circular(16 * s),
            onTap: _nextPage,
            child: SizedBox(
              width: 144 * s,
              height: 60 * s,
              child: Center(
                child: Text(
                  isLast ? 'Get Started' : 'Next',
                  style: GoogleFonts.poppins(
                    fontSize: 18 * s,
                    height: 27 / 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.18 * s,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
