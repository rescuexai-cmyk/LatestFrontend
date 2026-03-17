import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/theme/app_colors.dart';

class _ItemCategory {
  final String id;
  final String label;
  final IconData icon;
  const _ItemCategory(this.id, this.label, this.icon);
}

const _categories = [
  _ItemCategory('phone', 'Phone', Icons.phone_android),
  _ItemCategory('wallet', 'Wallet / Purse', Icons.account_balance_wallet),
  _ItemCategory('keys', 'Keys', Icons.vpn_key),
  _ItemCategory('bag', 'Bag / Luggage', Icons.luggage),
  _ItemCategory('clothing', 'Clothing', Icons.checkroom),
  _ItemCategory('electronics', 'Electronics', Icons.headphones),
  _ItemCategory('documents', 'Documents', Icons.description),
  _ItemCategory('other', 'Other', Icons.more_horiz),
];

class LostAndFoundSheet extends StatefulWidget {
  final Ride ride;

  const LostAndFoundSheet({super.key, required this.ride});

  static bool isEligible(Ride ride) {
    if (ride.status != RideStatus.completed) return false;
    final rideEnd = ride.completedAt ?? ride.createdAt;
    return DateTime.now().difference(rideEnd).inHours < 48;
  }

  static String remainingTime(Ride ride) {
    final rideEnd = ride.completedAt ?? ride.createdAt;
    final remaining = const Duration(hours: 48) - DateTime.now().difference(rideEnd);
    if (remaining.isNegative) return 'Expired';
    final h = remaining.inHours;
    final m = remaining.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m left';
    return '${m}m left';
  }

  static Future<void> show(BuildContext context, Ride ride) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => LostAndFoundSheet(ride: ride),
      ),
    );
  }

  @override
  State<LostAndFoundSheet> createState() => _LostAndFoundSheetState();
}

class _LostAndFoundSheetState extends State<LostAndFoundSheet> {
  static const _accent = Color(0xFFD4956A);

  String? _selectedCategory;
  final _descController = TextEditingController();
  bool _submitted = false;
  bool _submitting = false;

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: _submitted ? _buildSuccessView() : _buildFormView(),
    );
  }

  Widget _buildFormView() {
    final hasDriver = widget.ride.driver != null;
    final driverName = widget.ride.driver?.name ?? 'Driver';
    final remaining = LostAndFoundSheet.remainingTime(widget.ride);

    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.search, color: _accent, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lost Something?',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, size: 14, color: AppColors.textHint),
                          const SizedBox(width: 4),
                          Text(
                            remaining,
                            style: const TextStyle(fontSize: 13, color: AppColors.textHint, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 8),
                          Container(width: 4, height: 4, decoration: const BoxDecoration(color: AppColors.textHint, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Report within 48h of ride',
                              style: TextStyle(fontSize: 13, color: AppColors.textHint),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Contact driver card
          if (hasDriver) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F5F0),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border.withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.phone_in_talk, size: 18, color: _accent),
                        const SizedBox(width: 8),
                        const Text(
                          'Contact your driver first',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Most items are found quickly when you call your driver directly.',
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.call,
                            label: 'Call $driverName',
                            color: AppColors.success,
                            onTap: () => _contactDriver('tel'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.message,
                            label: 'Message',
                            color: AppColors.info,
                            onTap: () => _contactDriver('sms'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Divider with text
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(child: Divider(color: Colors.grey[300])),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    hasDriver ? 'Or file a report' : 'File a report',
                    style: TextStyle(fontSize: 12, color: AppColors.textHint, fontWeight: FontWeight.w500),
                  ),
                ),
                Expanded(child: Divider(color: Colors.grey[300])),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Category picker
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: const Text(
              'What did you lose?',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final cat = _categories[i];
                final selected = _selectedCategory == cat.id;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategory = cat.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 78,
                    decoration: BoxDecoration(
                      color: selected ? _accent.withOpacity(0.12) : const Color(0xFFF8F5F0),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected ? _accent : Colors.transparent,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(cat.icon, size: 28, color: selected ? _accent : AppColors.textSecondary),
                        const SizedBox(height: 6),
                        Text(
                          cat.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? _accent : AppColors.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),

          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: const Text(
              'Describe the item',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TextField(
              controller: _descController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'e.g. Black leather wallet left on the back seat',
                hintStyle: TextStyle(color: AppColors.textHint, fontSize: 14),
                filled: true,
                fillColor: const Color(0xFFF8F5F0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
          const SizedBox(height: 28),

          // Submit button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _canSubmit ? _submitReport : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  disabledBackgroundColor: _accent.withOpacity(0.3),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Text('Submit Report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    final driverName = widget.ride.driver?.name ?? 'Driver';
    final hasDriver = widget.ride.driver != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(bottom: 24),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: AppColors.success.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_outline, color: AppColors.success, size: 44),
          ),
          const SizedBox(height: 20),
          const Text(
            'Report Submitted',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            'We\'ve notified ${hasDriver ? driverName : 'the driver'} and our support team. '
            'You\'ll receive updates via email.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 28),
          if (hasDriver)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => _contactDriver('tel'),
                icon: const Icon(Icons.call, size: 20),
                label: Text('Call $driverName'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          if (hasDriver) const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  bool get _canSubmit => _selectedCategory != null && _descController.text.trim().isNotEmpty && !_submitting;

  Future<void> _submitReport() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);

    // Build report for support email
    final ride = widget.ride;
    final cat = _categories.firstWhere((c) => c.id == _selectedCategory);
    final body = StringBuffer()
      ..writeln('Lost Item Report')
      ..writeln('─────────────────')
      ..writeln('Ride ID: ${ride.id}')
      ..writeln('Date: ${ride.createdAt}')
      ..writeln('Pickup: ${ride.pickupLocation.address ?? 'N/A'}')
      ..writeln('Dropoff: ${ride.destinationLocation.address ?? 'N/A'}')
      ..writeln('Driver: ${ride.driver?.name ?? 'N/A'}')
      ..writeln('Vehicle: ${ride.driver?.vehicleInfo?.plateNumber ?? 'N/A'}')
      ..writeln('')
      ..writeln('Category: ${cat.label}')
      ..writeln('Description: ${_descController.text.trim()}');

    try {
      final uri = Uri(
        scheme: 'mailto',
        path: 'support@raahi.app',
        query: Uri.encodeFull(
          'subject=Lost Item Report — Ride ${ride.id.substring(0, 8)}&body=${body.toString()}',
        ),
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 600));

    if (mounted) setState(() { _submitting = false; _submitted = true; });
  }

  Future<void> _contactDriver(String scheme) async {
    final phone = widget.ride.driver?.phone;
    if (phone == null || phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Driver phone number unavailable')),
        );
      }
      return;
    }
    final uri = Uri(scheme: scheme, path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
