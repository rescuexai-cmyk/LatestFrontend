import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_widgets.dart';

/// Figma screen 8 — Handover verification with OTP.
class RescueHandoverScreen extends ConsumerWidget {
  const RescueHandoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(rescueBookingProvider);
    final otp = s.summary?.rescueOtp ?? '----';
    final reg = s.vehicleDetails.registrationNumber;
    final driver = s.summary?.driver1Name ?? 'Rescue driver';

    return RescueScaffold(
      title: 'Verify handover',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Verify vehicle handover with your rescue driver.',
              style: RescueTheme.body,
            ),
            const SizedBox(height: 20),
            RescueCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Vehicle number', reg.isEmpty ? '—' : reg),
                  const SizedBox(height: 12),
                  _row('Driver name', driver),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('Share this OTP', style: RescueTheme.label, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: otp.split('').map((d) {
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 52,
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: RescueTheme.accent, width: 2),
                  ),
                  child: Text(
                    d,
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: RescueTheme.accent,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: otp));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('OTP copied')));
              },
              icon: const Icon(Icons.copy, color: RescueTheme.accent),
              label: Text('Copy OTP', style: TextStyle(color: RescueTheme.accent)),
            ),
          ],
        ),
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: () {
            ref.read(rescueBookingProvider.notifier).setHandoverCompleted(true);
            context.go(AppRoutes.rescueJourneyHub);
          },
          child: const Text('Verified — Continue'),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: RescueTheme.body.copyWith(fontSize: 13)),
        Text(value, style: RescueTheme.label),
      ],
    );
  }
}
