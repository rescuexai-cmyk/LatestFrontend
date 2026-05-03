import 'package:equatable/equatable.dart';

enum PenaltyStatus { pending, cleared, none }

class DriverPenalty extends Equatable {
  final String? id;
  final String driverId;
  final double amount;
  final String reason;
  final PenaltyStatus status;
  final DateTime? createdAt;
  final DateTime? clearedAt;

  const DriverPenalty({
    this.id,
    required this.driverId,
    required this.amount,
    required this.reason,
    required this.status,
    this.createdAt,
    this.clearedAt,
  });

  factory DriverPenalty.fromJson(Map<String, dynamic> json) {
    return DriverPenalty(
      id: json['id'] as String?,
      driverId: json['driverId'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      reason: json['reason'] as String? ?? 'Penalty',
      status: _parseStatus(json['status'] as String?),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      clearedAt: json['clearedAt'] != null
          ? DateTime.tryParse(json['clearedAt'] as String)
          : null,
    );
  }

  static PenaltyStatus _parseStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'pending':
        return PenaltyStatus.pending;
      case 'cleared':
        return PenaltyStatus.cleared;
      default:
        return PenaltyStatus.none;
    }
  }

  bool get isPending => status == PenaltyStatus.pending;
  bool get isCleared => status == PenaltyStatus.cleared;

  @override
  List<Object?> get props => [id, driverId, amount, reason, status, createdAt, clearedAt];
}

class PenaltyStatusResponse extends Equatable {
  final bool hasPendingPenalty;
  final double penaltyAmount;
  final String? penaltyReason;
  final String? penaltyId;
  final double walletBalance;
  final bool canPayFromWallet;

  const PenaltyStatusResponse({
    required this.hasPendingPenalty,
    required this.penaltyAmount,
    this.penaltyReason,
    this.penaltyId,
    required this.walletBalance,
    required this.canPayFromWallet,
  });

  factory PenaltyStatusResponse.fromJson(Map<String, dynamic> json) {
    final penalty = json['penalty'] as Map<String, dynamic>?;
    final wallet = json['wallet'] as Map<String, dynamic>?;

    var penaltyAmount = (penalty?['amount'] as num?)?.toDouble() ??
        (json['penaltyAmount'] as num?)?.toDouble() ??
        0.0;

    var walletBalance = (wallet?['balance'] as num?)?.toDouble() ??
        (json['walletBalance'] as num?)?.toDouble() ??
        (json['availableBalance'] as num?)?.toDouble() ??
        0.0;

    // Driver wallet API shape: { balance: { available: n } }
    if (walletBalance == 0 && json['balance'] is Map<String, dynamic>) {
      final b = json['balance'] as Map<String, dynamic>;
      walletBalance = (b['available'] as num?)?.toDouble() ?? 0.0;
    }
    if (walletBalance == 0 && wallet != null && wallet['available'] != null) {
      walletBalance = (wallet['available'] as num).toDouble();
    }

    var hasPending =
        json['hasPendingPenalty'] as bool? ?? json['hasPenalty'] as bool? ?? false;
    final status = penalty?['status']?.toString().toLowerCase();
    if (!hasPending && penaltyAmount > 0) {
      if (status == null ||
          status == 'pending' ||
          status == 'unpaid' ||
          status == 'active') {
        hasPending = true;
      }
    }

    return PenaltyStatusResponse(
      hasPendingPenalty: hasPending,
      penaltyAmount: penaltyAmount,
      penaltyReason: penalty?['reason'] as String? ?? json['penaltyReason'] as String?,
      penaltyId: penalty?['id'] as String? ?? json['penaltyId'] as String?,
      walletBalance: walletBalance,
      // Wallet pay only if balance strictly exceeds ₹10 and covers penalty (product rule)
      canPayFromWallet: walletBalance > 10 && walletBalance >= penaltyAmount && penaltyAmount > 0,
    );
  }

  factory PenaltyStatusResponse.none() {
    return const PenaltyStatusResponse(
      hasPendingPenalty: false,
      penaltyAmount: 0,
      walletBalance: 0,
      canPayFromWallet: false,
    );
  }

  @override
  List<Object?> get props => [
        hasPendingPenalty,
        penaltyAmount,
        penaltyReason,
        penaltyId,
        walletBalance,
        canPayFromWallet,
      ];
}

class ClearPenaltyResponse extends Equatable {
  final bool success;
  final String? message;
  final double? newWalletBalance;

  const ClearPenaltyResponse({
    required this.success,
    this.message,
    this.newWalletBalance,
  });

  factory ClearPenaltyResponse.fromJson(Map<String, dynamic> json) {
    return ClearPenaltyResponse(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String?,
      newWalletBalance: (json['newWalletBalance'] as num?)?.toDouble(),
    );
  }

  @override
  List<Object?> get props => [success, message, newWalletBalance];
}
