import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../providers/driver_onboarding_provider.dart';
import '../../../../core/providers/settings_provider.dart';

class DriverOnboardingScreen extends ConsumerStatefulWidget {
  final bool isUpdateMode;
  final bool returnToProfileOnBack;

  const DriverOnboardingScreen({
    super.key,
    this.isUpdateMode = false,
    this.returnToProfileOnBack = false,
  });

  @override
  ConsumerState<DriverOnboardingScreen> createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends ConsumerState<DriverOnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isResolvingUpdateMode = false;

  // Raahi color palette
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);

  @override
  void initState() {
    super.initState();
    if (widget.isUpdateMode) {
      _isResolvingUpdateMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resolveUpdateModeEntry();
      });
    }
  }

  Future<void> _resolveUpdateModeEntry() async {
    try {
      final response = await ref.read(apiClientProvider).getDriverProfile();
      final data = (response['data'] as Map<String, dynamic>?) ?? const {};
      final profile = (data['driver'] as Map<String, dynamic>?) ?? data;
      final onboarding =
          (profile['onboarding'] as Map<String, dynamic>?) ?? const {};

      final isOnboarded = profile['isOnboarded'] == true ||
          profile['is_onboarded'] == true ||
          profile['onboardingCompleted'] == true ||
          profile['onboarding_completed'] == true ||
          onboarding['is_verified'] == true ||
          onboarding['documents_verified'] == true ||
          onboarding['documents_submitted'] == true ||
          (onboarding['status'] as String?)?.toUpperCase() == 'COMPLETED' ||
          (onboarding['status'] as String?)?.toUpperCase() ==
              'DOCUMENT_VERIFICATION';
      final hasDocuments = _profileHasDocuments(profile['documents']);

      if (mounted && widget.isUpdateMode && isOnboarded && hasDocuments) {
        final returnToProfile = widget.returnToProfileOnBack ? 'true' : 'false';
        context.go(
          '${AppRoutes.driverDocuments}?isUpdateMode=true&returnToProfile=$returnToProfile',
        );
        return;
      }
    } catch (e) {
      debugPrint('❌ Failed to resolve update mode entry: $e');
    }

    if (mounted) {
      setState(() => _isResolvingUpdateMode = false);
    }
  }

  bool _profileHasDocuments(dynamic rawDocuments) {
    if (rawDocuments is List) {
      return rawDocuments.isNotEmpty;
    }
    if (rawDocuments is Map) {
      if (rawDocuments.isEmpty) return false;
      final pendingCount =
          (rawDocuments['pending_count'] as num?)?.toInt() ??
              (rawDocuments['pendingCount'] as num?)?.toInt() ??
              0;
      if (pendingCount > 0) return true;

      if (rawDocuments['all_verified'] == true ||
          rawDocuments['allVerified'] == true ||
          rawDocuments['license_verified'] == true ||
          rawDocuments['insurance_verified'] == true ||
          rawDocuments['vehicle_registration_verified'] == true) {
        return true;
      }

      return rawDocuments.values.any((value) {
        if (value == null) return false;
        if (value is bool) return value;
        if (value is num) return value > 0;
        if (value is String) return value.trim().isNotEmpty;
        if (value is List) return value.isNotEmpty;
        if (value is Map) return value.isNotEmpty;
        return true;
      });
    }
    return false;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < 4) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      if (widget.returnToProfileOnBack) {
        context.go(AppRoutes.driverHome);
      } else {
        context.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isResolvingUpdateMode) {
      return const Scaffold(
        backgroundColor: _beige,
        body: Center(
          child: CircularProgressIndicator(color: _accent),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _beige,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            
            // Page content
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (page) => setState(() => _currentPage = page),
                children: [
                  _LanguageSelectionPage(onContinue: _nextPage),
                  _VehicleTypeSelectionPage(onContinue: _nextPage),
                  _PersonalInfoPage(onContinue: _nextPage),
                  _DocumentsUploadFlow(onComplete: _nextPage),
                  _VerificationStatusPage(onComplete: () => context.go(AppRoutes.driverWelcome)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          GestureDetector(
            onTap: _previousPage,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _inputBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded, color: _textPrimary, size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.asset('assets/images/raahi_logo.png', height: 28),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      'Support',
                      style: TextStyle(fontSize: 12, color: _textSecondary),
                    ),
                    Icon(Icons.keyboard_arrow_down, size: 16, color: _textSecondary),
                  ],
                ),
              ],
            ),
          ),
          // Progress indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _inputBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${_currentPage + 1}/5',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Page 1: Language Selection
class _LanguageSelectionPage extends ConsumerStatefulWidget {
  final VoidCallback onContinue;

  const _LanguageSelectionPage({required this.onContinue});

  @override
  ConsumerState<_LanguageSelectionPage> createState() => _LanguageSelectionPageState();
}

class _LanguageSelectionPageState extends ConsumerState<_LanguageSelectionPage> {
  String? _selectedLanguage;
  final _emailController = TextEditingController();
  final _emailFocusNode = FocusNode();
  bool _isEmailValid = true;
  bool _isSavingEmail = false;

  static const _languages = [
    {'code': 'en', 'name': 'English', 'native': 'English'},
    {'code': 'hi', 'name': 'Hindi', 'native': 'हिंदी'},
    {'code': 'pa', 'name': 'Punjabi', 'native': 'ਪੰਜਾਬੀ'},
    {'code': 'ta', 'name': 'Tamil', 'native': 'தமிழ்'},
    {'code': 'te', 'name': 'Telugu', 'native': 'తెలుగు'},
    {'code': 'bn', 'name': 'Bengali', 'native': 'বাংলা'},
    {'code': 'mr', 'name': 'Marathi', 'native': 'मराठी'},
    {'code': 'gu', 'name': 'Gujarati', 'native': 'ગુજરાતી'},
  ];

  @override
  void initState() {
    super.initState();
    // Pre-fill with user's existing email if available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final onboardingState = ref.read(driverOnboardingProvider);
      if (onboardingState.email != null && onboardingState.email!.isNotEmpty) {
        _emailController.text = onboardingState.email!;
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  bool _validateEmail(String email) {
    if (email.isEmpty) return false;
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return emailRegex.hasMatch(email);
  }

  Future<void> _saveEmailAndContinue() async {
    final email = _emailController.text.trim();
    
    if (email.isEmpty) {
      setState(() => _isEmailValid = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('enter_email_prompt')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!_validateEmail(email)) {
      setState(() => _isEmailValid = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('enter_valid_email')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isEmailValid = true;
      _isSavingEmail = true;
    });

    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      final success = await notifier.updateEmail(email);
      
      if (mounted) {
        setState(() => _isSavingEmail = false);
        
        if (success) {
          widget.onContinue();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.tr('email_save_failed')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingEmail = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sign-in Details Required',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Set up your driver account for Raahi services.\nBuy online codes by email, phone or text message.\n\nSample code address on Random country providing for confirmation and receive your secret activation code.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[600],
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          
          // Email field (editable)
          const Text(
            'Email Address',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _emailController,
            focusNode: _emailFocusNode,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Enter your email address',
              hintStyle: TextStyle(color: Colors.grey[500]),
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF888888), size: 20),
              suffixIcon: _emailController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18, color: Color(0xFF888888)),
                      onPressed: () {
                        _emailController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _isEmailValid ? const Color(0xFFE8E0D4) : Colors.red,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _isEmailValid ? const Color(0xFFE8E0D4) : Colors.red,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _isEmailValid ? const Color(0xFFD4956A) : Colors.red,
                  width: 2,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (value) {
              setState(() {
                _isEmailValid = value.isEmpty || _validateEmail(value);
              });
            },
          ),
          if (!_isEmailValid)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Please enter a valid email address',
                style: TextStyle(fontSize: 12, color: Colors.red[600]),
              ),
            ),
          const SizedBox(height: 24),
          
          // Language selection
          const Text(
            'Select your language',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'You can change your language anytime you want from settings',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          
          Text(ref.tr('language'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFEDE6DA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8E0D4)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _selectedLanguage,
                hint: const Text('English'),
                items: _languages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang['code'],
                    child: Text('${lang['name']} - ${lang['native']}'),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedLanguage = value);
                  if (value != null) {
                    ref.read(driverOnboardingProvider.notifier).setLanguage(value);
                  }
                },
              ),
            ),
          ),
          
          const SizedBox(height: 80),
          
          // Continue button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _isSavingEmail ? null : _saveEmailAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[400],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: _isSavingEmail
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Continue',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// Page 2: Vehicle Type Selection
class _VehicleTypeSelectionPage extends ConsumerStatefulWidget {
  final VoidCallback onContinue;

  const _VehicleTypeSelectionPage({required this.onContinue});

  @override
  ConsumerState<_VehicleTypeSelectionPage> createState() => _VehicleTypeSelectionPageState();
}

class _VehicleTypeSelectionPageState extends ConsumerState<_VehicleTypeSelectionPage> {
  String? _selectedVehicleType;
  final _referralController = TextEditingController();

  static const _vehicleTypes = [
    {
      'id': 'auto',
      'name': 'Auto',
      'description': 'Whether you have a cab that provides in Auto',
      'icon': Icons.electric_rickshaw,
      'color': Color(0xFF4CAF50),
    },
    {
      'id': 'commercial_car',
      'name': 'Commercial Car',
      'description': 'Whether your cab that provides in Car Service',
      'icon': Icons.directions_car,
      'color': Color(0xFF2196F3),
    },
    {
      'id': 'motorbike',
      'name': 'Motorbike',
      'description': 'If you want to work for Taxi or Deliveries\nNote: Taxi in Badshahpur',
      'icon': Icons.two_wheeler,
      'color': Color(0xFFFF9800),
    },
  ];

  @override
  void dispose() {
    _referralController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Start Earning with Raahi',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Details which vehicles and where you want earn.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          
          const Text(
            'Where would you like to earn?',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFEDE6DA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE8E0D4)),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Delhi NCR',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down, color: Color(0xFF888888)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          // Referral code
          const Text(
            'Referral code (optional)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _referralController,
            decoration: InputDecoration(
              hintText: 'Enter referral code',
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
            ),
            onChanged: (value) {
              ref.read(driverOnboardingProvider.notifier).setReferralCode(value);
            },
          ),
          const SizedBox(height: 24),
          
          const Text(
            'Choose how you want to earn with Raahi',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          
          // Vehicle type cards
          ..._vehicleTypes.map((vehicle) {
            final isSelected = _selectedVehicleType == vehicle['id'];
            return GestureDetector(
              onTap: () {
                setState(() => _selectedVehicleType = vehicle['id'] as String);
                ref.read(driverOnboardingProvider.notifier).setVehicleType(vehicle['id'] as String);
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFFF5E6D3) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? const Color(0xFFD4956A) : const Color(0xFFE8E0D4),
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: (vehicle['color'] as Color).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        vehicle['icon'] as IconData,
                        color: vehicle['color'] as Color,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vehicle['name'] as String,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            vehicle['description'] as String,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      const Icon(Icons.check_circle, color: Color(0xFFD4956A)),
                  ],
                ),
              ),
            );
          }),
          
          const SizedBox(height: 24),
          
          // Continue button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _selectedVehicleType != null ? widget.onContinue : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[300],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Page 3: Personal Info (Name, etc.)
class _PersonalInfoPage extends ConsumerStatefulWidget {
  final VoidCallback onContinue;

  const _PersonalInfoPage({required this.onContinue});

  @override
  ConsumerState<_PersonalInfoPage> createState() => _PersonalInfoPageState();
}

class _PersonalInfoPageState extends ConsumerState<_PersonalInfoPage> {
  final _nameController = TextEditingController();
  final _vehicleNumberController = TextEditingController();
  final _vehicleModelController = TextEditingController();
  final _aadhaarController = TextEditingController();
  bool _isSubmitting = false;
  String? _vehicleNumberError;
  String? _vehicleModelError;

  static final _vehicleNumberRegex = RegExp(r'^[A-Z]{2}\s?\d{1,2}\s?[A-Z]{1,3}\s?\d{1,4}$', caseSensitive: false);

  @override
  void dispose() {
    _nameController.dispose();
    _vehicleNumberController.dispose();
    _vehicleModelController.dispose();
    _aadhaarController.dispose();
    super.dispose();
  }

  bool _validateVehicleNumber(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    return _vehicleNumberRegex.hasMatch(trimmed.replaceAll('-', ' '));
  }

  Future<void> _submitAndContinue() async {
    final vehicleNum = _vehicleNumberController.text.trim();
    final vehicleModel = _vehicleModelController.text.trim();

    if (vehicleNum.isEmpty) {
      setState(() => _vehicleNumberError = 'Vehicle registration number is required');
      return;
    }
    if (!_validateVehicleNumber(vehicleNum)) {
      setState(() => _vehicleNumberError = 'Enter a valid number (e.g., DL 01 AB 1234)');
      return;
    }
    setState(() => _vehicleNumberError = null);
    if (vehicleModel.isEmpty) {
      setState(() => _vehicleModelError = 'Vehicle model is required');
      return;
    }
    setState(() => _vehicleModelError = null);

    setState(() => _isSubmitting = true);
    
    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      
      final startSuccess = await notifier.startOnboarding();
      debugPrint('📋 Start onboarding result: $startSuccess');
      
      await notifier.setPersonalInfo(
        fullName: _nameController.text.isNotEmpty ? _nameController.text : null,
        vehicleNumber: vehicleNum.toUpperCase().replaceAll(RegExp(r'\s+'), ''),
        vehicleModel: vehicleModel,
        aadhaarNumber: _aadhaarController.text.isNotEmpty ? _aadhaarController.text : null,
      );
      
      if (mounted) {
        setState(() => _isSubmitting = false);
        widget.onContinue();
      }
    } catch (e) {
      debugPrint('❌ Submit error: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
        widget.onContinue();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "You've almost finished",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Complete the details and verify your documents.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          
          // Full name
          Text(ref.tr('full_name'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'As per your Aadhaar',
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Vehicle registration number (mandatory — used to cross-verify RC)
          Row(
            children: [
              Text(ref.tr('vehicle_reg_number'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const Text(' *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.red)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Must match your RC — used for verification',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _vehicleNumberController,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'e.g., DL 01 AB 1234',
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              errorText: _vehicleNumberError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleNumberError != null ? Colors.red : const Color(0xFFE8E0D4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleNumberError != null ? Colors.red : const Color(0xFFE8E0D4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleNumberError != null ? Colors.red : const Color(0xFFD4956A), width: 2),
              ),
            ),
            onChanged: (_) {
              if (_vehicleNumberError != null) setState(() => _vehicleNumberError = null);
            },
          ),
          const SizedBox(height: 16),
          Text(ref.tr('vehicle_model'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _vehicleModelController,
            decoration: InputDecoration(
              hintText: 'e.g., Maruti Swift Dzire',
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              errorText: _vehicleModelError,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleModelError != null ? Colors.red : const Color(0xFFE8E0D4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleModelError != null ? Colors.red : const Color(0xFFE8E0D4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _vehicleModelError != null ? Colors.red : const Color(0xFFD4956A), width: 2),
              ),
            ),
            onChanged: (_) {
              if (_vehicleModelError != null) setState(() => _vehicleModelError = null);
            },
          ),
          const SizedBox(height: 16),
          
          // Aadhaar number
          Text(ref.tr('aadhaar_number'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _aadhaarController,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: InputDecoration(
              hintText: '0000-0000-0000',
              counterText: '',
              filled: true,
              fillColor: const Color(0xFFEDE6DA),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE8E0D4)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Terms checkbox
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: true,
                onChanged: (value) {},
                activeColor: const Color(0xFFD4956A),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'By proceeding, I agree that Raahi or its representatives may contact me by email, phone, or SMS (including by automatic telephone dialing system) and/or share your information to our marketing partners for marketing purposes. For Terms and Conditions.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600], height: 1.4),
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Submit button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitAndContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[400],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Submit',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// Page 4: Documents Upload Flow - All required documents
class _DocumentsUploadFlow extends ConsumerStatefulWidget {
  final VoidCallback onComplete;

  const _DocumentsUploadFlow({required this.onComplete});

  @override
  ConsumerState<_DocumentsUploadFlow> createState() => _DocumentsUploadFlowState();
}

class _DocumentsUploadFlowState extends ConsumerState<_DocumentsUploadFlow> {
  final PageController _docPageController = PageController();
  int _currentDocIndex = 0;
  final ImagePicker _picker = ImagePicker();
  
  // Track uploaded documents
  final Map<String, String?> _uploadedPaths = {};
  final Map<String, bool> _uploadStatus = {};
  bool _isUploading = false;
  
  // Raahi color palette
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);
  static const _success = Color(0xFF4CAF50);
  static const _blue = Color(0xFF2196F3);

  // Backend required documents
  static const List<Map<String, dynamic>> _requiredDocuments = [
    {
      'id': 'LICENSE',
      'frontendId': 'driving_license',
      'title': 'Driving License',
      'subtitle': 'Front side of your valid driving license',
      'icon': Icons.badge_outlined,
      'color': Color(0xFF2196F3),
      'requirements': [
        'Ensure the photo is from your actual driving licence',
        'Make sure it\'s perfectly readable and clearly visible',
        'Make sure your document is laid on a flat surface',
        'Use a plain white or light-colored background',
      ],
    },
    {
      'id': 'RC',
      'frontendId': 'vehicle_rc',
      'title': 'Vehicle RC',
      'subtitle': 'Registration Certificate of your vehicle',
      'icon': Icons.description_outlined,
      'color': Color(0xFF9C27B0),
      'requirements': [
        'Upload the front side of your RC',
        'Ensure all details are clearly visible',
        'Vehicle number should be readable',
        'Owner name must match your profile',
      ],
    },
    {
      'id': 'INSURANCE',
      'frontendId': 'vehicle_insurance',
      'title': 'Vehicle Insurance',
      'subtitle': 'Valid insurance document for your vehicle',
      'icon': Icons.security_outlined,
      'color': Color(0xFF00BCD4),
      'requirements': [
        'Insurance must be valid and not expired',
        'Policy number should be visible',
        'Vehicle number must match your RC',
        'Cover type should be comprehensive/third-party',
      ],
    },
    {
      'id': 'PAN_CARD',
      'frontendId': 'pan_card',
      'title': 'PAN Card',
      'subtitle': 'Your Permanent Account Number card',
      'icon': Icons.credit_card_outlined,
      'color': Color(0xFFFF9800),
      'requirements': [
        'Photo should be clearly visible',
        'PAN number must be readable',
        'Name should match your profile',
        'Ensure no glare or shadows',
      ],
    },
    {
      'id': 'AADHAAR_CARD',
      'frontendId': 'aadhaar_card',
      'title': 'Aadhaar Card',
      'subtitle': 'Your Aadhaar identification card',
      'icon': Icons.fingerprint,
      'color': Color(0xFF4CAF50),
      'requirements': [
        'Upload front side of Aadhaar',
        'Aadhaar number should be visible',
        'Photo and QR code must be clear',
        'Name and DOB should be readable',
      ],
    },
    {
      'id': 'PROFILE_PHOTO',
      'frontendId': 'profile_photo',
      'title': 'Profile Photo',
      'subtitle': 'A clear photo of yourself',
      'icon': Icons.person_outline,
      'color': Color(0xFFD4956A),
      'requirements': [
        'Take a clear selfie or passport-style photo',
        'Face should be clearly visible',
        'Plain background preferred',
        'Good lighting, no sunglasses or hat',
      ],
    },
  ];

  @override
  void dispose() {
    _docPageController.dispose();
    super.dispose();
  }

  void _nextDocument() {
    if (_currentDocIndex < _requiredDocuments.length - 1) {
      _docPageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      // Only proceed to verification when we're truly on the last document step
      assert(_currentDocIndex == _requiredDocuments.length - 1, 'onComplete only from last doc');
      widget.onComplete();
    }
  }

  void _previousDocument() {
    if (_currentDocIndex > 0) {
      _docPageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _showImageSourceDialog(String docId) async {
    if (!mounted) return;
    // Use dialog instead of bottom sheet for reliable behavior on release APK / all devices
    final source = await showDialog<ImageSource>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Select Image Source',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.camera_alt, color: _accent),
              ),
              title: Text(ref.tr('camera'), style: const TextStyle(color: _textPrimary)),
              subtitle: Text(ref.tr('take_photo'), style: const TextStyle(color: _textSecondary)),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.photo_library, color: _blue),
              ),
              title: Text(ref.tr('gallery'), style: const TextStyle(color: _textPrimary)),
              subtitle: Text(ref.tr('choose_gallery'), style: const TextStyle(color: _textSecondary)),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    _pickImage(source, docId);
  }

  Future<void> _pickImage(ImageSource source, String docId) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _uploadedPaths[docId] = image.path;
          _uploadStatus[docId] = false; // Not uploaded yet
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pick image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _uploadDocument(Map<String, dynamic> doc) async {
    final docId = doc['id'] as String;
    final frontendId = doc['frontendId'] as String;
    final imagePath = _uploadedPaths[docId];
    
    if (imagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.tr('please_select_image')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isUploading = true);

    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      final result = await notifier.uploadDocument(
        frontendId,
        imagePath,
        isFront: true,
      );
      
      final success = result['success'] as bool? ?? false;
      final nextStep = result['next_step'] as String?;
      final isComplete = result['is_complete'] as bool? ?? false;

      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadStatus[docId] = success;
        });
        
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${doc['title']} uploaded successfully!'),
              backgroundColor: _success,
            ),
          );
          
          // Check if this was the last document and onboarding is complete
          if (isComplete || nextStep == 'COMPLETED') {
            debugPrint('✅ All documents uploaded! Onboarding complete.');
            // Navigate to verification/completion
            widget.onComplete();
          } else {
            _nextDocument();
          }
        } else {
          // Get actual error from provider state
          final errorMsg = result['error'] as String? ?? ref.read(driverOnboardingProvider).error;
          _showUploadErrorDialog(doc['title'] as String, errorMsg ?? 'Upload failed. Server may be unavailable.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploading = false);
        final msg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        _showUploadErrorDialog(doc['title'] as String, msg);
      }
    }
  }
  
  void _showUploadErrorDialog(String docTitle, String errorMsg) {
    // Show backend message without "Exception: " prefix
    final displayMsg = errorMsg.replaceFirst(RegExp(r'^Exception:\s*'), '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Upload Failed',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textPrimary),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Failed to upload $docTitle',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                displayMsg,
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This could be due to:\n• Server is temporarily unavailable\n• Network connection issue\n• Invalid document format',
              style: TextStyle(fontSize: 12, color: _textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _nextDocument(); // Skip this document
            },
            child: Text(ref.tr('skip_for_now'), style: const TextStyle(color: _textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: _textPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(ref.tr('try_again')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Document progress indicator
        _buildDocumentProgressBar(),
        
        // Document pages
        Expanded(
          child: PageView.builder(
            controller: _docPageController,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (page) => setState(() => _currentDocIndex = page),
            itemCount: _requiredDocuments.length,
            itemBuilder: (context, index) {
              return _buildDocumentUploadPage(_requiredDocuments[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentProgressBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          // Progress dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_requiredDocuments.length, (index) {
              final docId = _requiredDocuments[index]['id'] as String;
              final isUploaded = _uploadStatus[docId] == true;
              final isCurrent = index == _currentDocIndex;
              
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isCurrent ? 24 : 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isUploaded 
                      ? _success 
                      : (isCurrent ? _accent : _border),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: isUploaded 
                    ? const Icon(Icons.check, color: Colors.white, size: 8)
                    : null,
              );
            }),
          ),
          const SizedBox(height: 8),
          Text(
            'Document ${_currentDocIndex + 1} of ${_requiredDocuments.length}',
            style: TextStyle(
              fontSize: 12,
              color: _textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentUploadPage(Map<String, dynamic> doc) {
    final docId = doc['id'] as String;
    final imagePath = _uploadedPaths[docId];
    final isUploaded = _uploadStatus[docId] == true;
    final docColor = doc['color'] as Color;
    final requirements = doc['requirements'] as List<String>;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with icon
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: docColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  doc['icon'] as IconData,
                  color: docColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc['title'] as String,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: _textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      doc['subtitle'] as String,
                      style: TextStyle(fontSize: 13, color: _textSecondary),
                    ),
                  ],
                ),
              ),
              if (isUploaded)
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: _success,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
                ),
            ],
          ),
          const SizedBox(height: 24),
          
          // Document preview area
          GestureDetector(
            onTap: () => _showImageSourceDialog(docId),
            child: Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                color: _inputBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: imagePath != null ? _success : _border,
                  width: imagePath != null ? 2 : 1,
                ),
              ),
              child: imagePath != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(imagePath),
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _uploadedPaths[docId] = null;
                                _uploadStatus[docId] = false;
                              }),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isUploaded ? _success : docColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isUploaded ? Icons.cloud_done : Icons.image,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isUploaded ? 'Uploaded' : 'Ready to upload',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_a_photo_outlined,
                          size: 56,
                          color: docColor.withOpacity(0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tap to take a photo or\nselect from gallery',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: _textSecondary,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Requirements box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: docColor),
                    const SizedBox(width: 8),
                    const Text(
                      'Requirements',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...requirements.map((req) => _buildRequirement(req)),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // Action buttons
          Row(
            children: [
              if (_currentDocIndex > 0)
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      onPressed: _previousDocument,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _textPrimary,
                        side: const BorderSide(color: _border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Previous',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              if (_currentDocIndex > 0) const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isUploading
                        ? null
                        : (imagePath != null
                            ? () => _uploadDocument(doc)
                            : () {
                                // Always show camera/gallery choice — never navigate away
                                _showImageSourceDialog(docId);
                              }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: imagePath != null && !isUploaded
                          ? _success
                          : _textPrimary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey[300],
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _isUploading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                imagePath != null
                                    ? (isUploaded ? Icons.arrow_forward : Icons.cloud_upload)
                                    : Icons.camera_alt,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                imagePath != null
                                    ? (isUploaded
                                        ? (_currentDocIndex < _requiredDocuments.length - 1
                                            ? 'Next Document'
                                            : 'Complete')
                                        : 'Upload')
                                    : 'Take photo',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
          
          // Skip option (only for optional re-upload)
          if (isUploaded && _currentDocIndex < _requiredDocuments.length - 1)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: TextButton(
                  onPressed: _nextDocument,
                  child: Text(
                    'Skip to next document',
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRequirement(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: _success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ),
        ],
      ),
    );
  }
}

// Page 5: Verification Status — submits docs to backend and shows progress
class _VerificationStatusPage extends ConsumerStatefulWidget {
  final VoidCallback onComplete;

  const _VerificationStatusPage({required this.onComplete});

  @override
  ConsumerState<_VerificationStatusPage> createState() => _VerificationStatusPageState();
}

class _VerificationStatusPageState extends ConsumerState<_VerificationStatusPage> {
  bool _isSubmitting = false;
  bool _hasSubmitted = false;
  String? _submitError;
  bool _initialized = false;
  bool _isPolling = false;
  int _pollCount = 0;
  static const int _maxPollCount = 30; // Poll for max 5 minutes (30 * 10 seconds)
  static const Duration _pollInterval = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    // Schedule the submission after the first frame to avoid modifying provider during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_initialized) {
        _initialized = true;
        _submitDocuments();
      }
    });
  }
  
  @override
  void dispose() {
    _isPolling = false;
    super.dispose();
  }

  Future<void> _submitDocuments() async {
    if (!mounted) return;
    
    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });
    
    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      final success = await notifier.submitForVerification();
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _hasSubmitted = success;
          if (!success) _submitError = 'Failed to submit documents. Please try again.';
        });
        
        // Start polling for verification status after successful submission
        if (success) {
          _startPollingForVerification();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _submitError = 'Error: $e';
        });
      }
    }
  }
  
  /// Poll the backend status to check if verification is complete.
  /// Auto-navigates to driver home when onboarding is complete and can start rides.
  Future<void> _startPollingForVerification() async {
    if (_isPolling) return;
    _isPolling = true;
    _pollCount = 0;
    
    debugPrint('🔄 Starting verification status polling...');
    
    while (_isPolling && mounted && _pollCount < _maxPollCount) {
      _pollCount++;
      await Future.delayed(_pollInterval);
      
      if (!mounted || !_isPolling) break;
      
      debugPrint('🔄 Polling verification status (attempt $_pollCount/$_maxPollCount)...');
      
      try {
        final notifier = ref.read(driverOnboardingProvider.notifier);
        final status = await notifier.fetchOnboardingStatus();
        
        debugPrint('🔄 Poll result: isOnboardingComplete=${status.isOnboardingComplete}, isVerified=${status.isVerified}, canStartRides=${status.canStartRides}');
        
        // Check if verification is complete and driver can start rides
        if (status.isOnboardingComplete && status.canStartRides) {
          debugPrint('✅ Verification complete! Auto-navigating to driver home...');
          _isPolling = false;
          
          if (mounted) {
            // Navigate to driver home
            widget.onComplete();
          }
          return;
        }
        
        // Check if all documents are verified (alternative check)
        if (status.verificationProgress >= 100 || status.isVerified) {
          debugPrint('✅ All documents verified! Auto-navigating to driver home...');
          _isPolling = false;
          
          if (mounted) {
            widget.onComplete();
          }
          return;
        }
        
      } catch (e) {
        debugPrint('❌ Poll error: $e');
        // Continue polling despite error
      }
    }
    
    _isPolling = false;
    debugPrint('🔄 Polling stopped (max attempts reached or unmounted)');
  }
  
  /// Manually refresh verification status
  Future<void> _refreshStatus() async {
    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      final status = await notifier.fetchOnboardingStatus();
      
      if (mounted && status.isOnboardingComplete && status.canStartRides) {
        widget.onComplete();
      }
    } catch (e) {
      debugPrint('❌ Refresh error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final onboardingState = ref.watch(driverOnboardingProvider);
    final progress = (onboardingState.verificationProgress * 100).toInt();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _hasSubmitted
                ? 'Documents submitted\nfor verification'
                : 'Submitting your\ndocuments...',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _hasSubmitted
                ? 'We\'re reviewing your documents. This usually takes 24-48 hours. You\'ll be notified once verified.'
                : 'Please wait while we upload your documents to the server.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.5),
          ),
          if (_hasSubmitted && _isPolling) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: const Color(0xFFD4956A),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Checking verification status...',
                  style: TextStyle(fontSize: 12, color: Color(0xFFD4956A), fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_submitError!, style: const TextStyle(color: Colors.red, fontSize: 13))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          
          _buildDocumentStatus('Initial Information', 'Completed', DocumentStatus.verified),
          _buildDocumentStatus('Driving License', _hasSubmitted ? 'Under Review' : 'Uploading...', onboardingState.drivingLicense.status),
          _buildDocumentStatus('Vehicle RC', _hasSubmitted ? 'Under Review' : 'Uploading...', onboardingState.vehicleRC.status),
          _buildDocumentStatus('Aadhaar Card', _hasSubmitted ? 'Under Review' : 'Uploading...', onboardingState.aadhaarCard.status),
          
          const Spacer(),
          
          if (_isSubmitting) ...[
            const Center(child: CircularProgressIndicator(color: Color(0xFFD4956A))),
            const SizedBox(height: 24),
          ],

          // Progress bar
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(ref.tr('verification_progress'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  Text('$progress%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFD4956A))),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: onboardingState.verificationProgress,
                backgroundColor: const Color(0xFFEDE6DA),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFD4956A)),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Retry button if there was an error
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: _isSubmitting ? null : _submitDocuments,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4956A),
                    side: const BorderSide(color: Color(0xFFD4956A)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    'Retry Submission',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          
          // Manual refresh button
          if (_hasSubmitted && !_isPolling)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _refreshStatus,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text(
                    'Check Status',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4956A),
                    side: const BorderSide(color: Color(0xFFD4956A)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          
          // Start Ride button - disabled until verified
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: onboardingState.canStartRides ? widget.onComplete : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: onboardingState.canStartRides 
                    ? const Color(0xFF4CAF50) 
                    : Colors.grey[400],
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[350],
                disabledForegroundColor: Colors.grey[600],
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    onboardingState.canStartRides 
                        ? Icons.directions_car 
                        : Icons.lock_outline,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    onboardingState.canStartRides 
                        ? 'Start Ride' 
                        : 'Start Ride (Verification Pending)',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          
          // Info text about verification
          if (!onboardingState.canStartRides)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 6),
                  Text(
                    'You\'ll be notified once verified',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentStatus(String title, String status, DocumentStatus docStatus, {bool needsAttention = false}) {
    IconData icon;
    Color iconColor;
    
    switch (docStatus) {
      case DocumentStatus.verified:
        icon = Icons.check_circle;
        iconColor = const Color(0xFF4CAF50);
        break;
      case DocumentStatus.rejected:
        icon = Icons.error;
        iconColor = Colors.red;
        break;
      case DocumentStatus.inReview:
      case DocumentStatus.uploading:
      case DocumentStatus.uploaded:
        icon = Icons.hourglass_empty;
        iconColor = const Color(0xFFD4956A);
        break;
      case DocumentStatus.notUploaded:
      default:
        icon = Icons.circle_outlined;
        iconColor = Colors.grey;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: needsAttention ? Colors.red : Colors.grey[600],
                    fontWeight: needsAttention ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          if (needsAttention)
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.red),
        ],
      ),
    );
  }
}
