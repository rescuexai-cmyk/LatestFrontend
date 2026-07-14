import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/theme/app_colors.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import 'package:ride_hailing_flutter/core/theme/primary_cta_styles.dart';
import 'package:ride_hailing_flutter/core/widgets/raahi_mandala_background.dart';

class _LostOption {
  final String id;
  final String label;
  final IconData icon;
  const _LostOption(this.id, this.label, this.icon);
}

const _lostOptions = [
  _LostOption(
    'wallet',
    'I have left my wallet in the cab',
    Icons.account_balance_wallet_outlined,
  ),
  _LostOption(
    'keys',
    'I have left keys in the cab',
    Icons.vpn_key_outlined,
  ),
  _LostOption(
    'laptop',
    'I have left laptop in the cab',
    Icons.laptop_mac_outlined,
  ),
  _LostOption(
    'other',
    'Other items',
    Icons.more_horiz,
  ),
];

enum _LostStep { selectItem, askNumber, contactDriver, done }

class LostAndFoundSheet extends StatefulWidget {
  final Ride ride;
  final ScrollController? scrollController;

  const LostAndFoundSheet({
    super.key,
    required this.ride,
    this.scrollController,
  });

  static bool isEligible(Ride ride) {
    if (ride.status != RideStatus.completed &&
        ride.status != RideStatus.cancelled) {
      return false;
    }
    final rideEnd =
        ride.completedAt ?? ride.cancelledAt ?? ride.createdAt;
    return DateTime.now().difference(rideEnd).inHours < 48;
  }

  static String remainingTime(Ride ride) {
    final rideEnd =
        ride.completedAt ?? ride.cancelledAt ?? ride.createdAt;
    final remaining =
        const Duration(hours: 48) - DateTime.now().difference(rideEnd);
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
        initialChildSize: 0.88,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        builder: (_, controller) => LostAndFoundSheet(
          ride: ride,
          scrollController: controller,
        ),
      ),
    );
  }

  @override
  State<LostAndFoundSheet> createState() => _LostAndFoundSheetState();
}

class _LostAndFoundSheetState extends State<LostAndFoundSheet> {
  static const _accent = Color(0xFFD4956A);

  _LostStep _step = _LostStep.selectItem;
  String? _selectedOptionId;
  bool _wantDriverNumber = false;
  final _otherDescController = TextEditingController();
  bool _submitting = false;
  String? _revealedDriverPhone;

  @override
  void dispose() {
    _otherDescController.dispose();
    super.dispose();
  }

  _LostOption? get _selectedOption {
    if (_selectedOptionId == null) return null;
    return _lostOptions.firstWhere((o) => o.id == _selectedOptionId);
  }

  bool get _hasDriverPhone {
    final phone = widget.ride.driver?.phone?.trim();
    return phone != null && phone.isNotEmpty;
  }

  String get _driverDisplayName =>
      widget.ride.driver?.name?.trim().isNotEmpty == true
          ? widget.ride.driver!.name
          : 'your driver';

  @override
  Widget build(BuildContext context) {
    return RaahiMandalaStack(
      expand: true,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        type: MaterialType.transparency,
        child: switch (_step) {
          _LostStep.selectItem => _buildSelectItemStep(),
          _LostStep.askNumber => _buildAskNumberStep(),
          _LostStep.contactDriver => _buildContactDriverStep(),
          _LostStep.done => _buildDoneStep(),
        },
      ),
    );
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFD4C4B0),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader({required String title, String? subtitle}) {
    final remaining = LostAndFoundSheet.remainingTime(widget.ride);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.search, color: _accent, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle ?? 'Report within 48h • $remaining',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textHint,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectItemStep() {
    return SizedBox.expand(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: EdgeInsets.only(
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHandle(),
            _buildHeader(
              title: 'Lost & Found',
              subtitle:
                  'What did you leave behind? • ${LostAndFoundSheet.remainingTime(widget.ride)}',
            ),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Select an option',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            ..._lostOptions.map((option) {
              final selected = _selectedOptionId == option.id;
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Material(
                  color: selected
                      ? _accent.withValues(alpha: 0.14)
                      : Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _selectedOptionId = option.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected ? _accent : const Color(0xFFE8E0D4),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            option.icon,
                            color:
                                selected ? _accent : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              option.label,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: selected ? _accent : AppColors.textHint,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            if (_selectedOptionId == 'other') ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: _otherDescController,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Describe the item you left behind',
                    hintStyle: const TextStyle(
                        color: AppColors.textHint, fontSize: 14),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:
                          const BorderSide(color: _accent, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: PrimaryCtaStyles.height,
                child: ElevatedButton(
                  onPressed: _canContinueFromSelect ? _goToAskNumber : null,
                  style: PrimaryCtaStyles.elevated(),
                  child: const Text(
                    'Continue',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _canContinueFromSelect {
    if (_selectedOptionId == null) return false;
    if (_selectedOptionId == 'other' &&
        _otherDescController.text.trim().length < 3) {
      return false;
    }
    return true;
  }

  void _goToAskNumber() {
    setState(() {
      _wantDriverNumber = false;
      _step = _LostStep.askNumber;
    });
  }

  Widget _buildAskNumberStep() {
    final option = _selectedOption!;
    return SizedBox.expand(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHandle(),
            _buildHeader(title: 'Contact driver?'),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE8E0D4)),
                ),
                child: Row(
                  children: [
                    Icon(option.icon, color: _accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        option.id == 'other'
                            ? _otherDescController.text.trim()
                            : option.label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Do you want $_driverDisplayName’s number from Raahi to contact them directly?',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'We’ll also notify the driver about your lost item.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: _ChoiceChipButton(
                      label: 'Yes, share number',
                      selected: _wantDriverNumber,
                      onTap: () => setState(() => _wantDriverNumber = true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ChoiceChipButton(
                      label: 'No, just report',
                      selected: !_wantDriverNumber,
                      onTap: () => setState(() => _wantDriverNumber = false),
                    ),
                  ),
                ],
              ),
            ),
            if (_wantDriverNumber && !_hasDriverPhone) ...[
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Driver number isn’t available for this ride. We’ll still notify them and our support team.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFFB45309),
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _step = _LostStep.selectItem),
                    child: const Text('Back'),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: PrimaryCtaStyles.height,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _submitReport,
                      style: PrimaryCtaStyles.elevated(),
                      child: _submitting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _wantDriverNumber
                                  ? 'Submit & show number'
                                  : 'Submit report',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitReport() async {
    if (_submitting || _selectedOption == null) return;
    setState(() => _submitting = true);

    final ride = widget.ride;
    final option = _selectedOption!;
    final categoryLabel = option.id == 'other'
        ? 'Other — ${_otherDescController.text.trim()}'
        : option.label;
    final description = StringBuffer()
      ..writeln('Lost Item Report')
      ..writeln('─────────────────')
      ..writeln('Ride ID: ${ride.id}')
      ..writeln('Date: ${ride.createdAt.toIso8601String()}')
      ..writeln('Status: ${ride.status.name}')
      ..writeln('Pickup: ${ride.pickupLocation.address ?? 'N/A'}')
      ..writeln('Dropoff: ${ride.destinationLocation.address ?? 'N/A'}')
      ..writeln('Driver: ${ride.driver?.name ?? 'N/A'}')
      ..writeln(
          'Vehicle: ${ride.driver?.vehicleInfo?.plateNumber ?? 'N/A'}')
      ..writeln('')
      ..writeln('Option: ${option.label}')
      ..writeln('Category: $categoryLabel')
      ..writeln(
          'Wants driver number: ${_wantDriverNumber ? 'Yes' : 'No'}');

    try {
      await apiClient.submitLostItemReport(
        rideId: ride.id,
        category: categoryLabel,
        description: description.toString(),
        driverId: ride.driverId ?? ride.driver?.id,
      );
    } catch (e) {
      debugPrint('Lost item report failed: $e');
      try {
        final uri = Uri(
          scheme: 'mailto',
          path: AppConfig.supportEmail,
          queryParameters: {
            'subject':
                'Lost Item Report — Ride ${ride.id.length > 8 ? ride.id.substring(0, 8) : ride.id}',
            'body': description.toString(),
          },
        );
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
      if (mounted) {
        AppMessenger.showErrorBanner(
          context,
          'Could not reach server — opened email draft instead',
        );
      }
    }

    if (!mounted) return;

    final phone = ride.driver?.phone?.trim();
    setState(() {
      _submitting = false;
      if (_wantDriverNumber && phone != null && phone.isNotEmpty) {
        _revealedDriverPhone = phone;
        _step = _LostStep.contactDriver;
      } else {
        _step = _LostStep.done;
      }
    });
  }

  Widget _buildContactDriverStep() {
    final phone = _revealedDriverPhone ?? '';
    final displayPhone = _formatPhone(phone);
    return SizedBox.expand(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          children: [
            _buildHandle(),
            const SizedBox(height: 12),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline,
                color: AppColors.success,
                size: 44,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Report submitted',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'We’ve notified $_driverDisplayName about your lost item. Here’s their number from Raahi — you can contact them directly.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F5F0).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _accent.withValues(alpha: 0.35)),
              ),
              child: Column(
                children: [
                  Text(
                    _driverDisplayName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    displayPhone,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: phone));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Number copied')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18, color: _accent),
                    label: const Text(
                      'Copy number',
                      style: TextStyle(color: _accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _launchPhone('tel', phone),
                    icon: const Icon(Icons.call, size: 20),
                    label: const Text('Call'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.success,
                      side: const BorderSide(color: AppColors.success),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _launchPhone('sms', phone),
                    icon: const Icon(Icons.message, size: 20),
                    label: const Text('Message'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.info,
                      side: const BorderSide(color: AppColors.info),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: PrimaryCtaStyles.height,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: PrimaryCtaStyles.elevated(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDoneStep() {
    return SizedBox.expand(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          children: [
            _buildHandle(),
            const SizedBox(height: 40),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline,
                color: AppColors.success,
                size: 44,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Report submitted',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.ride.driver != null
                  ? 'We’ve notified $_driverDisplayName and our support team about your lost item.'
                  : 'We’ve filed your report with Raahi support. You’ll hear back if we have an update.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: PrimaryCtaStyles.height,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: PrimaryCtaStyles.elevated(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.length >= 10) {
      final last10 = digits.substring(digits.length - 10);
      return '+91 $last10';
    }
    return phone;
  }

  Future<void> _launchPhone(String scheme, String phone) async {
    final uri = Uri(scheme: scheme, path: phone);
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        AppMessenger.showErrorBanner(context, 'Cannot open $scheme');
      }
    } catch (_) {
      if (mounted) {
        AppMessenger.showErrorBanner(context, 'Cannot open $scheme');
      }
    }
  }
}

class _ChoiceChipButton extends StatelessWidget {
  const _ChoiceChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const _accent = Color(0xFFD4956A);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _accent.withValues(alpha: 0.14) : const Color(0xFFF8F5F0),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? _accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? _accent : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
