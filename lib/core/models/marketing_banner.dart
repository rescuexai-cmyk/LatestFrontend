import '../config/app_config.dart';

/// Marketing carousel banner from `GET /api/banners/active`.
class MarketingBanner {
  final String id;
  final String title;
  final String imageUrl;
  final String? linkUrl;
  final String placement;
  final int sortOrder;
  final double width;
  final double height;

  const MarketingBanner({
    required this.id,
    required this.title,
    required this.imageUrl,
    this.linkUrl,
    this.placement = 'HOME',
    this.sortOrder = 0,
    this.width = 320,
    this.height = 120,
  });

  factory MarketingBanner.fromJson(Map<String, dynamic> json) {
    double toDouble(dynamic v, double fallback) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? fallback;
    }

    return MarketingBanner(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      imageUrl: (json['imageUrl'] ?? '').toString(),
      linkUrl: json['linkUrl']?.toString(),
      placement: (json['placement'] ?? 'HOME').toString(),
      sortOrder: json['sortOrder'] is int
          ? json['sortOrder'] as int
          : int.tryParse(json['sortOrder']?.toString() ?? '') ?? 0,
      width: toDouble(json['width'], 320),
      height: toDouble(json['height'], 120),
    );
  }

  /// Absolute URL for [CachedNetworkImage] (S3/CloudFront or gateway uploads).
  String get resolvedImageUrl => resolveBannerImageUrl(imageUrl);

  /// App-facing image URL — proxied via API so private S3 objects load correctly.
  String get displayImageUrl {
    if (id.isNotEmpty) {
      return resolveBannerImageUrl('/api/banners/image/$id');
    }
    return resolvedImageUrl;
  }
}

/// Backend slot size for home carousels (matches admin upload validation).
const double kMarketingBannerWidth = 320;
const double kMarketingBannerHeight = 120;

String resolveBannerImageUrl(String imageUrl) {
  final trimmed = imageUrl.trim();
  if (trimmed.isEmpty) return trimmed;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }

  var base = AppConfig.apiUrl.trim();
  if (base.endsWith('/')) base = base.substring(0, base.length - 1);
  if (trimmed.startsWith('/')) return '$base$trimmed';
  return '$base/$trimmed';
}
