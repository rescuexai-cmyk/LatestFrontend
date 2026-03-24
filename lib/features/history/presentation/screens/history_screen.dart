import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../ride/presentation/widgets/lost_and_found_sheet.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<Ride> _rides = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRides();
  }

  Future<void> _loadRides() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      setState(() {
        _error = 'Please sign in to view ride history';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      debugPrint('📋 Loading rides for user: ${user.id}');

      // Backend: GET /api/rides (authenticated, token-based)
      final response = await apiClient.getUserRides();
      final data = response['data'] as Map<String, dynamic>? ?? {};
      final ridesJson = data['rides'] as List<dynamic>? ?? [];
      debugPrint('Received ${ridesJson.length} rides');

      final rides = <Ride>[];
      for (var r in ridesJson) {
        try {
          rides.add(Ride.fromJson(r as Map<String, dynamic>));
        } catch (e) {
          debugPrint('Error parsing ride: $e');
        }
      }

      // Sort by date, newest first
      rides.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() => _rides = rides);
    } catch (e) {
      setState(() => _error = 'Failed to load ride history');
      debugPrint('Error loading rides: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = ref.read(settingsProvider.notifier).tr;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(tr('ride_history')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRides,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          // Active ride banner at bottom
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ActiveRideBanner(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final tr = ref.read(settingsProvider.notifier).tr;

    if (_isLoading) {
      return UberShimmer(
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: 6,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, __) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    UberShimmerBox(width: 120, height: 10),
                    UberShimmerBox(
                        width: 64,
                        height: 18,
                        borderRadius: BorderRadius.all(Radius.circular(4))),
                  ],
                ),
                SizedBox(height: 14),
                UberShimmerBox(width: double.infinity, height: 10),
                SizedBox(height: 10),
                UberShimmerBox(width: double.infinity, height: 10),
                SizedBox(height: 16),
                UberShimmerBox(width: 140, height: 10),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: AppColors.error)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadRides, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_rides.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              tr('no_rides_yet'),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              'Your ride history will appear here',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textHint),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRides,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _rides.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _RideCard(
          ride: _rides[index],
          onTap: () =>
              context.push(AppRoutes.rideDetailsPath(_rides[index].id)),
          onLostItem: (ride) => LostAndFoundSheet.show(context, ride),
        ),
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  final Ride ride;
  final VoidCallback onTap;
  final void Function(Ride)? onLostItem;

  const _RideCard({required this.ride, required this.onTap, this.onLostItem});

  Color get _statusColor {
    switch (ride.status) {
      case RideStatus.completed:
        return AppColors.success;
      case RideStatus.cancelled:
        return AppColors.error;
      case RideStatus.inProgress:
        return AppColors.secondary;
      default:
        return AppColors.warning;
    }
  }

  String get _statusText {
    switch (ride.status) {
      case RideStatus.completed:
        return 'Completed';
      case RideStatus.cancelled:
        return 'Cancelled';
      case RideStatus.inProgress:
        return 'In Progress';
      case RideStatus.requested:
        return 'Requested';
      case RideStatus.accepted:
        return 'Accepted';
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return 'Driver Arriving';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy • hh:mm a');
    DateTime toIst(DateTime value) {
      final utc = value.isUtc ? value : value.toUtc();
      return utc.add(const Duration(hours: 5, minutes: 30));
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  dateFormat.format(toIst(ride.createdAt)),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _statusText,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Locations
            Row(
              children: [
                Column(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                            color: AppColors.pickupMarker,
                            shape: BoxShape.circle)),
                    Container(width: 2, height: 24, color: AppColors.border),
                    Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                            color: AppColors.dropoffMarker,
                            shape: BoxShape.circle)),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ride.pickupLocation.address ?? 'Pickup',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        ride.destinationLocation.address ?? 'Destination',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),

            // Footer
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.directions_car,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      ride.rideType.toUpperCase(),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.straighten,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      '${ride.distance.toStringAsFixed(1)} km',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
                Text(
                  '₹${ride.fare.round()}',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),

            // Rating (if completed)
            if (ride.status == RideStatus.completed && ride.rating != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  ...List.generate(
                      5,
                      (index) => Icon(
                            index < ride.rating!.round()
                                ? Icons.star
                                : Icons.star_border,
                            size: 16,
                            color: AppColors.starYellow,
                          )),
                ],
              ),
            ],

            // Lost & Found quick link (within 48h of completion)
            if (LostAndFoundSheet.isEligible(ride)) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => onLostItem?.call(ride),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        size: 15, color: const Color(0xFFD4956A)),
                    const SizedBox(width: 5),
                    Text(
                      'Lost something?',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFD4956A)),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '• ${LostAndFoundSheet.remainingTime(ride)}',
                      style: TextStyle(fontSize: 11, color: AppColors.textHint),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
