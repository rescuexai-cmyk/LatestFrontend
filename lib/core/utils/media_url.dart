import '../config/app_config.dart';

/// Helpers for driver/rider document & avatar image URLs.
class MediaUrl {
  MediaUrl._();

  /// Absolute URL for relative `/uploads/...` paths.
  static String? resolve(String? rawUrl) {
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

  /// True when the URL is already signed (S3/CloudFront/query auth).
  /// Appending extra query params would invalidate the signature.
  static bool isSigned(String url) {
    final lower = url.toLowerCase();
    return lower.contains('x-amz-signature=') ||
        lower.contains('x-amz-credential=') ||
        lower.contains('x-amz-algorithm=') ||
        lower.contains('signature=') ||
        lower.contains('expires=') && lower.contains('awsaccesskeyid=');
  }

  /// Cache-bust only when safe. Prefer a [ValueKey] for signed URLs.
  static String withCacheBust(String url, int? bustMs) {
    if (bustMs == null || isSigned(url)) return url;
    final separator = url.contains('?') ? '&' : '?';
    return '$url${separator}v=$bustMs';
  }
}
