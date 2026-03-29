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
import '../../../../core/router/app_routes.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../../core/widgets/schedule_ride_sheet.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/nearby_places_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../ride/providers/ride_booking_provider.dart';
import '../../../ride/providers/ride_provider.dart';

class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  static const String _hubBackgroundAsset =
      'assets/images/services_hub_background.png';

  // ── Raahi palette ──
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
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

  // ── Service definitions (realtime - no static badges) ──
  static final _services = [
    _Svc('cab_mini', 'Cab Mini', 'Compact cars', Icons.directions_car,
        const Color(0xFF2196F3),
        imagePath: 'assets/vehicles/cab_mini.png'),
    _Svc('auto', 'Auto', 'Budget-friendly', Icons.electric_rickshaw,
        const Color(0xFF4CAF50),
        imagePath: 'assets/vehicles/auto.png'),
    _Svc('cab_xl', 'Cab XL', 'Spacious SUVs', Icons.airport_shuttle,
        const Color(0xFF7B1FA2),
        imagePath: 'assets/vehicles/cab_xl.png'),
    _Svc('bike_rescue', 'Rescue', 'Quick pickup', Icons.two_wheeler, _accent,
        imagePath: 'assets/vehicles/bike_rescue.png'),
    // Swapped artwork for Premium and Driver Rental to match final design
    _Svc('cab_premium', 'Premium', 'Luxury rides', Icons.diamond,
        const Color(0xFFFF9800),
        imagePath: 'assets/vehicles/captain.png'),
    _Svc('personal_driver', 'Driver Rental', 'Hire a driver', Icons.person,
        const Color(0xFF455A64),
        imagePath: 'assets/vehicles/cab_premium.png'),
  ];

  // ── Action cards (footer: Get Rescued, Hire a Driver, Plan a Trip) ──
  static final _actionCards = [
    _ActionCard('Get Rescued', Icons.two_wheeler, 'bike_rescue',
        imagePath: 'assets/images/rescued.png'),
    _ActionCard('Hire a Driver', Icons.person, 'personal_driver',
        imagePath: 'assets/images/hire.png'),
    _ActionCard('Plan a Trip', Icons.route, 'cab_mini',
        imagePath: 'assets/images/plan.png'),
  ];

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  // Schedule state
  DateTime? _scheduledTime;
  bool get _isScheduled => _scheduledTime != null;

  @override
  void initState() {
    super.initState();
    _fetchRealtimeLocationAndPlaces();
  }

  /// Fetch current device location (realtime) and set pickup + nearby places
  Future<void> _fetchRealtimeLocationAndPlaces() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) return;

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 5),
      );
      final latLng = LatLng(position.latitude, position.longitude);

      String address = 'Current Location';
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          address = [
            p.street,
            p.subLocality,
            p.locality,
          ].where((s) => s != null && s.isNotEmpty).join(', ');
          if (address.isEmpty)
            address = '${p.administrativeArea ?? ''} ${p.country ?? ''}'.trim();
          if (address.isEmpty) address = 'Current Location';
        }
      } catch (_) {}

      if (mounted) {
        ref
            .read(rideBookingProvider.notifier)
            .setPickupLocation(address, latLng);
        await ref.read(nearbyPlacesProvider.notifier).refresh();
      }
    } catch (_) {
      if (mounted) await ref.read(nearbyPlacesProvider.notifier).refresh();
    }
  }

  String get _scheduleDisplayText {
    if (_scheduledTime == null) return 'Later';
    final now = DateTime.now();
    final scheduled = _scheduledTime!;

    // If today, show time only
    if (scheduled.day == now.day &&
        scheduled.month == now.month &&
        scheduled.year == now.year) {
      return DateFormat('h:mm a').format(scheduled);
    }
    // If tomorrow, show "Tomorrow, time"
    final tomorrow = now.add(const Duration(days: 1));
    if (scheduled.day == tomorrow.day &&
        scheduled.month == tomorrow.month &&
        scheduled.year == tomorrow.year) {
      return 'Tomorrow, ${DateFormat('h:mm a').format(scheduled)}';
    }
    // Otherwise show date and time
    return DateFormat('MMM d, h:mm a').format(scheduled);
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

  // Services that are not yet available
  static const _comingSoonServices = {
    'cab_xl',
    'cab_premium',
    'personal_driver'
  };

  void _navigateToFindTrip({String serviceType = 'bike_rescue'}) {
    // Show "Coming Soon" for services not yet launched
    if (_comingSoonServices.contains(serviceType)) {
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
      context.push(AppRoutes.searchingDrivers);
      return;
    }

    String route =
        '${AppRoutes.findTrip}?autoSearch=true&serviceType=$serviceType';
    if (_scheduledTime != null) {
      route += '&scheduledTime=${_scheduledTime!.toIso8601String()}';
    }
    context.push(route);
  }

  void _showComingSoonDialog(String serviceType) {
    final serviceName = ServicesScreen._services
            .where((s) => s.id == serviceType)
            .map((s) => s.name)
            .firstOrNull ??
        serviceType;

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
              '$serviceName is coming soon!',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: ServicesScreen._textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'We\'re working hard to bring $serviceName to your city. Stay tuned for updates!',
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
                child: const Text('Got it',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
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
              fontSize: 32,
              fontWeight: FontWeight.w500,
              color: ServicesScreen._textPrimary,
              height: 1.2,
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
    final user = ref.watch(currentUserProvider);
    final displayName = user?.name ?? user?.email ?? 'User';
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
                        const SizedBox(height: 12),

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
                                color: ServicesScreen._accent,
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
                              'Hi, $firstName!',
                              style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: ServicesScreen._textPrimary,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _showSchedulePicker,
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
                                    _scheduleDisplayText,
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
                          childAspectRatio: 0.85,
                        ),
                        itemCount: ServicesScreen._services.length,
                        itemBuilder: (ctx, i) => _ServiceCard(
                          svc: ServicesScreen._services[i],
                          onTap: () => _navigateToFindTrip(
                              serviceType: ServicesScreen._services[i].id),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Promotional banner (single design asset, 24px radius) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: GestureDetector(
                        onTap: () => _navigateToFindTrip(),
                        child: Container(
                          height: 160,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Image.asset(
                              'assets/images/cashback_banner.png',
                              fit: BoxFit.fill,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A1A1A),
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  alignment: Alignment.center,
                                  child: const Text(
                                    '30% Cashback',
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Places near you (realtime from device location) with black background container ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                        decoration: BoxDecoration(
                          color: Colors.black,
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
                                        child: const Text(
                                          'Tap to find places near you',
                                          style: TextStyle(
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
                          final titleParts = a.title.split(' ');
                          final firstLine = titleParts.length > 1 ? titleParts.sublist(0, titleParts.length - 1).join(' ') : '';
                          final lastWord = titleParts.isNotEmpty ? titleParts.last : a.title;
                          return Padding(
                            padding: const EdgeInsets.only(right: 15),
                            child: GestureDetector(
                              onTap: () => _navigateToFindTrip(
                                  serviceType: a.serviceType),
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
                                      // Full-bleed image background
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
                                      // Bottom gradient overlay
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
                                      // Title text at bottom center - two lines
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        bottom: 14,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.center,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (firstLine.isNotEmpty)
                                              Text(
                                                firstLine,
                                                style: const TextStyle(
                                                  fontFamily: 'Poppins',
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w400,
                                                  color: Colors.white,
                                                  height: 1.2,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            Text(
                                              lastWord,
                                              style: const TextStyle(
                                                fontFamily: 'Poppins',
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                                height: 1.2,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
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
                              'Curated with love in India ',
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
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ActiveRideBanner(),
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
  final String id, name, desc;
  final IconData icon;
  final Color color;
  final String badge;
  final String? imagePath;
  const _Svc(this.id, this.name, this.desc, this.icon, this.color,
      {this.badge = '', this.imagePath});
}

// ── Action card ──
class _ActionCard {
  final String title;
  final IconData icon;
  final String serviceType;
  final String? imagePath;
  const _ActionCard(this.title, this.icon, this.serviceType, {this.imagePath});
}

// ── Service card (grid item) ──
class _ServiceCard extends StatelessWidget {
  final _Svc svc;
  final VoidCallback onTap;
  const _ServiceCard({super.key, required this.svc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: ServicesScreen._surfaceCard,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(4),
              child: svc.imagePath != null
                  ? Image.asset(
                      svc.imagePath!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          Icon(svc.icon, color: svc.color, size: 70),
                    )
                  : Icon(svc.icon, color: svc.color, size: 70),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            svc.name,
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
