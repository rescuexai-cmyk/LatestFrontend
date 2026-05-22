import 'package:equatable/equatable.dart';

enum SubscriptionStatus { active, expired, neverPurchased }

class DriverSubscription extends Equatable {
  final String driverId;
  final DateTime? lastPaidAt;
  final DateTime? validTill;
  final bool isActive;
  final SubscriptionStatus status;

  const DriverSubscription({
    required this.driverId,
    this.lastPaidAt,
    this.validTill,
    required this.isActive,
    required this.status,
  });

  factory DriverSubscription.fromJson(Map<String, dynamic> json) {
    final data = json['data'] ?? json;

    DateTime? parseDateTime(dynamic value) {
      if (value == null) return null;
      if (value is String) return DateTime.tryParse(value);
      if (value is int) {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      }
      return null;
    }

    SubscriptionStatus parseStatus(dynamic value) {
      if (value == null) return SubscriptionStatus.neverPurchased;
      switch (value.toString().toLowerCase()) {
        case 'active':
          return SubscriptionStatus.active;
        case 'expired':
          return SubscriptionStatus.expired;
        default:
          return SubscriptionStatus.neverPurchased;
      }
    }

    return DriverSubscription(
      driverId: data['driverId']?.toString() ?? '',
      lastPaidAt: parseDateTime(data['lastPaidAt']),
      validTill: parseDateTime(data['validTill']),
      isActive: data['allowOnline'] == true || data['isActive'] == true,
      status: parseStatus(data['status']),
    );
  }

  bool get canGoOnline => isActive && status == SubscriptionStatus.active;

  Duration? get remainingTime {
    if (validTill == null) return null;
    final remaining = validTill!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String get remainingTimeFormatted {
    final remaining = remainingTime;
    if (remaining == null || remaining == Duration.zero) return 'Expired';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  String get validTillFormatted {
    if (validTill == null) return 'Not purchased';
    // Always display subscription expiry in IST (UTC+05:30) on UI.
    final istTime = validTill!.toUtc().add(const Duration(hours: 5, minutes: 30));
    final hour = istTime.hour;
    final minute = istTime.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$displayHour:${minute.toString().padLeft(2, '0')} $period IST';
  }

  @override
  List<Object?> get props => [driverId, lastPaidAt, validTill, isActive, status];
}

class SubscriptionActivationResponse extends Equatable {
  final bool success;
  final String? message;
  final DateTime? validTill;

  const SubscriptionActivationResponse({
    required this.success,
    this.message,
    this.validTill,
  });

  factory SubscriptionActivationResponse.fromJson(Map<String, dynamic> json) {
    final data = json['data'] ?? json;
    DateTime? validTill;
    if (data['validTill'] != null) {
      if (data['validTill'] is String) {
        validTill = DateTime.tryParse(data['validTill']);
      } else if (data['validTill'] is int) {
        validTill = DateTime.fromMillisecondsSinceEpoch(data['validTill']);
      }
    }

    return SubscriptionActivationResponse(
      success: json['success'] == true,
      message: json['message']?.toString(),
      validTill: validTill,
    );
  }

  @override
  List<Object?> get props => [success, message, validTill];
}
