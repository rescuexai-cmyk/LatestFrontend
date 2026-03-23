import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/widgets/upi_app_icon.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../providers/ride_booking_provider.dart';
import '../../providers/ride_provider.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key});

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  String _selectedPaymentMethod = 'cash';
  bool _isLoading = false;
  String? _appliedVoucher;
  double _voucherDiscount = 0;

  // Linked UPI accounts - will be displayed in payment methods section
  final List<Map<String, dynamic>> _linkedUpiAccounts = [];

  /// Generate a 4-digit PIN for ride verification.
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
    final rideBookingState = ref.read(rideBookingProvider);
    final baseAmount =
        rideBookingState.fare > 0 ? rideBookingState.fare : 193.20;

    // Calculate discount if voucher is applied
    double discountAmount = 0;
    if (_appliedVoucher != null && _voucherDiscount > 0) {
      discountAmount = baseAmount * (_voucherDiscount / 100);
      if (_appliedVoucher == 'FIRST50' && discountAmount > 100) {
        discountAmount = 100;
      } else if (_appliedVoucher == 'RAAHI20' && discountAmount > 50) {
        discountAmount = 50;
      } else if (_appliedVoucher == 'WELCOME10' && discountAmount > 30) {
        discountAmount = 30;
      }
    }
    final totalAmount = (baseAmount - discountAmount).toStringAsFixed(2);

    final transactionNote = 'Raahi Ride Payment';
    final payeeVpa = AppConfig.companyUpiId; // Company UPI ID
    final payeeName = AppConfig.companyDisplayName;

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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Opening ${app['name']}...'),
              backgroundColor: app['color'] as Color,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (await canLaunchUrl(upiUrl)) {
        // Fallback to generic UPI intent
        await launchUrl(upiUrl, mode: LaunchMode.externalApplication);
      } else {
        // App not installed
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${app['name']} is not installed'),
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
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open ${app['name']}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
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
                    const SizedBox(height: 24),
                    _buildSelectedPayment(),
                  ],
                ),
              ),
            ),
            _buildConfirmButton(),
          ],
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
          GestureDetector(
            onTap: () => context.pop(),
            child: const Icon(Icons.arrow_back, color: Color(0xFF1A1A1A)),
          ),
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
          const Icon(Icons.menu, color: Color(0xFF1A1A1A)),
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
    final rideBookingState = ref.watch(rideBookingProvider);
    final baseAmount =
        rideBookingState.fare > 0 ? rideBookingState.fare : 193.20;

    // Calculate discount if voucher is applied
    double discountAmount = 0;
    if (_appliedVoucher != null && _voucherDiscount > 0) {
      discountAmount = baseAmount * (_voucherDiscount / 100);
      if (_appliedVoucher == 'FIRST50' && discountAmount > 100) {
        discountAmount = 100;
      } else if (_appliedVoucher == 'RAAHI20' && discountAmount > 50) {
        discountAmount = 50;
      } else if (_appliedVoucher == 'WELCOME10' && discountAmount > 30) {
        discountAmount = 30;
      }
    }
    final totalAmount = baseAmount - discountAmount;

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
                  '₹${totalAmount.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
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

  Widget _buildDirectUpiAppButton(Map<String, dynamic> app) {
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
            child: Center(
              child: UpiAppIcon(
                appName: app['name'] as String,
                size: 26,
              ),
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
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (account['color'] as Color).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                account['icon'] as IconData,
                color: account['color'] as Color,
                size: 24,
              ),
            ),
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('UPI account removed')),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildVouchersAddSection() {
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
        const SizedBox(height: 16),
        _buildPaymentOption(
          icon: Icons.confirmation_number_outlined,
          title: _appliedVoucher != null
              ? 'Voucher: $_appliedVoucher'
              : 'Add voucher',
          isSelected: _appliedVoucher != null,
          onTap: _showVoucherSheet,
          showArrow: false,
        ),
      ],
    );
  }

  void _showPaymentSelectedSnackbar(String method) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$method selected'),
        backgroundColor: const Color(0xFF4CAF50),
        duration: const Duration(seconds: 1),
      ),
    );
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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Raahi Wallet selected'),
        backgroundColor: Color(0xFF4CAF50),
        duration: Duration(seconds: 1),
      ),
    );
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

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$upiMethod linked: $upiId'),
                    backgroundColor: const Color(0xFF4CAF50),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD4956A),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Simpl integration coming soon')),
                        );
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
              child: Icon(icon, color: iconColor, size: 24),
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
    final voucherController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
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
              const SizedBox(height: 24),
              // Voucher input
              TextField(
                controller: voucherController,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'Enter voucher code',
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE8E8E8)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFD4956A)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Available vouchers
              const Text(
                'Available Vouchers',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 12),
              _buildVoucherCard(
                code: 'FIRST50',
                description: '50% off on your first ride',
                discount: '50%',
                maxDiscount: '₹100',
                onApply: () {
                  setState(() {
                    _appliedVoucher = 'FIRST50';
                    _voucherDiscount = 50;
                  });
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Voucher FIRST50 applied!'),
                      backgroundColor: Color(0xFF4CAF50),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildVoucherCard(
                code: 'RAAHI20',
                description: '20% off on all rides',
                discount: '20%',
                maxDiscount: '₹50',
                onApply: () {
                  setState(() {
                    _appliedVoucher = 'RAAHI20';
                    _voucherDiscount = 20;
                  });
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Voucher RAAHI20 applied!'),
                      backgroundColor: Color(0xFF4CAF50),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              // Apply button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final code = voucherController.text.trim().toUpperCase();
                    if (code.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Please enter a voucher code')),
                      );
                      return;
                    }
                    // Check voucher validity
                    if (code == 'FIRST50' ||
                        code == 'RAAHI20' ||
                        code == 'WELCOME10') {
                      setState(() {
                        _appliedVoucher = code;
                        _voucherDiscount = code == 'FIRST50'
                            ? 50
                            : (code == 'RAAHI20' ? 20 : 10);
                      });
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Voucher $code applied!'),
                          backgroundColor: const Color(0xFF4CAF50),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Invalid voucher code'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4956A),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Apply Voucher',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              // Remove voucher button if applied
              if (_appliedVoucher != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        _appliedVoucher = null;
                        _voucherDiscount = 0;
                      });
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Voucher removed')),
                      );
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
  }

  Widget _buildVoucherCard({
    required String code,
    required String description,
    required String discount,
    required String maxDiscount,
    required VoidCallback onApply,
  }) {
    final isApplied = _appliedVoucher == code;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isApplied ? const Color(0xFFF5F0EA) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isApplied ? const Color(0xFFD4956A) : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFD4956A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              discount,
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
                  code,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
                ),
                Text(
                  'Max discount: $maxDiscount',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
          if (isApplied)
            const Icon(Icons.check_circle, color: Color(0xFF4CAF50))
          else
            TextButton(
              onPressed: onApply,
              child: const Text(
                'APPLY',
                style: TextStyle(
                  color: Color(0xFFD4956A),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
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
    final rideBookingState = ref.watch(rideBookingProvider);
    final baseAmount =
        rideBookingState.fare > 0 ? rideBookingState.fare : 193.20;

    // Calculate discount if voucher is applied
    double discountAmount = 0;
    if (_appliedVoucher != null && _voucherDiscount > 0) {
      discountAmount = baseAmount * (_voucherDiscount / 100);
      // Apply max discount cap
      if (_appliedVoucher == 'FIRST50' && discountAmount > 100) {
        discountAmount = 100;
      } else if (_appliedVoucher == 'RAAHI20' && discountAmount > 50) {
        discountAmount = 50;
      } else if (_appliedVoucher == 'WELCOME10' && discountAmount > 30) {
        discountAmount = 30;
      }
    }
    final totalAmount = baseAmount - discountAmount;

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
    }
    // Default is Cash

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF8F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD4956A)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: paymentColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(paymentIcon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paymentName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                Text(
                  paymentSubtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹${totalAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              if (discountAmount > 0) ...[
                Text(
                  '₹${baseAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                Text(
                  '-₹${discountAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF4CAF50),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
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
    final existingRideId = ref.read(rideBookingProvider).rideId;
    if (existingRideId != null && existingRideId.isNotEmpty) {
      debugPrint('⚠️ Ride already created ($existingRideId) — resuming');
      if (mounted) context.push(AppRoutes.searchingDrivers);
      return;
    }

    // ── Guard 2: user already has an active ride in provider ──
    final hasActive = ref.read(hasActiveRideProvider);
    if (hasActive) {
      debugPrint('⚠️ Active ride exists in provider — blocking duplicate');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You already have an active ride'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);

    final client = ref.read(apiClientProvider);
    final user = ref.read(currentUserProvider);

    try {
      debugPrint('💰 Creating ride via apiClient...');

      // Create ride request via the centralized API client (includes auth token)
      // Backend: POST /api/rides  body: { pickupLat, pickupLng, dropLat, dropLng, pickupAddress, dropAddress, paymentMethod }
      final waypoints = rideBookingState.stops.isNotEmpty
          ? rideBookingState.stops
              .map((s) => {
                    'lat': s.location.latitude,
                    'lng': s.location.longitude,
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
        paymentMethod: _selectedPaymentMethod.toUpperCase(),
        waypoints: waypoints,
        vehicleType: rideBookingState.selectedCabTypeId,
      );

      debugPrint('API Response: $responseData');

      if (responseData['success'] == true) {
        final rideData = responseData['data'];
        if (rideData != null && rideData is Map) {
          final rideId = rideData['id']?.toString();

          // Backend generates OTP during ride creation and returns it in rideOtp field.
          // This OTP is stored in the database and will be verified when driver starts the ride.
          final rideOtp =
              rideData['rideOtp']?.toString() ?? rideData['otp']?.toString();

          if (rideOtp == null || rideOtp.isEmpty) {
            debugPrint(
                '⚠️ No OTP received from backend - this may cause issues');
          }

          debugPrint('✅ Ride created: $rideId');
          debugPrint(
              '🔐 Ride OTP from backend: $rideOtp - Share this with your driver!');

          // Store the ride ID and PIN
          ref.read(rideBookingProvider.notifier).setRideDetails(
                rideId: rideId,
                otp: rideOtp,
              );

          if (mounted) {
            // Navigate to searching drivers screen
            context.push(AppRoutes.searchingDrivers);
          }
        } else {
          debugPrint('❌ Invalid ride data received');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Invalid ride data received from server'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  responseData['error']?.toString() ?? 'Failed to create ride'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error creating ride: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Error creating ride: ${e.toString().contains('Connection') ? 'Cannot connect to server' : e}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildConfirmButton() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: GestureDetector(
        onTap: _isLoading ? null : _confirmAndCreateRide,
        child: Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color:
                _isLoading ? const Color(0xFFE0E0E0) : const Color(0xFFD4956A),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Center(
            child: _isLoading
                ? const UberShimmer(
                    baseColor: Color(0x99FFFFFF),
                    highlightColor: Color(0xFFFFFFFF),
                    child: UberShimmerBox(
                      width: 140,
                      height: 16,
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                  )
                : const Text(
                    'Confirm Payment',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
