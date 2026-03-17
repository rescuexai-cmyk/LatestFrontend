import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';

/// Notification action identifiers
class NotificationActions {
  static const String acceptRide = 'ACCEPT_RIDE';
  static const String declineRide = 'DECLINE_RIDE';
  static const String viewRide = 'VIEW_RIDE';
  static const String callDriver = 'CALL_DRIVER';
  static const String callRider = 'CALL_RIDER';
}

/// Service to handle push notifications via Firebase Cloud Messaging (FCM)
/// 
/// Features:
/// - Registers device token with backend
/// - Handles foreground, background, and terminated notifications
/// - Navigates to relevant screens on notification tap
/// - Manages Android notification channels
class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  /// Lazy: avoid accessing Firebase before Firebase.initializeApp() runs.
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  
  String? _fcmToken;
  bool _isInitialized = false;
  
  // Callback for handling notification taps
  void Function(Map<String, dynamic> data)? onNotificationTap;
  
  // Callback for handling notification actions (Accept/Decline)
  Future<void> Function(String action, Map<String, dynamic> data)? onNotificationAction;
  
  // Stream controller for notification events
  final _notificationController = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get notificationStream => _notificationController.stream;
  
  // Stream for ride request actions (Accept/Decline from notification)
  final _rideActionController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get rideActionStream => _rideActionController.stream;

  // Stream for in-app chat-open intents triggered by push taps.
  final _chatOpenController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get chatOpenStream => _chatOpenController.stream;

  String? get fcmToken => _fcmToken;

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
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    
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
      onDidReceiveBackgroundNotificationResponse: _handleBackgroundNotificationResponse,
    );
    
    // Create Android notification channels
    if (Platform.isAndroid) {
      await _createAndroidChannels();
    }
  }
  
  /// Handle notification response (tap or action button)
  void _handleNotificationResponse(NotificationResponse response) {
    debugPrint('📬 Notification response: action=${response.actionId}, payload=${response.payload}');
    
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
    
    // Call the callback if set
    onNotificationAction?.call(actionId, data);
    
    // Handle the action
    switch (actionId) {
      case NotificationActions.acceptRide:
        _acceptRideFromNotification(data);
        break;
      case NotificationActions.declineRide:
        _declineRideFromNotification(data);
        break;
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
    debugPrint('❌ Declining ride from notification: $rideId');
    // For decline, we just dismiss - no API call needed
    // The ride will timeout or be assigned to another driver
  }
  
  /// Show a simple confirmation notification
  void _showConfirmationNotification(String title, String body, Map<String, dynamic> data) {
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
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidPlugin == null) return;
    
    // Ride requests channel (high priority with custom sound)
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
  
  /// Get Android notification details with action buttons for ride requests
  AndroidNotificationDetails _getRideRequestNotificationDetails() {
    return const AndroidNotificationDetails(
      'raahi_ride_requests',
      'Ride Requests',
      channelDescription: 'New ride request notifications',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true, // Show on lock screen
      category: AndroidNotificationCategory.call, // Treat as urgent
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
    debugPrint('📬 Foreground message received: ${message.notification?.title}');
    
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
      final isRideRequest = message.data['type'] == 'RIDE_UPDATE' && 
                           message.data['event'] == 'NEW_RIDE_REQUEST';
      
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
            channelId.replaceAll('raahi_', '').replaceAll('_', ' ').toUpperCase(),
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
        notification.title,
        notification.body,
        notificationDetails,
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
        debugPrint('❌ Failed to register FCM token: ${responseData?['message']}');
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
    if (_fcmToken == null) {
      // Try to get token if not available
      _fcmToken = await _messaging.getToken();
    }
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
  debugPrint('📬 Background notification response: action=${response.actionId}');
  
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
    } else {
      debugPrint('❌ Failed to accept ride in background: ${responseData?['message']}');
    }
  } catch (e) {
    debugPrint('❌ Error accepting ride in background: $e');
  }
}
