import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:ionicons/ionicons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/widgets/draggable_active_ride_banner.dart';
import '../../../../core/widgets/marketing_banner_carousel.dart';
import '../../../../core/providers/marketing_banners_provider.dart';
import '../../../../core/models/marketing_banner.dart';
import '../../../../core/widgets/schedule_ride_sheet.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/nearby_places_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../../core/services/app_language_service.dart';
import '../../../../core/providers/service_catalog_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../rescue/providers/rescue_booking_provider.dart';
import '../../../ride/providers/ride_booking_provider.dart';
import '../../../ride/providers/ride_provider.dart';

class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  static const String _hubBackgroundAsset =
      'assets/images/services_hub_background.png';

  // ── Raahi palette ──
  static const _beige = Color(0xFFF6EFE4);
  /// Vertical gap below status bar before “Hi …” / Later row — avoids cramped header.
  static const _hubHeaderTopSpacing = 26.0;
  static const _accent = Color(0xFFD4956A);
  /// Profile avatar circle (greeting row, left of “Hi,”).
  static const _profileAvatarBg = Color(0xFFCF923D);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _muted = Color(0xFFB8AFA0);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);
  /// Design tokens (services hub refresh)
  static const _surfaceCard = Color(0xFFF5F5F5);
  static const _strokeMuted = Color(0xFFCBC6BB);
  static const _placesCardActive = Color(0xFFFFF8E4);
  static const _footerHeart = Color(0xFFFCD848);
  /// “Places near you” section background.
  static const _placesNearYouBg = Color(0xFF151513);

  // ── Service definitions (realtime - no static badges) ──
  static final _services = [
    _Svc(
        'cab_mini',
        'cab_mini',
        Icons.directions_car,
        const Color(0xFF2196F3),
        imagePath: 'assets/vehicles/cab_mini.png'),
    _Svc(
        'auto',
        'auto',
        Icons.electric_rickshaw,
        const Color(0xFF4CAF50),
        imagePath: 'assets/vehicles/auto.png',
        imagePadding: 2),
    _Svc(
        'bike_taxi',
        'bike_taxi',
        Icons.two_wheeler,
        _accent,
        imagePath: 'assets/vehicles/bike_taxi.png',
        imagePadding: 2),
    _Svc(
        'bike_rescue',
        'rescue',
        Icons.two_wheeler,
        _accent,
        imagePath: 'assets/vehicles/bike_rescue.png',
        showNewBadge: true),
    _Svc(
        'cab_xl',
        'cab_xl',
        Icons.airport_shuttle,
        const Color(0xFF7B1FA2),
        imagePath: 'assets/vehicles/cab_xl.png'),
    _Svc(
        'cab_premium',
        'premium',
        Icons.diamond,
        const Color(0xFFFF9800),
        imagePath: 'assets/vehicles/cab_premium.png'),
  ];

  // ── Action cards (footer: Get Rescued, Hire a Driver, Plan a Trip) ──
  static final _actionCards = [
    _ActionCard('get_rescued', Icons.two_wheeler, 'bike_rescue',
        imagePath: 'assets/images/rescued.png'),
    _ActionCard('hire_driver', Icons.person, 'personal_driver',
        imagePath: 'assets/images/hire.png'),
    _ActionCard('plan_trip', Icons.route, 'cab_mini',
        imagePath: 'assets/images/plan.png'),
  ];

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  // Schedule state
  DateTime? _scheduledTime;
  bool get _isScheduled => _scheduledTime != null;

  bool _restoringParkedScheduled = false;

  @override
  void initState() {
    super.initState();
    _fetchRealtimeLocationAndPlaces();
  }

  /// If a scheduled ride was parked aside for an instant booking that has
  /// since finished (or was abandoned), bring it back so its banner and
  /// polling resume. Safe to call repeatedly — no-ops while a booking exists.
  void _maybeRestoreParkedScheduledRide() {
    if (_restoringParkedScheduled) return;
    if (ref.read(rideBookingProvider).hasActiveRideId) return;
    _restoringParkedScheduled = true;
    Future.microtask(() async {
      try {
        await ref
            .read(rideBookingProvider.notifier)
            .restoreParkedScheduledRide();
      } finally {
        _restoringParkedScheduled = false;
      }
    });
  }

  /// Fetch current device location (realtime) and set pickup + nearby places
  Future<void> _fetchRealtimeLocationAndPlaces() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (!mounted) return;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!mounted) return;
      if (permission == LocationPermission.deniedForever) return;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 5),
      );
      if (!mounted) return;

      final latLng = LatLng(position.latitude, position.longitude);

      final langCode = ref.read(settingsProvider).languageCode;
      String address = trWithCode('current_location', langCode);
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (!mounted) return;
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          address = [
            p.street,
            p.subLocality,
            p.locality,
          ].where((s) => s != null && s.isNotEmpty).join(', ');
          if (address.isEmpty)
            address = '${p.administrativeArea ?? ''} ${p.country ?? ''}'.trim();
          if (address.isEmpty) {
            address = trWithCode('current_location', langCode);
          }
        }
      } catch (_) {}

      if (!mounted) return;
      ref.read(rideBookingProvider.notifier).setPickupLocation(address, latLng);
      if (!mounted) return;
      await ref.read(nearbyPlacesProvider.notifier).refresh();
    } catch (_) {
      if (!mounted) return;
      await ref.read(nearbyPlacesProvider.notifier).refresh();
    }
  }

  String _scheduleChipText(BuildContext context) {
    if (_scheduledTime == null) return ref.tr('schedule_chip_later');
    final locale = Localizations.localeOf(context);
    final locId = locale.toString();
    final now = DateTime.now();
    final scheduled = _scheduledTime!;
    final timeStr = DateFormat.jm(locId).format(scheduled);

    if (scheduled.day == now.day &&
        scheduled.month == now.month &&
        scheduled.year == now.year) {
      return timeStr;
    }
    final tomorrow = now.add(const Duration(days: 1));
    if (scheduled.day == tomorrow.day &&
        scheduled.month == tomorrow.month &&
        scheduled.year == tomorrow.year) {
      return ref.tr('tomorrow_comma_time').replaceAll('{time}', timeStr);
    }
    return '${DateFormat.yMMMd(locId).format(scheduled)}, $timeStr';
  }

  void _showSchedulePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ScheduleRidePickerSheet(
        currentSchedule: _scheduledTime,
        accentColor: ServicesScreen._accent,
        onConfirm: (DateTime selected) {
          if (mounted) {
            setState(() => _scheduledTime = selected);
          }
          Navigator.pop(ctx);
        },
      ),
    );
  }

  ({IconData icon, Color color}) _placeIconForName(String name) {
    const defaultIcon = (icon: Icons.place, color: Color(0xFF8B7355));
    final lower = name.toLowerCase();
    if (lower.contains('mall') ||
        lower.contains('shop') ||
        lower.contains('market'))
      return (icon: Icons.shopping_bag, color: const Color(0xFF6B8E7F));
    if (lower.contains('hospital') || lower.contains('clinic'))
      return (icon: Icons.local_hospital, color: const Color(0xFFE57373));
    if (lower.contains('restaurant') ||
        lower.contains('cafe') ||
        lower.contains('food'))
      return (icon: Icons.restaurant, color: const Color(0xFF9B7E5E));
    if (lower.contains('park') || lower.contains('garden'))
      return (icon: Icons.park, color: const Color(0xFF4CAF50));
    if (lower.contains('temple') ||
        lower.contains('mosque') ||
        lower.contains('church') ||
        lower.contains('monument'))
      return (icon: Icons.account_balance, color: const Color(0xFF8B7355));
    return defaultIcon;
  }

  // Services that are not yet available.
  // Personal Driver ("Hire a Driver") is now live: it's dispatched to
  // independent drivers and surfaces via calculate-all / vehicleType
  // "personal_driver" in the Find Trip flow.
  static const _comingSoonServices = <String>{};

  void _navigateToRescueFlow() {
    ref.read(rescueBookingProvider.notifier).reset();
    ref.read(rescueBookingProvider.notifier).prefillFromRideBooking();
    ref.read(rescueBookingProvider.notifier).setVehicleWithYou(true);
    context.push(AppRoutes.rescueLanding);
  }

  /// Backend catalog + local fallback: a service is "coming soon" if the static
  /// set says so, or the backend rollout marks it coming_soon for this city.
  bool _isServiceComingSoon(String serviceType) {
    if (_comingSoonServices.contains(serviceType)) return true;
    final catalog = ref.read(serviceCatalogValueProvider);
    return catalog?.isComingSoon(serviceType) ?? false;
  }

  /// Grid services, filtered/ordered by the backend catalog when available.
  /// Falls back to the full static list if the catalog is missing, so the hub
  /// never breaks. Unknown ids stay visible (fail-open).
  List<_Svc> _resolveGridServices() {
    final catalog = ref.watch(serviceCatalogValueProvider);
    if (catalog == null || catalog.isEmpty) {
      return ServicesScreen._services;
    }

    final visible = ServicesScreen._services
        .where((s) => catalog.isVisible(s.id))
        .toList();

    visible.sort((a, b) {
      final ai = catalog.itemFor(a.id)?.sortOrder ??
          ServicesScreen._services.indexOf(a);
      final bi = catalog.itemFor(b.id)?.sortOrder ??
          ServicesScreen._services.indexOf(b);
      return ai.compareTo(bi);
    });

    // Never render an empty grid — fall back to the static list.
    return visible.isEmpty ? ServicesScreen._services : visible;
  }

  Future<void> _navigateToFindTrip({String serviceType = 'cab_mini'}) async {
    if (_isServiceComingSoon(serviceType)) {
      _showComingSoonDialog(serviceType);
      return;
    }

    // Check if there's an active ride - redirect to appropriate screen
    final activeRideState = ref.read(activeRideProvider);
    final bookingState = ref.read(rideBookingProvider);

    if (activeRideState.hasActiveRide) {
      context.push(AppRoutes.driverAssigned);
      return;
    }

    if (bookingState.rideId != null && bookingState.rideId!.isNotEmpty) {
      if (bookingState.isScheduledRide) {
        // A ride scheduled for later shouldn't block booking a cab right now.
        // Park it aside (it stays booked on the backend and is restored once
        // this booking finishes) and continue into the create-ride flow.
        await ref.read(rideBookingProvider.notifier).parkScheduledRide();
        if (!mounted) return;
      } else {
        context.push(AppRoutes.searchingDrivers);
        return;
      }
    }

    String route =
        '${AppRoutes.findTrip}?autoSearch=true&serviceType=$serviceType';
    if (_scheduledTime != null) {
      route += '&scheduledTime=${_scheduledTime!.toIso8601String()}';
    }
    context.push(route);
  }

  Future<void> _onMarketingBannerTap(MarketingBanner banner) async {
    final link = banner.linkUrl?.trim();
    if (link != null && link.isNotEmpty) {
      final uri = Uri.tryParse(link);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    _navigateToFindTrip();
  }

  void _showComingSoonDialog(String serviceType) {
    final matched =
        ServicesScreen._services.where((s) => s.id == serviceType);
    final serviceName =
        matched.isEmpty ? serviceType : ref.tr(matched.first.titleKey);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: ServicesScreen._accent.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.rocket_launch_rounded,
                  size: 36, color: ServicesScreen._accent),
            ),
            const SizedBox(height: 20),
            Text(
              ref.tr('service_coming_soon').replaceAll('{service}', serviceName),
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: ServicesScreen._textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              ref
                  .tr('service_coming_desc')
                  .replaceAll('{service}', serviceName),
              style: const TextStyle(
                  fontSize: 14,
                  color: ServicesScreen._textSecondary,
                  height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ServicesScreen._accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                  elevation: 0,
                ),
                child: Text(ref.tr('got_it'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Primary destination entry (pickup is set elsewhere; opens Find Trip like before).
  Widget _buildWhereToBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () => _navigateToFindTrip(),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ServicesScreen._strokeMuted),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            ref.tr('where_to'),
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.45,
              height: 1.2,
              color: ServicesScreen._textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// Recent shortcut only when history exists (outline clock + title + subtitle).
  Widget _buildRecentLocationRow() {
    final savedLocations = ref.watch(savedLocationsProvider);
    final recentLocations = savedLocations.recentLocations;
    if (recentLocations.isEmpty) return const SizedBox.shrink();

    const clockOutline = Color(0xFFB8956A);
    final mostRecent = recentLocations.first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: GestureDetector(
        onTap: () {
          ref.read(rideBookingProvider.notifier).setDestinationLocation(
                mostRecent.address,
                mostRecent.latLng,
              );
          _navigateToFindTrip();
        },
        behavior: HitTestBehavior.opaque,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: clockOutline, width: 1.5),
              ),
              child: Icon(
                Ionicons.time_outline,
                color: clockOutline,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mostRecent.name,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: ServicesScreen._textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mostRecent.address,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: ServicesScreen._textSecondary,
                      height: 1.25,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch so returning here after the instant ride finishes re-runs restore.
    ref.watch(rideBookingProvider.select((s) => s.hasActiveRideId));
    _maybeRestoreParkedScheduledRide();

    final user = ref.watch(currentUserProvider);
    final langCode = ref.watch(settingsProvider).languageCode;
    final gridServices = _resolveGridServices();
    // Never show email as greeting — use name, or last 4 digits of phone, or localized User
    final rawName = user?.name;
    final hasRealName = rawName != null && rawName.isNotEmpty && rawName != 'User';
    String displayName;
    if (hasRealName) {
      displayName =
          AppLanguageService.transliterateName(rawName!, langCode);
    } else if (user?.phone != null && user!.phone!.isNotEmpty) {
      final digits = user.phone!.replaceAll(RegExp(r'[^\d]'), '');
      displayName = digits.length >= 4
          ? trWithCode('user_phone_suffix', langCode)
              .replaceAll('{digits}', digits.substring(digits.length - 4))
          : trWithCode('user', langCode);
    } else {
      displayName = trWithCode('user', langCode);
    }
    final firstName = displayName.split(' ').first;
    final initial = firstName.isNotEmpty ? firstName[0].toUpperCase() : 'U';

    return Scaffold(
      backgroundColor: ServicesScreen._beige,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Image.asset(
              ServicesScreen._hubBackgroundAsset,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (context, error, stackTrace) =>
                  const ColoredBox(color: ServicesScreen._beige),
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _fetchRealtimeLocationAndPlaces,
                  color: ServicesScreen._accent,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics()),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                            height: ServicesScreen._hubHeaderTopSpacing),

                    // ── Top bar: profile + "Hi, Name!" + schedule (no back) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => context.push(AppRoutes.profile),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                color: ServicesScreen._profileAvatarBg,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    fontFamily: 'Poppins',
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              ref
                                  .tr('hi_user')
                                  .replaceAll('{name}', firstName),
                              style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: ServicesScreen._textPrimary,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              if (_scheduledTime != null) {
                                _showSchedulePicker();
                              } else {
                                context.push(
                                  '${AppRoutes.findTrip}?autoSearch=true&scheduleAfterLocations=true',
                                );
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: ServicesScreen._inputBg,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Ionicons.time_outline,
                                    size: 17,
                                    color: ServicesScreen._textSecondary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _scheduleChipText(context),
                                    style: const TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: ServicesScreen._textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(Icons.keyboard_arrow_down_rounded,
                                      size: 18,
                                      color: ServicesScreen._textSecondary),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Where to? + optional recent shortcut (no pickup / home on hub) ──
                    _buildWhereToBar(),
                    _buildRecentLocationRow(),
                    const SizedBox(height: 20),

                    // ── Vehicle type grid (Cab Mini, Auto, Cab XL, Rescue, Premium, Driver Rental) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.92,
                        ),
                        itemCount: gridServices.length,
                        itemBuilder: (ctx, i) {
                          final s = gridServices[i];
                          return _ServiceCard(
                            title: ref.tr(s.titleKey),
                            svc: s,
                            onTap: () =>
                                _navigateToFindTrip(serviceType: s.id),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Marketing banners (backend carousel, 320×120 slot) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Consumer(
                        builder: (context, ref, _) {
                          final bannersAsync =
                              ref.watch(homeMarketingBannersProvider);
                          return bannersAsync.when(
                            data: (banners) {
                              if (banners.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return MarketingBannerCarousel(
                                banners: banners,
                                onBannerTap: _onMarketingBannerTap,
                              );
                            },
                            loading: () => const SizedBox(
                              height: kMarketingBannerHeight,
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            ),
                            error: (_, __) => const SizedBox.shrink(),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Places near you (realtime from device location) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                        decoration: BoxDecoration(
                          color: ServicesScreen._placesNearYouBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 220),
                                    child: Text(
                                      ref.tr('places_near_you'),
                                      style: const TextStyle(
                                        fontFamily: 'Poppins',
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      maxLines: 2,
                                      softWrap: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () {
                                    ref
                                        .read(nearbyPlacesProvider.notifier)
                                        .refresh();
                                    _navigateToFindTrip();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      '${ref.tr('create_trip')} →',
                                      style: const TextStyle(
                                        fontFamily: 'Poppins',
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Consumer(
                              builder: (ctx, ref, _) {
                                final nearbyState =
                                    ref.watch(nearbyPlacesProvider);
                                if (nearbyState.isLoading &&
                                    nearbyState.places.isEmpty) {
                                  return SizedBox(
                                    height: 158,
                                    child: UberShimmer(
                                      baseColor: Colors.white24,
                                      highlightColor: Colors.white38,
                                      child: ListView(
                                        scrollDirection: Axis.horizontal,
                                        children: List.generate(
                                          3,
                                          (_) => Padding(
                                            padding: const EdgeInsets.only(
                                                right: 12),
                                            child: Column(
                                              children: [
                                                Container(
                                                  width: 120,
                                                  padding: const EdgeInsets.all(
                                                      8),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            24),
                                                    border: Border.all(
                                                      color: Colors.white24,
                                                    ),
                                                  ),
                                                  child: const Column(
                                                    children: [
                                                      UberShimmerBox(
                                                        width: double.infinity,
                                                        height: 75,
                                                        borderRadius:
                                                            BorderRadius.all(
                                                          Radius.circular(12),
                                                        ),
                                                      ),
                                                      SizedBox(height: 10),
                                                      UberShimmerBox(
                                                          width: 90, height: 12),
                                                      SizedBox(height: 6),
                                                      UberShimmerBox(
                                                          width: 70, height: 10),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                if (nearbyState.places.isEmpty) {
                                  return SizedBox(
                                    height: 100,
                                    child: Center(
                                      child: GestureDetector(
                                        onTap: () => ref
                                            .read(nearbyPlacesProvider.notifier)
                                            .refresh(),
                                        child: Text(
                                          ref.tr('tap_find_places'),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Colors.white,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                return SizedBox(
                                  height: 185,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: EdgeInsets.zero,
                                    itemCount: nearbyState.places.length,
                                    itemBuilder: (ctx, i) {
                                      final p = nearbyState.places[i];
                                      final icon = _placeIconForName(p.name);
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 12),
                                        child: Material(
                                          color: Colors.white,
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(24),
                                            side: const BorderSide(
                                              color:
                                                  ServicesScreen._strokeMuted,
                                            ),
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: InkWell(
                                            onTap: () {
                                              ref
                                                  .read(rideBookingProvider
                                                      .notifier)
                                                  .setDestinationLocation(
                                                      p.address, p.latLng);
                                              _navigateToFindTrip();
                                            },
                                            splashColor: ServicesScreen
                                                ._placesCardActive
                                                .withOpacity(0.65),
                                            highlightColor: ServicesScreen
                                                ._placesCardActive
                                                .withOpacity(0.45),
                                            borderRadius:
                                                BorderRadius.circular(24),
                                            child: SizedBox(
                                              width: 120,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.all(8),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Expanded(
                                                      child: ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                                12),
                                                        child: SizedBox(
                                                          width: double.infinity,
                                                        child: p.photoUrl != null
                                                            ? CachedNetworkImage(
                                                                imageUrl:
                                                                    p.photoUrl!,
                                                                fit: BoxFit
                                                                    .cover,
                                                                placeholder:
                                                                    (context,
                                                                            url) =>
                                                                        UberShimmer(
                                                                  child:
                                                                      const UberShimmerBox(
                                                                    width: double
                                                                        .infinity,
                                                                    height: double
                                                                        .infinity,
                                                                    borderRadius:
                                                                        BorderRadius
                                                                            .zero,
                                                                  ),
                                                                ),
                                                                errorWidget:
                                                                    (context,
                                                                            url,
                                                                            error) =>
                                                                        Container(
                                                                  color: icon
                                                                      .color
                                                                      .withOpacity(
                                                                          0.2),
                                                                  child: Center(
                                                                      child: Icon(
                                                                          icon
                                                                              .icon,
                                                                          size:
                                                                              36,
                                                                          color:
                                                                              icon.color)),
                                                                ),
                                                              )
                                                            : Container(
                                                                color: icon
                                                                    .color
                                                                    .withOpacity(
                                                                        0.2),
                                                                child: Center(
                                                                    child: Icon(
                                                                        icon
                                                                            .icon,
                                                                        size:
                                                                            36,
                                                                        color: icon
                                                                            .color)),
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                    Padding(
                                                      padding: const EdgeInsets
                                                          .fromLTRB(
                                                          4, 6, 4, 0),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            p.name,
                                                            style:
                                                                const TextStyle(
                                                              fontFamily:
                                                                  'Poppins',
                                                              fontSize: 13,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: ServicesScreen
                                                                  ._textPrimary,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          Text(
                                                            p.timeText,
                                                            style:
                                                                const TextStyle(
                                                              fontFamily:
                                                                  'Poppins',
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w400,
                                                              color: ServicesScreen
                                                                  ._textSecondary,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Action cards: Get Rescued, Hire a Driver, Plan a Trip ──
                    SizedBox(
                      height: 200,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: ServicesScreen._actionCards.length,
                        itemBuilder: (ctx, i) {
                          final a = ServicesScreen._actionCards[i];
                          final title = ref.tr(a.titleKey);
                          return Padding(
                            padding: const EdgeInsets.only(right: 15),
                            child: GestureDetector(
                              onTap: () {
                                if (a.serviceType == 'bike_rescue') {
                                  _navigateToRescueFlow();
                                } else {
                                  _navigateToFindTrip(serviceType: a.serviceType);
                                }
                              },
                              child: Container(
                                width: 140,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.16),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: a.imagePath != null
                                            ? Image.asset(
                                                a.imagePath!,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                color: Colors.black,
                                              ),
                                      ),
                                      Positioned.fill(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.transparent,
                                                Colors.transparent,
                                                Colors.black.withOpacity(0.7),
                                              ],
                                              stops: const [0.0, 0.4, 1.0],
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        left: 8,
                                        right: 8,
                                        bottom: 14,
                                        child: Text(
                                          title,
                                          style: const TextStyle(
                                            fontFamily: 'Poppins',
                                            fontSize: 17,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                            height: 1.2,
                                          ),
                                          textAlign: TextAlign.center,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Footer ──
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 100),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${ref.tr('curated_india')} ',
                              style: TextStyle(
                                fontFamily: 'Poppins',
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: ServicesScreen._muted,
                              ),
                            ),
                            Icon(
                              Icons.favorite,
                              size: 14,
                              color: ServicesScreen._footerHeart,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned.fill(
              child: DraggableActiveRideBanner(),
            ),
          ],
        ),
      ),
        ],
      ),
    );
  }
}

// ── Service helper ──
class _Svc {
  final String id;
  /// Key for [AppStrings] / [ref.tr] (e.g. `cab_mini`, `rescue`).
  final String titleKey;
  final IconData icon;
  final Color color;
  final String badge;
  final String? imagePath;
  final bool showNewBadge;
  final double imagePadding;
  const _Svc(this.id, this.titleKey, this.icon, this.color,
      {this.badge = '',
      this.imagePath,
      this.showNewBadge = false,
      this.imagePadding = 6});
}

// ── Action card ──
class _ActionCard {
  final String titleKey;
  final IconData icon;
  final String serviceType;
  final String? imagePath;
  const _ActionCard(this.titleKey, this.icon, this.serviceType,
      {this.imagePath});
}

// ── Service card (grid item) ──
class _ServiceCard extends StatelessWidget {
  /// Figma service tile image frame (~108×90).
  static const _tileAspectRatio = 108.63 / 90.08;

  final String title;
  final _Svc svc;
  final VoidCallback onTap;
  const _ServiceCard(
      {super.key, required this.title, required this.svc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: _tileAspectRatio,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: ServicesScreen._surfaceCard,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: EdgeInsets.all(svc.imagePadding),
                      child: svc.imagePath != null
                          ? Image.asset(
                              svc.imagePath!,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(svc.icon, color: svc.color, size: 48),
                            )
                          : Icon(svc.icon, color: svc.color, size: 48),
                    ),
                  ),
                ),
                if (svc.showNewBadge)
                  const Positioned(
                    top: 6.89,
                    right: 5.6,
                    child: _ServiceNewBadge(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ServicesScreen._textPrimary,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Figma Frame 1410081702 — red "NEW!" pill on Rescue tile.
class _ServiceNewBadge extends StatelessWidget {
  const _ServiceNewBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 31.21,
      height: 13.15,
      padding: const EdgeInsets.symmetric(horizontal: 5.60348, vertical: 1.07531),
      decoration: BoxDecoration(
        color: const Color(0xFFB72F2F),
        borderRadius: BorderRadius.circular(11.7968),
      ),
      alignment: Alignment.center,
      child: const Text(
        'NEW!',
        style: TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w500,
          fontSize: 7.41848,
          height: 11 / 7.41848,
          color: Colors.white,
        ),
      ),
    );
  }
}
