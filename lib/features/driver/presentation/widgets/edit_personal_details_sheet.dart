import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_flutter/core/theme/primary_cta_styles.dart';
import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';
import '../../providers/driver_onboarding_provider.dart';

/// Bottom sheet for editing driver personal details (Aadhaar, email, vehicle).
///
/// When [forceShowAllFields] is true (Update Documents flow), Aadhaar and email
/// are always shown. Otherwise fields follow rejection/mismatch flags.
class EditPersonalDetailsSheet extends ConsumerStatefulWidget {
  const EditPersonalDetailsSheet({
    super.key,
    this.forceShowAllFields = false,
  });

  final bool forceShowAllFields;

  static Future<void> show(
    BuildContext context, {
    bool forceShowAllFields = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EditPersonalDetailsSheet(
        forceShowAllFields: forceShowAllFields,
      ),
    );
  }

  @override
  ConsumerState<EditPersonalDetailsSheet> createState() =>
      _EditPersonalDetailsSheetState();
}

class _EditPersonalDetailsSheetState
    extends ConsumerState<EditPersonalDetailsSheet> {
  final _emailController = TextEditingController();
  final _aadhaarController = TextEditingController();
  final _vehicleNumberController = TextEditingController();
  final _vehicleModelController = TextEditingController();
  bool _isSubmitting = false;
  bool _showAadhaar = false;
  bool _showVehicle = false;
  bool _showEmail = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final backendStatus = ref.read(driverOnboardingProvider).backendStatus;
      if (widget.forceShowAllFields) {
        _showAadhaar = true;
        _showEmail = true;
        _showVehicle = true;
      } else {
        _showAadhaar = backendStatus.shouldEditAadhaar;
        _showVehicle = backendStatus.shouldEditVehicle;
        _showEmail = backendStatus.shouldEditEmail;
      }
      if (_showAadhaar && backendStatus.aadhaarNumber != null) {
        _aadhaarController.text = backendStatus.aadhaarNumber!;
      }
      if (_showVehicle) {
        if (backendStatus.vehicleNumber != null) {
          _vehicleNumberController.text = backendStatus.vehicleNumber!;
        }
        if (backendStatus.vehicleModel != null) {
          _vehicleModelController.text = backendStatus.vehicleModel!;
        }
      }
      if (_showEmail && backendStatus.email != null) {
        _emailController.text = backendStatus.email!;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _aadhaarController.dispose();
    _vehicleNumberController.dispose();
    _vehicleModelController.dispose();
    super.dispose();
  }

  String _buildSubtitle() {
    if (widget.forceShowAllFields) {
      return 'Update Aadhaar, email, or vehicle details if needed.';
    }
    final parts = <String>[];
    if (_showAadhaar) parts.add('Aadhaar');
    if (_showVehicle) parts.add('RC number');
    if (_showEmail) parts.add('email');
    if (parts.isEmpty) {
      return 'Update your details if there was a mismatch during verification.';
    }
    return 'Fix ${parts.join(', ')} if entered wrong';
  }

  Future<void> _submit() async {
    final email = _showEmail ? _emailController.text.trim() : '';
    final aadhaar = _showAadhaar ? _aadhaarController.text.trim() : '';
    final vehicleNumber =
        _showVehicle ? _vehicleNumberController.text.trim() : '';
    final vehicleModel =
        _showVehicle ? _vehicleModelController.text.trim() : '';
    if (email.isEmpty &&
        aadhaar.isEmpty &&
        vehicleNumber.isEmpty &&
        vehicleModel.isEmpty) {
      AppMessenger.showDriverErrorBanner(
          context, 'Please update at least one field');
      return;
    }
    if (aadhaar.isNotEmpty && !RegExp(r'^\d{12}$').hasMatch(aadhaar)) {
      AppMessenger.showDriverErrorBanner(
          context, 'Aadhaar must be exactly 12 digits');
      return;
    }
    if (email.isNotEmpty &&
        !RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      AppMessenger.showDriverErrorBanner(
          context, 'Please enter a valid email address');
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      final notifier = ref.read(driverOnboardingProvider.notifier);
      var success = true;
      if (email.isNotEmpty) {
        final emailSuccess = await notifier.updateEmail(email);
        if (!emailSuccess) success = false;
      }
      if (aadhaar.isNotEmpty ||
          vehicleNumber.isNotEmpty ||
          vehicleModel.isNotEmpty) {
        final personalInfoSuccess = await notifier.setPersonalInfo(
          aadhaarNumber: aadhaar.isNotEmpty ? aadhaar : null,
          vehicleNumber: vehicleNumber.isNotEmpty ? vehicleNumber : null,
          vehicleModel: vehicleModel.isNotEmpty ? vehicleModel : null,
        );
        if (!personalInfoSuccess) success = false;
      }
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Details updated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
        notifier.fetchOnboardingStatus();
      } else {
        AppMessenger.showDriverErrorBanner(
            context, 'Failed to update details.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      AppMessenger.showDriverErrorBanner(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAnyField = _showAadhaar || _showVehicle || _showEmail;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD4956A).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.edit_note_rounded,
                          color: Color(0xFFD4956A), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Edit Your Details',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _buildSubtitle(),
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
            const SizedBox(height: 20),
            if (!hasAnyField) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F8F0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        color: Color(0xFF4CAF50), size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'All your personal details look correct. No fields need editing.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF2E7D32)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
            if (_showAadhaar) ...[
              const Text('Aadhaar Number',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _aadhaarController,
                keyboardType: TextInputType.number,
                maxLength: 12,
                decoration: InputDecoration(
                  hintText: 'Enter 12-digit Aadhaar number',
                  filled: true,
                  fillColor: const Color(0xFFEDE6DA),
                  counterText: '',
                  prefixIcon:
                      const Icon(Icons.fingerprint, color: Color(0xFF888888)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_showVehicle) ...[
              const Text('Vehicle Registration No.',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _vehicleNumberController,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'e.g. DL 01 AB 1234',
                  filled: true,
                  fillColor: const Color(0xFFEDE6DA),
                  prefixIcon: const Icon(Icons.directions_car_outlined,
                      color: Color(0xFF888888)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Vehicle Model',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _vehicleModelController,
                decoration: InputDecoration(
                  hintText: 'e.g. Maruti Swift Dzire',
                  filled: true,
                  fillColor: const Color(0xFFEDE6DA),
                  prefixIcon: const Icon(Icons.local_taxi_outlined,
                      color: Color(0xFF888888)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_showEmail) ...[
              const Text('Email Address',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'you@email.com',
                  filled: true,
                  fillColor: const Color(0xFFEDE6DA),
                  prefixIcon:
                      const Icon(Icons.mail_outline, color: Color(0xFF888888)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (hasAnyField) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_outlined, size: 20),
                  label: Text(
                    _isSubmitting ? 'Saving...' : 'Save Details',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: PrimaryCtaStyles.elevated(),
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
