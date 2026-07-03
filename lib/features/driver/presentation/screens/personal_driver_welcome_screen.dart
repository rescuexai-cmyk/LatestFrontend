import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../providers/personal_driver_onboarding_provider.dart';

/// Status screen after personal driver submits documents.
class PersonalDriverWelcomeScreen extends ConsumerStatefulWidget {
  const PersonalDriverWelcomeScreen({super.key});

  @override
  ConsumerState<PersonalDriverWelcomeScreen> createState() =>
      _PersonalDriverWelcomeScreenState();
}

class _PersonalDriverWelcomeScreenState
    extends ConsumerState<PersonalDriverWelcomeScreen> {
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _success = Color(0xFF4CAF50);
  static const _danger = Color(0xFFE53935);

  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    // Pull the latest Cloud-Vision verification verdict from the backend.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    await ref
        .read(personalDriverOnboardingProvider.notifier)
        .refreshVerificationStatus();
    if (mounted) setState(() => _isRefreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final pd = ref.watch(personalDriverOnboardingProvider);
    final canGoOnline = pd.canStartRescueJobs;
    final hasRejected = pd.status == PersonalDriverOnboardingStatus.rejected;

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
                hasRejected
                    ? Icons.error_outline
                    : (canGoOnline
                        ? Icons.verified_outlined
                        : Icons.hourglass_top),
                size: 72,
                color: hasRejected
                    ? _danger
                    : (canGoOnline ? _success : _accent),
              ),
              const SizedBox(height: 20),
              Text(
                hasRejected
                    ? 'Some documents need attention'
                    : (canGoOnline
                        ? 'You\'re ready for rescue jobs'
                        : 'Verification in progress'),
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                hasRejected
                    ? 'Our document check flagged one or more of your documents. Please review the details below and re-upload.'
                    : (canGoOnline
                        ? 'Go online to receive rescue requests. You\'ll get the same accept/decline popup when a rider needs a personal driver.'
                        : 'We\'re verifying your documents. This usually takes 24–48 hours.'),
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  height: 1.5,
                  color: _textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: ListView(
                  children: [
                    _docRow('Driving License', pd.drivingLicense),
                    _docRow('Aadhaar Card', pd.aadhaar),
                    _docRow('PAN Card', pd.pan),
                  ],
                ),
              ),
              const SizedBox(height: 8),
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
                SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: _isRefreshing ? null : _refresh,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _accent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(_accent),
                            ),
                          )
                        : const Icon(Icons.refresh, color: _accent),
                    label: Text(
                      _isRefreshing ? 'Checking…' : 'Refresh status',
                      style: GoogleFonts.poppins(
                        color: _accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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

  Widget _docRow(String title, PersonalDriverDocument doc) {
    final _Verdict verdict = _verdictFor(doc);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: verdict.color.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(verdict.icon, color: verdict.color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: verdict.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  verdict.label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: verdict.color,
                  ),
                ),
              ),
            ],
          ),
          if (doc.aiConfidence != null) ...[
            const SizedBox(height: 6),
            Text(
              'Document check confidence: ${(doc.aiConfidence! * 100).round()}%',
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: _textSecondary,
              ),
            ),
          ],
          if (doc.verificationReason != null &&
              doc.verificationReason!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              doc.verificationReason!,
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: _danger,
              ),
            ),
          ],
        ],
      ),
    );
  }

  _Verdict _verdictFor(PersonalDriverDocument doc) {
    switch (doc.status) {
      case PersonalDocStatus.verified:
        return const _Verdict('Verified', Icons.verified, _success);
      case PersonalDocStatus.rejected:
        return const _Verdict('Flagged', Icons.error_outline, _danger);
      case PersonalDocStatus.inReview:
        return const _Verdict('In review', Icons.hourglass_top, _accent);
      case PersonalDocStatus.uploaded:
        return const _Verdict('Uploaded', Icons.check_circle_outline, _accent);
      case PersonalDocStatus.notUploaded:
        return const _Verdict(
            'Not uploaded', Icons.pending_outlined, _textSecondary);
    }
  }
}

class _Verdict {
  const _Verdict(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}
