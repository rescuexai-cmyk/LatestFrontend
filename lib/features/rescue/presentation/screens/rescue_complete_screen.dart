import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

/// Figma screen 11 — Rating & complete.
class RescueCompleteScreen extends ConsumerStatefulWidget {
  const RescueCompleteScreen({super.key});

  @override
  ConsumerState<RescueCompleteScreen> createState() =>
      _RescueCompleteScreenState();
}

class _RescueCompleteScreenState extends ConsumerState<RescueCompleteScreen> {
  int _riderRating = 5;
  int _vehicleDriverRating = 5;
  int _supportRating = 5;
  bool _problemSolved = true;
  final _feedbackController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await ref.read(rescueBookingProvider.notifier).submitRating(
            RescueRatingInput(
              riderRating: _riderRating,
              vehicleDriverRating: _vehicleDriverRating,
              supportRating: _supportRating,
              problemSolved: _problemSolved,
              feedback: _feedbackController.text.trim(),
            ),
          );
      ref.read(rescueBookingProvider.notifier).reset();
      if (!mounted) return;
      context.go(AppRoutes.home);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVehicle = ref.watch(rescueBookingProvider).hasVehicle;

    return RescueScaffold(
      title: 'Rescue completed!',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: RescueTheme.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, size: 44, color: RescueTheme.success),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Thank you for using Raahi Rescue',
            textAlign: TextAlign.center,
            style: RescueTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          Text('Was your problem solved?', style: RescueTheme.label),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _solvedChip('Yes', _problemSolved, () => setState(() => _problemSolved = true)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _solvedChip('No', !_problemSolved, () => setState(() => _problemSolved = false)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _RatingBlock(
            title: 'Rider',
            value: _riderRating,
            onChanged: (v) => setState(() => _riderRating = v),
          ),
          if (hasVehicle) ...[
            const SizedBox(height: 12),
            _RatingBlock(
              title: 'Vehicle driver',
              value: _vehicleDriverRating,
              onChanged: (v) => setState(() => _vehicleDriverRating = v),
            ),
          ],
          const SizedBox(height: 12),
          _RatingBlock(
            title: 'Support',
            value: _supportRating,
            onChanged: (v) => setState(() => _supportRating = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _feedbackController,
            maxLines: 2,
            decoration: RescueTheme.fieldDecoration('Optional feedback'),
            style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
          ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Submit'),
        ),
      ),
    );
  }

  Widget _solvedChip(String label, bool on, VoidCallback tap) {
    return Material(
      color: on ? RescueTheme.accent.withValues(alpha: 0.15) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? RescueTheme.accent : RescueTheme.stroke),
          ),
          child: Text(label, style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _RatingBlock extends StatelessWidget {
  const _RatingBlock({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return RescueCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: RescueTheme.label),
          Row(
            children: List.generate(5, (i) {
              final star = i + 1;
              return IconButton(
                padding: EdgeInsets.zero,
                onPressed: () => onChanged(star),
                icon: Icon(
                  star <= value ? Icons.star : Icons.star_border,
                  color: RescueTheme.accent,
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
