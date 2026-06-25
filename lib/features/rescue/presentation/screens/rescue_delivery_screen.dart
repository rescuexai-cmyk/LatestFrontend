import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

/// Figma screen 10 — Vehicle delivery verification.
class RescueDeliveryScreen extends ConsumerStatefulWidget {
  const RescueDeliveryScreen({super.key});

  @override
  ConsumerState<RescueDeliveryScreen> createState() =>
      _RescueDeliveryScreenState();
}

class _RescueDeliveryScreenState extends ConsumerState<RescueDeliveryScreen> {
  final _issueController = TextEditingController();

  @override
  void dispose() {
    _issueController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    await ref.read(rescueBookingProvider.notifier).confirmVehicleDelivery(
          accepted: true,
        );
    if (!mounted) return;
    context.go(AppRoutes.rescueComplete);
  }

  Future<void> _reportIssue() async {
    final issueText = _issueController.text.trim();
    await ref.read(rescueBookingProvider.notifier).confirmVehicleDelivery(
          accepted: false,
          issue: issueText.isNotEmpty ? issueText : 'Unspecified issue',
        );
    if (!mounted) return;
    context.go(AppRoutes.rescueComplete);
  }

  @override
  Widget build(BuildContext context) {
    final photos = ref.watch(rescueBookingProvider).vehicleDetails.photos;

    return RescueScaffold(
      title: 'Verify delivery',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Please check and confirm the vehicle condition.',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 16),
          Text('Pickup photos', style: RescueTheme.label),
          const SizedBox(height: 10),
          if (photos.isEmpty)
            Text('No photos on file', style: RescueTheme.body)
          else
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final e = photos.entries.elementAt(i);
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(e.value),
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 18),
          Text('Any damage or issues?', style: RescueTheme.label),
          const SizedBox(height: 8),
          TextField(
            controller: _issueController,
            maxLines: 3,
            decoration: RescueTheme.fieldDecoration('Describe any new damage…'),
            style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
          ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: RescueTheme.success,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _accept,
              child: const Text('Looks good, Accept'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _reportIssue,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade700),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Report an issue'),
            ),
          ],
        ),
      ),
    );
  }
}
