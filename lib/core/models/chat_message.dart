import 'package:flutter/foundation.dart';

enum ChatSenderType { passenger, driver, system }
enum MessageDeliveryStatus { queued, sent, delivered, read, failed }

@immutable
class ChatMessage {
  final String id;
  final String rideId;
  final String senderId;
  final String message;
  final DateTime timestamp;
  final ChatSenderType senderType;
  final bool isRead;
  final bool isSending;
  final bool sendFailed;
  final MessageDeliveryStatus status;
  final int retryCount;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  const ChatMessage({
    required this.id,
    required this.rideId,
    required this.senderId,
    required this.message,
    required this.timestamp,
    required this.senderType,
    this.isRead = false,
    this.isSending = false,
    this.sendFailed = false,
    this.status = MessageDeliveryStatus.sent,
    this.retryCount = 0,
    this.deliveredAt,
    this.readAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json, {String? currentUserId, String? passengerId}) {
    final senderId = json['senderId'] as String? ?? 
                     json['sender'] as String? ?? 
                     json['userId'] as String? ?? '';
    
    ChatSenderType senderType;
    if (json['senderType'] != null) {
      final typeStr = json['senderType'].toString().toLowerCase();
      if (typeStr == 'driver') {
        senderType = ChatSenderType.driver;
      } else if (typeStr == 'passenger' || typeStr == 'rider' || typeStr == 'user') {
        senderType = ChatSenderType.passenger;
      } else if (typeStr == 'system') {
        senderType = ChatSenderType.system;
      } else {
        senderType = ChatSenderType.values.firstWhere(
          (e) => e.name == typeStr,
          orElse: () => ChatSenderType.passenger,
        );
      }
    } else if (json['sender'] == 'driver' || json['senderRole'] == 'driver') {
      senderType = ChatSenderType.driver;
    } else if (json['sender'] == 'passenger' || json['sender'] == 'rider' || json['senderRole'] == 'passenger') {
      senderType = ChatSenderType.passenger;
    } else if (passengerId != null && passengerId.isNotEmpty) {
      senderType = senderId == passengerId ? ChatSenderType.passenger : ChatSenderType.driver;
    } else {
      senderType = ChatSenderType.passenger;
    }

    final parsedStatus = _parseStatus(
      json['status']?.toString(),
      isRead: json['isRead'] as bool? ?? json['read'] as bool? ?? false,
      readAt: json['readAt'] ?? json['read_at'],
    );

    return ChatMessage(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      rideId: json['rideId'] as String? ?? '',
      senderId: senderId,
      message: json['message'] as String? ?? json['text'] as String? ?? json['content'] as String? ?? '',
      timestamp: _parseTimestamp(json['timestamp'] ?? json['time'] ?? json['createdAt']),
      senderType: senderType,
      isRead: json['isRead'] as bool? ?? json['read'] as bool? ?? false,
      status: parsedStatus,
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
      deliveredAt: _parseDateNullable(json['deliveredAt'] ?? json['delivered_at']),
      readAt: _parseDateNullable(json['readAt'] ?? json['read_at']),
    );
  }

  static DateTime _parseTimestamp(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is DateTime) return value.toLocal();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    if (value is String) {
      final dt = DateTime.tryParse(value);
      return dt?.toLocal() ?? DateTime.now();
    }
    return DateTime.now();
  }

  static DateTime? _parseDateNullable(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    return null;
  }

  static MessageDeliveryStatus _parseStatus(String? status, {required bool isRead, dynamic readAt}) {
    final normalized = status?.toUpperCase();
    if (normalized == 'FAILED') return MessageDeliveryStatus.failed;
    if (normalized == 'QUEUED') return MessageDeliveryStatus.queued;
    if (normalized == 'READ' || isRead || readAt != null) {
      return MessageDeliveryStatus.read;
    }
    if (normalized == 'DELIVERED') {
      return MessageDeliveryStatus.delivered;
    }
    return MessageDeliveryStatus.sent;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'rideId': rideId,
    'senderId': senderId,
    'message': message,
    'timestamp': timestamp.toIso8601String(),
    'senderType': senderType.name,
    'isRead': isRead,
    'status': status.name.toUpperCase(),
    'retryCount': retryCount,
    'deliveredAt': deliveredAt?.toIso8601String(),
    'readAt': readAt?.toIso8601String(),
  };

  ChatMessage copyWith({
    String? id,
    String? rideId,
    String? senderId,
    String? message,
    DateTime? timestamp,
    ChatSenderType? senderType,
    bool? isRead,
    bool? isSending,
    bool? sendFailed,
    MessageDeliveryStatus? status,
    int? retryCount,
    DateTime? deliveredAt,
    DateTime? readAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      rideId: rideId ?? this.rideId,
      senderId: senderId ?? this.senderId,
      message: message ?? this.message,
      timestamp: timestamp ?? this.timestamp,
      senderType: senderType ?? this.senderType,
      isRead: isRead ?? this.isRead,
      isSending: isSending ?? this.isSending,
      sendFailed: sendFailed ?? this.sendFailed,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
    );
  }

  bool get isFromCurrentUser => senderType == ChatSenderType.passenger;
  bool get isFromDriver => senderType == ChatSenderType.driver;
  bool get isSystemMessage => senderType == ChatSenderType.system;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChatMessage(id: $id, message: $message, sender: $senderType)';
}
