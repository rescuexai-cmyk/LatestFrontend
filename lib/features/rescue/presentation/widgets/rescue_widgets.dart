import 'package:flutter/material.dart';
import 'package:ride_hailing_flutter/core/widgets/figma_square_back_button.dart';
import '../../rescue_theme.dart';

class RescueScaffold extends StatelessWidget {
  const RescueScaffold({
    super.key,
    required this.title,
    required this.body,
    this.bottom,
    this.onBack,
    this.showBack = true,
  });

  final String title;
  final Widget body;
  final Widget? bottom;
  final VoidCallback? onBack;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RescueTheme.screenBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  if (showBack)
                    FigmaSquareBackButton(
                      onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                    ),
                  if (showBack) const SizedBox(width: 8),
                  Expanded(
                    child: Text(title, style: RescueTheme.titleMedium),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
            if (bottom != null) bottom!,
          ],
        ),
      ),
    );
  }
}

class RescueCard extends StatelessWidget {
  const RescueCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RescueTheme.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: child,
    );
  }
}

class RescueFareRow extends StatelessWidget {
  const RescueFareRow({
    super.key,
    required this.label,
    required this.amount,
    this.muted = false,
    this.bold = false,
  });

  final String label;
  final double amount;
  final bool muted;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? RescueTheme.price.copyWith(fontSize: 18, fontWeight: FontWeight.w700)
        : RescueTheme.body.copyWith(
            color: muted ? RescueTheme.textMuted : RescueTheme.textSecondary,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text('₹${amount.toStringAsFixed(0)}', style: style),
        ],
      ),
    );
  }
}

class RescueStaticBadge extends StatelessWidget {
  const RescueStaticBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: RescueTheme.panelBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Estimate',
        style: RescueTheme.label.copyWith(
          fontSize: 11,
          color: RescueTheme.textMuted,
        ),
      ),
    );
  }
}

String rescueStatusLabel(String status) {
  switch (status) {
    case 'PENDING':
      return 'Finding rescue drivers…';
    case 'DRIVER1_ACCEPTED':
      return 'First driver assigned — matching second driver…';
    case 'BOTH_ACCEPTED':
      return 'Both drivers assigned';
    case 'DRIVERS_EN_ROUTE':
      return 'Drivers are on the way';
    case 'DRIVERS_ARRIVED':
      return 'Drivers have arrived';
    case 'IN_PROGRESS':
      return 'Rescue in progress';
    case 'COMPLETED':
      return 'Rescue completed';
    case 'CANCELLED':
      return 'Rescue cancelled';
    default:
      return status.replaceAll('_', ' ').toLowerCase();
  }
}
