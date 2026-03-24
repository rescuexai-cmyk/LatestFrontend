import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../auth/presentation/widgets/switch_account_sheet.dart';
import '../../../driver/providers/driver_onboarding_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isCheckingDriver = false;

  /// Called when user taps "Open Drivers' App".
  /// 
  /// FLOW:
  /// 1. First, ensure driver onboarding is started (POST /start if needed)
  /// 2. Then fetch backend onboarding status
  /// 3. Navigate based on status
  /// 
  /// This ensures new drivers always have their profile created before
  /// any other API calls are made.
  Future<void> _openDriversApp() async {
    if (_isCheckingDriver) return;
    setState(() => _isCheckingDriver = true);

    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      
      // fetchOnboardingStatus() now auto-calls /start if 404 is returned
      // This ensures the correct order: /start first, then /status
      final status = await notifier.fetchOnboardingStatus();

      if (!mounted) return;

      debugPrint('📋 Driver onboarding status: ${status.onboardingStatus.name}');

      switch (status.onboardingStatus) {
        case OnboardingStatus.completed:
          if (status.canStartRides) {
            context.push(AppRoutes.driverHome);
          } else {
            _showVerificationBanner('Your account setup is complete but rides are temporarily disabled. Please contact support.');
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
            content: Text('${ref.tr('driver_status_error')}: ${e.toString().replaceAll('Exception: ', '')}'),
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
        backgroundColor: const Color(0xFFD4956A),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFFF6EFE4),
        child: Stack(
          children: [
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
                    const SizedBox(height: 16),
                    
                    // User profile dropdown — show actual name
                    _buildUserDropdown(context, user?.name ?? user?.email ?? 'User'),
                    
                    SizedBox(height: MediaQuery.of(context).size.height * 0.12),
                    
                    // Logo with tagline
                    _buildRaahiLogo(),
                    
                    const Spacer(),
                    
                    // Find a Ride button → navigates to services screen
                    _buildFindRideButton(context),
                    
                    const SizedBox(height: 20),
                    
                    // Open Drivers' App button
                    _buildDriversAppButton(context),
                    
                    const SizedBox(height: 20),
                    
                    // Switch Account link
                    _buildSwitchAccountLink(context),
                    
                    const SizedBox(height: 30),
                    
                    // Footer
                    _buildFooter(),
                    
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // ── Active ride banner (pinned at bottom) ──
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(child: ActiveRideBanner()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserDropdown(BuildContext context, String name) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFEDE6DA),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFFD4956A),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              name,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF1A1A1A),
                fontWeight: FontWeight.w500,
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

  Widget _buildFindRideButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: const Color(0xFFD4956A),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: () {
            context.push(AppRoutes.services);
          },
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Text(
                  'Find a Ride Now!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 12),
                Icon(
                  Icons.arrow_forward,
                  color: Colors.white,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDriversAppButton(BuildContext context) {
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
            onTap: _isCheckingDriver ? null : _openDriversApp,
            borderRadius: BorderRadius.circular(28),
            child: Center(
              child: _isCheckingDriver
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5C5C5C)),
                    )
                  : Text(
                      ref.tr('open_drivers_app'),
                      style: const TextStyle(
                        color: Color(0xFF5C5C5C),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchAccountLink(BuildContext context) {
    return GestureDetector(
      onTap: () {
        showSwitchAccountSheet(context);
      },
      child: Text(
        ref.tr('switch_account'),
        style: const TextStyle(
          fontSize: 15,
          color: Color(0xFF5C5C5C),
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFF5C5C5C),
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
      ],
    );
  }
}
