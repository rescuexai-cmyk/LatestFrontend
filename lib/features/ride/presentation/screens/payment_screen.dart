import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/models/promo.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/utils/fare_format.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../widgets/figma_ride_selection_widgets.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';
import 'scheduled_ride_screen.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import 'package:ride_hailing_flutter/core/widgets/figma_square_back_button.dart';
import 'package:ride_hailing_flutter/core/theme/primary_cta_styles.dart';
import 'package:ride_hailing_flutter/core/widgets/raahi_mandala_background.dart';
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key});
  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}
class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  static const Duration _statusBannerDuration = Duration(milliseconds: 2500);

  String _selectedPaymentMethod = 'cash';
  bool _isLoading = false;
  String? _appliedVoucher;
  Promo? _appliedPromo;
  /// Backend-computed preview from POST /api/promo/apply (authoritative).
  PromoPreview? _promoPreview;
  bool _isApplyingVoucher = false;
  List<Promo> _availablePromos = [];
  /// Tracks fare + vehicle used for the last successful promo preview.
  (double, String)? _promoAppliedFor;
  /// Stops promo re-validation once ride booking starts (avoids stale errors on later screens).
  bool _suppressPromoReapply = false;
  // Linked UPI accounts - will be displayed in payment methods section
  final List<Map<String, dynamic>> _linkedUpiAccounts = [];

  @override
  void initState() {
    super.initState();
    _loadAvailablePromos();
  }

  /// Loads server-owned promo codes for the current vehicle type. Failures are
  /// swallowed (empty list) so the payment screen never breaks over promos.
  Future<void> _loadAvailablePromos() async {
    final booking = ref.read(rideBookingProvider);
    final raw = await ref.read(apiClientProvider).getActivePromos(
          vehicleType: booking.selectedCabTypeId,
          city: inferPromoCity(booking.pickupAddress),
        );
    if (!mounted) return;
    setState(() {
      _availablePromos = raw
          .map((e) => Promo.fromJson(e))
          .where((p) => p.code.isNotEmpty)
          .toList();
    });
  }

  String? _promoCity() =>
      inferPromoCity(ref.read(rideBookingProvider).pickupAddress);

  double _estimateFare() {
    final booking = ref.read(rideBookingProvider);
    if (booking.fare > 0) return roundFare(booking.fare);
    if (booking.originalFare > 0) return roundFare(booking.originalFare);
    return 0;
  }

  double _displayOriginalFare() {
    final preview = _promoPreview;
    if (preview != null && preview.originalFare > 0) {
      return roundFare(preview.originalFare);
    }
    return _estimateFare();
  }

  double _payableAmount() {
    final preview = _promoPreview;
    if (preview != null) return roundFare(preview.payableNow);
    return _estimateFare();
  }

  double _discountAmount() {
    final preview = _promoPreview;
    if (preview != null && !preview.isCashback) return preview.discountAmount;
    return 0;
  }

  double? _cashbackAmount() {
    final preview = _promoPreview;
    if (preview == null) return null;
    if (preview.isCashback) {
      return preview.cashbackAmount ?? preview.discountAmount;
    }
    return null;
  }

  void _clearPromo({bool notify = false}) {
    setState(() {
      _appliedVoucher = null;
      _appliedPromo = null;
      _promoPreview = null;
      _promoAppliedFor = null;
    });
    if (notify && mounted) {
      _showStatusSnackBar('Voucher removed');
    }
  }

  PromoPreview? _parsePromoPreview(Map<String, dynamic> res) {
    final data = res['data'];
    if (data is! Map) return null;
    return PromoPreview.fromJson(Map<String, dynamic>.from(data));
  }

  bool _isPromoInvalidResponse(Map<String, dynamic> res) =>
      res['code']?.toString() == 'PROMO_INVALID';

  List<String> _promoConditionLines(Promo promo) {
    final lines = <String>[];
    if (promo.minFare != null) {
      lines.add('Valid on fares ₹${_trimNum(promo.minFare!)}+');
    }
    if (promo.maxDiscount != null) {
      lines.add('Max discount ₹${_trimNum(promo.maxDiscount!)}');
    }
    return lines;
  }

  String? _promoIneligibilityNote(Promo promo, double fare) {
    if (fare <= 0 || promo.minFare == null) return null;
    if (promo.meetsMinFare(fare)) return null;
    final needed = promo.minFare! - fare;
    return 'Your fare is ₹${_trimNum(fare)} · need ₹${_trimNum(promo.minFare!)}+ '
        '(add ₹${_trimNum(needed)} more)';
  }

  Widget _buildVoucherSheetBanner({
    required String message,
    bool isError = true,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFFEBEE) : const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? const Color(0xFFE57373)
              : const Color(0xFF81C784),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 20,
            color: isError ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isError ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Promo? _findPromoByCode(String code) {
    final wanted = code.trim().toUpperCase();
    for (final p in _availablePromos) {
      if (p.code.toUpperCase() == wanted) return p;
    }
    return null;
  }

  Future<void> _applyVoucherCode(String raw, {Promo? known}) async {
    final code = raw.trim().toUpperCase();
    if (code.isEmpty || _isApplyingVoucher) return;

    final fare = _estimateFare();
    if (fare <= 0) return;

    setState(() => _isApplyingVoucher = true);

    final booking = ref.read(rideBookingProvider);
    final client = ref.read(apiClientProvider);
    final city = _promoCity();

    final res = await client.applyPromoPreview(
      code: code,
      fare: fare,
      vehicleType: booking.selectedCabTypeId,
      city: city,
    );
    if (!mounted) return;

    if (res['success'] == true) {
      final preview = _parsePromoPreview(res);
      if (preview == null) {
        setState(() => _isApplyingVoucher = false);
        return;
      }
      setState(() {
        _appliedVoucher = preview.code;
        _appliedPromo = known ?? _findPromoByCode(preview.code);
        _promoPreview = preview;
        _promoAppliedFor = (fare, booking.selectedCabTypeId);
        _isApplyingVoucher = false;
      });
      if (Navigator.canPop(context)) Navigator.pop(context);
      final savings = preview.isCashback
          ? '₹${_trimNum(preview.cashbackAmount ?? preview.discountAmount)} cashback after ride'
          : 'You save ₹${_trimNum(preview.discountAmount)}';
      _showStatusSnackBar('$code applied · $savings');
    } else {
      setState(() => _isApplyingVoucher = false);
    }
  }

  /// Re-call apply when vehicle type or fare changes while a code is applied.
  Future<void> _reapplyPromoIfNeeded() async {
    if (_suppressPromoReapply || _isLoading) return;

    final code = _appliedVoucher;
    if (code == null || _isApplyingVoucher) return;

    final fare = _estimateFare();
    final vehicleType = ref.read(rideBookingProvider).selectedCabTypeId;
    if (fare <= 0) {
      _clearPromo();
      return;
    }

    final key = (fare, vehicleType);
    if (_promoAppliedFor == key) return;

    final res = await ref.read(apiClientProvider).applyPromoPreview(
          code: code,
          fare: fare,
          vehicleType: vehicleType,
          city: _promoCity(),
        );
    if (!mounted) return;

    if (res['success'] == true) {
      final preview = _parsePromoPreview(res);
      if (preview == null) {
        _clearPromo();
        return;
      }
      setState(() {
        _promoPreview = preview;
        _promoAppliedFor = key;
      });
    } else {
      _clearPromo();
    }
  }

  /// Formats a promo number without trailing ".0" (e.g. 50 not 50.0).
  String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  bool _isPromoInvalidError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['code'] == 'PROMO_INVALID') return true;
    }
    return false;
  }

  void _handlePromoInvalidAtBooking() {
    _clearPromo();
  }

  /// Maps UI payment selection to backend enum: CASH | CARD | UPI | WALLET | SCAN_TO_PAY.
  String _paymentMethodForApi() {
    final id = _selectedPaymentMethod.toLowerCase();
    switch (id) {
      case 'cash':
        return 'CASH';
      case 'card':
      case 'netbanking':
        return 'CARD';
      case 'scan':
      case 'qr_pay':
        // Backend now accepts SCAN_TO_PAY natively (no longer remapped to UPI).
        return 'SCAN_TO_PAY';
      case 'raahi_wallet':
        return 'WALLET';
      default:
        final isLinkedUpi = _linkedUpiAccounts.any(
          (a) => (a['id'] as String?)?.toLowerCase() == id,
        );
        if (isLinkedUpi ||
            id.contains('upi') ||
            id.contains('paytm') ||
            id.contains('gpay') ||
            id.contains('phonepe')) {
          return 'UPI';
        }
        return 'CASH';
    }
  }

  String _rideCreationErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final backendMsg = data['error'] ?? data['message'];
        // Express-validator failures come as { message: 'Validation failed',
        // errors: [{ path, msg }, ...] } — surface which field failed.
        final validationErrors = data['errors'];
        if (validationErrors is List && validationErrors.isNotEmpty) {
          final first = validationErrors.first;
          if (first is Map) {
            final field = (first['path'] ?? first['param'])?.toString();
            final msg = first['msg']?.toString();
            if (field != null && msg != null) {
              return 'Invalid booking details ($field: $msg). Please try a different payment method.';
            }
          }
        }
        if (backendMsg != null && backendMsg.toString().trim().isNotEmpty) {
          return backendMsg.toString();
        }
      }
      if (error.response?.statusCode == 400) {
        return 'Invalid booking details. Please check your trip and payment method.';
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Cannot connect to server. Please check your connection.';
      }
    }
    return 'Failed to create ride. Please try again.';
  }

  /// This is a fallback when backend doesn't provide OTP.
  String _generateRidePin() {
    final random = DateTime.now().millisecondsSinceEpoch % 9000 + 1000;
    return random.toString();
  }
  // Available payment methods
  final List<Map<String, dynamic>> _walletOptions = [
    {
      'id': 'raahi_wallet',
      'name': 'Raahi Wallet',
      'icon': Icons.account_balance_wallet,
      'balance': 0
    },
  ];
  final List<Map<String, dynamic>> _upiOptions = [
    {
      'id': 'paytm',
      'name': 'Paytm UPI',
      'icon': Icons.payment,
      'color': Color(0xFF00BAF2)
    },
    {
      'id': 'gpay',
      'name': 'GPay UPI',
      'icon': Icons.g_mobiledata,
      'color': Color(0xFF4285F4)
    },
    {
      'id': 'phonepe',
      'name': 'PhonePe',
      'icon': Icons.phone_android,
      'color': Color(0xFF5F259F)
    },
    {
      'id': 'bhim',
      'name': 'BHIM UPI',
      'icon': Icons.account_balance,
      'color': Color(0xFF00695C)
    },
  ];
  final List<Map<String, dynamic>> _otherOptions = [
    {
      'id': 'card',
      'name': 'Credit/Debit Card',
      'icon': Icons.credit_card,
      'color': Color(0xFF1A1A1A)
    },
    {
      'id': 'netbanking',
      'name': 'Net Banking',
      'icon': Icons.account_balance,
      'color': Color(0xFF2196F3)
    },
  ];
  // Direct UPI Payment Apps
  static const List<Map<String, dynamic>> _directUpiApps = [
    {
      'name': 'Google Pay',
      'package': 'com.google.android.apps.nbu.paisa.user',
      'scheme': 'gpay',
      'icon': Icons.g_mobiledata,
      'color': Color(0xFF4285F4),
    },
    {
      'name': 'PhonePe',
      'package': 'com.phonepe.app',
      'scheme': 'phonepe',
      'icon': Icons.phone_android,
      'color': Color(0xFF5F259F),
    },
    {
      'name': 'Paytm',
      'package': 'net.one97.paytm',
      'scheme': 'paytmmp',
      'icon': Icons.payment,
      'color': Color(0xFF00BAF2),
    },
    {
      'name': 'CRED',
      'package': 'com.dreamplug.androidapp',
      'scheme': 'credpay',
      'icon': Icons.credit_score,
      'color': Color(0xFF1A1A1A),
    },
  ];
  /// Launch UPI payment intent with the specified app
  Future<void> _launchDirectUpiPayment(Map<String, dynamic> app) async {
    final totalAmount = _payableAmount().toStringAsFixed(2);
    final transactionNote = 'Raahi Ride Payment';
    final payeeVpa = AppConfig.companyUpiId;
    final payeeName = AppConfig.companyName;
    // Construct UPI URL
    final upiUrl = Uri.parse(
        'upi://pay?pa=$payeeVpa&pn=$payeeName&am=$totalAmount&cu=INR&tn=${Uri.encodeComponent(transactionNote)}');
    try {
      // Try to launch with the specific app scheme first
      final appScheme = app['scheme'] as String;
      final appSpecificUrl = Uri.parse(
          '$appScheme://pay?pa=$payeeVpa&pn=$payeeName&am=$totalAmount&cu=INR&tn=${Uri.encodeComponent(transactionNote)}');
      if (await canLaunchUrl(appSpecificUrl)) {
        await launchUrl(appSpecificUrl, mode: LaunchMode.externalApplication);
        if (mounted) {
          AppMessenger.showErrorBanner(context, 'Opening ${app['name']}...');
        }
      } else if (await canLaunchUrl(upiUrl)) {
        // Fallback to generic UPI intent
        await launchUrl(upiUrl, mode: LaunchMode.externalApplication);
      } else {
        // App not installed
        if (mounted) {
          _showStatusSnackBar(
            '${app['name']} is not installed',
            backgroundColor: Colors.orange,
            action: SnackBarAction(
              label: 'Install',
              textColor: Colors.white,
              onPressed: () {
                final playStoreUrl = Uri.parse(
                    'https://play.google.com/store/apps/details?id=${app['package']}');
                launchUrl(playStoreUrl, mode: LaunchMode.externalApplication);
              },
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppMessenger.showErrorBanner(context, 'Could not open ${app['name']}: $e');
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    ref.listen(
      rideBookingProvider.select((s) => (s.fare, s.selectedCabTypeId)),
      (prev, next) {
        if (prev != null &&
            prev != next &&
            _appliedVoucher != null &&
            !_suppressPromoReapply &&
            !_isLoading) {
          _reapplyPromoIfNeeded();
        }
      },
    );

    return Scaffold(
      backgroundColor: RaahiMandalaBackground.beige,
      body: RaahiMandalaStack(
        expand: true,
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildVouchersSection(),
                      const SizedBox(height: 24),
                      _buildPaymentMethodsSection(),
                      const SizedBox(height: 24),
                      _buildVouchersAddSection(),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: _buildSelectedPayment(),
              ),
              _buildConfirmButton(),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildHeader() {
    final rideBookingState = ref.watch(rideBookingProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          FigmaSquareBackButton(onPressed: () => context.pop()),
          // Show selected cab type
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              rideBookingState.selectedCabTypeName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 24), // Replaces the menu icon to keep the center widget balanced
        ],
      ),
    );
  }
  Widget _buildVouchersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Payment Methods',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: 40,
          height: 3,
          color: const Color(0xFF1A1A1A),
        ),
      ],
    );
  }
  Widget _buildPaymentMethodsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select payment method',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 16),
        // Linked UPI accounts
        if (_linkedUpiAccounts.isNotEmpty) ...[
          ..._linkedUpiAccounts.map((account) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildLinkedUpiOption(account),
              )),
        ],
        // Cash — always on-screen so users can switch back from card / scan / UPI.
        _buildPaymentOption(
          icon: Icons.payments_outlined,
          title: 'Cash',
          isSelected: _selectedPaymentMethod == 'cash',
          onTap: () {
            setState(() => _selectedPaymentMethod = 'cash');
            _showPaymentSelectedSnackbar('Cash');
          },
        ),
        const SizedBox(height: 12),
        // Scan to Pay option
        _buildPaymentOption(
          icon: Icons.qr_code_scanner,
          title: 'Scan to Pay',
          isSelected: _selectedPaymentMethod == 'scan',
          onTap: () => setState(() => _selectedPaymentMethod = 'scan'),
        ),
        const SizedBox(height: 12),
        // Add payment method
        _buildPaymentOption(
          icon: Icons.add,
          title: 'Add payment method',
          isSelected: false,
          onTap: _showPaymentMethodsSheet,
          showArrow: false,
        ),
        const SizedBox(height: 24),
        // Direct UPI Payment Section
        _buildDirectUpiPaymentSection(),
      ],
    );
  }
  Widget _buildDirectUpiPaymentSection() {
    final discountAmount = _discountAmount();
    final totalAmount = _payableAmount();
    final cashback = _cashbackAmount();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF8F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4956A).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.flash_on,
                  color: Color(0xFFD4956A),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pay Directly via UPI',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    Text(
                      'Quick payment through your favorite app',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4956A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  formatInrFare(totalAmount),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (cashback != null && cashback > 0) ...[
            const SizedBox(height: 8),
            Text(
              '₹${_trimNum(cashback)} cashback after ride',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (discountAmount > 0) ...[
            const SizedBox(height: 8),
            Text(
              'You save ₹${_trimNum(discountAmount)}',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // UPI App Grid
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _directUpiApps
                .map((app) => _buildDirectUpiAppButton(app))
                .toList(),
          ),
        ],
      ),
    );
  }
  /// Resolve a UPI brand logo asset path for a known brand key/scheme/method id.
  /// Returns null when no brand asset is available (caller should fall back to
  /// a Material icon).
  static String? _upiBrandAssetFor(String? key) {
    if (key == null) return null;
    final k = key.toLowerCase();
    if (k.contains('gpay') || k.contains('google')) {
      return 'assets/images/upi_gpay.png';
    }
    if (k.contains('phonepe')) return 'assets/images/upi_phonepe.png';
    if (k.contains('paytm')) return 'assets/images/upi_paytm.png';
    if (k.contains('bhim')) return 'assets/images/upi_bhim.png';
    if (k.contains('cred')) return 'assets/images/upi_cred.png';
    return null;
  }
  Widget _buildDirectUpiAppButton(Map<String, dynamic> app) {
    final brandAsset = _upiBrandAssetFor(app['scheme'] as String?) ??
        _upiBrandAssetFor(app['name'] as String?);
    return GestureDetector(
      onTap: () => _launchDirectUpiPayment(app),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (app['color'] as Color).withOpacity(0.3),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (app['color'] as Color).withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: brandAsset != null
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.asset(brandAsset, fit: BoxFit.contain),
                  )
                : Icon(
                    app['icon'] as IconData,
                    color: app['color'] as Color,
                    size: 26,
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            app['name'] as String,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A1A),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
  Widget _buildLinkedUpiOption(Map<String, dynamic> account) {
    final isSelected = _selectedPaymentMethod == account['id'];
    return GestureDetector(
      onTap: () => setState(() => _selectedPaymentMethod = account['id']),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFAF8F5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                isSelected ? const Color(0xFFD4956A) : const Color(0xFFE8E8E8),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Builder(builder: (_) {
              final brandAsset =
                  _upiBrandAssetFor(account['methodId'] as String?) ??
                      _upiBrandAssetFor(account['methodName'] as String?);
              return Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (account['color'] as Color).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: brandAsset != null
                    ? Padding(
                        padding: const EdgeInsets.all(7),
                        child: Image.asset(brandAsset, fit: BoxFit.contain),
                      )
                    : Icon(
                        account['icon'] as IconData,
                        color: account['color'] as Color,
                        size: 24,
                      ),
              );
            }),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account['methodName'] as String,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    account['upiId'] as String,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Color(0xFFD4956A), size: 24)
            else
              GestureDetector(
                onTap: () => _removeLinkedUpi(account['id']),
                child:
                    const Icon(Icons.close, color: Color(0xFF888888), size: 20),
              ),
          ],
        ),
      ),
    );
  }
  void _removeLinkedUpi(String accountId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove UPI'),
        content:
            const Text('Are you sure you want to remove this UPI account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _linkedUpiAccounts.removeWhere((acc) => acc['id'] == accountId);
                if (_selectedPaymentMethod == accountId) {
                  _selectedPaymentMethod = 'cash';
                }
              });
              AppMessenger.showErrorBanner(context, 'UPI account removed');
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
  Widget _buildVouchersAddSection() {
    final discountAmount = _discountAmount();
    final cashback = _cashbackAmount();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Vouchers',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        if (_appliedVoucher != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF4CAF50).withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cashback != null && cashback > 0
                        ? '$_appliedVoucher applied · ₹${_trimNum(cashback)} cashback after ride'
                        : '$_appliedVoucher applied · You save ₹${_trimNum(discountAmount)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2E7D32),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _clearPromo(notify: true),
                  child: const Text(
                    'Remove',
                    style: TextStyle(
                      color: Color(0xFF2E7D32),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildPaymentOption(
          icon: Icons.confirmation_number_outlined,
          title: _appliedVoucher != null
              ? 'Change voucher'
              : 'Add voucher',
          isSelected: _appliedVoucher != null,
          onTap: _showVoucherSheet,
          showArrow: false,
        ),
      ],
    );
  }
  void _showStatusSnackBar(
    String message, {
    Color backgroundColor = const Color(0xFF4CAF50),
    SnackBarAction? action,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: _statusBannerDuration,
        action: action,
      ),
    );
  }

  void _showPaymentSelectedSnackbar(String method) {
    _showStatusSnackBar('$method selected');
  }
  void _addWalletToLinkedAccounts() {
    setState(() {
      // Check if Raahi Wallet already exists
      final existingIndex =
          _linkedUpiAccounts.indexWhere((acc) => acc['id'] == 'raahi_wallet');
      if (existingIndex == -1) {
        // Add Raahi Wallet to linked accounts
        _linkedUpiAccounts.insert(0, {
          'id': 'raahi_wallet',
          'methodId': 'raahi_wallet',
          'methodName': 'Raahi Wallet',
          'upiId': 'Balance: ₹0',
          'icon': Icons.account_balance_wallet,
          'color': const Color(0xFFD4956A),
        });
      }
      // Select Raahi Wallet
      _selectedPaymentMethod = 'raahi_wallet';
    });
    _showStatusSnackBar('Raahi Wallet selected');
  }
  void _showUpiInputDialog(String upiMethod, String methodId) {
    final upiController = TextEditingController();
    String? upiError;
    // Get placeholder based on method
    String placeholder;
    String hint;
    switch (upiMethod) {
      case 'Paytm UPI':
        placeholder = 'mobile@paytm';
        hint = 'Enter your Paytm UPI ID';
        break;
      case 'GPay UPI':
        placeholder = 'mobile@okicici';
        hint = 'Enter your Google Pay UPI ID';
        break;
      case 'PhonePe':
        placeholder = 'mobile@ybl';
        hint = 'Enter your PhonePe UPI ID';
        break;
      case 'BHIM UPI':
        placeholder = 'mobile@upi';
        hint = 'Enter your BHIM UPI ID';
        break;
      default:
        placeholder = 'yourname@bank';
        hint = 'Enter your UPI ID';
    }
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4956A).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:
                    const Icon(Icons.account_balance, color: Color(0xFFD4956A)),
              ),
              const SizedBox(width: 12),
              Text(upiMethod, style: const TextStyle(fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hint,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF888888),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: upiController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: placeholder,
                  prefixIcon: const Icon(Icons.alternate_email),
                  errorText: upiError,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE8E8E8)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFD4956A)),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.red),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Example: mobile@paytm, yourname@okicici',
                style: TextStyle(fontSize: 11, color: Color(0xFF888888)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final upiId = upiController.text.trim();
                // Validate UPI ID
                if (upiId.isEmpty) {
                  setDialogState(() => upiError = 'Please enter UPI ID');
                  return;
                }
                if (!upiId.contains('@')) {
                  setDialogState(() => upiError = 'Invalid UPI ID format');
                  return;
                }
                // Valid UPI ID - Add to linked accounts
                Navigator.pop(context);
                // Get icon and color for the UPI method
                IconData upiIcon;
                Color upiColor;
                switch (methodId) {
                  case 'paytm_upi':
                    upiIcon = Icons.payment;
                    upiColor = const Color(0xFF00BAF2);
                    break;
                  case 'gpay_upi':
                    upiIcon = Icons.g_mobiledata;
                    upiColor = const Color(0xFF4285F4);
                    break;
                  case 'phonepe':
                    upiIcon = Icons.phone_android;
                    upiColor = const Color(0xFF5F259F);
                    break;
                  case 'bhim_upi':
                    upiIcon = Icons.account_balance;
                    upiColor = const Color(0xFF00695C);
                    break;
                  default:
                    upiIcon = Icons.account_balance;
                    upiColor = const Color(0xFFD4956A);
                }
                // Create unique ID for this linked account
                final linkedId =
                    '${methodId}_${DateTime.now().millisecondsSinceEpoch}';
                setState(() {
                  // Check if this UPI ID already exists
                  final existingIndex = _linkedUpiAccounts
                      .indexWhere((acc) => acc['upiId'] == upiId);
                  if (existingIndex == -1) {
                    // Add new linked account
                    _linkedUpiAccounts.add({
                      'id': linkedId,
                      'methodId': methodId,
                      'methodName': upiMethod,
                      'upiId': upiId,
                      'icon': upiIcon,
                      'color': upiColor,
                    });
                  }
                  // Select this payment method
                  _selectedPaymentMethod = linkedId;
                });
                _showStatusSnackBar('$upiMethod linked: $upiId');
              },
              style: PrimaryCtaStyles.elevated(
                minimumSize: const Size(0, PrimaryCtaStyles.height),
              ),
              child:
                  const Text('Link UPI', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
  void _showPaymentMethodsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Payments',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.help_outline, color: Colors.white),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    // Personal Wallet Section
                    const Text(
                      'Personal Wallet',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Raahi Wallet
                    _buildPaymentMethodTile(
                      icon: Icons.account_balance_wallet,
                      iconColor: const Color(0xFFD4956A),
                      title: 'Raahi Wallet',
                      trailing: '₹0',
                      onTap: () {
                        Navigator.pop(context);
                        _addWalletToLinkedAccounts();
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    // QR Pay
                    _buildPaymentMethodTile(
                      icon: Icons.qr_code_scanner,
                      iconColor: Colors.grey,
                      title: 'QR Pay',
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _selectedPaymentMethod = 'qr_pay');
                        _showPaymentSelectedSnackbar('QR Pay');
                      },
                    ),
                    const SizedBox(height: 24),
                    // UPI Section
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'UPI',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A1A),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Pay by any UPI app',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Paytm UPI
                    _buildPaymentMethodTile(
                      icon: Icons.payment,
                      iconColor: const Color(0xFF00BAF2),
                      iconAsset: 'assets/images/upi_paytm.png',
                      title: 'Paytm UPI',
                      subtitle: 'Assured ₹25-₹200 Cashback',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiInputDialog('Paytm UPI', 'paytm_upi');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    // GPay UPI
                    _buildPaymentMethodTile(
                      icon: Icons.g_mobiledata,
                      iconColor: const Color(0xFF4285F4),
                      iconAsset: 'assets/images/upi_gpay.png',
                      title: 'GPay UPI',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiInputDialog('GPay UPI', 'gpay_upi');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    // PhonePe
                    _buildPaymentMethodTile(
                      icon: Icons.phone_android,
                      iconColor: const Color(0xFF5F259F),
                      iconAsset: 'assets/images/upi_phonepe.png',
                      title: 'PhonePe',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiInputDialog('PhonePe', 'phonepe');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    // BHIM UPI
                    _buildPaymentMethodTile(
                      icon: Icons.account_balance,
                      iconColor: const Color(0xFF00695C),
                      iconAsset: 'assets/images/upi_bhim.png',
                      title: 'BHIM UPI',
                      onTap: () {
                        Navigator.pop(context);
                        _showUpiInputDialog('BHIM UPI', 'bhim_upi');
                      },
                    ),
                    const SizedBox(height: 24),
                    // Pay Later Section
                    const Text(
                      'Pay later',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildPaymentMethodTile(
                      icon: Icons.schedule,
                      iconColor: const Color(0xFF4CAF50),
                      title: 'Simpl',
                      trailing: 'LINK',
                      trailingColor: const Color(0xFF2196F3),
                      onTap: () {
                        AppMessenger.showErrorBanner(context, 'Simpl integration coming soon');
                      },
                    ),
                    const SizedBox(height: 24),
                    // Other Methods
                    const Text(
                      'Other methods',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildPaymentMethodTile(
                      icon: Icons.credit_card,
                      iconColor: Colors.white,
                      title: 'Credit/Debit Card',
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _selectedPaymentMethod = 'card');
                        _showPaymentSelectedSnackbar('Credit/Debit Card');
                      },
                    ),
                    const Divider(color: Colors.grey, height: 1),
                    _buildPaymentMethodTile(
                      icon: Icons.money,
                      iconColor: const Color(0xFF4CAF50),
                      title: 'Cash',
                      subtitle: 'Pay on delivery',
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _selectedPaymentMethod = 'cash');
                        _showPaymentSelectedSnackbar('Cash');
                      },
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildPaymentMethodTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    String? trailing,
    Color? trailingColor,
    required VoidCallback onTap,
    String? iconAsset,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: iconAsset != null
                  ? Padding(
                      padding: const EdgeInsets.all(7),
                      child: Image.asset(iconAsset, fit: BoxFit.contain),
                    )
                  : Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                      maxLines: 2,
                    ),
                ],
              ),
            ),
            trailing != null
                ? Text(
                    trailing,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: trailingColor ?? Colors.white,
                    ),
                  )
                : const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
  void _showVoucherSheet() {
    final voucherController = TextEditingController(
      text: _appliedVoucher ?? '',
    );
    final currentFare = _estimateFare();
    String? sheetError;
    String? sheetErrorCode;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void clearSheetError() {
            if (sheetError == null) return;
            setSheetState(() {
              sheetError = null;
              sheetErrorCode = null;
            });
          }

          Future<void> applyFromSheet(String raw, {Promo? known}) async {
            final code = raw.trim().toUpperCase();
            if (code.isEmpty) {
              setSheetState(() {
                sheetError = 'Please enter a voucher code';
                sheetErrorCode = null;
              });
              return;
            }
            if (_isApplyingVoucher) return;

            final fare = _estimateFare();
            if (fare <= 0) {
              setSheetState(() {
                sheetError =
                    'Trip fare is not ready yet. Please go back and select a vehicle.';
                sheetErrorCode = code;
              });
              return;
            }

            if (known != null && !known.meetsMinFare(fare)) {
              setSheetState(() {
                sheetError = _promoIneligibilityNote(known, fare) ??
                    'This voucher needs a higher fare to apply.';
                sheetErrorCode = code;
              });
              return;
            }

            setSheetState(() {
              _isApplyingVoucher = true;
              sheetError = null;
              sheetErrorCode = null;
            });

            final booking = ref.read(rideBookingProvider);
            final res = await ref.read(apiClientProvider).applyPromoPreview(
                  code: code,
                  fare: fare,
                  vehicleType: booking.selectedCabTypeId,
                  city: _promoCity(),
                );
            if (!mounted) return;

            if (res['success'] == true) {
              final preview = _parsePromoPreview(res);
              if (preview == null) {
                setSheetState(() {
                  _isApplyingVoucher = false;
                  sheetError =
                      'Could not read discount from server. Please try again.';
                  sheetErrorCode = code;
                });
                return;
              }
              setState(() {
                _appliedVoucher = preview.code;
                _appliedPromo = known ?? _findPromoByCode(preview.code);
                _promoPreview = preview;
                _promoAppliedFor = (fare, booking.selectedCabTypeId);
                _isApplyingVoucher = false;
              });
              if (Navigator.canPop(sheetContext)) Navigator.pop(sheetContext);
              final savings = preview.isCashback
                  ? '₹${_trimNum(preview.cashbackAmount ?? preview.discountAmount)} cashback after ride'
                  : 'You save ₹${_trimNum(preview.discountAmount)}';
              _showStatusSnackBar('${preview.code} applied · $savings');
            } else {
              setSheetState(() {
                _isApplyingVoucher = false;
                sheetError =
                    (res['message'] ?? 'This voucher code is not valid.')
                        .toString();
                sheetErrorCode = code;
              });
            }
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0E0E0),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Apply Voucher',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Enter your voucher code to get discount',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF888888),
                      ),
                    ),
                    if (sheetError != null) ...[
                      const SizedBox(height: 16),
                      _buildVoucherSheetBanner(message: sheetError!),
                    ],
                    const SizedBox(height: 24),
                    TextField(
                      controller: voucherController,
                      textCapitalization: TextCapitalization.characters,
                      enabled: !_isApplyingVoucher,
                      onChanged: (_) => clearSheetError(),
                      decoration: InputDecoration(
                        hintText: 'Enter voucher code',
                        errorText: sheetError != null && sheetErrorCode == null
                            ? sheetError
                            : null,
                        prefixIcon: const Icon(Icons.confirmation_number_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: sheetError != null
                                ? const Color(0xFFE57373)
                                : const Color(0xFFE8E8E8),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: sheetError != null
                                ? const Color(0xFFC62828)
                                : const Color(0xFFD4956A),
                          ),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFC62828)),
                        ),
                      ),
                    ),
                    if (currentFare > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Current trip fare: ₹${_trimNum(currentFare)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_availablePromos.isNotEmpty) ...[
                      const Text(
                        'Available Vouchers',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ..._availablePromos.map(
                        (p) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildVoucherCard(
                            p,
                            fare: currentFare,
                            highlightError: sheetErrorCode == p.code,
                            errorMessage:
                                sheetErrorCode == p.code ? sheetError : null,
                            onApply: p.meetsMinFare(currentFare) || currentFare <= 0
                                ? () => applyFromSheet(p.code, known: p)
                                : null,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isApplyingVoucher
                            ? null
                            : () => applyFromSheet(voucherController.text),
                        style: PrimaryCtaStyles.elevated(),
                        child: _isApplyingVoucher
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Apply Voucher',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                    if (_appliedVoucher != null) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: _isApplyingVoucher
                              ? null
                              : () {
                                  _clearPromo(notify: true);
                                  if (Navigator.canPop(sheetContext)) {
                                    Navigator.pop(sheetContext);
                                  }
                                },
                          child: const Text(
                            'Remove Applied Voucher',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Applies a promo picked from the active list (backend-validated).
  void _applyPromo(Promo promo) {
    _applyVoucherCode(promo.code, known: promo);
  }

  Widget _buildVoucherCard(
    Promo promo, {
    required double fare,
    VoidCallback? onApply,
    bool highlightError = false,
    String? errorMessage,
  }) {
    final isApplied = _appliedVoucher == promo.code;
    final isEligible = fare <= 0 || promo.meetsMinFare(fare);
    final ineligibilityNote = _promoIneligibilityNote(promo, fare);
    final conditionLines = _promoConditionLines(promo);
    final discountLabel = promo.type == PromoType.percent
        ? '${_trimNum(promo.value)}%'
        : '₹${_trimNum(promo.value)}';

    Color cardBg;
    Color borderColor;
    if (isApplied) {
      cardBg = const Color(0xFFF5F0EA);
      borderColor = const Color(0xFFD4956A);
    } else if (highlightError) {
      cardBg = const Color(0xFFFFEBEE);
      borderColor = const Color(0xFFE57373);
    } else if (!isEligible) {
      cardBg = const Color(0xFFFAFAFA);
      borderColor = const Color(0xFFE0E0E0);
    } else {
      cardBg = const Color(0xFFF5F5F5);
      borderColor = Colors.transparent;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isEligible
                      ? const Color(0xFFD4956A)
                      : const Color(0xFFBDBDBD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  discountLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      promo.code,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: isEligible
                            ? const Color(0xFF1A1A1A)
                            : const Color(0xFF757575),
                      ),
                    ),
                    if (promo.description.isNotEmpty)
                      Text(
                        promo.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: isEligible
                              ? const Color(0xFF888888)
                              : const Color(0xFF9E9E9E),
                        ),
                      ),
                  ],
                ),
              ),
              if (isApplied)
                const Icon(Icons.check_circle, color: Color(0xFF4CAF50))
              else if (onApply != null)
                TextButton(
                  onPressed: onApply,
                  child: const Text(
                    'APPLY',
                    style: TextStyle(
                      color: Color(0xFFD4956A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                Text(
                  'Not eligible',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),
          if (conditionLines.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: conditionLines
                  .map(
                    (line) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isEligible
                            ? const Color(0xFFFBF2E8)
                            : const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isEligible
                              ? const Color(0xFFD4956A).withValues(alpha: 0.35)
                              : const Color(0xFFE0E0E0),
                        ),
                      ),
                      child: Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isEligible
                              ? const Color(0xFF8B5E34)
                              : const Color(0xFF757575),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          if (isEligible && fare > 0 && promo.minFare != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 14,
                  color: Colors.green.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  'Eligible for your ₹${_trimNum(fare)} fare',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade700,
                  ),
                ),
              ],
            ),
          ],
          if (!isEligible && ineligibilityNote != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Colors.orange.shade800,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    ineligibilityNote,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade900,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (highlightError && errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              errorMessage,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFFC62828),
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
  Widget _buildPaymentOption({
    required IconData icon,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
    bool showArrow = true,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFAF8F5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                isSelected ? const Color(0xFFD4956A) : const Color(0xFFE8E8E8),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: const Color(0xFF1A1A1A), size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ),
            if (showArrow && isSelected)
              const Icon(Icons.check_circle, color: Color(0xFFD4956A)),
          ],
        ),
      ),
    );
  }
  Widget _buildSelectedPayment() {
    ref.watch(rideBookingProvider);
    final baseAmount = _displayOriginalFare();
    final discountAmount = _discountAmount();
    final totalAmount = _payableAmount();
    final cashback = _cashbackAmount();
    // Get selected payment method details
    String paymentName = 'Cash';
    String paymentSubtitle = 'Pay on delivery';
    IconData paymentIcon = Icons.money;
    Color paymentColor = const Color(0xFF4CAF50);
    // Check if it's a linked UPI account
    final linkedAccount = _linkedUpiAccounts.firstWhere(
      (acc) => acc['id'] == _selectedPaymentMethod,
      orElse: () => {},
    );
    if (linkedAccount.isNotEmpty) {
      paymentName = linkedAccount['methodName'] as String;
      paymentSubtitle = linkedAccount['upiId'] as String;
      paymentIcon = linkedAccount['icon'] as IconData;
      paymentColor = linkedAccount['color'] as Color;
    } else if (_selectedPaymentMethod == 'raahi_wallet') {
      paymentName = 'Raahi Wallet';
      paymentSubtitle = 'Balance: ₹0';
      paymentIcon = Icons.account_balance_wallet;
      paymentColor = const Color(0xFFD4956A);
    } else if (_selectedPaymentMethod == 'scan') {
      paymentName = 'Scan to Pay';
      paymentSubtitle = 'Scan QR code';
      paymentIcon = Icons.qr_code_scanner;
      paymentColor = const Color(0xFF1A1A1A);
    } else if (_selectedPaymentMethod == 'qr_pay') {
      paymentName = 'QR Pay';
      paymentSubtitle = 'Scan QR code';
      paymentIcon = Icons.qr_code_scanner;
      paymentColor = const Color(0xFF888888);
    } else if (_selectedPaymentMethod == 'card') {
      paymentName = 'Credit/Debit Card';
      paymentSubtitle = 'Visa, Mastercard, RuPay';
      paymentIcon = Icons.credit_card;
      paymentColor = const Color(0xFF1A1A1A);
    } else if (_selectedPaymentMethod == 'netbanking') {
      paymentName = 'Net Banking';
      paymentSubtitle = 'Pay from your bank account';
      paymentIcon = Icons.account_balance;
      paymentColor = const Color(0xFF2196F3);
    } else if (_selectedPaymentMethod == 'cash') {
      paymentName = 'Cash';
      paymentSubtitle = 'Pay on delivery';
      paymentIcon = Icons.payments_outlined;
      paymentColor = const Color(0xFF4CAF50);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Selected method',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBF7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFD4956A).withValues(alpha: 0.45),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color: paymentColor.withValues(alpha: 0.28),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: paymentColor,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Icon(paymentIcon, color: Colors.white, size: 17),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        paymentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A1A),
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        paymentSubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: Color(0xFF888888),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5EDE4),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        child: Text(
                          formatInrFare(totalAmount),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFB8743A),
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                    if (discountAmount > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        '₹${baseAmount.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF9E9E9E),
                          decoration: TextDecoration.lineThrough,
                          height: 1,
                        ),
                      ),
                      Text(
                        '-₹${discountAmount.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF4CAF50),
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                    ] else if (cashback != null && cashback > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        '₹${_trimNum(cashback)} cashback',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF4CAF50),
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
  static const double _intercityThresholdKm = 50;
  Future<void> _confirmAndCreateRide() async {
    // ── Guard 0: block intercity rides (coming soon) ──
    final rideBookingState = ref.read(rideBookingProvider);
    final distanceKm = rideBookingState.distance / 1000;
    if (distanceKm > _intercityThresholdKm) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(Icons.info_outline, color: Color(0xFFD4956A), size: 28),
                SizedBox(width: 12),
                Text('Intercity Coming Soon'),
              ],
            ),
            content: const Text(
              'Rides between different cities are not available yet. We are working on bringing intercity rides soon. Please book a ride within the same city for now.',
              style: TextStyle(fontSize: 15),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }
    // ── Guard 1: ride already created for this booking (idempotency) ──
    final existingBooking = ref.read(rideBookingProvider);
    final existingRideId = existingBooking.rideId;
    if (existingRideId != null && existingRideId.isNotEmpty) {
      if (existingBooking.isScheduledRide) {
        await ref
            .read(rideBookingProvider.notifier)
            .stashScheduledAndReleaseSlot();
      } else {
        debugPrint('⚠️ Ride already created ($existingRideId) — resuming');
        if (mounted) resumePendingRideNavigation(context, ref);
        return;
      }
    }
    // ── Guard 2: user already has an active ride in provider ──
    final hasActive = ref.read(hasActiveRideProvider);
    if (hasActive) {
      debugPrint('⚠️ Active ride exists in provider — blocking duplicate');
      if (mounted) {
        AppMessenger.showErrorBanner(context, 'You already have an active ride');
      }
      return;
    }
    setState(() {
      _isLoading = true;
      _suppressPromoReapply = true;
    });
    final client = ref.read(apiClientProvider);
    final user = ref.read(currentUserProvider);
    try {
      debugPrint('💰 Creating ride via apiClient...');
      // Create ride request via the centralized API client (includes auth token)
      // Backend: POST /api/rides  body: { pickupLat, pickupLng, dropLat, dropLng, pickupAddress, dropAddress, paymentMethod }
      final completeStops = rideBookingState.stops
          .where((s) => s.location != null)
          .toList();
      final stopsForApi = completeStops.isNotEmpty
          ? completeStops
              .map((s) => {
                    'lat': s.location!.latitude,
                    'lng': s.location!.longitude,
                    'address': s.address,
                  })
              .toList()
          : null;
      final responseData = await client.createRide(
        pickupLat: rideBookingState.pickupLocation?.latitude ?? 0,
        pickupLng: rideBookingState.pickupLocation?.longitude ?? 0,
        dropLat: rideBookingState.destinationLocation?.latitude ?? 0,
        dropLng: rideBookingState.destinationLocation?.longitude ?? 0,
        pickupAddress: rideBookingState.pickupAddress ?? 'Unknown pickup',
        dropAddress:
            rideBookingState.destinationAddress ?? 'Unknown destination',
        paymentMethod: _paymentMethodForApi(),
        stops: stopsForApi,
        vehicleType: rideBookingState.selectedCabTypeId,
        scheduledTime: rideBookingState.scheduledTime?.toUtc().toIso8601String(),
        promoCode: _appliedVoucher,
        quotedFare: _payableAmount(),
      );
      debugPrint('API Response: $responseData');
      if (responseData['success'] == true) {
        final rideData = responseData['data'];
        if (rideData != null && rideData is Map) {
          final rideMap = Map<String, dynamic>.from(rideData);
          final rideId = rideMap['id']?.toString();
          final rideOtp =
              rideMap['rideOtp']?.toString() ?? rideMap['otp']?.toString();

          // Authoritative fare after promo applied at booking time.
          _clearPromo();
          final totalFareRaw = rideMap['totalFare'] ?? rideMap['total_fare'];
          if (totalFareRaw is num) {
            ref.read(rideBookingProvider.notifier).updateRouteInfo(
                  fare: totalFareRaw.toDouble(),
                );
          }

          if (rideOtp == null || rideOtp.isEmpty) {
            debugPrint(
                '⚠️ No OTP received from backend - this may cause issues');
          }
          debugPrint('✅ Ride created: $rideId');
          debugPrint(
              '🔐 Ride OTP from backend: $rideOtp - Share this with your driver!');
          await ref.read(rideBookingProvider.notifier).setRideDetails(
                rideId: rideId,
                otp: rideOtp,
              );
          if (mounted) {
            navigateAfterRideCreated(context, ref);
          }
        } else {
          debugPrint('❌ Invalid ride data received');
          if (mounted) {
            AppMessenger.showErrorBanner(context, 'Invalid ride data received from server');
          }
        }
      } else {
        if (mounted) {
          if (_isPromoInvalidResponse(responseData)) {
            _handlePromoInvalidAtBooking();
          } else {
            AppMessenger.showErrorBanner(
              context,
              responseData['message']?.toString() ??
                  responseData['error']?.toString() ??
                  'Failed to create ride',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error creating ride: $e');
      if (mounted) {
        if (_isPromoInvalidError(e)) {
          _handlePromoInvalidAtBooking();
        } else {
          AppMessenger.showErrorBanner(context, _rideCreationErrorMessage(e));
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
  Widget _buildConfirmButton() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SizedBox(
        width: double.infinity,
        child: _isLoading
            ? Container(
                height: FigmaSlideToBookButton.trackHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(
                    FigmaSlideToBookButton.trackRadius,
                  ),
                ),
                child: const UberShimmer(
                  baseColor: Color(0x99CCCCCC),
                  highlightColor: Color(0xFFFFFFFF),
                  child: UberShimmerBox(
                    width: 180,
                    height: 14,
                    borderRadius: BorderRadius.all(Radius.circular(7)),
                  ),
                ),
              )
            : FigmaSlideToBookButton(
                enabled: !_isLoading,
                trackLabel: 'Slide to confirm payment!',
                onSlideComplete: _confirmAndCreateRide,
              ),
      ),
    );
  }
}