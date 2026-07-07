import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/models/user.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/firebase_phone_auth_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/primary_cta_styles.dart';
import '../../../../core/widgets/app_messenger.dart';
import '../../../../core/widgets/figma_square_back_button.dart';
import '../../../auth/providers/auth_provider.dart';

/// Edit Profile — update name, email, phone (OTP-verified) and profile photo.
///
/// Photo flow: pick (camera/gallery, compressed client-side) → on Save, get a
/// presigned S3 URL from the backend, PUT the bytes, then save the public URL
/// via PUT /api/auth/profile. Phone changes always require OTP verification
/// of the new number; the backend rejects numbers used by other accounts.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;

  final ImagePicker _picker = ImagePicker();

  // Original values, used for dirty-state detection.
  late String _initialFirstName;
  late String _initialLastName;
  late String _initialEmail;

  /// Newly picked photo waiting to be uploaded on Save.
  File? _pickedPhoto;

  /// True when the user chose "Remove photo" for an existing avatar.
  bool _photoRemoved = false;

  bool _saving = false;

  static const _accent = Color(0xFFD4956A);

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider);
    final meta = user?.userMetadata ?? const {};
    // Prefer the first/last split the backend stores; fall back to splitting
    // the display name.
    String first = (meta['firstName'] as String?)?.trim() ?? '';
    String last = (meta['lastName'] as String?)?.trim() ?? '';
    if (first.isEmpty && (user?.name.isNotEmpty ?? false)) {
      final parts = user!.name.trim().split(RegExp(r'\s+'));
      first = parts.first;
      last = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    }
    _initialFirstName = first;
    _initialLastName = last;
    // Google-signup accounts get a placeholder email; treat it as empty.
    final email = user?.email ?? '';
    _initialEmail = email.endsWith('@placeholder.raahi.app') ? '' : email;

    _firstNameController = TextEditingController(text: _initialFirstName);
    _lastNameController = TextEditingController(text: _initialLastName);
    _emailController = TextEditingController(text: _initialEmail);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  bool get _isDirty {
    return _pickedPhoto != null ||
        _photoRemoved ||
        _firstNameController.text.trim() != _initialFirstName ||
        _lastNameController.text.trim() != _initialLastName ||
        _emailController.text.trim() != _initialEmail;
  }

  // ─── Photo ───────────────────────────────────────────────────────────

  Future<void> _showPhotoOptions() async {
    final user = ref.read(currentUserProvider);
    final hasExistingPhoto =
        (_pickedPhoto != null || (user?.avatarUrl?.isNotEmpty ?? false)) &&
            !_photoRemoved;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            if (hasExistingPhoto)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFD14544)),
                title: const Text('Remove photo',
                    style: TextStyle(color: Color(0xFFD14544))),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'remove') {
      setState(() {
        _pickedPhoto = null;
        _photoRemoved = true;
      });
      return;
    }

    await _pickPhoto(
        action == 'camera' ? ImageSource.camera : ImageSource.gallery);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 82,
        preferredCameraDevice: CameraDevice.front,
      );
      if (image == null) return; // user cancelled

      final file = File(image.path);
      final sizeBytes = await file.length();
      if (sizeBytes > 8 * 1024 * 1024) {
        if (mounted) {
          AppMessenger.showErrorBanner(
              context, 'Photo is too large. Please choose a smaller image.');
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        _pickedPhoto = file;
        _photoRemoved = false;
      });
    } on PlatformException catch (e) {
      // Camera/photos permission denied or hardware unavailable.
      if (!mounted) return;
      final denied = (e.code).toLowerCase().contains('access') ||
          (e.message ?? '').toLowerCase().contains('denied');
      AppMessenger.showErrorBanner(
        context,
        denied
            ? 'Permission denied. Please allow camera/photos access in Settings.'
            : 'Could not open ${source == ImageSource.camera ? 'camera' : 'gallery'}. Please try again.',
      );
    } catch (_) {
      if (mounted) {
        AppMessenger.showErrorBanner(
            context, 'Could not pick the photo. Please try again.');
      }
    }
  }

  /// Uploads the picked photo to S3 via a presigned URL.
  /// Returns the public download URL, or null on failure (error already shown).
  Future<String?> _uploadPickedPhoto() async {
    final photo = _pickedPhoto;
    if (photo == null) return null;
    try {
      final fileName = photo.path.split('/').last;
      final ext = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : 'jpg';
      final contentType = switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        _ => 'image/jpeg',
      };

      final urlResponse = await apiClient.getProfilePhotoUploadUrl(
        fileName: fileName,
        contentType: contentType,
      );
      final data = urlResponse['data'] as Map<String, dynamic>?;
      final uploadUrl = data?['uploadUrl'] as String?;
      final downloadUrl = data?['downloadUrl'] as String?;
      if (uploadUrl == null || downloadUrl == null) {
        throw Exception('Invalid upload URL response');
      }

      final bytes = await photo.readAsBytes();
      await apiClient.uploadToPresignedUrl(
        uploadUrl: uploadUrl,
        bytes: bytes,
        contentType: contentType,
      );
      return downloadUrl;
    } on DioException catch (e) {
      if (mounted) {
        final msg = e.response?.statusCode == 503
            ? 'Photo upload is unavailable right now. Other changes were not saved — please try again.'
            : 'Photo upload failed. Please check your connection and try again.';
        AppMessenger.showErrorBanner(context, msg);
      }
      return null;
    } catch (_) {
      if (mounted) {
        AppMessenger.showErrorBanner(
            context, 'Photo upload failed. Please try again.');
      }
      return null;
    }
  }

  // ─── Save ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_isDirty) {
      context.pop();
      return;
    }

    setState(() => _saving = true);
    try {
      // 1. Photo first — if the upload fails we abort without partial saves.
      String? photoUrl;
      if (_pickedPhoto != null) {
        photoUrl = await _uploadPickedPhoto();
        if (photoUrl == null) {
          setState(() => _saving = false);
          return;
        }
      }

      // 2. Profile fields.
      final firstName = _firstNameController.text.trim();
      final lastName = _lastNameController.text.trim();
      final email = _emailController.text.trim();

      final payload = <String, dynamic>{
        if (firstName != _initialFirstName) 'firstName': firstName,
        if (lastName != _initialLastName) 'lastName': lastName,
        if (email != _initialEmail && email.isNotEmpty) 'email': email,
        if (photoUrl != null) 'profileImage': photoUrl,
        if (_photoRemoved) 'profileImage': '',
      };

      if (payload.isNotEmpty) {
        await apiClient.updateUser(payload);
      }

      // 3. Re-fetch so state, cache and every screen reflect the change.
      await ref.read(authStateProvider.notifier).refreshCurrentUser();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile updated'),
          backgroundColor: Color(0xFF4CAF50),
        ),
      );
      context.pop();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final data = e.response?.data;
      String message = 'Could not save your profile. Please try again.';
      if (e.response?.statusCode == 409) {
        message = 'This email is already used by another account.';
      } else if (data is Map && data['message'] != null) {
        message = data['message'].toString();
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        message = 'No internet connection. Please try again.';
      }
      AppMessenger.showErrorBanner(context, message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppMessenger.showErrorBanner(
          context, 'Could not save your profile. Please try again.');
    }
  }

  // ─── Phone change (OTP) ──────────────────────────────────────────────

  Future<void> _startPhoneChange() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _ChangePhoneSheet(),
    );
    if (changed == true && mounted) {
      await ref.read(authStateProvider.notifier).refreshCurrentUser();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Phone number updated'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
        setState(() {});
      }
    }
  }

  // ─── Back handling ───────────────────────────────────────────────────

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved changes to your profile.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard',
                style: TextStyle(color: Color(0xFFD14544))),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _handleBack() async {
    if (await _confirmDiscard()) {
      if (mounted) context.pop();
    }
  }

  // ─── UI ──────────────────────────────────────────────────────────────

  String _initials(User? user) {
    final name =
        '${_firstNameController.text} ${_lastNameController.text}'.trim();
    final source = name.isNotEmpty ? name : (user?.name ?? 'U');
    final parts = source.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first.isNotEmpty ? parts.first[0].toUpperCase() : 'U';
  }

  String _formatPhone(String phone) {
    var digits = phone.replaceFirst(RegExp(r'^\+91\s*'), '');
    digits = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 10) {
      return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
    }
    return phone.startsWith('+') ? phone : '+91 $phone';
  }

  Widget _buildAvatar(User? user) {
    ImageProvider? image;
    if (_pickedPhoto != null) {
      image = FileImage(_pickedPhoto!);
    } else if (!_photoRemoved && (user?.avatarUrl?.isNotEmpty ?? false)) {
      image = NetworkImage(user!.avatarUrl!);
    }

    return Center(
      child: Stack(
        children: [
          CircleAvatar(
            radius: 52,
            backgroundColor: AppColors.secondary,
            backgroundImage: image,
            child: image == null
                ? Text(
                    _initials(user),
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  )
                : null,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Material(
              color: _accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _saving ? null : _showPhotoOptions,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.photo_camera_outlined,
                      size: 20, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: AppColors.inputBackground,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _accent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFD14544)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFD14544), width: 1.4),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    FigmaSquareBackButton(onPressed: _handleBack),
                    const SizedBox(width: 14),
                    const Text(
                      'Edit Profile',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Form(
                    key: _formKey,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildAvatar(user),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _firstNameController,
                          decoration: _fieldDecoration('First name'),
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          maxLength: 50,
                          buildCounter: (context,
                                  {required currentLength,
                                  required isFocused,
                                  maxLength}) =>
                              null,
                          onChanged: (_) => setState(() {}),
                          validator: (value) {
                            final v = value?.trim() ?? '';
                            if (v.isEmpty) return 'First name is required';
                            if (v.length < 2) {
                              return 'First name is too short';
                            }
                            if (!RegExp(r"^[a-zA-Z\u0900-\u097F][a-zA-Z\u0900-\u097F\s.'-]*$")
                                .hasMatch(v)) {
                              return 'Please enter a valid name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _lastNameController,
                          decoration:
                              _fieldDecoration('Last name', hint: 'Optional'),
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          maxLength: 50,
                          buildCounter: (context,
                                  {required currentLength,
                                  required isFocused,
                                  maxLength}) =>
                              null,
                          onChanged: (_) => setState(() {}),
                          validator: (value) {
                            final v = value?.trim() ?? '';
                            if (v.isEmpty) return null;
                            if (!RegExp(r"^[a-zA-Z\u0900-\u097F][a-zA-Z\u0900-\u097F\s.'-]*$")
                                .hasMatch(v)) {
                              return 'Please enter a valid name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _emailController,
                          decoration:
                              _fieldDecoration('Email', hint: 'Optional'),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          onChanged: (_) => setState(() {}),
                          validator: (value) {
                            final v = value?.trim() ?? '';
                            if (v.isEmpty) return null;
                            if (!RegExp(
                                    r'^[\w.+-]+@[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$')
                                .hasMatch(v)) {
                              return 'Please enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        // Phone — read-only; changing requires OTP verification.
                        Material(
                          color: AppColors.inputBackground,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: _saving ? null : _startPhoneChange,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Phone number',
                                          style: TextStyle(
                                            fontFamily: 'Poppins',
                                            fontSize: 12,
                                            color: const Color(0xFF1A1A1A)
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          (user?.phone?.isNotEmpty ?? false)
                                              ? _formatPhone(user!.phone!)
                                              : 'Not set',
                                          style: const TextStyle(
                                            fontFamily: 'Poppins',
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF1A1A1A),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Text(
                                    'Change',
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _accent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            'Changing your number requires OTP verification.',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              fontSize: 12,
                              color: const Color(0xFF1A1A1A)
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: (_isDirty && !_saving) ? _save : null,
                    style: PrimaryCtaStyles.elevated(),
                    child: _saving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Save changes',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-step sheet: enter new number → enter OTP. Pops with `true` when the
/// backend confirms the phone change.
class _ChangePhoneSheet extends ConsumerStatefulWidget {
  const _ChangePhoneSheet();

  @override
  ConsumerState<_ChangePhoneSheet> createState() => _ChangePhoneSheetState();
}

class _ChangePhoneSheetState extends ConsumerState<_ChangePhoneSheet> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  bool _otpSent = false;
  bool _busy = false;
  String? _error;
  int _resendCooldown = 0;

  static const _accent = Color(0xFFD4956A);

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    setState(() => _resendCooldown = 30);
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _resendCooldown = _resendCooldown - 1);
      return _resendCooldown > 0;
    });
  }

  String? _validatePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    final local =
        digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    if (local.length != 10) return 'Enter a valid 10-digit mobile number';
    if (!RegExp(r'^[6-9]').hasMatch(local)) {
      return 'Enter a valid Indian mobile number';
    }
    final currentPhone = ref.read(currentUserProvider)?.phone ?? '';
    if (currentPhone.replaceAll(RegExp(r'[^\d]'), '').endsWith(local)) {
      return 'This is already your current number';
    }
    return null;
  }

  Future<void> _sendOtp() async {
    final validationError = _validatePhone(_phoneController.text);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await firebasePhoneAuth.sendOTP(_phoneController.text);
    if (!mounted) return;

    if (result.success) {
      setState(() {
        _busy = false;
        _otpSent = true;
      });
      _startResendCooldown();
      // SMS auto-read on Android can verify without typing the OTP.
      if (result.autoVerified && result.idToken != null) {
        await _submitTokenToBackend(result.idToken!);
      }
    } else {
      setState(() {
        _busy = false;
        _error = result.error ?? 'Failed to send OTP. Please try again.';
      });
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpController.text.trim().length != 6) {
      setState(() => _error = 'Please enter the 6-digit OTP');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await firebasePhoneAuth.verifyOTP(_otpController.text);
    if (!mounted) return;

    if (result.success && result.idToken != null) {
      await _submitTokenToBackend(result.idToken!);
    } else {
      setState(() {
        _busy = false;
        _error = result.error ?? 'Incorrect OTP. Please try again.';
      });
    }
  }

  Future<void> _submitTokenToBackend(String idToken) async {
    try {
      await apiClient.changePhone(idToken);
      if (mounted) Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      String message = 'Could not update your phone number. Please try again.';
      if (e.response?.statusCode == 409) {
        message = 'This number is already used by another Raahi account.';
      } else {
        final data = e.response?.data;
        if (data is Map && data['message'] != null) {
          message = data['message'].toString();
        }
      }
      setState(() {
        _busy = false;
        _error = message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not update your phone number. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _otpSent ? 'Verify your new number' : 'Change phone number',
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _otpSent
                ? 'Enter the 6-digit code sent to +91 ${_phoneController.text.replaceAll(RegExp(r'[^\d]'), '')}'
                : 'We will send an OTP to verify your new number.',
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 13,
              color: const Color(0xFF1A1A1A).withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 18),
          if (!_otpSent)
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              autofocus: true,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                prefixText: '+91 ',
                labelText: 'New phone number',
                counterText: '',
                filled: true,
                fillColor: AppColors.inputBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            )
          else
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              autofocus: true,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 20, letterSpacing: 8),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                labelText: 'OTP',
                counterText: '',
                filled: true,
                fillColor: AppColors.inputBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) {
                if (_error != null) setState(() => _error = null);
                if (value.length == 6 && !_busy) _verifyOtp();
              },
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontSize: 13,
                color: Color(0xFFD14544),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _busy ? null : (_otpSent ? _verifyOtp : _sendOtp),
              style: PrimaryCtaStyles.elevated(),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white),
                    )
                  : Text(
                      _otpSent ? 'Verify & update' : 'Send OTP',
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
          if (_otpSent) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: (_busy || _resendCooldown > 0)
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      final result = await firebasePhoneAuth
                          .resendOTP(_phoneController.text);
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _error = result.success ? null : result.error;
                      });
                      if (result.success) _startResendCooldown();
                    },
              child: Text(
                _resendCooldown > 0
                    ? 'Resend OTP in ${_resendCooldown}s'
                    : 'Resend OTP',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 13,
                  color: _accent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
