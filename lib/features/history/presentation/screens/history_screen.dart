import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
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
import '../../../rescue/data/rescue_repository.dart';
import '../../../rescue/models/rescue_models.dart';
import '../../../rescue/presentation/widgets/rescue_history_card.dart';
import '../../../rescue/presentation/widgets/rescue_widgets.dart';
import '../../../rescue/providers/rescue_booking_provider.dart';
import '../../../rescue/rescue_theme.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<Ride> _rides = [];
  List<RescueRequestSummary> _rescues = [];
  bool _isLoadingRides = true;
  bool _isLoadingRescues = true;
  String? _ridesError;
  String? _rescuesError;

  void _exitHistory(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadRides();
    _loadRescues();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadRides() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      setState(() {
        _ridesError = 'Please sign in to view ride history';
        _isLoadingRides = false;
      });
      return;
    }

    setState(() {
      _isLoadingRides = true;
      _ridesError = null;
    });

    try {
      final response = await apiClient.getUserRides();
      final data = response['data'] as Map<String, dynamic>? ?? {};
      final ridesJson = data['rides'] as List<dynamic>? ?? [];

      final rides = <Ride>[];
      for (var r in ridesJson) {
        try {
          rides.add(Ride.fromJson(r as Map<String, dynamic>));
        } catch (e) {
          debugPrint('Error parsing ride: $e');
        }
      }

      rides.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      setState(() => _rides = rides);
    } catch (e) {
      setState(() => _ridesError = 'Failed to load ride history');
      debugPrint('Error loading rides: $e');
    } finally {
      setState(() => _isLoadingRides = false);
    }
  }

  Future<void> _loadRescues() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      setState(() {
        _rescuesError = 'Please sign in to view rescue history';
        _isLoadingRescues = false;
      });
      return;
    }

    setState(() {
      _isLoadingRescues = true;
      _rescuesError = null;
    });

    try {
      final rescues =
          await ref.read(rescueRepositoryProvider).getHistory(limit: 50);
      setState(() => _rescues = rescues);
    } catch (e) {
      setState(() => _rescuesError = 'Failed to load rescue history');
      debugPrint('Error loading rescues: $e');
    } finally {
      setState(() => _isLoadingRescues = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadRides(), _loadRescues()]);
  }

  void _openRescueItem(RescueRequestSummary rescue) {
    final notifier = ref.read(rescueBookingProvider.notifier);
    notifier.reset();
    notifier.setRescueId(rescue.id);
    notifier.setVehicleWithYou(rescue.hasVehicle);

    if (rescue.isSearching) {
      context.push(AppRoutes.rescueTracking);
      return;
    }
    if (rescue.isLive) {
      context.push(AppRoutes.rescueJourneyPath(rescue.id));
      return;
    }
    _showRescueDetailSheet(rescue);
  }

  void _showRescueDetailSheet(RescueRequestSummary rescue) {
    final dateFormat = DateFormat('dd MMM yyyy • hh:mm a');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RescueTheme.screenBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: RescueTheme.stroke,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Rescue details', style: RescueTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                rescueStatusLabel(rescue.status),
                style: RescueTheme.body.copyWith(color: RescueTheme.accent),
              ),
              if (rescue.createdAt != null) ...[
                const SizedBox(height: 4),
                Text(
                  dateFormat.format(rescue.createdAt!.toLocal()),
                  style: RescueTheme.body.copyWith(
                    fontSize: 13,
                    color: RescueTheme.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Pickup', style: RescueTheme.label),
              Text(
                rescue.pickupAddress ?? '—',
                style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              Text('Drop', style: RescueTheme.label),
              Text(
                rescue.dropAddress ?? '—',
                style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
              ),
              if (rescue.driver1Name?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text('Driver', style: RescueTheme.label),
                Text(
                  rescue.driver1Name!,
                  style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
                ),
              ],
              if (rescue.hasVehicle && rescue.driver2Name?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text('Vehicle driver', style: RescueTheme.label),
                Text(
                  rescue.driver2Name!,
                  style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
                ),
              ],
              const SizedBox(height: 20),
              if (rescue.isCompleted)
                FilledButton(
                  style: RescueTheme.primaryButton,
                  onPressed: () {
                    Navigator.pop(ctx);
                    context.push(AppRoutes.rescueComplete);
                  },
                  child: const Text('Rate this rescue'),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = ref.read(settingsProvider.notifier).tr;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitHistory(context);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => _exitHistory(context),
          ),
          title: Text(tr('ride_history')),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshAll,
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            labelColor: RescueTheme.accent,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: RescueTheme.accent,
            labelStyle: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            unselectedLabelStyle: GoogleFonts.poppins(
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
            tabs: const [
              Tab(text: 'Rides'),
              Tab(text: 'Rescue'),
            ],
          ),
        ),
        body: Stack(
          children: [
            TabBarView(
              controller: _tabController,
              children: [
                _buildRidesTab(tr),
                _buildRescueTab(),
              ],
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

  Widget _buildRidesTab(String Function(String) tr) {
    if (_isLoadingRides) return _buildShimmerList();

    if (_ridesError != null) {
      return _buildError(_ridesError!, _loadRides);
    }

    if (_rides.isEmpty) {
      return _buildEmpty(
        icon: Icons.history,
        title: tr('no_rides_yet'),
        subtitle: 'Your ride history will appear here',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRides,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewPadding.bottom,
        ),
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

  Widget _buildRescueTab() {
    if (_isLoadingRescues) return _buildShimmerList();

    if (_rescuesError != null) {
      return _buildError(_rescuesError!, _loadRescues);
    }

    if (_rescues.isEmpty) {
      return _buildEmpty(
        icon: Icons.emergency_share_outlined,
        title: 'No rescue history yet',
        subtitle: 'Your rescue requests will appear here',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRescues,
      color: RescueTheme.accent,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewPadding.bottom,
        ),
        itemCount: _rescues.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) => RescueHistoryCard(
          rescue: _rescues[index],
          onTap: () => _openRescueItem(_rescues[index]),
        ),
      ),
    );
  }

  Widget _buildShimmerList() {
    return UberShimmer(
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewPadding.bottom,
        ),
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
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
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

  Widget _buildError(String message, Future<void> Function() onRetry) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: AppColors.error)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildEmpty({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textHint),
          ),
        ],
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
