import 'package:flutter/material.dart';

class UpiAppIcon extends StatelessWidget {
  final String appName;
  final double size;

  const UpiAppIcon({
    super.key,
    required this.appName,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    final spec = _specFor(appName);

    // If spec has an image asset, show that instead of text mark
    if (spec.imagePath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.asset(
            spec.imagePath!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildTextIcon(spec),
          ),
        ),
      );
    }

    return _buildTextIcon(spec);
  }

  Widget _buildTextIcon(_UpiIconSpec spec) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: spec.background,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: spec.border),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          spec.mark,
          style: TextStyle(
            color: spec.foreground,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.42,
            letterSpacing: 0.2,
            height: 1,
          ),
        ),
      ),
    );
  }

  _UpiIconSpec _specFor(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('google') || lower.contains('gpay')) {
      return const _UpiIconSpec(
        mark: 'G',
        foreground: Color(0xFF1A73E8),
        background: Color(0xFFE8F0FE),
        border: Color(0xFFB3D0FF),
      );
    }
    if (lower.contains('phonepe')) {
      return const _UpiIconSpec(
        mark: 'P',
        foreground: Color(0xFF5F259F),
        background: Color(0xFFF1E9FF),
        border: Color(0xFFD8C2FF),
      );
    }
    if (lower.contains('paytm')) {
      return const _UpiIconSpec(
        mark: 'PT',
        foreground: Color(0xFF00A0E3),
        background: Color(0xFFE5F7FF),
        border: Color(0xFFBDEBFF),
      );
    }
    if (lower.contains('bhim')) {
      return const _UpiIconSpec(
        mark: 'B',
        foreground: Color(0xFF00695C),
        background: Color(0xFFE3F3F1),
        border: Color(0xFFB9E1DC),
      );
    }
    if (lower.contains('cred')) {
      return const _UpiIconSpec(
        mark: 'CRED',
        foreground: Color(0xFFFFFFFF),
        background: Color(0xFF1A1A1A),
        border: Color(0xFF1A1A1A),
        imagePath: 'assets/images/upi_cred.png',
      );
    }
    if (lower.contains('upi')) {
      return const _UpiIconSpec(
        mark: 'UPI',
        foreground: Color(0xFF2E7D32),
        background: Color(0xFFEAF7EB),
        border: Color(0xFFC4E8C7),
      );
    }
    return const _UpiIconSpec(
      mark: 'U',
      foreground: Color(0xFF1A1A1A),
      background: Color(0xFFF3F3F3),
      border: Color(0xFFD9D9D9),
    );
  }
}

class _UpiIconSpec {
  final String mark;
  final Color foreground;
  final Color background;
  final Color border;
  final String? imagePath;

  const _UpiIconSpec({
    required this.mark,
    required this.foreground,
    required this.background,
    required this.border,
    this.imagePath,
  });
}
