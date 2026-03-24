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
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/nearby_places_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../ride/providers/ride_booking_provider.dart';
import '../../../ride/providers/ride_provider.dart';

class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  // ── Raahi palette ──
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _muted = Color(0xFFB8AFA0);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);
  /// Design tokens (services hub refresh)
  static const _backButtonFill = Color(0xFFEDE7DB);
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
    if (_scheduledTime == null) return 'Now';
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
      builder: (context) => _SchedulePickerSheet(
        currentSchedule: _scheduledTime,
        onScheduleSelected: (DateTime? selectedTime) {
          if (mounted) {
            setState(() {
              _scheduledTime = selectedTime;
            });
          }
          Navigator.pop(context);
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

  /// Open bottom sheet to set home location
  void _openSetHomeSheet() {
    final TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> searchPlaces(String query) async {
              if (query.isEmpty) {
                setModalState(() {
                  searchResults = [];
                  isSearching = false;
                });
                return;
              }

              setModalState(() => isSearching = true);

              try {
                final locations = await locationFromAddress(query);
                if (locations.isNotEmpty) {
                  final results = <Map<String, dynamic>>[];
                  for (final loc in locations.take(5)) {
                    final placemarks = await placemarkFromCoordinates(
                        loc.latitude, loc.longitude);
                    if (placemarks.isNotEmpty) {
                      final pm = placemarks.first;
                      results.add({
                        'name': query,
                        'address': [
                          pm.street,
                          pm.subLocality,
                          pm.locality,
                          pm.administrativeArea
                        ].where((s) => s != null && s.isNotEmpty).join(', '),
                        'lat': loc.latitude,
                        'lng': loc.longitude,
                      });
                    }
                  }
                  setModalState(() {
                    searchResults = results;
                    isSearching = false;
                  });
                }
              } catch (e) {
                setModalState(() {
                  searchResults = [];
                  isSearching = false;
                });
              }
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    // Handle bar
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Header
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                          const Expanded(
                            child: Text(
                              'Set Home Address',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Search input
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        controller: searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Search for your home address',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    searchController.clear();
                                    setModalState(() => searchResults = []);
                                  },
                                )
                              : null,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                BorderSide(color: ServicesScreen._border),
                          ),
                          filled: true,
                          fillColor: ServicesScreen._inputBg,
                        ),
                        onChanged: (value) {
                          if (value.length >= 3) {
                            searchPlaces(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Results
                    Expanded(
                      child: isSearching
                          ? const Center(child: CircularProgressIndicator())
                          : searchResults.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.home_outlined,
                                          size: 64, color: Colors.grey[400]),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Search for your home address',
                                        style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 16),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  controller: scrollController,
                                  itemCount: searchResults.length,
                                  itemBuilder: (context, index) {
                                    final place = searchResults[index];
                                    return ListTile(
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: ServicesScreen._accent
                                              .withOpacity(0.1),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Icon(Icons.home,
                                            color: ServicesScreen._accent),
                                      ),
                                      title: Text(place['name'] ?? ''),
                                      subtitle: Text(
                                        place['address'] ?? '',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: () async {
                                        final lat = place['lat'] as double;
                                        final lng = place['lng'] as double;
                                        final address =
                                            place['address'] as String? ??
                                                place['name'] as String;

                                        // Save to provider
                                        await ref
                                            .read(
                                                savedLocationsProvider.notifier)
                                            .setHomeLocation(
                                              name: 'Home',
                                              address: address,
                                              location: LatLng(lat, lng),
                                            );

                                        if (context.mounted) {
                                          Navigator.pop(context);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              content:
                                                  Text('Home address saved!'),
                                              backgroundColor:
                                                  Color(0xFF4CAF50),
                                            ),
                                          );
                                        }
                                      },
                                    );
                                  },
                                ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Build location display with pickup and saved Home
  Widget _buildLocationDisplay(String pickupDisplay) {
    final savedLocations = ref.watch(savedLocationsProvider);
    final homeLocation = savedLocations.homeLocation;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _navigateToFindTrip(),
            child: Row(
              children: [
                Icon(Icons.place, size: 20, color: ServicesScreen._accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    pickupDisplay,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: ServicesScreen._textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Divider(
            height: 1,
            thickness: 1,
            color: ServicesScreen._strokeMuted,
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () {
              if (homeLocation != null) {
                // If home is set, use it as destination
                ref.read(rideBookingProvider.notifier).setDestinationLocation(
                      homeLocation.address,
                      homeLocation.latLng,
                    );
                _navigateToFindTrip();
              } else {
                // If home is not set, open location picker to set home
                _openSetHomeSheet();
              }
            },
            child: Row(
              children: [
                Icon(Icons.home_rounded,
                    size: 20,
                    color: homeLocation != null
                        ? const Color(0xFF4CAF50)
                        : ServicesScreen._textPrimary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    homeLocation?.address ?? 'Set Home',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: homeLocation != null
                          ? ServicesScreen._textPrimary
                          : ServicesScreen._textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (homeLocation == null)
                  Icon(Icons.add, size: 18, color: ServicesScreen._accent),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build recent location card with actual recent locations
  Widget _buildRecentLocationCard() {
    final savedLocations = ref.watch(savedLocationsProvider);
    final recentLocations = savedLocations.recentLocations;

    if (recentLocations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GestureDetector(
          onTap: () => _navigateToFindTrip(),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ServicesScreen._surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ServicesScreen._strokeMuted),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ServicesScreen._accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.search_rounded,
                      color: ServicesScreen._accent, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    ref.tr('where_to'),
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: ServicesScreen._textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show most recent location
    final mostRecent = recentLocations.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GestureDetector(
        onTap: () {
          // Set destination to recent location and navigate
          ref.read(rideBookingProvider.notifier).setDestinationLocation(
                mostRecent.address,
                mostRecent.latLng,
              );
          _navigateToFindTrip();
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ServicesScreen._surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ServicesScreen._strokeMuted),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ServicesScreen._accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Ionicons.time_outline,
                  color: ServicesScreen._accent,
                  size: 24,
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
                        fontWeight: FontWeight.w600,
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
              const Icon(Icons.arrow_forward_ios,
                  size: 16, color: ServicesScreen._muted),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final bookingState = ref.watch(rideBookingProvider);
    final displayName = user?.name ?? user?.email ?? 'User';
    final firstName = displayName.split(' ').first;
    final initial = firstName.isNotEmpty ? firstName[0].toUpperCase() : 'U';

    final pickupAddr = bookingState.pickupAddress ?? '';
    final pickupDisplay = pickupAddr.isNotEmpty
        ? (pickupAddr.length > 45
            ? '${pickupAddr.substring(0, 45)}...'
            : pickupAddr)
        : 'Add pickup location';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
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

                    // ── Top bar: back + "Hi, Name!" + Now + avatar (first image style) ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => context.pop(),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: ServicesScreen._backButtonFill,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(Icons.arrow_back_rounded,
                                  size: 20, color: ServicesScreen._textPrimary),
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
                                  Text(
                                    _scheduleDisplayText,
                                    style: const TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: ServicesScreen._textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.keyboard_arrow_down_rounded,
                                      size: 18,
                                      color: ServicesScreen._textSecondary),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
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
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Location display: pickup + saved destination ──
                    _buildLocationDisplay(pickupDisplay),
                    const SizedBox(height: 16),

                    // ── Recent Location card ──
                    _buildRecentLocationCard(),
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
                          childAspectRatio: 0.82,
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
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: SizedBox(
                            height: 120,
                            width: double.infinity,
                            child: Image.asset(
                              'assets/images/cashback_banner.png',
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: const Color(0xFF1A1A1A),
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
                                  height: 158,
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
                                                    ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              12),
                                                      child: SizedBox(
                                                        height: 75,
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
                                                    Padding(
                                                      padding: const EdgeInsets
                                                          .fromLTRB(
                                                          4, 10, 4, 0),
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
                                                              fontSize: 14,
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
                                                              fontSize: 12,
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
                      height: 140,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: ServicesScreen._actionCards.length,
                        itemBuilder: (ctx, i) {
                          final a = ServicesScreen._actionCards[i];
                          return Padding(
                            padding: const EdgeInsets.only(right: 15),
                            child: GestureDetector(
                              onTap: () => _navigateToFindTrip(
                                  serviceType: a.serviceType),
                              child: Container(
                                width: 140,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.16),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
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
                                                Colors.black.withOpacity(0.8),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Title text at bottom
                                      Positioned(
                                        left: 12,
                                        right: 12,
                                        bottom: 12,
                                        child: Text(
                                          a.title,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
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
    );
  }
}

// ── Schedule Picker Bottom Sheet ──
class _SchedulePickerSheet extends StatefulWidget {
  final DateTime? currentSchedule;
  final Function(DateTime?) onScheduleSelected;

  const _SchedulePickerSheet({
    required this.currentSchedule,
    required this.onScheduleSelected,
  });

  @override
  State<_SchedulePickerSheet> createState() => _SchedulePickerSheetState();
}

class _SchedulePickerSheetState extends State<_SchedulePickerSheet> {
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;
  bool _isNow = true;

  @override
  void initState() {
    super.initState();
    if (widget.currentSchedule != null) {
      _selectedDate = widget.currentSchedule!;
      _selectedTime = TimeOfDay.fromDateTime(widget.currentSchedule!);
      _isNow = false;
    } else {
      _selectedDate = DateTime.now();
      _selectedTime = TimeOfDay.now();
      _isNow = true;
    }
  }

  DateTime get _combinedDateTime {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );
  }

  bool get _isValidSchedule {
    if (_isNow) return true;
    final combined = _combinedDateTime;
    final minTime = DateTime.now().add(const Duration(minutes: 15));
    return combined.isAfter(minTime);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Title
          const Text(
            'When do you want to ride?',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 20),

          // Now option
          GestureDetector(
            onTap: () => setState(() => _isNow = true),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _isNow
                    ? ServicesScreen._accent.withOpacity(0.1)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isNow ? ServicesScreen._accent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.flash_on_rounded,
                    color: _isNow ? ServicesScreen._accent : Colors.grey[600],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Now',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _isNow
                                ? ServicesScreen._accent
                                : const Color(0xFF1A1A1A),
                          ),
                        ),
                        Text(
                          'Get a ride right away',
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  if (_isNow)
                    const Icon(Icons.check_circle,
                        color: ServicesScreen._accent),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Schedule for later option
          GestureDetector(
            onTap: () => setState(() => _isNow = false),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: !_isNow
                    ? ServicesScreen._accent.withOpacity(0.1)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: !_isNow ? ServicesScreen._accent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    color: !_isNow ? ServicesScreen._accent : Colors.grey[600],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Schedule for later',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: !_isNow
                                ? ServicesScreen._accent
                                : const Color(0xFF1A1A1A),
                          ),
                        ),
                        Text(
                          'Pick a date and time',
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  if (!_isNow)
                    const Icon(Icons.check_circle,
                        color: ServicesScreen._accent),
                ],
              ),
            ),
          ),

          // Date and time pickers (visible when scheduling)
          if (!_isNow) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                // Date picker
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 7)),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: ColorScheme.light(
                                primary: ServicesScreen._accent,
                                onPrimary: Colors.white,
                                surface: Colors.white,
                                onSurface: const Color(0xFF1A1A1A),
                              ),
                            ),
                            child: child ?? const SizedBox.shrink(),
                          );
                        },
                      );
                      if (date != null && mounted) {
                        setState(() => _selectedDate = date);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today,
                              size: 20, color: Color(0xFF666666)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              DateFormat('EEE, MMM d').format(_selectedDate),
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                          ),
                          const Icon(Icons.keyboard_arrow_down,
                              color: Color(0xFF666666)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Time picker
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: _selectedTime,
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: ColorScheme.light(
                                primary: ServicesScreen._accent,
                                onPrimary: Colors.white,
                                surface: Colors.white,
                                onSurface: const Color(0xFF1A1A1A),
                              ),
                            ),
                            child: child ?? const SizedBox.shrink(),
                          );
                        },
                      );
                      if (time != null && mounted) {
                        setState(() => _selectedTime = time);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.access_time,
                              size: 20, color: Color(0xFF666666)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _selectedTime.format(context),
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                          ),
                          const Icon(Icons.keyboard_arrow_down,
                              color: Color(0xFF666666)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (!_isValidSchedule) ...[
              const SizedBox(height: 8),
              Text(
                'Please select a time at least 15 minutes from now',
                style: TextStyle(fontSize: 12, color: Colors.red[600]),
              ),
            ],
          ],

          const SizedBox(height: 24),

          // Confirm button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isValidSchedule
                  ? () => widget
                      .onScheduleSelected(_isNow ? null : _combinedDateTime)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: ServicesScreen._accent,
                disabledBackgroundColor: Colors.grey[300],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26)),
                elevation: 0,
              ),
              child: Text(
                _isNow ? 'Confirm' : 'Schedule Ride',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
            ),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 10),
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
          Container(
            width: 100,
            height: 80,
            decoration: BoxDecoration(
              color: ServicesScreen._surfaceCard,
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: svc.imagePath != null
                ? Image.asset(
                    svc.imagePath!,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        Icon(svc.icon, color: svc.color, size: 42),
                  )
                : Icon(svc.icon, color: svc.color, size: 42),
          ),
          const SizedBox(height: 8),
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
