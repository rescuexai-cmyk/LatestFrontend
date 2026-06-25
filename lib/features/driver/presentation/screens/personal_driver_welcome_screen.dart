import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../providers/personal_driver_onboarding_provider.dart';

/// Status screen after personal driver submits documents.
class PersonalDriverWelcomeScreen extends ConsumerWidget {
  const PersonalDriverWelcomeScreen({super.key});

  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _success = Color(0xFF4CAF50);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pd = ref.watch(personalDriverOnboardingProvider);
    final canGoOnline = pd.canStartRescueJobs;

    return Scaffold(
      backgroundColor: _beige,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(
                canGoOnline ? Icons.verified_outlined : Icons.hourglass_top,
                size: 72,
                color: canGoOnline ? _success : _accent,
              ),
              const SizedBox(height: 20),
              Text(
                canGoOnline
                    ? 'You\'re ready for rescue jobs'
                    : 'Verification in progress',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                canGoOnline
                    ? 'Go online to receive rescue requests. You\'ll get the same accept/decline popup when a rider needs a personal driver.'
                    : 'We\'re reviewing your Aadhaar and Driving License. This usually takes 24–48 hours.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  height: 1.5,
                  color: _textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              _docRow(
                'Driving License',
                pd.drivingLicense.status.name,
                pd.drivingLicense.isComplete,
              ),
              _docRow(
                'Aadhaar Card',
                pd.aadhaar.status.name,
                pd.aadhaar.isComplete,
              ),
              const Spacer(),
              if (canGoOnline)
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1A1A1A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      await ref
                          .read(personalDriverOnboardingProvider.notifier)
                          .setDriverAppMode(
                            PersonalDriverOnboardingNotifier.modePersonalRescue,
                          );
                      if (context.mounted) {
                        context.go(AppRoutes.driverHome);
                      }
                    },
                    child: const Text('Go to Driver Home'),
                  ),
                )
              else
                Text(
                  'Backend verification will sync automatically once available.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: _textSecondary,
                  ),
                ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go(AppRoutes.home),
                child: const Text('Back to Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _docRow(String title, String status, bool uploaded) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E0D4)),
      ),
      child: Row(
        children: [
          Icon(
            uploaded ? Icons.check_circle : Icons.pending_outlined,
            color: uploaded ? _success : _accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
                Text(
                  status.replaceAll('_', ' '),
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    color: _textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
