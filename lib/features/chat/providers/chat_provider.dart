import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/websocket_service.dart';

final chatProvider = StateNotifierProvider.family<ChatNotifier, ChatState, String>(
  (ref, rideId) => ChatNotifier(rideId, ref),
);

@immutable
class ChatState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isSending;
  final String? error;
  final bool isTyping;
  final bool otherUserTyping;
  final int unreadCount;

  const ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.isSending = false,
    this.error,
    this.isTyping = false,
    this.otherUserTyping = false,
    this.unreadCount = 0,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isSending,
    String? error,
    bool? isTyping,
    bool? otherUserTyping,
    int? unreadCount,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isSending: isSending ?? this.isSending,
      error: error,
      isTyping: isTyping ?? this.isTyping,
      otherUserTyping: otherUserTyping ?? this.otherUserTyping,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final String rideId;
  final Ref ref;
  
  final List<VoidCallback> _unsubscribers = [];
  Timer? _typingTimer;
  Timer? _pollTimer;
  String? _currentUserId;
  String? _passengerId;
  bool _isDriver = false;
  bool _isInitialized = false;
  bool _isChatOpen = false;
  final Set<String> _messageIds = {};
  final Set<String> _processedMessageIds = {};
  final List<ChatMessage> _pendingQueue = [];
  final Map<String, Timer> _retryTimers = {};
  final Set<String> _persistedMessageIds = {};
  StreamSubscription<bool>? _socketConnectionSub;
  bool _isFlushingQueue = false;
  bool _isSyncingUnreadCount = false;

  ChatNotifier(this.rideId, this.ref) : super(const ChatState());

  void initialize({
    required String currentUserId,
    String? passengerId,
    bool isDriver = false,
  }) {
    if (_isInitialized) return;
    _currentUserId = currentUserId;
    _passengerId = passengerId;
    _isDriver = isDriver;
    _isInitialized = true;
    
    _subscribeToMessages();
    loadMessages();
    _startPolling();
    unawaited(_loadPendingQueue());
    _socketConnectionSub?.cancel();
    _socketConnectionSub = webSocketService.connectionStatus.listen((connected) {
      if (connected) {
        unawaited(_flushQueue());
      }
    });
    // Keep socket warm for near-instant message delivery.
    unawaited(_ensureSocketReady());
  }

  void _subscribeToMessages() {
    webSocketService.joinRideTracking(rideId);
    
    _unsubscribers.add(webSocketService.subscribe('ride_message', (message) {
      _handleIncomingMessage(message.data);
    }));
    
    _unsubscribers.add(webSocketService.subscribe('chat_history', (message) {
      _handleChatHistory(message.data);
    }));
    
    _unsubscribers.add(webSocketService.subscribe('typing_indicator', (message) {
      _handleTypingIndicator(message.data);
    }));
    _unsubscribers.add(webSocketService.subscribe('typing_start', (message) {
      _handleTypingSignal(message.data, true);
    }));
    _unsubscribers.add(webSocketService.subscribe('typing_stop', (message) {
      _handleTypingSignal(message.data, false);
    }));

    _unsubscribers.add(webSocketService.subscribe('message_delivered', (message) {
      _handleMessageDelivered(message.data);
    }));

    _unsubscribers.add(webSocketService.subscribe('message_read', (message) {
      _handleMessageRead(message.data);
    }));

    _unsubscribers.add(webSocketService.subscribe('chat_read', (message) {
      _handleChatReadCursor(message.data);
    }));
  }

  void _handleIncomingMessage(dynamic data) {
    if (data == null) return;
    
    Map<String, dynamic> messageData;
    if (data is Map<String, dynamic>) {
      final nested = data['message'];
      messageData = (nested is Map<String, dynamic>) ? nested : data;
    } else {
      return;
    }

    final senderRole = (messageData['sender'] as String? ?? '').toLowerCase();
    final senderId = messageData['senderId'] as String? ??
        messageData['userId'] as String? ??
        '';
    final isSelfByRole = _isDriver
        ? senderRole == 'driver'
        : (senderRole == 'rider' || senderRole == 'passenger' || senderRole == 'user');
    final isSelfById = senderId.isNotEmpty && senderId == _currentUserId;
    if (isSelfByRole || isSelfById) return;

    final messageId = messageData['id']?.toString() ?? '';

    final msgText = messageData['message'] as String? ??
                    messageData['text'] as String? ??
                    messageData['content'] as String? ?? '';
    if (msgText.isEmpty) return;

    final effectiveId = messageId.isNotEmpty
        ? messageId
        : _buildMessageSignature(messageData);
    if (_processedMessageIds.contains(effectiveId)) return;
    _processedMessageIds.add(effectiveId);
    if (messageId.isNotEmpty) _messageIds.add(messageId);

    messageData['id'] = effectiveId;

    final chatMessage = ChatMessage.fromJson(
      messageData,
      currentUserId: _currentUserId,
      passengerId: _passengerId,
    );
    
    final alreadyInState = state.messages.any((m) => m.id == chatMessage.id);
    if (alreadyInState) return;

    final updatedMessages = [...state.messages, chatMessage];
    updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Emit delivery/read receipts for incoming messages with server IDs.
    if (messageId.isNotEmpty && (_currentUserId?.isNotEmpty ?? false)) {
      webSocketService.sendMessageDelivered(
        messageId: messageId,
        rideId: rideId,
        receiverId: _currentUserId!,
      );
      if (_isChatOpen) {
        webSocketService.sendMessageRead(
          messageId: messageId,
          rideId: rideId,
          readerId: _currentUserId!,
        );
      }
    }
    
    state = state.copyWith(
      messages: updatedMessages,
      otherUserTyping: false,
      unreadCount: _isChatOpen ? state.unreadCount : state.unreadCount + 1,
    );
  }

  void _handleChatHistory(dynamic data) {
    if (data == null) return;
    
    List<dynamic> messagesList;
    if (data is List) {
      messagesList = data;
    } else if (data is Map && data['messages'] is List) {
      messagesList = data['messages'] as List;
    } else {
      return;
    }
    
    final messages = <ChatMessage>[];
    for (final item in messagesList) {
      if (item is Map<String, dynamic>) {
        final id = item['id'] as String? ?? '';
        if (id.isNotEmpty && !_messageIds.contains(id)) {
          _messageIds.add(id);
          _processedMessageIds.add(id);
          messages.add(ChatMessage.fromJson(
            item,
            currentUserId: _currentUserId,
            passengerId: _passengerId,
          ));
        }
      }
    }
    
    if (messages.isNotEmpty) {
      final allMessages = [...state.messages, ...messages];
      allMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      final uniqueMessages = <String, ChatMessage>{};
      for (final msg in allMessages) {
        uniqueMessages[msg.id] = msg;
      }
      
      state = state.copyWith(messages: uniqueMessages.values.toList());
    }

    // History/polling can ingest new messages before realtime callbacks.
    // Keep unread badge aligned with backend truth when chat is closed.
    if (!_isChatOpen) {
      unawaited(_syncUnreadCountFromBackend());
    }
  }

  void _handleTypingIndicator(dynamic data) {
    if (data == null) return;
    
    final senderId = data['senderId'] as String?;
    final isTyping = data['isTyping'] as bool? ?? false;
    
    if (senderId != null && senderId != _currentUserId) {
      state = state.copyWith(otherUserTyping: isTyping);
      
      if (isTyping) {
        _typingTimer?.cancel();
        _typingTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            state = state.copyWith(otherUserTyping: false);
          }
        });
      }
    }
  }

  void _handleTypingSignal(dynamic data, bool isTyping) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final msgRideId = payload['rideId']?.toString();
    if (msgRideId != null && msgRideId != rideId) return;

    final senderId = payload['userId']?.toString() ?? payload['senderId']?.toString();
    if (senderId == null || senderId == _currentUserId) return;

    state = state.copyWith(otherUserTyping: isTyping);
    _typingTimer?.cancel();
    if (isTyping) {
      _typingTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          state = state.copyWith(otherUserTyping: false);
        }
      });
    }
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      loadMessages(silent: true);
      if (webSocketService.isConnected && _pendingQueue.isNotEmpty) {
        unawaited(_flushQueue());
      }
    });
  }

  Future<void> loadMessages({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoading: true, error: null);
    }
    
    try {
      final messagesList = await apiClient.getChatMessages(rideId);
      
      final messages = <ChatMessage>[];
      for (final item in messagesList) {
        final id = item['id'] as String? ?? '';
        _messageIds.add(id);
        if (id.isNotEmpty) _processedMessageIds.add(id);
        messages.add(ChatMessage.fromJson(
          item,
          currentUserId: _currentUserId,
          passengerId: _passengerId,
        ));
      }
      
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Preserve unsent local messages while refreshing from server.
      final localUnsent = state.messages.where((m) =>
          m.id.startsWith('local_') ||
          m.status == MessageDeliveryStatus.queued ||
          m.status == MessageDeliveryStatus.failed).toList();
      final merged = [...messages, ...localUnsent];
      final uniqueById = <String, ChatMessage>{};
      for (final msg in merged) {
        uniqueById[msg.id] = msg;
      }
      final mergedSorted = uniqueById.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      state = state.copyWith(
        messages: mergedSorted,
        isLoading: false,
      );

      if (!_isChatOpen) {
        unawaited(_syncUnreadCountFromBackend());
      }
    } catch (e) {
      debugPrint('❌ Failed to load chat messages: $e');
      if (!silent) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load messages',
        );
      }
    }
  }

  Future<void> _syncUnreadCountFromBackend() async {
    if (_isChatOpen || _isSyncingUnreadCount) return;
    _isSyncingUnreadCount = true;
    try {
      final backendUnread = await apiClient.getRideUnreadCount(rideId);
      if (mounted && !_isChatOpen && backendUnread != state.unreadCount) {
        state = state.copyWith(unreadCount: backendUnread);
      }
    } catch (e) {
      debugPrint('⚠️ Failed to sync unread count: $e');
    } finally {
      _isSyncingUnreadCount = false;
    }
  }

  Future<bool> sendMessage(String text) async {
    if (text.trim().isEmpty) return false;
    
    final tempId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    final trimmed = text.trim();
    final tempMessage = ChatMessage(
      id: tempId,
      rideId: rideId,
      senderId: _currentUserId ?? '',
      message: trimmed,
      timestamp: DateTime.now(),
      senderType: _isDriver ? ChatSenderType.driver : ChatSenderType.passenger,
      isSending: true,
      status: MessageDeliveryStatus.sent,
      retryCount: 0,
    );
    
    _messageIds.add(tempId);
    _processedMessageIds.add(tempId);
    state = state.copyWith(
      messages: [...state.messages, tempMessage],
      isSending: true,
    );

    if (!webSocketService.isConnected) {
      _enqueueMessage(tempMessage);
      _upsertLocalMessage(
        tempId,
        status: MessageDeliveryStatus.queued,
        isSending: false,
      );
      // REST persistence is the primary fallback when socket is down.
      // This prevents permanent "queued" messages when realtime is flaky.
      unawaited(_persistOutgoingMessage(tempId, trimmed));
      state = state.copyWith(isSending: false);
      return true;
    }

    _scheduleRetry(tempId);
    unawaited(_sendWithAck(tempId, trimmed));
    unawaited(_persistOutgoingMessage(tempId, trimmed));
    return true;
  }

  Future<void> _sendWithAck(String messageId, String text) async {
    try {
      if (!webSocketService.isConnected) {
        _enqueueExistingLocalMessage(messageId);
        _upsertLocalMessage(
          messageId,
          status: MessageDeliveryStatus.queued,
          isSending: false,
        );
        return;
      }
      final senderRole = _isDriver ? 'driver' : 'rider';
      final ack = await webSocketService.sendRideMessageWithAck(
        rideId,
        text,
        sender: senderRole,
        senderName: _currentUserId,
        clientMessageId: messageId,
      );
      if (ack == null) return;

      final ackMessageId = ack['messageId']?.toString();
      final deliveredAtRaw = ack['deliveredAt'];
      final deliveredAt = _parseAckDate(deliveredAtRaw) ?? DateTime.now();
      _markDeliveredFromAck(
        tempId: messageId,
        serverMessageId: ackMessageId,
        deliveredAt: deliveredAt,
      );
    } catch (e) {
      debugPrint('⚠️ Socket emitWithAck failed: $e');
    }
  }

  void _scheduleRetry(String messageId) {
    _retryTimers[messageId]?.cancel();
    _retryTimers[messageId] = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final message = state.messages.where((m) => m.id == messageId).isEmpty
          ? null
          : state.messages.firstWhere((m) => m.id == messageId);
      if (message == null) {
        _retryTimers.remove(messageId)?.cancel();
        return;
      }
      if (message.status == MessageDeliveryStatus.delivered || message.status == MessageDeliveryStatus.read) {
        _retryTimers.remove(messageId)?.cancel();
        return;
      }
      if (message.retryCount >= 3) {
        if (_persistedMessageIds.contains(messageId)) {
          // Message is already stored via REST; don't mark it as failed just
          // because socket ack didn't arrive.
          _upsertLocalMessage(
            messageId,
            status: MessageDeliveryStatus.sent,
            sendFailed: false,
            isSending: false,
          );
        } else {
          _upsertLocalMessage(
            messageId,
            status: MessageDeliveryStatus.failed,
            sendFailed: true,
            isSending: false,
          );
        }
        _pendingQueue.removeWhere((m) => m.id == messageId);
        unawaited(_savePendingQueue());
        _retryTimers.remove(messageId)?.cancel();
        return;
      }

      final nextRetry = message.retryCount + 1;
      _upsertLocalMessage(
        messageId,
        retryCount: nextRetry,
        status: webSocketService.isConnected ? MessageDeliveryStatus.sent : MessageDeliveryStatus.queued,
        isSending: webSocketService.isConnected,
      );

      if (!webSocketService.isConnected) {
        _enqueueExistingLocalMessage(messageId);
      } else {
        unawaited(_sendWithAck(messageId, message.message));
      }
      _scheduleRetry(messageId);
    });
  }

  void _enqueueMessage(ChatMessage message) {
    if (_pendingQueue.any((m) => m.id == message.id)) return;
    _pendingQueue.add(message.copyWith(
      status: MessageDeliveryStatus.queued,
      isSending: false,
    ));
    unawaited(_savePendingQueue());
  }

  void _enqueueExistingLocalMessage(String messageId) {
    final msg = state.messages.where((m) => m.id == messageId).isEmpty
        ? null
        : state.messages.firstWhere((m) => m.id == messageId);
    if (msg == null) return;
    _enqueueMessage(msg);
  }

  Future<void> _flushQueue() async {
    if (_isFlushingQueue || _pendingQueue.isEmpty || !webSocketService.isConnected) return;
    _isFlushingQueue = true;
    try {
      final queued = List<ChatMessage>.from(_pendingQueue);
      for (final msg in queued) {
        if (_persistedMessageIds.contains(msg.id)) {
          _pendingQueue.removeWhere((m) => m.id == msg.id);
          continue;
        }
        _pendingQueue.removeWhere((m) => m.id == msg.id);
        _upsertLocalMessage(
          msg.id,
          status: MessageDeliveryStatus.sent,
          isSending: true,
        );
        _scheduleRetry(msg.id);
        unawaited(_sendWithAck(msg.id, msg.message));
        unawaited(_persistOutgoingMessage(msg.id, msg.message));
      }
      await _savePendingQueue();
    } finally {
      _isFlushingQueue = false;
    }
  }

  Future<void> _loadPendingQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _pendingQueueKey();
      final raw = prefs.getStringList(key) ?? const [];
      if (raw.isEmpty) return;

      final loaded = <ChatMessage>[];
      for (final entry in raw) {
        final parts = entry.split('|');
        if (parts.length < 5) continue;
        final id = parts[0];
        final senderId = parts[1];
        final timestamp = DateTime.tryParse(parts[2]) ?? DateTime.now();
        final retry = int.tryParse(parts[3]) ?? 0;
        final text = parts.sublist(4).join('|');
        loaded.add(ChatMessage(
          id: id,
          rideId: rideId,
          senderId: senderId,
          message: text,
          timestamp: timestamp,
          senderType: _isDriver ? ChatSenderType.driver : ChatSenderType.passenger,
          status: MessageDeliveryStatus.queued,
          retryCount: retry,
          isSending: false,
        ));
      }

      if (loaded.isEmpty) return;
      for (final msg in loaded) {
        if (_processedMessageIds.contains(msg.id)) continue;
        _processedMessageIds.add(msg.id);
        _messageIds.add(msg.id);
        _pendingQueue.add(msg);
      }

      final merged = [...state.messages, ...loaded];
      final unique = <String, ChatMessage>{};
      for (final msg in merged) {
        unique[msg.id] = msg;
      }
      final sorted = unique.values.toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: sorted);

      if (webSocketService.isConnected) {
        unawaited(_flushQueue());
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load pending queue: $e');
    }
  }

  Future<void> _savePendingQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _pendingQueueKey();
      final raw = _pendingQueue.map((m) {
        final safeText = m.message.replaceAll('\n', ' ');
        return '${m.id}|${m.senderId}|${m.timestamp.toIso8601String()}|${m.retryCount}|$safeText';
      }).toList();
      await prefs.setStringList(key, raw);
    } catch (e) {
      debugPrint('⚠️ Failed to persist pending queue: $e');
    }
  }

  String _pendingQueueKey() => 'chat_pending_queue_$rideId';

  void _markDeliveredFromAck({
    required String tempId,
    required String? serverMessageId,
    required DateTime deliveredAt,
  }) {
    _retryTimers.remove(tempId)?.cancel();
    _pendingQueue.removeWhere((m) => m.id == tempId);
    unawaited(_savePendingQueue());

    final targetId = serverMessageId?.isNotEmpty == true ? serverMessageId! : tempId;
    if (targetId != tempId) {
      if (_persistedMessageIds.remove(tempId)) {
        _persistedMessageIds.add(targetId);
      }
      _messageIds.remove(tempId);
      _processedMessageIds.remove(tempId);
      _messageIds.add(targetId);
      _processedMessageIds.add(targetId);
    }

    final updated = state.messages.map((m) {
      if (m.id != tempId) return m;
      return m.copyWith(
        id: targetId,
        status: MessageDeliveryStatus.delivered,
        deliveredAt: deliveredAt,
        isSending: false,
        sendFailed: false,
      );
    }).toList();
    state = state.copyWith(messages: updated, isSending: false);
  }

  DateTime? _parseAckDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    }
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    return null;
  }

  void _upsertLocalMessage(
    String messageId, {
    MessageDeliveryStatus? status,
    int? retryCount,
    bool? isSending,
    bool? sendFailed,
  }) {
    final pendingIndex = _pendingQueue.indexWhere((m) => m.id == messageId);
    if (pendingIndex != -1) {
      _pendingQueue[pendingIndex] = _pendingQueue[pendingIndex].copyWith(
        status: status ?? _pendingQueue[pendingIndex].status,
        retryCount: retryCount ?? _pendingQueue[pendingIndex].retryCount,
        isSending: isSending ?? _pendingQueue[pendingIndex].isSending,
        sendFailed: sendFailed ?? _pendingQueue[pendingIndex].sendFailed,
      );
      unawaited(_savePendingQueue());
    }

    final updated = state.messages.map((m) {
      if (m.id != messageId) return m;
      return m.copyWith(
        status: status ?? m.status,
        retryCount: retryCount ?? m.retryCount,
        isSending: isSending ?? m.isSending,
        sendFailed: sendFailed ?? m.sendFailed,
      );
    }).toList();
    state = state.copyWith(messages: updated);
  }

  Future<void> _persistOutgoingMessage(String tempId, String text) async {
    try {
      final serverMessage = await apiClient.sendChatMessage(
        rideId,
        text,
        clientMessageId: tempId,
      );
      if (serverMessage == null) {
        return;
      }

      final serverId = serverMessage['id']?.toString() ?? tempId;
      _persistedMessageIds.add(tempId);
      _persistedMessageIds.add(serverId);
      _retryTimers.remove(tempId)?.cancel();
      _pendingQueue.removeWhere((m) => m.id == tempId || m.id == serverId);
      unawaited(_savePendingQueue());
      _messageIds.remove(tempId);
      _messageIds.add(serverId);
      _processedMessageIds.remove(tempId);
      _processedMessageIds.add(serverId);

      final confirmedMessage = ChatMessage.fromJson(
        serverMessage,
        currentUserId: _currentUserId,
        passengerId: _passengerId,
      ).copyWith(
        status: MessageDeliveryStatus.sent,
        isSending: false,
        sendFailed: false,
      );

      final updatedMessages = state.messages
          .map((m) => m.id == tempId ? confirmedMessage : m)
          .toList();
      updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      state = state.copyWith(
        messages: updatedMessages,
        isSending: false,
      );
    } catch (e) {
      debugPrint('❌ Failed to persist outgoing message: $e');
    }
  }

  Future<void> _ensureSocketReady() async {
    try {
      await webSocketService.ensureConnected();
      webSocketService.joinRideTracking(rideId);
      await _flushQueue();
    } catch (e) {
      debugPrint('⚠️ Socket warmup failed: $e');
    }
  }

  Future<bool> retryMessage(String messageId) async {
    final message = state.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw Exception('Message not found'),
    );
    
    final updatedMessages = state.messages.where((m) => m.id != messageId).toList();
    _retryTimers.remove(messageId)?.cancel();
    _messageIds.remove(messageId);
    _processedMessageIds.remove(messageId);
    _pendingQueue.removeWhere((m) => m.id == messageId);
    unawaited(_savePendingQueue());
    state = state.copyWith(messages: updatedMessages);
    
    return sendMessage(message.message);
  }

  void sendTypingStart() {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    webSocketService.sendTypingStart(
      rideId: rideId,
      userId: userId,
    );
    state = state.copyWith(isTyping: true);
  }

  void sendTypingStop() {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    webSocketService.sendTypingStop(
      rideId: rideId,
      userId: userId,
    );
    state = state.copyWith(isTyping: false);
  }

  void _handleMessageDelivered(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final msgRideId = payload['rideId'] as String?;
    if (msgRideId != null && msgRideId != rideId) return;
    final messageId = payload['messageId']?.toString();
    if (messageId == null || messageId.isEmpty) return;
    _retryTimers.remove(messageId)?.cancel();

    final updated = state.messages.map((m) {
      if (m.id == messageId && m.senderId == _currentUserId) {
        if (m.status == MessageDeliveryStatus.read) return m;
        return m.copyWith(
          status: MessageDeliveryStatus.delivered,
          deliveredAt: _parseAckDate(payload['deliveredAt']) ?? DateTime.now(),
        );
      }
      return m;
    }).toList();

    state = state.copyWith(messages: updated);
  }

  void _handleMessageRead(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final msgRideId = payload['rideId'] as String?;
    if (msgRideId != null && msgRideId != rideId) return;
    final messageId = payload['messageId']?.toString();
    if (messageId == null || messageId.isEmpty) return;
    _retryTimers.remove(messageId)?.cancel();

    final updated = state.messages.map((m) {
      if (m.id == messageId && m.senderId == _currentUserId) {
        return m.copyWith(
          status: MessageDeliveryStatus.read,
          isRead: true,
          readAt: _parseAckDate(payload['readAt']) ?? DateTime.now(),
        );
      }
      return m;
    }).toList();

    state = state.copyWith(messages: updated);
  }

  void _handleChatReadCursor(dynamic data) {
    if (data is! Map) return;
    final payload = Map<String, dynamic>.from(data);
    final msgRideId = payload['rideId'] as String?;
    if (msgRideId != null && msgRideId != rideId) return;

    final readerId = payload['readerId']?.toString() ?? '';
    if (readerId.isEmpty) return;
    // This cursor reflects what the OTHER participant has read.
    if (_currentUserId != null && readerId == _currentUserId) return;

    final lastReadAt = _parseAckDate(payload['lastReadAt']);
    if (lastReadAt == null) return;

    final updated = state.messages.map((m) {
      final isMine = m.senderId == _currentUserId;
      if (!isMine) return m;
      if (m.timestamp.isAfter(lastReadAt)) return m;
      if (m.status == MessageDeliveryStatus.read &&
          m.readAt != null &&
          !m.readAt!.isBefore(lastReadAt)) {
        return m;
      }
      return m.copyWith(
        status: MessageDeliveryStatus.read,
        isRead: true,
        readAt: lastReadAt,
      );
    }).toList();

    state = state.copyWith(messages: updated);
  }

  void openChat() {
    _isChatOpen = true;
    unawaited(() async {
      await _ensureSocketReady();
      if (_currentUserId?.isNotEmpty ?? false) {
        webSocketService.sendChatOpen(
          rideId: rideId,
          userId: _currentUserId!,
        );
      }
    }());
    unawaited(apiClient.markRideMessagesRead(rideId));
    // Mark unseen incoming messages as read and notify sender.
    final now = DateTime.now();
    final updated = state.messages.map((m) {
      final isMine = m.senderId == _currentUserId;
      if (isMine) return m;
      if (m.id.startsWith('local_')) return m;
      if (m.status == MessageDeliveryStatus.read) return m;
      if (_currentUserId?.isNotEmpty ?? false) {
        webSocketService.sendMessageRead(
          messageId: m.id,
          rideId: rideId,
          readerId: _currentUserId!,
        );
      }
      return m.copyWith(
        status: MessageDeliveryStatus.read,
        isRead: true,
        readAt: now,
      );
    }).toList();
    state = state.copyWith(messages: updated, unreadCount: 0);
  }

  void closeChat() {
    _isChatOpen = false;
    if (_currentUserId?.isNotEmpty ?? false) {
      webSocketService.sendChatClose(
        rideId: rideId,
        userId: _currentUserId!,
      );
    }
  }

  void markAllAsRead() {
    final now = DateTime.now();
    final updated = state.messages.map((m) {
      final isMine = m.senderId == _currentUserId;
      if (isMine || m.status == MessageDeliveryStatus.read || m.id.startsWith('local_')) {
        return m;
      }
      if (_currentUserId?.isNotEmpty ?? false) {
        webSocketService.sendMessageRead(
          messageId: m.id,
          rideId: rideId,
          readerId: _currentUserId!,
        );
      }
      return m.copyWith(
        status: MessageDeliveryStatus.read,
        isRead: true,
        readAt: now,
      );
    }).toList();
    state = state.copyWith(messages: updated, unreadCount: 0);
  }

  /// Handle incoming chat message from external source (SSE, push notification, etc.)
  /// This allows the ride tracking screen to forward SSE chat events to the chat provider.
  void handleExternalChatMessage(Map<String, dynamic> data) {
    _handleIncomingMessage(data);
  }

  String _buildMessageSignature(Map<String, dynamic> messageData) {
    final sender = messageData['sender']?.toString() ??
        messageData['senderId']?.toString() ??
        '';
    final text = messageData['message']?.toString() ??
        messageData['text']?.toString() ??
        messageData['content']?.toString() ??
        '';
    final ts = messageData['timestamp']?.toString() ??
        messageData['time']?.toString() ??
        messageData['createdAt']?.toString() ??
        '';
    return '$rideId|$sender|$text|$ts';
  }

  @override
  void dispose() {
    for (final unsub in _unsubscribers) {
      unsub();
    }
    _unsubscribers.clear();
    _typingTimer?.cancel();
    _pollTimer?.cancel();
    _socketConnectionSub?.cancel();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _persistedMessageIds.clear();
    sendTypingStop();
    unawaited(_savePendingQueue());
    
    webSocketService.leaveRideTracking(rideId);
    
    super.dispose();
  }
}
