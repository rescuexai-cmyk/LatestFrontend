import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';

const String _pendingRideActionsPrefKey =
    'pending_ride_notification_actions_v1';

Future<void> _enqueuePendingRideAction(
  String action,
  Map<String, dynamic> data, {
  bool accepted = false,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing =
        prefs.getStringList(_pendingRideActionsPrefKey) ?? <String>[];
    final entry = jsonEncode({
      'action': action,
      'accepted': accepted,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    });
    final updated = <String>[...existing, entry];
    // Keep queue bounded.
    if (updated.length > 20) {
      updated.removeRange(0, updated.length - 20);
    }
    await prefs.setStringList(_pendingRideActionsPrefKey, updated);
  } catch (e) {
    debugPrint('❌ Failed to enqueue pending ride action: $e');
  }
}

Future<List<Map<String, dynamic>>> _drainPendingRideActions() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        prefs.getStringList(_pendingRideActionsPrefKey) ?? <String>[];
    await prefs.remove(_pendingRideActionsPrefKey);
    final actions = <Map<String, dynamic>>[];
    for (final item in encoded) {
      try {
        final parsed = jsonDecode(item);
        if (parsed is Map<String, dynamic>) actions.add(parsed);
      } catch (_) {}
    }
    return actions;
  } catch (e) {
    debugPrint('❌ Failed to drain pending ride actions: $e');
    return <Map<String, dynamic>>[];
  }
}

/// Notification action identifiers
class NotificationActions {
  static const String acceptRide = 'ACCEPT_RIDE';
  static const String declineRide = 'DECLINE_RIDE';
  static const String viewRide = 'VIEW_RIDE';
  static const String callDriver = 'CALL_DRIVER';
  static const String callRider = 'CALL_RIDER';
}

/// Notification type identifiers used in payload routing.
class NotificationTypes {
  static const String driverOnboarding = 'DRIVER_ONBOARDING';
  static const String newRide = 'NEW_RIDE';
}

/// Service to handle push notifications via Firebase Cloud Messaging (FCM)
///
/// Features:
/// - Registers device token with backend
/// - Handles foreground, background, and terminated notifications
/// - Navigates to relevant screens on notification tap
/// - Manages Android notification channels
class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  /// Lazy: avoid accessing Firebase before Firebase.initializeApp() runs.
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  bool _isInitialized = false;

  // Callback for handling notification taps
  void Function(Map<String, dynamic> data)? onNotificationTap;

  // Callback for handling notification actions (Accept/Decline)
  Future<void> Function(String action, Map<String, dynamic> data)?
      onNotificationAction;

  // Stream controller for notification events
  final _notificationController = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get notificationStream =>
      _notificationController.stream;

  // Stream for ride request actions (Accept/Decline from notification)
  final _rideActionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get rideActionStream =>
      _rideActionController.stream;

  // Stream for in-app chat-open intents triggered by push taps.
  final _chatOpenController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get chatOpenStream => _chatOpenController.stream;

  String? get fcmToken => _fcmToken;

  /// Show local notification when driver onboarding is approved.
  /// This is used as a fallback/companion to backend FCM events.
  Future<void> showDriverOnboardingCompletedNotification() async {
    final notificationsEnabled = await _areNotificationsEnabledInApp();
    if (!notificationsEnabled) return;

    const payload = {
      'type': NotificationTypes.driverOnboarding,
      'event': 'VERIFIED',
      'status': 'COMPLETED',
    };

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'You are verified!',
      'Your driver documents are approved. You can start taking rides now.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'raahi_system',
          'System',
          channelDescription: 'System notifications',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(payload),
    );
  }

  /// Initialize the push notification service
  /// Call this once at app startup after Firebase.initializeApp()
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Request permissions
      // Note: criticalAlert requires Apple-approved entitlement; use false to avoid crash
      final settings = await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      debugPrint('📱 Push permission status: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('⚠️ Push notifications denied by user');
        return;
      }

      // Initialize local notifications for foreground display
      await _initializeLocalNotifications();

      // Get the FCM token
      _fcmToken = await _messaging.getToken();
      debugPrint('📱 FCM Token: ${_fcmToken?.substring(0, 30)}...');

      // Listen for token refresh
      _messaging.onTokenRefresh.listen((newToken) {
        debugPrint('🔄 FCM Token refreshed');
        _fcmToken = newToken;
        // Re-register with backend
        _registerTokenWithBackend();
      });

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Handle notification tap when app is in background/terminated
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Check if app was opened from a notification
      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('📬 App opened from notification');
        // Delay to ensure navigation is ready
        Future.delayed(const Duration(seconds: 1), () {
          _handleNotificationTap(initialMessage);
        });
      }

      _isInitialized = true;
      debugPrint('✅ Push notification service initialized');
    } catch (e) {
      debugPrint('❌ Failed to initialize push notifications: $e');
    }
  }

  /// Initialize local notifications plugin for foreground display
  Future<void> _initializeLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS notification categories with actions
    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        // Ride request category with Accept/Decline actions
        DarwinNotificationCategory(
          'RIDE_REQUEST',
          actions: [
            DarwinNotificationAction.plain(
              NotificationActions.acceptRide,
              'Accept',
              options: {
                DarwinNotificationActionOption.foreground,
              },
            ),
            DarwinNotificationAction.plain(
              NotificationActions.declineRide,
              'Decline',
              options: {
                DarwinNotificationActionOption.destructive,
              },
            ),
          ],
          options: {
            DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
          },
        ),
      ],
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          _handleBackgroundNotificationResponse,
    );

    // Create Android notification channels
    if (Platform.isAndroid) {
      await _createAndroidChannels();
    }
  }

  /// Handle notification response (tap or action button)
  void _handleNotificationResponse(NotificationResponse response) {
    debugPrint(
        '📬 Notification response: action=${response.actionId}, payload=${response.payload}');

    if (response.payload == null) return;

    try {
      final data = jsonDecode(response.payload!) as Map<String, dynamic>;

      // Check if this is an action button press
      if (response.actionId != null && response.actionId!.isNotEmpty) {
        _handleActionButton(response.actionId!, data);
      } else {
        // Regular notification tap
        onNotificationTap?.call(data);
      }
    } catch (e) {
      debugPrint('❌ Failed to parse notification payload: $e');
    }
  }

  /// Handle action button press
  void _handleActionButton(String actionId, Map<String, dynamic> data) {
    debugPrint('🔘 Action button pressed: $actionId');

    // Emit to stream for listeners
    _rideActionController.add({
      'action': actionId,
      'data': data,
    });

    // Let app-level screen handlers consume this first so route/state flow
    // remains identical to in-screen accept/decline behavior.
    final hasAppHandler = onNotificationAction != null;
    onNotificationAction?.call(actionId, data);

    // Fallback only when no app handler is attached.
    if (!hasAppHandler) {
      switch (actionId) {
        case NotificationActions.acceptRide:
          _acceptRideFromNotification(data);
          break;
        case NotificationActions.declineRide:
          _declineRideFromNotification(data);
          break;
      }
    }
  }

  /// Accept ride directly from notification
  Future<void> _acceptRideFromNotification(Map<String, dynamic> data) async {
    final rideId = data['rideId'] as String?;
    if (rideId == null || rideId.isEmpty) {
      debugPrint('❌ No rideId in notification data');
      return;
    }

    debugPrint('✅ Accepting ride from notification: $rideId');

    try {
      // Call the accept ride API
      final response = await apiClient.post('/rides/$rideId/accept');
      final responseData = response.data as Map<String, dynamic>?;

      if (responseData?['success'] == true) {
        debugPrint('✅ Ride accepted successfully from notification');
        await _enqueuePendingRideAction(
          NotificationActions.acceptRide,
          data,
          accepted: true,
        );
        // Show a confirmation notification
        _showConfirmationNotification(
          'Ride Accepted!',
          'Navigate to pickup location',
          data,
        );
      } else {
        debugPrint('❌ Failed to accept ride: ${responseData?['message']}');
        _showConfirmationNotification(
          'Could not accept ride',
          responseData?['message'] ?? 'Ride may already be taken',
          data,
        );
      }
    } catch (e) {
      debugPrint('❌ Error accepting ride: $e');
      _showConfirmationNotification(
        'Error',
        'Could not accept ride. Please try from the app.',
        data,
      );
    }
  }

  /// Decline ride from notification
  Future<void> _declineRideFromNotification(Map<String, dynamic> data) async {
    final rideId = data['rideId'] as String?;
    if (rideId == null || rideId.isEmpty) {
      debugPrint('❌ No rideId in decline notification action');
      return;
    }

    debugPrint('❌ Declining ride from notification: $rideId');
    try {
      final response = await apiClient.declineRide(
        rideId,
        reason: 'Declined from notification',
      );
      debugPrint('Decline response: $response');
    } catch (e) {
      debugPrint('❌ Error declining ride from notification: $e');
    }
  }

  /// Called by app boot flow to replay background/cold-start ride actions
  /// into normal UI routing/state handlers.
  Future<List<Map<String, dynamic>>> consumePendingRideActions() async {
    return _drainPendingRideActions();
  }

  /// Show a simple confirmation notification
  void _showConfirmationNotification(
      String title, String body, Map<String, dynamic> data) {
    _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'raahi_rides',
          'Ride Updates',
          channelDescription: 'Ride update notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  /// Create Android notification channels for different notification types
  Future<void> _createAndroidChannels() async {
    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin == null) return;

    // Ride requests channel (high priority with custom sound)
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'ride_requests',
        'Ride Requests',
        description: 'High priority incoming ride requests',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        enableLights: true,
      ),
    );

    // Legacy ride request channel for backward compatibility
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_ride_requests',
        'Ride Requests',
        description: 'New ride request notifications',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        enableLights: true,
      ),
    );

    // General ride updates channel
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_rides',
        'Ride Updates',
        description: 'Updates about your rides',
        importance: Importance.high,
        playSound: true,
      ),
    );

    // Earnings channel
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_earnings',
        'Earnings',
        description: 'Earning notifications',
        importance: Importance.high,
        playSound: true,
      ),
    );

    // Payments channel
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_payments',
        'Payments',
        description: 'Payment notifications',
        importance: Importance.high,
      ),
    );

    // Promotions channel (lower priority)
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_promotions',
        'Promotions',
        description: 'Promotional offers and discounts',
        importance: Importance.defaultImportance,
      ),
    );

    // System notifications channel
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'raahi_system',
        'System',
        description: 'System notifications',
        importance: Importance.high,
      ),
    );

    debugPrint('✅ Android notification channels created');
  }

  bool _isRideRequestData(Map<String, dynamic> data) {
    final type = (data['type'] ?? '').toString().toUpperCase();
    final event =
        (data['event'] ?? data['status'] ?? '').toString().toUpperCase();
    return type == NotificationTypes.newRide ||
        (type == 'RIDE_UPDATE' && event == 'NEW_RIDE_REQUEST');
  }

  String _rideBodyFromData(Map<String, dynamic> data) {
    final fare = (data['fare'] ?? data['estimatedFare'] ?? '').toString();
    final distanceStr =
        (data['distance'] ?? data['pickupDistance'] ?? '').toString();
    
    // Calculate ETA from distance
    String etaStr = '';
    if (distanceStr.isNotEmpty) {
      final eta = _calculateEtaFromDistance(distanceStr);
      etaStr = '$distanceStr • $eta';
    }
    
    final chips = <String>[
      if (etaStr.isNotEmpty) etaStr,
      if (fare.isNotEmpty) '₹$fare',
    ];
    if (chips.isNotEmpty) return chips.join(' • ');
    return data['body']?.toString() ?? 'New ride request available';
  }
  
  /// Calculate ETA from distance string (e.g., "1.5 km" -> "5 min")
  String _calculateEtaFromDistance(String distanceStr) {
    final cleanStr = distanceStr.toLowerCase().trim();
    double distanceKm = 0;
    
    if (cleanStr.contains('km')) {
      final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
      distanceKm = double.tryParse(numStr) ?? 0;
    } else if (cleanStr.contains('m')) {
      final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
      distanceKm = (double.tryParse(numStr) ?? 0) / 1000;
    } else {
      // Try parsing as plain number (assume km)
      distanceKm = double.tryParse(cleanStr.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
    }
    
    if (distanceKm <= 0) return '0 min';
    
    // Average speed assumption: 20 km/h in city traffic
    const avgSpeedKmh = 20.0;
    final etaMinutes = (distanceKm / avgSpeedKmh * 60).ceil();
    
    if (etaMinutes < 1) return '< 1 min';
    if (etaMinutes == 1) return '1 min';
    if (etaMinutes >= 60) {
      final hours = etaMinutes ~/ 60;
      final mins = etaMinutes % 60;
      return mins > 0 ? '$hours hr $mins min' : '$hours hr';
    }
    return '$etaMinutes min';
  }

  /// Public helper so realtime ride-offer events can also trigger heads-up alerts.
  Future<void> showIncomingRideHeadsUp({
    required Map<String, dynamic> data,
    String title = 'New Ride Request',
  }) async {
    final notificationsEnabled = await _areNotificationsEnabledInApp();
    if (!notificationsEnabled) return;

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      _rideBodyFromData(data),
      NotificationDetails(
        android: _getRideRequestNotificationDetails(),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          categoryIdentifier: 'RIDE_REQUEST',
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  /// Get Android notification details with action buttons for ride requests
  AndroidNotificationDetails _getRideRequestNotificationDetails() {
    return const AndroidNotificationDetails(
      'ride_requests',
      'Ride Requests',
      channelDescription: 'New ride request notifications',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,
      playSound: true,
      enableVibration: true,
      actions: [
        AndroidNotificationAction(
          NotificationActions.acceptRide,
          'Accept',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          NotificationActions.declineRide,
          'Decline',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );
  }

  /// Handle foreground messages - show local notification
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint(
        '📬 Foreground message received: ${message.notification?.title}');

    _notificationController.add(message);

    final notificationsEnabled = await _areNotificationsEnabledInApp();
    if (!notificationsEnabled) {
      debugPrint(
        '🔕 Push suppressed by in-app setting '
        'userId=unknown notificationsEnabled=false pushSkipped=true',
      );
      return;
    }

    // Show local notification
    final notification = message.notification;

    if (notification != null) {
      final isRideRequest = _isRideRequestData(message.data);

      NotificationDetails notificationDetails;

      if (isRideRequest) {
        // Use special ride request notification with action buttons
        notificationDetails = NotificationDetails(
          android: _getRideRequestNotificationDetails(),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            categoryIdentifier: 'RIDE_REQUEST', // Links to action category
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        );
      } else {
        // Regular notification
        String channelId = 'raahi_rides';
        if (message.data['type'] == 'PAYMENT') {
          channelId = 'raahi_payments';
        } else if (message.data['type'] == 'PROMOTION') {
          channelId = 'raahi_promotions';
        }

        notificationDetails = NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelId
                .replaceAll('raahi_', '')
                .replaceAll('_', ' ')
                .toUpperCase(),
            channelDescription: 'Raahi notification',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      }

      _localNotifications.show(
        message.hashCode,
        notification.title ?? (isRideRequest ? 'New Ride Request' : 'Raahi'),
        notification.body ??
            (isRideRequest ? _rideBodyFromData(message.data) : ''),
        notificationDetails,
        payload: jsonEncode(message.data),
      );
      return;
    }

    // Fallback for data-only pushes (common for custom backend events).
    final type = message.data['type'] as String?;
    final event = message.data['event'] as String?;
    if (_isRideRequestData(message.data)) {
      await showIncomingRideHeadsUp(data: message.data);
      return;
    }
    if (type == NotificationTypes.driverOnboarding &&
        (event == 'VERIFIED' || message.data['status'] == 'COMPLETED')) {
      await _localNotifications.show(
        message.hashCode,
        'You are verified!',
        'Your driver documents are approved. You can start taking rides now.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'raahi_system',
            'System',
            channelDescription: 'System notifications',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: jsonEncode(message.data),
      );
    }
  }

  /// Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('📬 Notification tapped: ${message.data}');
    onNotificationTap?.call(message.data);
  }

  /// Ask active ride screen to open chat without navigation.
  void requestInAppChatOpen({
    required String rideId,
    String? senderId,
  }) {
    _chatOpenController.add({
      'rideId': rideId,
      if (senderId != null && senderId.isNotEmpty) 'senderId': senderId,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Register FCM token with the backend
  Future<bool> _registerTokenWithBackend() async {
    if (_fcmToken == null) {
      debugPrint('⚠️ No FCM token to register');
      return false;
    }

    try {
      final platform = Platform.isIOS ? 'ios' : 'android';

      final response = await apiClient.post('/notifications/device', data: {
        'fcmToken': _fcmToken,
        'platform': platform,
      });

      final responseData = response.data as Map<String, dynamic>?;
      if (responseData?['success'] == true) {
        debugPrint('✅ FCM token registered with backend');
        return true;
      } else {
        debugPrint(
            '❌ Failed to register FCM token: ${responseData?['message']}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error registering FCM token: $e');
      return false;
    }
  }

  /// Register token with backend (public method)
  /// Call this after user logs in
  Future<bool> registerToken() async {
    final notificationsEnabled = await _areNotificationsEnabledInApp();
    if (!notificationsEnabled) {
      debugPrint(
        '🔕 Skip token registration due to in-app setting '
        'userId=unknown notificationsEnabled=false pushSkipped=true',
      );
      await unregisterToken();
      return false;
    }
    // Try to get token if not available
    _fcmToken ??= await _messaging.getToken();
    return _registerTokenWithBackend();
  }

  /// Unregister device from push notifications
  /// Call this on logout
  Future<void> unregisterToken() async {
    try {
      await apiClient.delete('/notifications/device');
      debugPrint('✅ FCM token unregistered from backend');
    } catch (e) {
      debugPrint('❌ Error unregistering FCM token: $e');
    }
  }

  Future<bool> _areNotificationsEnabledInApp() async {
    final prefs = await SharedPreferences.getInstance();
    final appSetting = prefs.getBool('notificationsEnabled') ?? true;
    final profileSetting = prefs.getBool('pref_push_notifications') ?? true;
    return appSetting && profileSetting;
  }

  /// Subscribe to a topic (e.g., for broadcast notifications)
  Future<void> subscribeToTopic(String topic) async {
    try {
      await _messaging.subscribeToTopic(topic);
      debugPrint('✅ Subscribed to topic: $topic');
    } catch (e) {
      debugPrint('❌ Error subscribing to topic: $e');
    }
  }

  /// Unsubscribe from a topic
  Future<void> unsubscribeFromTopic(String topic) async {
    try {
      await _messaging.unsubscribeFromTopic(topic);
      debugPrint('✅ Unsubscribed from topic: $topic');
    } catch (e) {
      debugPrint('❌ Error unsubscribing from topic: $e');
    }
  }

  void dispose() {
    _notificationController.close();
    _rideActionController.close();
    _chatOpenController.close();
  }
}

/// Global instance
final pushNotificationService = PushNotificationService();

/// Background notification response handler (must be top-level)
@pragma('vm:entry-point')
void _handleBackgroundNotificationResponse(NotificationResponse response) {
  debugPrint(
      '📬 Background notification response: action=${response.actionId}');

  if (response.payload == null) return;

  try {
    final data = jsonDecode(response.payload!) as Map<String, dynamic>;

    if (response.actionId == NotificationActions.acceptRide) {
      // Accept ride in background
      _acceptRideInBackground(data);
    } else if (response.actionId == NotificationActions.declineRide) {
      // Just dismiss for decline
      debugPrint('❌ Ride declined from background');
    }
  } catch (e) {
    debugPrint('❌ Error handling background notification: $e');
  }
}

/// Accept ride when app is in background/terminated
Future<void> _acceptRideInBackground(Map<String, dynamic> data) async {
  final rideId = data['rideId'] as String?;
  if (rideId == null) return;

  debugPrint('✅ Accepting ride in background: $rideId');

  try {
    // We need to make a direct HTTP call since apiClient might not be initialized
    final response = await apiClient.post('/rides/$rideId/accept');
    final responseData = response.data as Map<String, dynamic>?;

    if (responseData?['success'] == true) {
      debugPrint('✅ Ride accepted in background');
      await _enqueuePendingRideAction(
        NotificationActions.acceptRide,
        data,
        accepted: true,
      );
    } else {
      debugPrint(
          '❌ Failed to accept ride in background: ${responseData?['message']}');
    }
  } catch (e) {
    debugPrint('❌ Error accepting ride in background: $e');
  }
}
