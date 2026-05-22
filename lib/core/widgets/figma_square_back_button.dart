import 'package:flutter/material.dart';

/// Figma *arrow-square-left*: ~22×22 rounded square [#292D32], white chevron.
class FigmaSquareBackButton extends StatelessWidget {
  const FigmaSquareBackButton({
    super.key,
    required this.onPressed,
    this.minTapSize = 36,
  });

  final VoidCallback onPressed;

  /// Touch target; the painted control stays [_controlSize]² and is centered.
  final double minTapSize;

  static const Color _fill = Color(0xFF292D32);
  static const double _controlSize = 22;

  @override
  Widget build(BuildContext context) {
    final icon = Container(
      width: _controlSize,
      height: _controlSize,
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(5.5),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.chevron_left_rounded,
        color: Colors.white,
        size: 16,
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
          // Leading-align the painted square so it lines up with padded content
          // (centering made the 22× glyph sit ~7px inset from the row’s start).
          child: Align(
            alignment: Alignment.centerLeft,
            child: icon,
          ),
        ),
      ),
    );
  }
}
