import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

class RescueReasonScreen extends ConsumerStatefulWidget {
  const RescueReasonScreen({super.key});

  @override
  ConsumerState<RescueReasonScreen> createState() => _RescueReasonScreenState();
}

class _RescueReasonScreenState extends ConsumerState<RescueReasonScreen> {
  final _otherController = TextEditingController();

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rescueBookingProvider);
    final selected = state.reason;

    return RescueScaffold(
      title: 'What\'s happening?',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Select the main reason for your rescue request',
            style: RescueTheme.body,
          ),
          const SizedBox(height: 16),
          ...RescueReason.values.map((reason) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RescueSelectTile(
                title: reason.label,
                selected: selected == reason,
                onTap: () {
                  ref.read(rescueBookingProvider.notifier).setReason(reason);
                  if (reason != RescueReason.other) _otherController.clear();
                },
              ),
            );
          }),
          if (selected == RescueReason.other) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _otherController,
              maxLines: 2,
              onChanged: (v) => ref
                  .read(rescueBookingProvider.notifier)
                  .setReason(RescueReason.other, note: v),
              decoration: RescueTheme.fieldDecoration('Tell us what happened'),
              style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
            ),
          ],
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: selected == null
              ? null
              : () => context.push(AppRoutes.rescueLocation),
          child: const Text('Continue'),
        ),
      ),
    );
  }
}
