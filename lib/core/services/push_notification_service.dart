import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
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

class NotificationTypes {
  static const String driverOnboarding = 'DRIVER_ONBOARDING';
  static const String newRide = 'NEW_RIDE';
  static const String chatMessage = 'CHAT_MESSAGE';
}

const String _chatAndroidChannelId = 'raahi_chat';

Map<String, dynamic> normalizeChatNotificationPayload(Map<String, dynamic> data) {
  final merged = Map<String, dynamic>.from(data);
  final payload = data['payload'];
  if (payload is Map) {
    for (final entry in Map<String, dynamic>.from(payload as Map).entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
  }
  final nestedMessage = data['message'];
  if (nestedMessage is Map) {
    for (final entry in Map<String, dynamic>.from(nestedMessage as Map).entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
  }
  return merged;
}

bool isChatMessageNotificationData(Map<String, dynamic> data) {
  final payload = normalizeChatNotificationPayload(data);
  final type = (payload['type'] ?? '').toString().toUpperCase();
  final messageType = (payload['messageType'] ?? '').toString().toUpperCase();
  final event = (payload['event'] ?? '').toString().toUpperCase();

  if (type == NotificationTypes.chatMessage) return true;
  if (type == 'RIDE_UPDATE' && messageType == 'RIDE_CHAT') return true;
  if (type == 'RIDE_MESSAGE' ||
      type == 'RIDE-MESSAGE' ||
      type == 'RIDE_CHAT_MESSAGE') {
    return true;
  }
  if (event == 'CHAT_MESSAGE' || event == 'NEW_CHAT_MESSAGE') return true;

  final rideId = (payload['rideId'] ?? payload['ride_id'] ?? '').toString();
  final text = payload['message'] ??
      payload['text'] ??
      payload['content'] ??
      payload['body'];
  if (rideId.isNotEmpty && text != null && text.toString().trim().isNotEmpty) {
    final sender = (payload['sender'] ?? payload['senderId'] ?? payload['sender_id'] ?? '')
        .toString();
    if (sender.isNotEmpty) return true;
  }
  return false;
}

String chatNotificationTitle(Map<String, dynamic> data) {
  final payload = normalizeChatNotificationPayload(data);
  for (final key in [
    'senderName',
    'sender_name',
    'riderName',
    'driverName',
    'fromName',
  ]) {
    final name = payload[key]?.toString().trim();
    if (name != null && name.isNotEmpty) return name;
  }
  final sender = (payload['sender'] ?? '').toString().toLowerCase();
  if (sender == 'driver') return 'Driver';
  if (sender == 'rider' || sender == 'passenger' || sender == 'user') {
    return 'Passenger';
  }
  return 'New message';
}

String chatNotificationBody(Map<String, dynamic> data) {
  final payload = normalizeChatNotificationPayload(data);
  final text = payload['message'] ??
      payload['text'] ??
      payload['content'] ??
      payload['body'];
  if (text == null) return 'You have a new message';
  final s = text.toString().trim();
  if (s.isEmpty) return 'You have a new message';
  return s.length > 140 ? '${s.substring(0, 137)}...' : s;
}

Map<String, dynamic> chatNotificationTapPayload(Map<String, dynamic> data) {
  final payload = normalizeChatNotificationPayload(data);
  final rideId = (payload['rideId'] ?? payload['ride_id'] ?? '').toString();
  return {
    'type': NotificationTypes.chatMessage,
    'rideId': rideId,
    if (payload['senderId'] != null) 'senderId': payload['senderId'],
    if (payload['sender_id'] != null) 'senderId': payload['sender_id'],
    if (payload['sender'] != null) 'sender': payload['sender'],
  };
}

int chatNotificationId(Map<String, dynamic> data) {
  final payload = normalizeChatNotificationPayload(data);
  final rideId = (payload['rideId'] ?? payload['ride_id'] ?? '').toString();
  final messageId = (payload['id'] ?? payload['messageId'] ?? '').toString();
  final text = chatNotificationBody(payload);
  return Object.hash(rideId, messageId, text) & 0x7fffffff;
}

NotificationDetails chatNotificationDetails() {
  return const NotificationDetails(
    android: AndroidNotificationDetails(
      _chatAndroidChannelId,
      'Chat Messages',
      channelDescription: 'Messages from your driver or passenger',
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
  );
}

Future<void> showChatLocalNotification(
  FlutterLocalNotificationsPlugin plugin,
  Map<String, dynamic> data,
) async {
  if (!isChatMessageNotificationData(data)) return;
  final payload = normalizeChatNotificationPayload(data);
  await plugin.show(
    chatNotificationId(payload),
    chatNotificationTitle(payload),
    chatNotificationBody(payload),
    chatNotificationDetails(),
    payload: jsonEncode(chatNotificationTapPayload(payload)),
  );
}

Future<void> ensureChatNotificationChannel(
  FlutterLocalNotificationsPlugin plugin,
) async {
  if (!Platform.isAndroid) return;
  final androidPlugin = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chatAndroidChannelId,
      'Chat Messages',
      description: 'Messages from your driver or passenger',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ),
  );
}

/// Background FCM entry point (separate isolate).
@pragma('vm:entry-point')
Future<void> processFirebaseBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  final data = Map<String, dynamic>.from(message.data);
  if (!isChatMessageNotificationData(data)) {
    debugPrint('📬 Background message ignored (non-chat): ${message.messageId}');
    return;
  }

  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    const InitializationSettings(android: androidSettings),
  );
  await ensureChatNotificationChannel(plugin);
  await showChatLocalNotification(plugin, data);
  debugPrint('📬 Background chat notification shown: ${message.messageId}');
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

    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        _chatAndroidChannelId,
        'Chat Messages',
        description: 'Messages from your driver or passenger',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
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
    final distanceLabel = _bestTripDistanceLabel(data);
    var etaLabel = _bestEtaLabel(data, distanceLabelForCalc: distanceLabel);

    // If ETA is still meaningless but distance is usable, approximate from km.
    if (!_isMeaningfulEta(etaLabel) &&
        distanceLabel.isNotEmpty &&
        !_isZeroPlaceholderDistance(distanceLabel)) {
      final derived = _calculateEtaFromDistance(distanceLabel);
      if (_isMeaningfulEta(derived)) etaLabel = derived;
    }

    final fareLabel = _formatRupeeFare(
      data['fare'] ??
          data['estimatedFare'] ??
          data['totalFare'] ??
          data['estimated_fare'],
    );

    final chips = <String>[];
    if (distanceLabel.isNotEmpty &&
        !_isZeroPlaceholderDistance(distanceLabel)) {
      chips.add(distanceLabel);
    }
    if (_isMeaningfulEta(etaLabel)) {
      chips.add(_stripTrailingAway(etaLabel));
    }
    if (fareLabel.isNotEmpty) chips.add(fareLabel);

    if (chips.isNotEmpty) return chips.join(' • ');
    return data['body']?.toString() ?? 'New ride request available';
  }

  bool _isMeaningfulEta(String eta) {
    final t = eta.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (t == '0 min' ||
        t == '0 mins' ||
        t == '0 min away' ||
        t.startsWith('0 hr') ||
        t == '0 hr') return false;
    if (RegExp(r'^0+\s*(min|mins|minute|minutes)\b').hasMatch(t)) {
      return false;
    }
    return true;
  }

  static final RegExp _kmNumberRe =
      RegExp(r'([\d]+\.?[\d]*)\s*km', caseSensitive: false);

  bool _isZeroPlaceholderDistance(String s) {
    final m = _kmNumberRe.firstMatch(s.toLowerCase());
    if (m != null) {
      final km = double.tryParse(m.group(1)!) ?? 0;
      return km <= 0;
    }
    final digits = RegExp(r'([\d]+\.?[\d]*)').firstMatch(s);
    if (digits != null && !s.toLowerCase().contains('km')) {
      final n = double.tryParse(digits.group(1)!) ?? 0;
      return n <= 0;
    }
    return s.trim().isEmpty;
  }

  String _stripTrailingAway(String eta) =>
      eta.replaceAll(RegExp(r'\s+away\s*$', caseSensitive: false), '').trim();

  /// Prefer trip / drop distance; skip pure pickup "0 km" when better fields exist later.
  String _bestTripDistanceLabel(Map<String, dynamic> data) {
    const keys = [
      'dropDistance',
      'drop_distance',
      'tripDistance',
      'trip_distance',
      'estimatedDistance',
      'estimated_distance',
      'distanceKm',
      'distance_km',
      'distance',
      'pickupDistance',
      'pickup_distance',
      'trip_km',
      'trip_km_estimate',
      'estimated_distance_km',
    ];
    for (final key in keys) {
      final raw = data[key];
      if (raw == null) continue;
      final formatted = _formatDistance(raw);
      if (formatted.isEmpty || _isZeroPlaceholderDistance(formatted)) continue;
      return formatted;
    }
    return '';
  }

  /// Interpret backend distance as kilometres or reuse a human-readable string.
  String _formatDistance(dynamic raw) {
    if (raw == null) return '';
    if (raw is num) {
      var km = raw.toDouble();
      // Large integers are often metres (e.g. 35600 → 35.6 km).
      if (km >= 999 && km == km.roundToDouble()) {
        km /= 1000;
      }
      final absKm = km.abs();
      final label = absKm >= 99 ? absKm.round().toString() : absKm.toStringAsFixed(1);
      final trimmed =
          absKm >= 99 ? label : label.replaceFirst(RegExp(r'\.0$'), '');
      return '$trimmed km';
    }
    final s = raw.toString().trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    if (lower.contains('km') ||
        lower.contains('mile') ||
        lower.endsWith(' m') ||
        lower.contains(' metre') ||
        lower.contains('meter')) {
      return s;
    }
    final numeric = RegExp(r'^([\d.]+)$').firstMatch(s);
    if (numeric != null) {
      final parsed = double.tryParse(numeric.group(1)!);
      if (parsed != null) return _formatDistance(parsed);
    }
    return s;
  }

  int? _optionalPositiveInt(dynamic v) {
    if (v == null) return null;
    if (v is int && v > 0) return v;
    if (v is double && v > 0) return v.ceil();
    return int.tryParse(v.toString()) ?? double.tryParse(v.toString())?.ceil();
  }

  String _formatDurationMinutes(int mins) {
    if (mins < 1) return '< 1 min';
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m > 0 ? '$h hr $m min' : '$h hr';
    }
    return '$mins min';
  }

  String _bestEtaLabel(
    Map<String, dynamic> data, {
    required String distanceLabelForCalc,
  }) {
    for (final key in [
      'durationMinutes',
      'duration_minutes',
      'estimatedDurationMinutes',
      'estimated_duration_minutes',
      'tripDurationMinutes',
      'etaMinutes',
      'eta_minutes',
      'durationMin',
      'duration_min',
      'estimatedDuration',
      'tripDuration',
      'estimated_duration_sec',
      'estimatedDurationSec',
      'estimated_duration_secs',
      'estimated_duration_seconds',
    ]) {
      final v = _optionalPositiveInt(data[key]);
      if (v != null && v > 0) {
        final secsHints = [
          'estimated_duration_sec',
          'estimatedDurationSec',
          'estimated_duration_secs',
          'estimated_duration_seconds',
        ];
        final minutes = secsHints.contains(key) ? (v + 59) ~/ 60 : v;
        return _formatDurationMinutes(minutes.clamp(1, 10080));
      }
    }
    final dropEta = [
      data['dropTime'],
      data['tripEta'],
      data['estimatedEta'],
      data['estimated_eta'],
      data['trip_time'],
      data['tripTime'],
    ];
    for (final raw in dropEta) {
      if (raw == null) continue;
      final s = raw.toString().trim();
      if (s.isEmpty) continue;
      if (RegExp(r'hr|hour|minute|away|mins', caseSensitive: false).hasMatch(s)) {
        return s;
      }
    }
    if (distanceLabelForCalc.isNotEmpty &&
        !_isZeroPlaceholderDistance(distanceLabelForCalc)) {
      return _calculateEtaFromDistance(distanceLabelForCalc);
    }
    return '';
  }

  /// One rupee prefix, numeric from strings like "₹₹292" or "INR 292".
  String _formatRupeeFare(dynamic raw) {
    if (raw == null) return '';
    if (raw is num) return '₹${_trimTrailingZeros(raw)}';
    var s = raw.toString().trim();
    if (s.isEmpty) return '';
    s = s.replaceAll('₹', '').replaceAll('Rs.', '').replaceAll('Rs', '').replaceAll('INR', '').trim();
    final match =
        RegExp(r'([\d,\s]*\d+)\.?([\d]*)').firstMatch(s.replaceAll(',', ''));
    if (match == null || match.group(1) == null) return '';
    final whole = match.group(1)!;
    final frac = match.group(2);
    double? value;
    if (frac != null && frac.isNotEmpty) {
      value = double.tryParse('$whole.$frac');
    } else {
      value = double.tryParse(whole);
    }
    if (value == null || value <= 0) return '';
    return '₹${_trimTrailingZeros(value)}';
  }

  String _trimTrailingZeros(num value) {
    final x = value.toDouble();
    if ((x - x.round()).abs() < 1e-6) return x.round().toString();
    final s = x.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
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

  /// Local heads-up when a chat message arrives (socket/SSE/FCM data-only).
  Future<void> showChatMessageNotification({
    required Map<String, dynamic> data,
  }) async {
    final notificationsEnabled = await _areNotificationsEnabledInApp();
    if (!notificationsEnabled) return;
    if (!isChatMessageNotificationData(data)) return;
    await showChatLocalNotification(_localNotifications, data);
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

    final chatPayload = normalizeChatNotificationPayload(
      Map<String, dynamic>.from(message.data),
    );
    final isChat = isChatMessageNotificationData(chatPayload);

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
      } else if (isChat) {
        notificationDetails = chatNotificationDetails();
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
        isChat ? chatNotificationId(chatPayload) : message.hashCode,
        isChat
            ? chatNotificationTitle(chatPayload)
            : (notification.title ??
                (isRideRequest ? 'New Ride Request' : 'Raahi')),
        isChat
            ? chatNotificationBody(chatPayload)
            : (isRideRequest
                ? _rideBodyFromData(message.data)
                : (notification.body ?? '')),
        notificationDetails,
        payload: jsonEncode(
          isChat ? chatNotificationTapPayload(chatPayload) : message.data,
        ),
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
    if (isChat) {
      await showChatMessageNotification(data: chatPayload);
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
