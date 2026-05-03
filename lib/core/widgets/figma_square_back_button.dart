import 'package:flutter/material.dart';

/// Figma *arrow-square-left*: 24×24 rounded square [#292D32], white chevron.
class FigmaSquareBackButton extends StatelessWidget {
  const FigmaSquareBackButton({
    super.key,
    required this.onPressed,
    this.minTapSize = 40,
  });

  final VoidCallback onPressed;

  /// Touch target; the painted control stays 24×24 and is centered.
  final double minTapSize;

  static const Color _fill = Color(0xFF292D32);

  @override
  Widget build(BuildContext context) {
    // Chevron is symmetric vs. iOS back chevron, so it centers cleanly in 24×24.
    final icon = Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.chevron_left_rounded,
        color: Colors.white,
        size: 18,
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(minTapSize / 2),
        child: SizedBox(
          width: minTapSize,
          height: minTapSize,
          child: Center(child: icon),
        ),
      ),
    );
  }
}
