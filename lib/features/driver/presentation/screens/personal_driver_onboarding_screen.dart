import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/router/app_routes.dart';
import '../../../../core/widgets/figma_square_back_button.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../providers/personal_driver_onboarding_provider.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';

/// Personal Rescue Driver onboarding — Aadhaar + Driving License only.
class PersonalDriverOnboardingScreen extends ConsumerStatefulWidget {
  const PersonalDriverOnboardingScreen({super.key});

  @override
  ConsumerState<PersonalDriverOnboardingScreen> createState() =>
      _PersonalDriverOnboardingScreenState();
}

class _PersonalDriverOnboardingScreenState
    extends ConsumerState<PersonalDriverOnboardingScreen> {
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _border = Color(0xFFE8E0D4);
  static const _success = Color(0xFF4CAF50);

  final PageController _pageController = PageController();
  final ImagePicker _picker = ImagePicker();
  int _currentPage = 0;
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(personalDriverOnboardingProvider.notifier).startOnboarding();
      final pd = ref.read(personalDriverOnboardingProvider);
      final user = ref.read(currentUserProvider);
      if (pd.fullName.isNotEmpty) {
        _nameController.text = pd.fullName;
      } else if (user != null && user.name.trim().isNotEmpty) {
        _nameController.text = user.name.trim();
      }
      final email = pd.email;
      if (email != null && email.isNotEmpty) {
        _emailController.text = email;
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < 2) {
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
      context.pop();
    }
  }

  Future<void> _submitDocuments() async {
    final ok =
        await ref.read(personalDriverOnboardingProvider.notifier).submitDocuments();
    if (!mounted) return;
    if (ok) {
      context.go(AppRoutes.personalDriverWelcome);
    } else {
      final err = ref.read(personalDriverOnboardingProvider).error;
      if (err != null) {
        AppMessenger.showDriverErrorBanner(context, err);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pd = ref.watch(personalDriverOnboardingProvider);

    return Scaffold(
      backgroundColor: _beige,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  FigmaSquareBackButton(onPressed: _previousPage),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Image.asset('assets/images/raahi_logo.png', height: 28),
                        const SizedBox(height: 4),
                        Text(
                          'Personal Rescue Driver',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: _textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _border),
                    ),
                    child: Text(
                      '${_currentPage + 1}/3',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (p) => setState(() => _currentPage = p),
                children: [
                  _IntroPage(onContinue: _nextPage),
                  _PersonalInfoPage(
                    nameController: _nameController,
                    emailController: _emailController,
                    onContinue: () async {
                      final name = _nameController.text.trim();
                      if (name.isEmpty) {
                        AppMessenger.showDriverErrorBanner(
                          context,
                          'Please enter your full name',
                        );
                        return;
                      }
                      await ref
                          .read(personalDriverOnboardingProvider.notifier)
                          .setFullName(name);
                      await ref
                          .read(personalDriverOnboardingProvider.notifier)
                          .setEmail(_emailController.text.trim());
                      _nextPage();
                    },
                  ),
                  _DocumentsPage(
                    drivingLicense: pd.drivingLicense,
                    aadhaar: pd.aadhaar,
                    isLoading: pd.isLoading,
                    onPick: _pickDocument,
                    onSubmit: _submitDocuments,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDocument({
    required String docType,
    required bool isFront,
    required String title,
  }) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Upload $title', style: const TextStyle(color: _textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: _accent),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: _accent),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (image == null) return;
      await ref.read(personalDriverOnboardingProvider.notifier).saveDocumentPath(
            docType: docType,
            path: image.path,
            isFront: isFront,
          );
    } catch (e) {
      if (mounted) {
        AppMessenger.showDriverErrorBanner(context, 'Failed to pick image: $e');
      }
    }
  }
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({required this.onContinue});

  final VoidCallback onContinue;

  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE8E0D4)),
            ),
            child: Column(
              children: [
                Icon(Icons.emergency_share_outlined,
                    size: 56, color: _accent.withValues(alpha: 0.9)),
                const SizedBox(height: 16),
                Text(
                  'Drive the car during rescues',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Personal Rescue Drivers drive a car and carry the rider while a bike partner moves their vehicle. You only need Aadhaar and a valid driving license.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    height: 1.5,
                    color: _textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _bullet(Icons.two_wheeler, 'Works with a bike rescue partner'),
          _bullet(Icons.directions_car, 'You drive the car — rider travels with you'),
          _bullet(Icons.verified_user_outlined, 'Quick verification — 2 documents'),
          const Spacer(),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onContinue,
              child: const Text('Get Started'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bullet(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, color: _accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(fontSize: 14, color: _textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonalInfoPage extends StatefulWidget {
  const _PersonalInfoPage({
    required this.nameController,
    required this.emailController,
    required this.onContinue,
  });

  final TextEditingController nameController;
  final TextEditingController emailController;
  final VoidCallback onContinue;

  @override
  State<_PersonalInfoPage> createState() => _PersonalInfoPageState();
}

class _PersonalInfoPageState extends State<_PersonalInfoPage> {
  bool _nameValid = true;

  bool get _canContinue => widget.nameController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.nameController.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    widget.nameController.removeListener(_onNameChanged);
    super.dispose();
  }

  void _onNameChanged() {
    setState(() {
      if (widget.nameController.text.trim().isNotEmpty) {
        _nameValid = true;
      }
    });
  }

  void _handleContinue() {
    if (widget.nameController.text.trim().isEmpty) {
      setState(() => _nameValid = false);
      return;
    }
    widget.onContinue();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your details',
            style: GoogleFonts.poppins(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We use this to verify your rescue driver profile.',
            style: GoogleFonts.poppins(
              fontSize: 14,
              color: const Color(0xFF888888),
            ),
          ),
          const SizedBox(height: 24),
          _fieldLabel('Full name', required: true),
          TextField(
            controller: widget.nameController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'Enter your full name',
              errorText: _nameValid ? null : 'Full name is required',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _nameValid
                      ? const Color(0xFFE8E0D4)
                      : Colors.red.shade400,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _nameValid
                      ? const Color(0xFFE8E0D4)
                      : Colors.red.shade400,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF1A1A1A),
                  width: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _fieldLabel('Email (optional)'),
          TextField(
            controller: widget.emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: 'you@email.com',
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
          const Spacer(),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _canContinue ? _handleContinue : null,
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String label, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1A1A1A),
            ),
          ),
          if (required)
            Text(
              ' *',
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.red.shade400,
              ),
            ),
        ],
      ),
    );
  }
}

class _DocumentsPage extends StatelessWidget {
  const _DocumentsPage({
    required this.drivingLicense,
    required this.aadhaar,
    required this.isLoading,
    required this.onPick,
    required this.onSubmit,
  });

  final PersonalDriverDocument drivingLicense;
  final PersonalDriverDocument aadhaar;
  final bool isLoading;
  final Future<void> Function({
    required String docType,
    required bool isFront,
    required String title,
  }) onPick;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final ready = drivingLicense.isComplete && aadhaar.isComplete;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(
          'Upload documents',
          style: GoogleFonts.poppins(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Only Aadhaar and Driving License are required for Personal Rescue Drivers.',
          style: GoogleFonts.poppins(fontSize: 14, color: const Color(0xFF888888)),
        ),
        const SizedBox(height: 20),
        _DocCard(
          title: 'Driving License',
          subtitle: 'Front side of your valid license',
          icon: Icons.badge_outlined,
          color: const Color(0xFF2196F3),
          imagePath: drivingLicense.frontPath,
          onTap: () => onPick(
            docType: 'driving_license',
            isFront: true,
            title: 'Driving License',
          ),
        ),
        const SizedBox(height: 12),
        _DocCard(
          title: 'Aadhaar — Front',
          subtitle: 'Clear photo of the front side',
          icon: Icons.fingerprint,
          color: const Color(0xFF4CAF50),
          imagePath: aadhaar.frontPath,
          onTap: () => onPick(
            docType: 'aadhaar_card',
            isFront: true,
            title: 'Aadhaar Front',
          ),
        ),
        const SizedBox(height: 12),
        _DocCard(
          title: 'Aadhaar — Back',
          subtitle: 'Clear photo of the back side',
          icon: Icons.fingerprint,
          color: const Color(0xFF4CAF50),
          imagePath: aadhaar.backPath,
          onTap: () => onPick(
            docType: 'aadhaar_card',
            isFront: false,
            title: 'Aadhaar Back',
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 56,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ready
                  ? const Color(0xFF1A1A1A)
                  : Colors.grey.shade400,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: ready && !isLoading ? onSubmit : null,
            child: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Submit for verification'),
          ),
        ),
      ],
    );
  }
}

class _DocCard extends StatelessWidget {
  const _DocCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.imagePath,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final hasImage = imagePath != null && imagePath!.isNotEmpty;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasImage ? color : const Color(0xFFE8E0D4),
              width: hasImage ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              if (hasImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(imagePath!),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color),
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      hasImage ? 'Tap to replace' : subtitle,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: const Color(0xFF888888),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                hasImage ? Icons.check_circle : Icons.upload_outlined,
                color: hasImage ? const Color(0xFF4CAF50) : const Color(0xFF888888),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
