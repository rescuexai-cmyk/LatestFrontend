import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../providers/driver_subscription_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';

class DriverSubscriptionPaymentScreen extends ConsumerStatefulWidget {
  const DriverSubscriptionPaymentScreen({super.key});

  @override
  ConsumerState<DriverSubscriptionPaymentScreen> createState() =>
      _DriverSubscriptionPaymentScreenState();
}

class _DriverSubscriptionPaymentScreenState
    extends ConsumerState<DriverSubscriptionPaymentScreen> {
  bool _isProcessing = false;
  bool _paymentInitiated = false;
  final TextEditingController _transactionIdController =
      TextEditingController();

  // Reset key to force the slide-to-confirm widget to snap back after action.
  int _slideResetKey = 0;

  @override
  void dispose() {
    _transactionIdController.dispose();
    super.dispose();
  }

  String _generateUpiUrl() {
    final amount = AppConfig.dailyPlatformFee.toStringAsFixed(2);
    return 'upi://pay?'
        'pa=${AppConfig.companyUpiId}'
        '&pn=${Uri.encodeComponent(AppConfig.companyDisplayName)}'
        '&am=$amount'
        '&cu=INR'
        '&tn=${Uri.encodeComponent('Daily Driver Fee')}';
  }

  Future<void> _launchUpiPayment() async {
    final upiUrl = _generateUpiUrl();
    final uri = Uri.parse(upiUrl);

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (launched) {
        setState(() => _paymentInitiated = true);
      } else {
        if (mounted) {
          AppMessenger.showDriverErrorBanner(context, 'No UPI app found. Please install a UPI app.');
        }
      }
    } catch (e) {
      debugPrint('Failed to launch UPI: $e');
      if (mounted) {
        AppMessenger.showDriverErrorBanner(context, 'Failed to open UPI app: $e');
      }
    }
  }

  Future<void> _launchSpecificUpiApp(String scheme) async {
    final amount = AppConfig.dailyPlatformFee.toStringAsFixed(2);
    final upiUrl = '$scheme://pay?'
        'pa=${AppConfig.companyUpiId}'
        '&pn=${Uri.encodeComponent(AppConfig.companyDisplayName)}'
        '&am=$amount'
        '&cu=INR'
        '&tn=${Uri.encodeComponent('Daily Driver Fee')}';

    try {
      final uri = Uri.parse(upiUrl);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (launched) {
        setState(() => _paymentInitiated = true);
      }
    } catch (e) {
      debugPrint('Failed to launch $scheme: $e');
      _launchUpiPayment();
    }
  }

  Future<void> _confirmPayment() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final success = await ref
          .read(driverSubscriptionProvider.notifier)
          .activateSubscription(
            transactionId: _transactionIdController.text.isNotEmpty
                ? _transactionIdController.text
                : null,
          );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Subscription activated! You can now go online.'),
            backgroundColor: Colors.green,
          ),
        );
        context.pop(true);
      } else if (mounted) {
        final error = ref.read(driverSubscriptionProvider).error;
        AppMessenger.showDriverErrorBanner(context, error ?? 'Failed to activate subscription');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _slideResetKey++;
        });
      }
    }
  }

  void _handleSlideAction() {
    if (!_paymentInitiated) {
      _launchUpiPayment();
      // Reset slider so the user can interact again after launching UPI app.
      setState(() => _slideResetKey++);
    } else {
      _confirmPayment();
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscriptionState = ref.watch(driverSubscriptionProvider);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          // Peach -> White gradient from top per Figma
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.18, 0.32],
            colors: [
              Color(0xFFCF923D),
              Color(0xFFF6DFC2),
              Color(0xFFFFFFFF),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPassCard(),
                      const SizedBox(height: 24),
                      const Padding(
                        padding: EdgeInsets.only(left: 2),
                        child: Text(
                          'Pay via UPI',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF010101),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildPaymentCard(),
                      if (_paymentInitiated) ...[
                        const SizedBox(height: 18),
                        _buildConfirmationSection(),
                      ],
                      const SizedBox(height: 18),
                      _buildHowItWorksCard(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              _buildBottomBar(subscriptionState),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(false),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.chevron_left_rounded,
                color: Color(0xFF2E2C2A),
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 14),
          const Text(
            'Daily Driver Pass',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Color(0xFF010101),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pass Card
  // ---------------------------------------------------------------------------
  Widget _buildPassCard() {
    // Figma reference: card 346x193, image asset 465x226 placed at (-47,-23).
    // We compute the same proportions so the car renders at native aspect
    // ratio on any device width, matching the Figma layout exactly.
    return LayoutBuilder(
      builder: (context, constraints) {
        const double figmaCardW = 346;
        const double figmaCardH = 193;
        const double figmaImgW = 465;
        const double figmaImgH = 226;
        const double figmaImgLeft = -47;
        const double figmaImgTop = -23;
        const double figmaOverlayLeft = 161; // right gradient overlay
        const double figmaDividerLeft = 201;
        const double figmaDividerWidth = 127;
        const double figmaDividerTop = 134.5;

        final double cardW = constraints.maxWidth;
        final double scale = cardW / figmaCardW;

        final double imgW = figmaImgW * scale;
        final double imgH = figmaImgH * scale;
        final double imgLeft = figmaImgLeft * scale;
        final double imgTop = figmaImgTop * scale;

        final double overlayLeft = figmaOverlayLeft * scale;
        final double dividerLeft = figmaDividerLeft * scale;
        final double dividerWidth = figmaDividerWidth * scale;
        final double dividerTop = figmaDividerTop * scale;

        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: figmaCardH * scale,
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Car image — exact Figma proportions, bleeds left/top/right/bottom
                Positioned(
                  left: imgLeft,
                  top: imgTop,
                  width: imgW,
                  height: imgH,
                  child: Image.asset(
                    'assets/images/driver_pass_car.png',
                    fit: BoxFit.cover,
                  ),
                ),
                // Right-side dark gradient overlay (Figma rect 180078:
                // 270.13deg, #121212 at right fading to transparent at left)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: overlayLeft,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerRight,
                        end: Alignment.centerLeft,
                        stops: [
                          0.158,
                          0.232,
                          0.302,
                          0.405,
                          0.555,
                          0.748,
                          1.0,
                        ],
                        colors: [
                          Color(0xFF121212),
                          Color(0xE1121212),
                          Color(0xDC121212),
                          Color(0xC4121212),
                          Color(0x99121212),
                          Color(0x60121212),
                          Color(0x00121212),
                        ],
                      ),
                    ),
                  ),
                ),
                // Bottom-left subtle fade so "Platform Fee" stays readable
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 70 * scale,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomLeft,
                        end: Alignment.topRight,
                        colors: [
                          Color(0xB3121212),
                          Color(0x00121212),
                        ],
                      ),
                    ),
                  ),
                ),
                // Title block (top-right)
                Positioned(
                  right: 16 * scale,
                  top: 14 * scale,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Raahi Driver Pass',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22 * scale,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                      SizedBox(height: 8 * scale),
                      Text(
                        '24 hours Access',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14 * scale,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                ),
                // Divider line on right side, above price
                Positioned(
                  left: dividerLeft,
                  width: dividerWidth,
                  top: dividerTop,
                  child: Container(
                    height: 1,
                    color: Colors.white.withOpacity(0.4),
                  ),
                ),
                // Bottom-left: Platform Fee + subtitle
                Positioned(
                  left: 18 * scale,
                  bottom: 16 * scale,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Platform Fee',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14 * scale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 2 * scale),
                      Text(
                        'Pay once, ride all day',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12 * scale,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                ),
                // Bottom-right: Price
                Positioned(
                  right: 18 * scale,
                  bottom: 18 * scale,
                  child: Text(
                    '₹ ${AppConfig.dailyPlatformFee.toInt()}',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30 * scale,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Payment Card (white card with UPI ID + 4 logos + Open any UPI)
  // ---------------------------------------------------------------------------
  Widget _buildPaymentCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.black.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildUpiIdRow(),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildUpiAppCard(
                label: 'Gpay',
                asset: 'assets/images/upi_gpay.png',
                scheme: 'gpay',
              ),
              _buildUpiAppCard(
                label: 'PhonePe',
                asset: 'assets/images/upi_phonepe.png',
                scheme: 'phonepe',
              ),
              _buildUpiAppCard(
                label: 'Paytm',
                asset: 'assets/images/upi_paytm.png',
                scheme: 'paytm',
              ),
              _buildUpiAppCard(
                label: 'BHIM',
                asset: 'assets/images/upi_bhim.png',
                scheme: 'bhim',
              ),
            ],
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _launchUpiPayment,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Open any other UPI App instead',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF424242),
                      height: 1.42,
                    ),
                  ),
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC932D),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.open_in_new_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpiIdRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 16,
          height: 16,
          margin: const EdgeInsets.only(top: 2),
          decoration: const BoxDecoration(
            color: Color(0xFFEC932D),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Text(
            'i',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w400,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF424242),
                height: 1.42,
              ),
              children: [
                const TextSpan(text: 'Pay only to: '),
                TextSpan(
                  text: AppConfig.companyUpiId,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () {
            Clipboard.setData(
              ClipboardData(text: AppConfig.companyUpiId),
            );
            AppMessenger.showDriverErrorBanner(context, 'UPI ID copied');
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 33,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: const Color(0x52464646),
                width: 0.7,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.copy_rounded,
              size: 14,
              color: Color(0xFF292D32),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUpiAppCard({
    required String label,
    required String asset,
    required String scheme,
  }) {
    return InkWell(
      onTap: () => _launchSpecificUpiApp(scheme),
      borderRadius: BorderRadius.circular(13),
      child: Container(
        width: 65,
        height: 81,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.black.withOpacity(0.1), width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1C000000),
              blurRadius: 3,
              offset: Offset(1, 1),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 6),
            SizedBox(
              width: 38,
              height: 38,
              child: Image.asset(asset, fit: BoxFit.contain),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Color(0xFF424242),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // How it works card (light blue)
  // ---------------------------------------------------------------------------
  Widget _buildHowItWorksCard() {
    final items = [
      'Pay ₹${AppConfig.dailyPlatformFee.toInt()} platform fee',
      'Get 24 hours of unlimited ride access',
      'Accept and complete rides without limits',
      'Pass expires automatically after 24 hours',
      'All payments go to Raahi Cab Services',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
      decoration: BoxDecoration(
        color: const Color(0xFFE2F0FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: Color(0xFF267CD3),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Text(
                  'i',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'How it works',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF424242),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...items.map(_buildHowItem),
        ],
      ),
    );
  }

  Widget _buildHowItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(
              Icons.check_rounded,
              size: 14,
              color: Color(0xFF267CD3),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Colors.black,
                height: 1.42,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Confirmation section (transaction id + helper text) — appears after UPI
  // launch. Uses the same styling palette as the rest of the screen.
  // ---------------------------------------------------------------------------
  Widget _buildConfirmationSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.green.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green.shade600, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Payment Completed?',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF010101),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _transactionIdController,
            decoration: InputDecoration(
              labelText: 'Transaction ID (Optional)',
              hintText: 'Enter UPI transaction ID',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              prefixIcon: const Icon(Icons.receipt_long, size: 20),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter the transaction ID from your UPI app for faster verification.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom bar — slide-to-confirm button matching Figma
  // ---------------------------------------------------------------------------
  Widget _buildBottomBar(DriverSubscriptionState state) {
    final label = !_paymentInitiated
        ? 'Slide to Pay ₹${AppConfig.dailyPlatformFee.toInt()}'
        : 'Slide to Activate Pass';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 19.75,
            offset: Offset(0, 3.91),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: _SlideToConfirm(
          key: ValueKey('slide_$_slideResetKey${_paymentInitiated}_${_isProcessing}'),
          label: label,
          isLoading: _isProcessing,
          onConfirmed: _handleSlideAction,
        ),
      ),
    );
  }
}

// =============================================================================
// SlideToConfirm widget
// =============================================================================

class _SlideToConfirm extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onConfirmed;

  const _SlideToConfirm({
    super.key,
    required this.label,
    required this.isLoading,
    required this.onConfirmed,
  });

  @override
  State<_SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<_SlideToConfirm>
    with SingleTickerProviderStateMixin {
  static const double _height = 60;
  static const double _handleSize = 46;
  static const double _padding = 7;

  double _dragPosition = 0;
  bool _confirming = false;

  void _onConfirm() {
    if (_confirming || widget.isLoading) return;
    setState(() => _confirming = true);
    HapticFeedback.mediumImpact();
    widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxDrag = maxWidth - _handleSize - (_padding * 2);
        final progress =
            maxDrag <= 0 ? 0.0 : (_dragPosition / maxDrag).clamp(0.0, 1.0);

        return SizedBox(
          height: _height,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Track
              Container(
                height: _height,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E2C2A),
                  borderRadius: BorderRadius.circular(190),
                ),
                alignment: Alignment.center,
                child: Opacity(
                  // Fade label out as user slides closer to the end
                  opacity: (1 - progress).clamp(0.3, 1.0),
                  child: Text(
                    widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              // Slide handle
              Positioned(
                left: _padding + _dragPosition,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    if (widget.isLoading || _confirming) return;
                    setState(() {
                      _dragPosition =
                          (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
                    });
                  },
                  onHorizontalDragEnd: (_) {
                    if (widget.isLoading || _confirming) return;
                    if (_dragPosition >= maxDrag * 0.9) {
                      setState(() => _dragPosition = maxDrag);
                      _onConfirm();
                    } else {
                      setState(() => _dragPosition = 0);
                    }
                  },
                  // Tap on the handle also confirms — simple, accessible fallback
                  onTap: _onConfirm,
                  child: Container(
                    width: _handleSize,
                    height: _handleSize,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: widget.isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFF2E2C2A),
                            ),
                          )
                        : const _DoubleChevron(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DoubleChevron extends StatelessWidget {
  const _DoubleChevron();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: const [
          Positioned(
            left: 0,
            top: 0,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: Color(0xFF2E2C2A),
            ),
          ),
          Positioned(
            left: 8,
            top: 0,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: Color(0xFF2E2C2A),
            ),
          ),
        ],
      ),
    );
  }
}
