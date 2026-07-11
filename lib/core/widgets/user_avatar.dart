import 'package:flutter/material.dart';

import '../config/app_config.dart';

/// Circular avatar that prefers a network/local photo and falls back to initials.
class UserAvatar extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final TextStyle? textStyle;

  const UserAvatar({
    super.key,
    this.imageUrl,
    required this.name,
    this.radius = 20,
    this.backgroundColor,
    this.foregroundColor,
    this.textStyle,
  });

  static String initialsFor(String name, {String fallback = '?'}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return fallback;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2 &&
        parts.first.isNotEmpty &&
        parts.last.isNotEmpty) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }

  static String? resolveUrl(String? rawUrl) {
    if (rawUrl == null) return null;
    final input = rawUrl.trim();
    if (input.isEmpty) return null;

    final uri = Uri.tryParse(input);
    if (uri != null && uri.hasScheme) return input;

    final apiUri = Uri.tryParse(AppConfig.apiUrl);
    if (apiUri == null || !apiUri.hasScheme) return input;
    final origin = '${apiUri.scheme}://${apiUri.authority}';
    if (input.startsWith('/')) return '$origin$input';
    return '$origin/$input';
  }

  @override
  Widget build(BuildContext context) {
    final resolved = resolveUrl(imageUrl);
    final initials = initialsFor(name);
    final bg = backgroundColor ?? const Color(0xFFD4956A);
    final fg = foregroundColor ?? Colors.white;
    final size = radius * 2;

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: ClipOval(
        child: resolved == null
            ? _Initials(initials: initials, foreground: fg, textStyle: textStyle)
            : Image.network(
                resolved,
                key: ValueKey(resolved),
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _Initials(
                  initials: initials,
                  foreground: fg,
                  textStyle: textStyle,
                ),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return SizedBox(
                    width: size,
                    height: size,
                    child: Center(
                      child: SizedBox(
                        width: radius * 0.7,
                        height: radius * 0.7,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  final String initials;
  final Color foreground;
  final TextStyle? textStyle;

  const _Initials({
    required this.initials,
    required this.foreground,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initials.length > 2 ? initials.substring(0, 2) : initials,
        style: textStyle ??
            TextStyle(
              color: foreground,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
