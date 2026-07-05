import 'package:flutter/material.dart';

import '../theme/primary_cta_styles.dart';

/// Full-width primary CTA — black, 60px tall, 16px corners.
class PrimaryCtaButton extends StatelessWidget {
  const PrimaryCtaButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.isLoading = false,
    this.useFilled = true,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool isLoading;
  final bool useFilled;

  @override
  Widget build(BuildContext context) {
    final child = isLoading
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Text(label);

    return SizedBox(
      width: double.infinity,
      height: PrimaryCtaStyles.height,
      child: useFilled
          ? FilledButton(
              onPressed: isLoading ? null : onPressed,
              style: PrimaryCtaStyles.filled(),
              child: child,
            )
          : ElevatedButton(
              onPressed: isLoading ? null : onPressed,
              style: PrimaryCtaStyles.elevated(),
              child: child,
            ),
    );
  }
}
