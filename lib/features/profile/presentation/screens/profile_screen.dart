import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import '../../../../core/models/user.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../../../core/services/places_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/widgets/active_ride_banner.dart';
import '../../../../core/widgets/uber_shimmer.dart';
import '../../../../core/providers/saved_locations_provider.dart';
import '../../../../core/providers/settings_provider.dart';
import '../../../auth/providers/auth_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with WidgetsBindingObserver {
  // User stats - loaded from backend
  int _totalRides = 0;
  double _rating = 0.0;
  int _savedPlacesCount = 0;
  bool _isLoadingStats = true;

  // Saved places
  List<Map<String, dynamic>> _savedPlaces = [];

  // Notification permission state – kept in sync with the OS
  bool _notificationsGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserStats();
    _loadSavedPlaces();
    _syncNotificationStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncNotificationStatus();
    }
  }

  /// Re-read the OS notification permission and align local prefs / FCM token.
  Future<void> _syncNotificationStatus() async {
    final status = await Permission.notification.status;
    final granted = status.isGranted;

    if (mounted && granted != _notificationsGranted) {
      setState(() => _notificationsGranted = granted);

      final prefs = await SharedPreferences.getInstance();
      if (granted) {
        // User enabled notifications from device settings – re-register FCM
        if (prefs.getBool('pref_push_notifications') != true) {
          await prefs.setBool('pref_push_notifications', true);
          await prefs.setBool('notificationsEnabled', true);
          pushNotificationService.registerToken().catchError((_) {});
        }
      } else {
        // User revoked notifications from device settings – unregister FCM
        if (prefs.getBool('pref_push_notifications') == true) {
          await prefs.setBool('pref_push_notifications', false);
          await prefs.setBool('notificationsEnabled', false);
          await pushNotificationService.unregisterToken();
        }
      }
    } else if (mounted) {
      setState(() => _notificationsGranted = granted);
    }
  }

  /// Format E.164 phone (+919450665544) as "+91 94506 65544"
  String _formatPhone(String phone) {
    var digits = phone.replaceFirst(RegExp(r'^\+91\s*'), '');
    digits = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 10) {
      return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
    }
    return phone.startsWith('+') ? phone : '+91 $phone';
  }

  Future<void> _loadUserStats() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    setState(() => _isLoadingStats = true);

    try {
      // Backend doesn't have a dedicated stats endpoint, get from rides
      final response = await apiClient.getUserRides();
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>? ?? {};
        final total = data['total'] as int? ?? 0;
        setState(() {
          _totalRides = total;
          _savedPlacesCount = _savedPlaces.length;
        });
      }
    } catch (e) {
      debugPrint('Error loading user stats: $e');
    } finally {
      setState(() => _isLoadingStats = false);
    }
  }

  Future<void> _loadSavedPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final placesJson = prefs.getString('saved_places') ?? '[]';
      final places = json.decode(placesJson) as List;
      final loadedPlaces =
          places.map((p) => Map<String, dynamic>.from(p)).toList();

      // Also sync from savedLocationsProvider to ensure consistency
      final savedLocations = ref.read(savedLocationsProvider);

      // Check if home exists in provider but not in local storage
      if (savedLocations.homeLocation != null) {
        final homeExists = loadedPlaces.any((p) => p['type'] == 'home');
        if (!homeExists) {
          final home = savedLocations.homeLocation!;
          loadedPlaces.add({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'name': 'Home',
            'address': home.address,
            'type': 'home',
            'lat': home.latLng.latitude,
            'lng': home.latLng.longitude,
          });
        }
      }

      // Check if work exists in provider but not in local storage
      if (savedLocations.workLocation != null) {
        final workExists = loadedPlaces.any((p) => p['type'] == 'work');
        if (!workExists) {
          final work = savedLocations.workLocation!;
          loadedPlaces.add({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'name': 'Work',
            'address': work.address,
            'type': 'work',
            'lat': work.latLng.latitude,
            'lng': work.latLng.longitude,
          });
        }
      }

      setState(() {
        _savedPlaces = loadedPlaces;
        _savedPlacesCount = _savedPlaces.length;
      });
    } catch (e) {
      debugPrint('Error loading saved places: $e');
    }
  }

  Future<void> _savePlacesToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_places', json.encode(_savedPlaces));
    setState(() => _savedPlacesCount = _savedPlaces.length);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(ref.tr('profile')),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(
                left: 20, right: 20, top: 20, bottom: 100),
            child: Column(
              children: [
                // Profile header
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.inputBackground,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 40,
                        backgroundColor: AppColors.secondary.withOpacity(0.2),
                        backgroundImage: user?.avatarUrl != null
                            ? NetworkImage(user!.avatarUrl!)
                            : null,
                        child: user?.avatarUrl == null
                            ? Text(
                                user?.name.isNotEmpty == true
                                    ? user!.name[0].toUpperCase()
                                    : 'U',
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.secondary,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.name ?? 'User',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              user?.email ?? '',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                            ),
                            if (user?.phone != null &&
                                user!.phone!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                _formatPhone(user.phone!),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Stats row - Dynamic values
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.directions_car,
                        label: 'Total Rides',
                        value: _isLoadingStats ? '' : _totalRides.toString(),
                        isLoading: _isLoadingStats,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.star,
                        label: 'Rating',
                        value: _isLoadingStats
                            ? ''
                            : (_rating > 0
                                ? _rating.toStringAsFixed(1)
                                : 'N/A'),
                        isLoading: _isLoadingStats,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.favorite,
                        label: 'Saved',
                        value:
                            _isLoadingStats ? '' : _savedPlacesCount.toString(),
                        isLoading: _isLoadingStats,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Menu items - Removed Ride History and Payment Methods
                _MenuItem(
                  icon: Icons.location_on_outlined,
                  title: ref.tr('saved_places'),
                  subtitle: 'Home, Work, and more',
                  onTap: () => _openSavedPlaces(context),
                ),
                _MenuItem(
                  icon: _notificationsGranted
                      ? Icons.notifications_active
                      : Icons.notifications_off_outlined,
                  title: ref.tr('notifications'),
                  subtitle: _notificationsGranted
                      ? ref.tr('notifications_enabled')
                      : ref.tr('notifications_disabled_tap'),
                  onTap: () => _openNotificationPreferences(context),
                ),
                _MenuItem(
                  icon: Icons.help_outline,
                  title: ref.tr('help_support'),
                  subtitle: 'Get help with your rides',
                  onTap: () => _openHelpOptions(context),
                ),
                _MenuItem(
                  icon: Icons.info_outline,
                  title: ref.tr('about'),
                  subtitle: ref.tr('about_desc'),
                  onTap: () {
                    showAboutDialog(
                      context: context,
                      applicationName: 'Raahi',
                      applicationVersion: '1.0.0',
                      applicationIcon: const Icon(Icons.directions_car,
                          size: 48, color: AppColors.primary),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // Logout button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final langCode = ref.read(settingsProvider).languageCode;
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(trWithCode('logout', langCode)),
                          content: Text(trWithCode('logout_confirm', langCode)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(trWithCode('cancel', langCode)),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.error),
                              child: Text(trWithCode('logout', langCode)),
                            ),
                          ],
                        ),
                      );

                      if (confirmed == true) {
                        await ref.read(authStateProvider.notifier).signOut();
                        if (context.mounted) {
                          context.go(AppRoutes.login);
                        }
                      }
                    },
                    icon: const Icon(Icons.logout, color: AppColors.error),
                    label: Text(ref.tr('logout'),
                        style: const TextStyle(color: AppColors.error)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.error),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
          // Active ride banner at bottom
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ActiveRideBanner(),
          ),
        ],
      ),
    );
  }

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<void> _openSettings(BuildContext context) async {
    final prefs = await _prefs();
    bool pushEnabled = prefs.getBool('pref_push_notifications') ?? false;
    bool promoEnabled = prefs.getBool('pref_promo_notifications') ?? false;

    // Check current notification permission status
    final notificationStatus = await Permission.notification.status;
    pushEnabled = pushEnabled && notificationStatus.isGranted;

    // Capture translations before entering StatefulBuilder
    final trNotificationsEnabled = ref.tr('notifications_enabled');
    final trNotifications = ref.tr('notifications');
    final trNotificationsDesc = ref.tr('notifications_desc');
    final trEnableInSettings = ref.tr('enable_in_settings');
    final trPromotions = ref.tr('promotions');
    final trPromotionsDesc = ref.tr('promotions_desc');
    final trEnableNotificationsFirst = ref.tr('enable_notifications_first');
    final trServerConfig = ref.tr('server_config');
    final trServerConfigDesc = ref.tr('server_config_desc');

    // ignore: use_build_context_synchronously
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Function to request notification permission
            Future<void> requestNotificationPermission(bool enable) async {
              if (enable) {
                // Brief delay helps Android 13 show the system dialog when requesting from a modal
                await Future.delayed(const Duration(milliseconds: 300));
                final status = await Permission.notification.request();

                if (status.isGranted) {
                  setModalState(() => pushEnabled = true);
                  await prefs.setBool('pref_push_notifications', true);
                  await prefs.setBool('notificationsEnabled', true);
                  // Register FCM token with backend (user may have denied at login, now enabling)
                  pushNotificationService.registerToken().catchError((_) {});
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(trNotificationsEnabled),
                        backgroundColor: Color(0xFF4CAF50),
                      ),
                    );
                  }
                } else if (status.isDenied || status.isPermanentlyDenied) {
                  setModalState(() => pushEnabled = false);
                  await prefs.setBool('pref_push_notifications', false);
                  // Always offer Open Settings when denied - on Android 13, request() often
                  // returns denied without showing a dialog; Settings is the only path.
                  if (context.mounted) {
                    _showOpenSettingsDialog(context, onOpenSettings: () {
                      Navigator.of(context)
                          .pop(); // pop sheet so next open reads fresh state
                      openAppSettings();
                    });
                  }
                }
              } else {
                // Just disable in preferences (can't revoke system permission)
                setModalState(() => pushEnabled = false);
                await prefs.setBool('pref_push_notifications', false);
                await prefs.setBool('notificationsEnabled', false);
                await pushNotificationService.unregisterToken();
              }
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: Text(trNotifications),
                    subtitle: Text(trNotificationsDesc),
                    value: pushEnabled,
                    activeColor: const Color(0xFFD4956A),
                    onChanged: (value) => requestNotificationPermission(value),
                  ),
                  // When permission not granted, offer direct path to settings
                  if (!pushEnabled) ...[
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                      child: TextButton.icon(
                        onPressed: () => openAppSettings(),
                        icon: const Icon(Icons.settings,
                            size: 18, color: Color(0xFFD4956A)),
                        label: Text(trEnableInSettings,
                            style: TextStyle(color: Color(0xFFD4956A))),
                      ),
                    ),
                  ],
                  SwitchListTile(
                    title: Text(trPromotions),
                    subtitle: Text(trPromotionsDesc),
                    value: promoEnabled,
                    activeColor: const Color(0xFFD4956A),
                    onChanged: (value) async {
                      if (value && !pushEnabled) {
                        // Need to enable notifications first
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(trEnableNotificationsFirst),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        }
                        return;
                      }
                      setModalState(() => promoEnabled = value);
                      await prefs.setBool('pref_promo_notifications', value);
                    },
                  ),
                  const Divider(),
                  // Language selection
                  ListTile(
                    leading: const Icon(Icons.language),
                    title: const Text('Language'),
                    subtitle: Text(_getCurrentLanguageName()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context);
                      _showLanguageSelector();
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(trServerConfig),
                    subtitle: Text(trServerConfigDesc),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context);
                      context.push('${AppRoutes.serverConfig}?initial=false');
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Get current language display name
  String _getCurrentLanguageName() {
    final settings = ref.read(settingsProvider);
    final currentLang = supportedLanguages.firstWhere(
      (l) => l.code == settings.languageCode,
      orElse: () => supportedLanguages.first,
    );
    return currentLang.nativeName.isNotEmpty
        ? '${currentLang.name} (${currentLang.nativeName})'
        : currentLang.name;
  }

  /// Show language selection bottom sheet
  /// FIXED: Use Consumer to get reactive updates so language can be changed multiple times
  void _showLanguageSelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          // Watch settings to get reactive updates
          final settings = ref.watch(settingsProvider);
          final currentCode = settings.languageCode;
          
          debugPrint('🌐 Language selector opened - current: $currentCode');
          
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Title
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.language, color: Color(0xFFD4956A)),
                      const SizedBox(width: 12),
                      Text(
                        ref.tr('select_language'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Language list
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: supportedLanguages.length,
                  itemBuilder: (context, index) {
                    final lang = supportedLanguages[index];
                    final isSelected = lang.code == currentCode;

                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFD4956A).withOpacity(0.1)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            lang.code.toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? const Color(0xFFD4956A)
                                  : Colors.grey[600],
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        lang.name,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                          color:
                              isSelected ? const Color(0xFFD4956A) : Colors.black87,
                        ),
                      ),
                      subtitle:
                          lang.nativeName.isNotEmpty && lang.nativeName != lang.name
                              ? Text(lang.nativeName)
                              : null,
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Color(0xFFD4956A))
                          : null,
                      onTap: () async {
                        // Close sheet first
                        Navigator.pop(sheetContext);
                        
                        // Always allow language change (removed the currentCode check that was blocking)
                        debugPrint('🌐 Language change requested: ${lang.code} (was: $currentCode)');
                        
                        // Small delay to let sheet animation finish
                        await Future.delayed(const Duration(milliseconds: 200));
                        
                        await ref
                            .read(settingsProvider.notifier)
                            .setLanguage(lang.code, lang.name);
                        
                        debugPrint('✅ Language changed to: ${lang.code}');
                        
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text('Language changed to ${lang.name}'),
                              backgroundColor: const Color(0xFF4CAF50),
                            ),
                          );
                          setState(() {}); // Refresh UI
                        }
                      },
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showOpenSettingsDialog(BuildContext context,
      {VoidCallback? onOpenSettings}) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ref.tr('notifications_disabled')),
        content: const Text(
          'Notification permission has been denied. To enable notifications, please go to your device settings and allow notifications for this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(ref.tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              if (onOpenSettings != null) {
                onOpenSettings();
              } else {
                openAppSettings();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD4956A),
            ),
            child: Text(ref.tr('open_settings'),
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _openSavedPlaces(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return Column(
                children: [
                  // Handle bar
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
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
                          'Saved Places',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  // Add place button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: GestureDetector(
                      onTap: () async {
                        Navigator.pop(context);
                        await _showAddPlaceScreen(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE8E8E8)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFFD4956A).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.add_location_alt,
                                  color: Color(0xFFD4956A)),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Add a new place',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Search and save your favorite locations',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF888888),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                color: Color(0xFF888888)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Saved places list
                  Expanded(
                    child: _savedPlaces.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.location_off_outlined,
                                    size: 64, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text(
                                  'No saved places yet',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Add home, work or other places\nfor quick booking',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[500],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: _savedPlaces.length,
                            itemBuilder: (context, index) {
                              final place = _savedPlaces[index];
                              return _buildSavedPlaceTile(place, setModalState);
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSavedPlaceTile(
      Map<String, dynamic> place, StateSetter setModalState) {
    IconData placeIcon;
    Color iconColor;

    switch (place['type'] ?? 'other') {
      case 'home':
        placeIcon = Icons.home;
        iconColor = const Color(0xFF4CAF50);
        break;
      case 'work':
        placeIcon = Icons.work;
        iconColor = const Color(0xFF2196F3);
        break;
      default:
        placeIcon = Icons.place;
        iconColor = const Color(0xFFD4956A);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(placeIcon, color: iconColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place['name'] ?? 'Saved Place',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  place['address'] ?? '',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF888888),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.error),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(ref.tr('delete_place')),
                  content: Text(
                      'Are you sure you want to delete "${place['name']}"?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(ref.tr('cancel')),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.error),
                      child: Text(ref.tr('delete'),
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                setModalState(() {
                  _savedPlaces.removeWhere((p) => p['id'] == place['id']);
                });
                setState(() {});
                await _savePlacesToPrefs();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(ref.tr('place_deleted'))),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showAddPlaceScreen(BuildContext context) async {
    final searchController = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;
    LatLng? userLocation;

    // Try to get user's current location for better search results
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 5));
      userLocation = LatLng(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('Could not get user location: $e');
    }

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (context, scrollController) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                Future<void> searchPlaces(String query) async {
                  if (query.length < 2) {
                    setModalState(() => searchResults = []);
                    return;
                  }

                  setModalState(() => isSearching = true);

                  try {
                    final results = await placesService.searchPlacesAsMap(query,
                        location: userLocation);
                    setModalState(() {
                      searchResults = results;
                      isSearching = false;
                    });
                  } catch (e) {
                    debugPrint('Error searching places: $e');
                    setModalState(() {
                      searchResults = [];
                      isSearching = false;
                    });
                  }
                }

                Future<void> savePlace(Map<String, dynamic> place) async {
                  // Show type selection dialog
                  final type = await showDialog<String>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(ref.tr('save_as')),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.home,
                                color: Color(0xFF4CAF50)),
                            title: Text(ref.tr('home')),
                            onTap: () => Navigator.pop(context, 'home'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.work,
                                color: Color(0xFF2196F3)),
                            title: Text(ref.tr('work')),
                            onTap: () => Navigator.pop(context, 'work'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.place,
                                color: Color(0xFFD4956A)),
                            title: Text(ref.tr('other')),
                            onTap: () => Navigator.pop(context, 'other'),
                          ),
                        ],
                      ),
                    ),
                  );

                  if (type == null) return;

                  // Get place details if we don't have coordinates yet
                  double? lat = place['lat'] as double?;
                  double? lng = place['lng'] as double?;

                  if ((lat == null || lng == null) &&
                      place['place_id'] != null) {
                    final placeDetails = await placesService
                        .getPlaceDetailsAsMap(place['place_id']);
                    lat = placeDetails?['lat'] as double?;
                    lng = placeDetails?['lng'] as double?;
                  }

                  final newPlace = {
                    'id': DateTime.now().millisecondsSinceEpoch.toString(),
                    'name': type == 'home'
                        ? 'Home'
                        : (type == 'work' ? 'Work' : place['name']),
                    'address': place['address'] ?? place['name'],
                    'type': type,
                    'lat': lat,
                    'lng': lng,
                    'place_id': place['place_id'],
                  };

                  // Check for duplicates
                  final existingIndex = _savedPlaces.indexWhere((p) =>
                      p['type'] == type && (type == 'home' || type == 'work'));
                  if (existingIndex != -1 &&
                      (type == 'home' || type == 'work')) {
                    setState(() {
                      _savedPlaces[existingIndex] = newPlace;
                    });
                  } else {
                    setState(() {
                      _savedPlaces.add(newPlace);
                    });
                  }

                  await _savePlacesToPrefs();

                  // Sync with savedLocationsProvider so it reflects everywhere in the app
                  if (lat != null && lng != null) {
                    final location = LatLng(lat, lng);
                    final placeName = newPlace['name'] as String;
                    final address = newPlace['address'] as String;

                    if (type == 'home') {
                      await ref
                          .read(savedLocationsProvider.notifier)
                          .setHomeLocation(
                            name: placeName,
                            address: address,
                            location: location,
                          );
                    } else if (type == 'work') {
                      await ref
                          .read(savedLocationsProvider.notifier)
                          .setWorkLocation(
                            name: placeName,
                            address: address,
                            location: location,
                          );
                    } else {
                      await ref
                          .read(savedLocationsProvider.notifier)
                          .addFavorite(
                            name: placeName,
                            address: address,
                            location: location,
                          );
                    }
                  }

                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${newPlace['name']} saved!'),
                        backgroundColor: const Color(0xFF4CAF50),
                      ),
                    );
                    _openSavedPlaces(context);
                  }
                }

                return Column(
                  children: [
                    // Handle bar
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Header
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          const Expanded(
                            child: Text(
                              'Add Place',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Search input
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        controller: searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText:
                              'Search for a place (e.g., Delhi, Connaught Place)',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    searchController.clear();
                                    setModalState(() => searchResults = []);
                                  },
                                )
                              : null,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Color(0xFFE8E8E8)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Color(0xFFD4956A)),
                          ),
                        ),
                        onChanged: (value) => searchPlaces(value),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Pick from map option
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: GestureDetector(
                        onTap: () async {
                          Navigator.pop(context);
                          await _showMapPicker(context);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8F8F8),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE8E8E8)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color:
                                      const Color(0xFFD4956A).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.map,
                                    color: Color(0xFFD4956A)),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Pick from map',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Tap to select location on map',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF888888),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  color: Color(0xFF888888)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Search results
                    Expanded(
                      child: isSearching
                          ? UberShimmer(
                              child: ListView.separated(
                                itemCount: 6,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (_, __) => const Row(
                                  children: [
                                    UberShimmerBox(
                                      width: 36,
                                      height: 36,
                                      borderRadius:
                                          BorderRadius.all(Radius.circular(18)),
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          UberShimmerBox(
                                              width: double.infinity,
                                              height: 12),
                                          SizedBox(height: 6),
                                          UberShimmerBox(
                                              width: 180, height: 10),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : searchResults.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.search,
                                          size: 64, color: Colors.grey[400]),
                                      const SizedBox(height: 16),
                                      Text(
                                        searchController.text.isEmpty
                                            ? 'Search for a location'
                                            : searchController.text.length < 2
                                                ? 'Type at least 2 characters'
                                                : 'No results found',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      if (searchController.text.isNotEmpty &&
                                          searchController.text.length >= 2)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 8),
                                          child: Text(
                                            'Try "Pick from map" option above',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey[500],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  controller: scrollController,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20),
                                  itemCount: searchResults.length,
                                  itemBuilder: (context, index) {
                                    final result = searchResults[index];
                                    return ListTile(
                                      leading: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5F5F5),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Icon(Icons.place,
                                            color: Color(0xFFD4956A)),
                                      ),
                                      title: Text(
                                        result['name'] ?? '',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w500),
                                      ),
                                      subtitle: Text(
                                        result['address'] ?? '',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      onTap: () => savePlace(result),
                                    );
                                  },
                                ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMapPicker(BuildContext context) async {
    LatLng? selectedLocation;
    String? selectedAddress;
    GoogleMapController? mapController;
    bool isLoadingAddress = false;
    String? mapStyle;

    // Load map style based on dark mode
    final isDarkMode = ref.read(settingsProvider).isDarkMode;
    try {
      final stylePath = isDarkMode
          ? 'assets/map_styles/raahi_dark.json'
          : 'assets/map_styles/raahi_light.json';
      mapStyle = await rootBundle.loadString(stylePath);
    } catch (e) {
      debugPrint('Failed to load map style: $e');
    }

    // Default to Delhi NCR
    LatLng initialPosition = const LatLng(28.6139, 77.2090);

    // Try to get current location
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 5));
      initialPosition = LatLng(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('Could not get location for map: $e');
    }

    selectedLocation = initialPosition;

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.95,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              Future<void> getAddressFromLatLng(LatLng position) async {
                setModalState(() => isLoadingAddress = true);
                try {
                  final placemarks = await geocoding.placemarkFromCoordinates(
                    position.latitude,
                    position.longitude,
                  );
                  if (placemarks.isNotEmpty) {
                    final place = placemarks.first;
                    final parts = <String>[];
                    if (place.name != null && place.name!.isNotEmpty)
                      parts.add(place.name!);
                    if (place.subLocality != null &&
                        place.subLocality!.isNotEmpty)
                      parts.add(place.subLocality!);
                    if (place.locality != null && place.locality!.isNotEmpty)
                      parts.add(place.locality!);
                    if (place.administrativeArea != null &&
                        place.administrativeArea!.isNotEmpty)
                      parts.add(place.administrativeArea!);

                    selectedAddress = parts.join(', ');
                  }
                } catch (e) {
                  debugPrint('Error getting address: $e');
                  selectedAddress =
                      '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}';
                }
                setModalState(() => isLoadingAddress = false);
              }

              // Get initial address
              if (selectedAddress == null && !isLoadingAddress) {
                getAddressFromLatLng(selectedLocation!);
              }

              return Column(
                children: [
                  // Handle bar
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Header
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        const Expanded(
                          child: Text(
                            'Pick Location',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Map
                  Expanded(
                    child: Stack(
                      children: [
                        GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: initialPosition,
                            zoom: 15,
                          ),
                          onMapCreated: (controller) {
                            mapController = controller;
                            // Apply map style
                            if (mapStyle != null) {
                              controller.setMapStyle(mapStyle);
                            }
                          },
                          onCameraMove: (position) {
                            selectedLocation = position.target;
                          },
                          onCameraIdle: () {
                            if (selectedLocation != null) {
                              getAddressFromLatLng(selectedLocation!);
                            }
                          },
                          myLocationEnabled: true,
                          myLocationButtonEnabled: true,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,
                        ),
                        // Center pin
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: 40),
                            child: Icon(
                              Icons.location_pin,
                              size: 50,
                              color: Color(0xFFD4956A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Bottom panel with address and confirm button
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 10,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFFD4956A).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.place,
                                  color: Color(0xFFD4956A)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: isLoadingAddress
                                  ? const UberShimmer(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          UberShimmerBox(
                                              width: 120, height: 12),
                                          SizedBox(height: 6),
                                          UberShimmerBox(
                                              width: 170, height: 10),
                                        ],
                                      ),
                                    )
                                  : Text(
                                      selectedAddress ??
                                          'Move map to select location',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: selectedLocation != null &&
                                    !isLoadingAddress
                                ? () async {
                                    Navigator.pop(context);
                                    await _saveMapLocation(
                                      context,
                                      selectedLocation!,
                                      selectedAddress ?? 'Selected location',
                                    );
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFD4956A),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Confirm Location',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _saveMapLocation(
      BuildContext context, LatLng location, String address) async {
    final type = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ref.tr('save_as')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.home, color: Color(0xFF4CAF50)),
              title: Text(ref.tr('home')),
              onTap: () => Navigator.pop(context, 'home'),
            ),
            ListTile(
              leading: const Icon(Icons.work, color: Color(0xFF2196F3)),
              title: Text(ref.tr('work')),
              onTap: () => Navigator.pop(context, 'work'),
            ),
            ListTile(
              leading: const Icon(Icons.place, color: Color(0xFFD4956A)),
              title: Text(ref.tr('other')),
              onTap: () => Navigator.pop(context, 'other'),
            ),
          ],
        ),
      ),
    );

    if (type == null || !context.mounted) return;

    String placeName =
        type == 'home' ? 'Home' : (type == 'work' ? 'Work' : 'Saved Place');

    // For 'other' type, let user enter a custom name
    if (type == 'other') {
      final nameController = TextEditingController();
      final customName = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(ref.tr('place_name')),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Enter place name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(ref.tr('cancel')),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, nameController.text.trim()),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD4956A)),
              child:
                  Text(ref.tr('save'), style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (customName == null || customName.isEmpty || !context.mounted) return;
      placeName = customName;
    }

    final newPlace = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': placeName,
      'address': address,
      'type': type,
      'lat': location.latitude,
      'lng': location.longitude,
    };

    final existingIndex = _savedPlaces.indexWhere(
        (p) => p['type'] == type && (type == 'home' || type == 'work'));
    if (existingIndex != -1 && (type == 'home' || type == 'work')) {
      setState(() {
        _savedPlaces[existingIndex] = newPlace;
      });
    } else {
      setState(() {
        _savedPlaces.add(newPlace);
      });
    }

    await _savePlacesToPrefs();

    // Sync with savedLocationsProvider so it reflects everywhere in the app
    if (type == 'home') {
      await ref.read(savedLocationsProvider.notifier).setHomeLocation(
            name: placeName,
            address: address,
            location: location,
          );
    } else if (type == 'work') {
      await ref.read(savedLocationsProvider.notifier).setWorkLocation(
            name: placeName,
            address: address,
            location: location,
          );
    } else {
      await ref.read(savedLocationsProvider.notifier).addFavorite(
            name: placeName,
            address: address,
            location: location,
          );
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$placeName saved!'),
          backgroundColor: const Color(0xFF4CAF50),
        ),
      );
      _openSavedPlaces(context);
    }
  }

  Future<void> _openNotificationPreferences(BuildContext context) async {
    await _openSettings(context);
    _syncNotificationStatus();
  }

  Future<void> _openHelpOptions(BuildContext context) async {
    const supportNumber = '+18001234567';
    const supportEmail = 'support@raahi.app';

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call),
              title: Text(ref.tr('call_support_profile')),
              subtitle: Text(supportNumber),
              onTap: () =>
                  _launchUri(Uri(scheme: 'tel', path: supportNumber), context),
            ),
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(ref.tr('email_support_profile')),
              subtitle: Text(supportEmail),
              onTap: () => _launchUri(
                  Uri(
                    scheme: 'mailto',
                    path: supportEmail,
                    query: 'subject=Support request',
                  ),
                  context),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(ref.tr('message_support')),
              subtitle: Text(ref.tr('reply_shortly')),
              onTap: () =>
                  _launchUri(Uri(scheme: 'sms', path: supportNumber), context),
            ),
          ],
        );
      },
    );
  }

  Future<void> _launchUri(Uri uri, BuildContext context) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(ref.tr('cannot_open_link')),
            backgroundColor: AppColors.error),
      );
    }
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isLoading;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.inputBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.primary, size: 24),
          const SizedBox(height: 8),
          if (isLoading)
            const UberShimmer(
              child: UberShimmerBox(width: 44, height: 18),
            )
          else
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          const SizedBox(height: 4),
          if (isLoading)
            const UberShimmer(
              child: UberShimmerBox(width: 56, height: 10),
            )
          else
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.inputBackground,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AppColors.textPrimary, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: onTap,
    );
  }
}
