import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../auth/providers/auth_provider.dart';

class TermsScreen extends ConsumerStatefulWidget {
  final String phone;

  const TermsScreen({
    super.key,
    required this.phone,
  });

  @override
  ConsumerState<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends ConsumerState<TermsScreen> {
  bool _agreed = false;

  void _handleNext() {
    if (_agreed) {
      // Mark onboarding as complete so the router redirects to home
      ref.read(authStateProvider.notifier).completeOnboarding();
      context.go(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),
              
              // Title
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    "Accept Rescue's",
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                      height: 1.2,
                    ),
                  ),
                  Text(
                    'Terms & Review',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                      height: 1.2,
                    ),
                  ),
                  Text(
                    'Privacy Note',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                      height: 1.2,
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 32),
              
              // Terms text
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF666666),
                    height: 1.5,
                  ),
                  children: [
                    const TextSpan(
                      text: "By selecting 'I Agree' below, I have reviewed and agree to the ",
                    ),
                    TextSpan(
                      text: 'Terms of Use',
                      style: TextStyle(
                        color: const Color(0xFF5B9BD5),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    const TextSpan(text: ' and acknowledge the '),
                    TextSpan(
                      text: 'Privacy Notice',
                      style: TextStyle(
                        color: const Color(0xFF5B9BD5),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    const TextSpan(text: '. I am at least 18 years of age.'),
                  ],
                ),
              ),
              
              const SizedBox(height: 32),
              
              // I agree checkbox
              GestureDetector(
                onTap: () => setState(() => _agreed = !_agreed),
                child: Row(
                  children: [
                    const Text(
                      'I agree',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: _agreed ? const Color(0xFF1A1A1A) : Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: const Color(0xFF1A1A1A),
                          width: 2,
                        ),
                      ),
                      child: _agreed
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              
              const Spacer(),
              
              // Back and Next buttons
              Row(
                children: [
                  // Back button
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: IconButton(
                      onPressed: () => context.pop(),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  
                  const Spacer(),
                  
                  // Next button (orange when enabled)
                  GestureDetector(
                    onTap: _agreed ? _handleNext : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                      decoration: BoxDecoration(
                        color: _agreed ? const Color(0xFFD4956A) : const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Next',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: _agreed ? Colors.white : const Color(0xFFBDBDBD),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.arrow_forward,
                            size: 20,
                            color: _agreed ? Colors.white : const Color(0xFFBDBDBD),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
