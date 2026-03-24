import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../providers/driver_onboarding_provider.dart';
import '../../../auth/providers/auth_provider.dart';

/// Screen for managing/updating driver documents.
/// Shows all uploaded documents with status, expiry warnings, and re-upload options.
class DriverDocumentManagementScreen extends ConsumerStatefulWidget {
  const DriverDocumentManagementScreen({super.key});

  @override
  ConsumerState<DriverDocumentManagementScreen> createState() => _DriverDocumentManagementScreenState();
}

class _DriverDocumentManagementScreenState extends ConsumerState<DriverDocumentManagementScreen> {
  static const _beige = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textPrimary = Color(0xFF1A1A1A);
  static const _textSecondary = Color(0xFF888888);
  static const _inputBg = Color(0xFFEDE6DA);
  static const _border = Color(0xFFE8E0D4);
  static const _success = Color(0xFF4CAF50);
  static const _error = Color(0xFFE53935);
  static const _warning = Color(0xFFFFA000);

  bool _hasFetchedStatus = false;
  final ImagePicker _picker = ImagePicker();
  String? _reuploadingDocType;

  static const List<Map<String, dynamic>> _allDocuments = [
    {'backendId': 'LICENSE', 'frontendId': 'driving_license', 'title': 'Driving License', 'icon': Icons.badge_outlined, 'color': Color(0xFF2196F3)},
    {'backendId': 'RC', 'frontendId': 'vehicle_rc', 'title': 'Registration Certificate (RC)', 'icon': Icons.description_outlined, 'color': Color(0xFF9C27B0)},
    {'backendId': 'INSURANCE', 'frontendId': 'vehicle_insurance', 'title': 'Vehicle Insurance', 'icon': Icons.security_outlined, 'color': Color(0xFF00BCD4)},
    {'backendId': 'PAN_CARD', 'frontendId': 'pan_card', 'title': 'PAN Card', 'icon': Icons.credit_card_outlined, 'color': Color(0xFFFF9800)},
    {'backendId': 'AADHAAR_CARD', 'frontendId': 'aadhaar_card', 'title': 'Aadhaar Card', 'icon': Icons.fingerprint, 'color': Color(0xFF4CAF50)},
    {'backendId': 'PROFILE_PHOTO', 'frontendId': 'profile_photo', 'title': 'Profile Photo', 'icon': Icons.person_outline, 'color': Color(0xFFD4956A)},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchBackendStatus();
    });
  }

  Future<void> _fetchBackendStatus() async {
    if (_hasFetchedStatus) return;
    _hasFetchedStatus = true;
    debugPrint('📋 DriverDocumentManagementScreen: Fetching backend status...');
    await ref.read(driverOnboardingProvider.notifier).fetchOnboardingStatus();
  }

  Future<void> _refreshStatus() async {
    await ref.read(driverOnboardingProvider.notifier).fetchOnboardingStatus();
  }

  Future<void> _reuploadDocument(String backendId, String frontendId, String title) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Update $title', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: _accent.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.camera_alt, color: _accent),
              ),
              title: Text(ref.tr('camera')),
              subtitle: Text(ref.tr('take_photo')),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF2196F3).withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.photo_library, color: Color(0xFF2196F3)),
              ),
              title: Text(ref.tr('gallery')),
              subtitle: Text(ref.tr('choose_gallery')),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;

    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (image == null || !mounted) return;

      setState(() => _reuploadingDocType = backendId);

      final notifier = ref.read(driverOnboardingProvider.notifier);
      final result = await notifier.uploadDocument(frontendId, image.path, isFront: true);
      final success = result['success'] as bool? ?? false;

      if (!mounted) return;
      setState(() => _reuploadingDocType = null);

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$title uploaded successfully!'),
            backgroundColor: _success,
          ),
        );
        await _refreshStatus();
      } else {
        final errorMsg = result['error'] as String? ?? 'Upload failed';
        _showUploadError(title, errorMsg);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _reuploadingDocType = null);
        _showUploadError(title, e.toString());
      }
    }
  }

  void _showUploadError(String docTitle, String error) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: _error, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(ref.tr('upload_failed'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Failed to upload $docTitle', style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Text(error.replaceFirst(RegExp(r'^Exception:\s*'), ''), style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ref.tr('ok'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onboardingState = ref.watch(driverOnboardingProvider);
    final backendStatus = onboardingState.backendStatus;
    final hasRejections = backendStatus.hasRejectedDocuments;
    final hasExpiring = _hasExpiringDocuments(backendStatus);

    return Scaffold(
      backgroundColor: _beige,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshStatus,
          color: _accent,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context),
                const SizedBox(height: 24),

                // Title
                const Text(
                  'Update Documents',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _textPrimary),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Review and update your driver documents',
                  style: TextStyle(fontSize: 14, color: _textSecondary),
                ),
                const SizedBox(height: 24),

                // Warning banner for rejections
                if (hasRejections) ...[
                  _buildRejectionBanner(backendStatus.rejectedDocuments.length),
                  const SizedBox(height: 16),
                ],

                // Warning banner for expiring documents
                if (hasExpiring && !hasRejections) ...[
                  _buildExpiryWarningBanner(),
                  const SizedBox(height: 16),
                ],

                // Document cards
                const Text(
                  'Your Documents',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _textPrimary),
                ),
                const SizedBox(height: 12),

                ..._allDocuments.map((doc) {
                  final backendId = doc['backendId'] as String;
                  final frontendId = doc['frontendId'] as String;
                  final title = doc['title'] as String;
                  final icon = doc['icon'] as IconData;
                  final color = doc['color'] as Color;
                  final docStatus = backendStatus.getDocumentStatus(backendId);
                  final rejectionReason = backendStatus.getRejectionReason(backendId);
                  final isReuploading = _reuploadingDocType == backendId;
                  final isExpiring = _isDocumentExpiring(backendId, backendStatus);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildDocumentCard(
                      icon: icon,
                      color: color,
                      title: title,
                      status: docStatus,
                      rejectionReason: rejectionReason,
                      isReuploading: isReuploading,
                      isExpiring: isExpiring,
                      onReupload: () => _reuploadDocument(backendId, frontendId, title),
                    ),
                  );
                }),

                const SizedBox(height: 24),

                // Back button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back, size: 20),
                    label: const Text(
                      'Back to Home',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textPrimary,
                      side: BorderSide(color: _border, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: () => context.pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: _inputBg, borderRadius: BorderRadius.circular(12)),
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
                  Text(ref.tr('support'), style: TextStyle(fontSize: 12, color: _textSecondary)),
                  Icon(Icons.keyboard_arrow_down, size: 16, color: _textSecondary),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: _refreshStatus,
          icon: const Icon(Icons.refresh_rounded, color: _textSecondary),
          tooltip: 'Refresh status',
        ),
      ],
    );
  }

  bool _hasExpiringDocuments(BackendOnboardingStatus status) {
    // Check if any document is about to expire
    // For now, we check documents that typically expire: LICENSE, INSURANCE, RC
    // In future, backend should provide expiry dates
    return false; // Will be enhanced when backend provides expiry info
  }

  bool _isDocumentExpiring(String backendId, BackendOnboardingStatus status) {
    // Documents that can expire: LICENSE, INSURANCE, RC
    // For now, return false - will be enhanced when backend provides expiry dates
    // Placeholder for future expiry logic
    return false;
  }

  Widget _buildRejectionBanner(int rejectedCount) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _error.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: _error, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$rejectedCount document${rejectedCount > 1 ? 's' : ''} need attention',
                  style: const TextStyle(fontSize: 14, color: _error, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Please review and re-upload the affected documents.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFC62828)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpiryWarningBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _warning.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.schedule, color: _warning, size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Documents expiring soon',
                  style: TextStyle(fontSize: 14, color: Color(0xFFE65100), fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  'Some documents are about to expire. Please update them to continue driving.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentCard({
    required IconData icon,
    required Color color,
    required String title,
    required DocumentStatus status,
    required String? rejectionReason,
    required bool isReuploading,
    required bool isExpiring,
    required VoidCallback onReupload,
  }) {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (status) {
      case DocumentStatus.verified:
        statusColor = _success;
        statusText = 'Verified';
        statusIcon = Icons.check_circle;
        break;
      case DocumentStatus.rejected:
        statusColor = _error;
        statusText = 'Verification Failed';
        statusIcon = Icons.cancel;
        break;
      case DocumentStatus.inReview:
        statusColor = _accent;
        statusText = 'Under Review';
        statusIcon = Icons.hourglass_empty;
        break;
      case DocumentStatus.uploading:
      case DocumentStatus.uploaded:
        statusColor = _accent;
        statusText = 'Uploaded';
        statusIcon = Icons.cloud_done_outlined;
        break;
      case DocumentStatus.notUploaded:
      default:
        statusColor = _textSecondary;
        statusText = 'Not uploaded';
        statusIcon = Icons.upload_file;
    }

    // Override for expiring documents
    if (isExpiring && status == DocumentStatus.verified) {
      statusColor = _warning;
      statusText = 'Expiring Soon';
      statusIcon = Icons.warning_amber_rounded;
    }

    final isRejected = status == DocumentStatus.rejected;
    final showReupload = isRejected || isExpiring || status == DocumentStatus.verified;

    Color cardBg = Colors.white;
    Color borderColor = _border;
    double borderWidth = 1;
    
    if (isRejected) {
      cardBg = const Color(0xFFFFF5F5);
      borderColor = _error.withOpacity(0.4);
      borderWidth = 1.5;
    } else if (isExpiring) {
      cardBg = const Color(0xFFFFF8E1);
      borderColor = _warning.withOpacity(0.4);
      borderWidth = 1.5;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: statusColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _textPrimary)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(statusIcon, size: 14, color: statusColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 12,
                              color: statusColor,
                              fontWeight: isRejected || isExpiring ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Show expiry warning icon
              if (isExpiring)
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.warning_amber_rounded, color: _warning, size: 24),
                )
              else if (status == DocumentStatus.verified)
                const Icon(Icons.check_circle, color: _success, size: 24),
            ],
          ),

          // Rejection reason
          if (isRejected && rejectionReason != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline, size: 16, color: _error),
                      const SizedBox(width: 6),
                      Text(ref.tr('rejection_reason'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _error)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    rejectionReason,
                    style: TextStyle(fontSize: 13, color: _error.withOpacity(0.85), height: 1.4),
                  ),
                ],
              ),
            ),
          ],

          // Re-upload button for rejected, expiring, or verified docs
          if (showReupload) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: isReuploading ? null : onReupload,
                icon: isReuploading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.cloud_upload_outlined, size: 20),
                label: Text(
                  isReuploading 
                      ? 'Uploading...' 
                      : isRejected 
                          ? 'Re-upload $title'
                          : 'Update $title',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRejected ? _error : (isExpiring ? _warning : _accent),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: (isRejected ? _error : _accent).withOpacity(0.6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
