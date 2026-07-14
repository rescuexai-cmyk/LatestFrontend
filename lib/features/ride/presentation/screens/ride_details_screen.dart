import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/fare_breakdown_widget.dart';
import '../widgets/lost_and_found_sheet.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import 'package:ride_hailing_flutter/core/widgets/figma_square_back_button.dart';
import 'package:ride_hailing_flutter/core/widgets/raahi_mandala_background.dart';

class RideDetailsScreen extends ConsumerStatefulWidget {
  final String rideId;

  const RideDetailsScreen({super.key, required this.rideId});

  @override
  ConsumerState<RideDetailsScreen> createState() => _RideDetailsScreenState();
}

class _RideDetailsScreenState extends ConsumerState<RideDetailsScreen> {
  Ride? _ride;
  bool _isLoading = true;
  String? _error;
  bool _isSubmittingRating = false;

  @override
  void initState() {
    super.initState();
    _loadRideDetails();
  }

  Future<void> _loadRideDetails() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final raw = await apiClient.getRide(widget.rideId);
      final payload = Ride.unwrapRidePayload(raw);
      setState(() => _ride = Ride.fromJson(payload));
    } catch (e) {
      setState(() => _error = 'Failed to load ride details');
      debugPrint('Error loading ride: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        leading: FigmaSquareBackButton(
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Ride Details'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null || _ride == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(_error ?? 'Ride not found'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadRideDetails, child: const Text('Retry')),
          ],
        ),
      );
    }

    final ride = _ride!;
    final rideCreatedIst = _toIst(ride.createdAt);
    final dateFormat = DateFormat('dd MMM yyyy');
    final timeFormat = DateFormat('hh:mm a');

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _getStatusColor(ride.status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(_getStatusIcon(ride.status), color: _getStatusColor(ride.status)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _getStatusText(ride.status),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _getStatusColor(ride.status),
                              ),
                            ),
                            Text(
                              '${dateFormat.format(rideCreatedIst)} at ${timeFormat.format(rideCreatedIst)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Route info
                Text('Route', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _buildLocationRow(Icons.circle, AppColors.pickupMarker, 'Pickup', ride.pickupLocation.address ?? 'Unknown'),
                Container(margin: const EdgeInsets.only(left: 11), width: 2, height: 24, color: AppColors.border),
                _buildLocationRow(Icons.location_on, AppColors.dropoffMarker, 'Dropoff', ride.destinationLocation.address ?? 'Unknown'),
                const SizedBox(height: 24),

                // Trip details
                Text('Trip Details', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _buildDetailRow('Vehicle Type', ride.rideType.toUpperCase()),
                _buildDetailRow('Distance', '${ride.distance.toStringAsFixed(1)} km'),
                _buildDetailRow('Duration', '${ride.estimatedDuration} min'),
                _buildDetailRow('Payment', ride.paymentMethod.name.toUpperCase()),
                const SizedBox(height: 24),

                // Fare breakdown
                Text('Fare Details', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                FareBreakdownWidget(
                  breakdown: _buildFareBreakdownModel(ride),
                  vehicleName: ride.rideType.toUpperCase(),
                  isReceipt: ride.status == RideStatus.completed,
                ),
                const SizedBox(height: 24),

                // Driver info (if available)
                if (ride.driver != null) ...[
                  Text('Driver', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.inputBackground,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: AppColors.secondary.withOpacity(0.2),
                          child: Text(
                            ride.driver!.name[0].toUpperCase(),
                            style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.secondary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(ride.driver!.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  if (ride.driver!.isVerified) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.verified, size: 16, color: AppColors.primary),
                                  ],
                                ],
                              ),
                              if (ride.driver!.vehicleInfo != null)
                                Text(
                                  '${ride.driver!.vehicleInfo!.color} ${ride.driver!.vehicleInfo!.type} • ${ride.driver!.vehicleInfo!.plateNumber}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                                ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(Icons.star, size: 16, color: AppColors.starYellow),
                            const SizedBox(width: 4),
                            Text(ride.driver!.rating.toStringAsFixed(1)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Rating (for completed rides)
                if (ride.status == RideStatus.completed) ...[
                  Text('Your Rating', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  if (ride.rating != null)
                    Row(
                      children: List.generate(5, (index) => Icon(
                        index < ride.rating!.round() ? Icons.star : Icons.star_border,
                        size: 32,
                        color: AppColors.starYellow,
                      )),
                    )
                  else
                    ElevatedButton(
                      onPressed: _showRatingDialog,
                      child: const Text('Rate this ride'),
                    ),
                ],
                // Lost & Found banner (completed rides within 48h)
                if (LostAndFoundSheet.isEligible(ride)) ...[
                  const SizedBox(height: 20),
                  _buildLostAndFoundBanner(ride),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        Material(
          color: Colors.white,
          elevation: 8,
          child: SafeArea(
            top: false,
            minimum: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openSupportOptions,
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Get Help'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _downloadReceipt,
                      icon: const Icon(Icons.receipt_outlined),
                      label: const Text('Receipt'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  FareBreakdown _buildFareBreakdownModel(Ride ride) {
    final fb = ride.fareBreakdown;
    double dn(String key, [double fallback = 0]) {
      final v = fb?[key];
      if (v == null) return fallback;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? fallback;
    }

    // Display backend snapshot only — no derived rates or recomputed totals.
    return FareBreakdown(
      baseFare: dn('startingFee', dn('baseFare')),
      distanceKm: dn('distanceKm', ride.distance),
      durationMin: dn('durationMin', ride.estimatedDuration.toDouble()),
      ratePerKm: dn('ratePerKm', dn('perKmRate')),
      ratePerMin: dn('ratePerMin', dn('perMinRate')),
      distanceFare: dn('distanceFare'),
      timeFare: dn('timeFare'),
      surgeMultiplier: dn('surgeMultiplier', dn('dynamicMultiplier', 1)),
      surgeAmount: dn('surgeAmount'),
      tolls: dn('tolls'),
      airportFee: dn('airportCharge', dn('airportFee')),
      waitingCharge: dn('waitingCharge'),
      parkingFees: dn('parkingFees'),
      extraStopsCharge: dn('extraStopsCharge'),
      discount: dn('discount', dn('discountAmount')),
      subtotal: dn('subtotal'),
      gstPercent: dn('gstPercent'),
      gstAmount: dn('gstAmount'),
      totalFare: ride.fare > 0 ? ride.fare : dn('totalFare'),
      promoCode: fb?['promoCode'] as String?,
      minimumFareApplied: fb?['minimumFareApplied'] == true,
    );
  }

  Widget _buildLostAndFoundBanner(Ride ride) {
    const accent = Color(0xFFD4956A);
    return GestureDetector(
      onTap: () => LostAndFoundSheet.show(context, ride),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accent.withOpacity(0.08), accent.withOpacity(0.04)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.search, color: accent, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Lost something?',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Report a lost item • ${LostAndFoundSheet.remainingTime(ride)}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: accent, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationRow(IconData icon, Color color, String label, String address) {
    return Row(
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              Text(address, style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Future<void> _showRatingDialog() async {
    if (_ride == null || _isSubmittingRating) return;

    double selectedRating = _ride!.rating ?? 5;
    String feedback = '';

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rate your ride'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final isFilled = index < selectedRating;
                  return IconButton(
                    icon: Icon(isFilled ? Icons.star : Icons.star_border, color: AppColors.starYellow),
                    onPressed: () {
                      setState(() => selectedRating = index + 1);
                    },
                  );
                }),
              ),
              TextField(
                onChanged: (value) => feedback = value,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Feedback (optional)',
                  hintText: 'Tell us about your trip',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _submitRating(selectedRating, feedback: feedback.trim());
              },
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submitRating(double rating, {String? feedback}) async {
    if (_ride == null || _isSubmittingRating) return;

    setState(() => _isSubmittingRating = true);
    try {
      await apiClient.submitRideRating(_ride!.id, rating, feedback: feedback);
      setState(() {
        _ride = _ride!.copyWith(rating: rating);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rating submitted'), backgroundColor: AppColors.success),
      );
    } catch (e) {
      debugPrint('Error submitting rating: $e');
      AppMessenger.showErrorBanner(context, 'Unable to submit rating');
    } finally {
      if (mounted) {
        setState(() => _isSubmittingRating = false);
      }
    }
  }

  Future<void> _openSupportOptions() async {
    const supportNumber = AppConfig.supportPhone;
    const supportEmail = AppConfig.supportEmail;
    final ride = _ride;
    final showLostAndFound =
        ride != null && LostAndFoundSheet.isEligible(ride);

    await showModalBottomSheet(
      context: context,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return RaahiMandalaStack(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              16 + MediaQuery.of(sheetContext).viewPadding.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4C4B0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Get Help',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                ),
                if (showLostAndFound)
                  ListTile(
                    leading: const Icon(Icons.search, color: Color(0xFFD4956A)),
                    title: const Text('Lost & Found'),
                    subtitle: Text(
                      'Report a lost item • ${LostAndFoundSheet.remainingTime(ride)}',
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      LostAndFoundSheet.show(context, ride);
                    },
                  ),
                if (showLostAndFound) const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.call),
                  title: const Text('Call support'),
                  subtitle: const Text(supportNumber),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _launchUri(Uri(scheme: 'tel', path: supportNumber));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email support'),
                  subtitle: const Text(supportEmail),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _launchUri(Uri(
                      scheme: 'mailto',
                      path: supportEmail,
                      query:
                          'subject=Ride support&body=Ride ID: ${ride?.id ?? ''}',
                    ));
                  },
                ),
                if (ride?.driver?.phone != null)
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: const Text('Message driver'),
                    subtitle: Text(ride!.driver!.phone!),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _launchUri(
                          Uri(scheme: 'sms', path: ride.driver!.phone!));
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _launchUri(Uri uri) async {
    // canLaunchUrl() can false-negative for mailto/tel on some devices, so
    // attempt the launch directly and only report failure if it throws.
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        AppMessenger.showErrorBanner(context, 'Cannot open link');
      }
    } catch (_) {
      if (mounted) {
        AppMessenger.showErrorBanner(context, 'Cannot open link');
      }
    }
  }

  Future<void> _downloadReceipt() async {
    if (_ride == null) return;

    try {
      final receipt = await apiClient.getRideReceipt(_ride!.id);
      final receiptText = _formatReceipt(receipt);
      await Share.share(receiptText, subject: 'Ride receipt');
    } catch (e) {
      debugPrint('Error fetching receipt: $e');
      final fallback = _formatReceipt({
        'rideId': _ride!.id,
        'fare': _ride!.fare,
        'pickup': _ride!.pickupLocation.address,
        'dropoff': _ride!.destinationLocation.address,
        'created_at': _ride!.createdAt.toIso8601String(),
        'status': _ride!.status.name,
      });
      await Share.share(fallback, subject: 'Ride receipt');
    }
  }

  String _formatReceipt(Map<String, dynamic> receipt) {
    final buffer = StringBuffer();
    buffer.writeln('Ride Receipt');
    buffer.writeln('Ride ID: ${receipt['rideId'] ?? receipt['id'] ?? _ride?.id}');
    buffer.writeln('Status: ${receipt['status'] ?? _ride?.status.name}');
    buffer.writeln('Fare: ₹${receipt['fare'] ?? receipt['total'] ?? _ride?.fare}');
    if (receipt['pickup'] != null) buffer.writeln('Pickup: ${receipt['pickup']}');
    if (receipt['dropoff'] != null) buffer.writeln('Dropoff: ${receipt['dropoff']}');
    if (receipt['created_at'] != null) {
      final ist = _tryParseToIst(receipt['created_at']);
      buffer.writeln('Date: ${ist != null ? DateFormat('dd MMM yyyy • hh:mm a').format(ist) : receipt['created_at']}');
    }
    if (receipt['payment_method'] != null) buffer.writeln('Payment: ${receipt['payment_method']}');
    if (receipt['driver'] != null) buffer.writeln('Driver: ${receipt['driver']}');
    return buffer.toString();
  }

  DateTime _toIst(DateTime value) {
    final utc = value.isUtc ? value : value.toUtc();
    return utc.add(const Duration(hours: 5, minutes: 30));
  }

  DateTime? _tryParseToIst(dynamic value) {
    if (value == null) return null;
    try {
      final parsed = DateTime.parse(value.toString());
      return _toIst(parsed);
    } catch (_) {
      return null;
    }
  }

  Color _getStatusColor(RideStatus status) {
    switch (status) {
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

  IconData _getStatusIcon(RideStatus status) {
    switch (status) {
      case RideStatus.completed:
        return Icons.check_circle;
      case RideStatus.cancelled:
        return Icons.cancel;
      case RideStatus.inProgress:
        return Icons.directions_car;
      default:
        return Icons.schedule;
    }
  }

  String _getStatusText(RideStatus status) {
    switch (status) {
      case RideStatus.completed:
        return 'Ride Completed';
      case RideStatus.cancelled:
        return 'Ride Cancelled';
      case RideStatus.inProgress:
        return 'Ride In Progress';
      case RideStatus.requested:
        return 'Ride Requested';
      case RideStatus.accepted:
        return 'Driver Accepted';
      case RideStatus.arriving:
      case RideStatus.driverArriving:
        return 'Driver Arriving';
    }
  }
}






