/// Backend-driven service availability catalog.
///
/// Drives per-city visibility/ordering of the services hub without an app
/// rebuild. The app keeps its own visual metadata (icons, artwork, localized
/// titles) keyed by [id]; the backend only decides whether a service is
/// `live` / `coming_soon` / `disabled` and in what order it appears.
enum ServiceStatus { live, comingSoon, disabled, unknown }

ServiceStatus serviceStatusFromString(String? raw) {
  switch ((raw ?? '').toLowerCase().trim()) {
    case 'live':
      return ServiceStatus.live;
    case 'coming_soon':
      return ServiceStatus.comingSoon;
    case 'disabled':
      return ServiceStatus.disabled;
    default:
      return ServiceStatus.unknown;
  }
}

class ServiceCatalogItem {
  final String id;
  final ServiceStatus status;
  final int sortOrder;
  final String? blockedReason;
  final bool showOnHome;
  final bool showInBooking;

  const ServiceCatalogItem({
    required this.id,
    required this.status,
    this.sortOrder = 0,
    this.blockedReason,
    this.showOnHome = true,
    this.showInBooking = true,
  });

  factory ServiceCatalogItem.fromJson(Map<String, dynamic> json) {
    return ServiceCatalogItem(
      id: (json['id'] ?? '').toString(),
      status: serviceStatusFromString(json['status']?.toString()),
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      blockedReason: json['blockedReason']?.toString(),
      showOnHome: json['showOnHome'] as bool? ?? true,
      showInBooking: json['showInBooking'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': switch (status) {
          ServiceStatus.live => 'live',
          ServiceStatus.comingSoon => 'coming_soon',
          ServiceStatus.disabled => 'disabled',
          ServiceStatus.unknown => 'unknown',
        },
        'sortOrder': sortOrder,
        if (blockedReason != null) 'blockedReason': blockedReason,
        'showOnHome': showOnHome,
        'showInBooking': showInBooking,
      };
}

class ServiceCatalog {
  final String city;
  final List<ServiceCatalogItem> services;
  final int version;

  const ServiceCatalog({
    required this.city,
    required this.services,
    this.version = 1,
  });

  factory ServiceCatalog.fromJson(Map<String, dynamic> json) {
    final rawServices = json['services'];
    final list = <ServiceCatalogItem>[];
    if (rawServices is List) {
      for (final e in rawServices) {
        if (e is Map) {
          list.add(ServiceCatalogItem.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return ServiceCatalog(
      city: (json['city'] ?? '').toString(),
      services: list,
      version: (json['version'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'city': city,
        'services': services.map((s) => s.toJson()).toList(),
        'version': version,
      };

  ServiceCatalogItem? itemFor(String id) {
    for (final s in services) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Status for [id]. Unknown ids default to [ServiceStatus.live] so a service
  /// the backend doesn't know about is never hidden (fail-open).
  ServiceStatus statusFor(String id) => itemFor(id)?.status ?? ServiceStatus.live;

  bool isVisible(String id) => statusFor(id) != ServiceStatus.disabled;

  bool isComingSoon(String id) => statusFor(id) == ServiceStatus.comingSoon;

  bool get isEmpty => services.isEmpty;
}
