import 'package:flutter/material.dart';

/// Shared cream + gold mandala treatment used on hub / payment / sheets.
class RaahiMandalaBackground {
  RaahiMandalaBackground._();

  static const String asset = 'assets/images/services_hub_background.png';
  static const Color beige = Color(0xFFF6EFE4);
}

/// Fills its parent with the mandala artwork over cream, then paints [child].
class RaahiMandalaStack extends StatelessWidget {
  const RaahiMandalaStack({
    super.key,
    required this.child,
    this.borderRadius,
    this.expand = false,
  });

  final Widget child;
  final BorderRadius? borderRadius;

  /// When true (full screens), expand to fill parent constraints.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: expand ? StackFit.expand : StackFit.loose,
      children: [
        Positioned.fill(
          child: Image.asset(
            RaahiMandalaBackground.asset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (context, error, stackTrace) =>
                const ColoredBox(color: RaahiMandalaBackground.beige),
          ),
        ),
        child,
      ],
    );

    final painted = ColoredBox(
      color: RaahiMandalaBackground.beige,
      child: content,
    );

    if (borderRadius == null) return painted;

    return ClipRRect(
      borderRadius: borderRadius!,
      child: painted,
    );
  }
}
