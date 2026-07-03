import 'package:equatable/equatable.dart';

enum UserType { rider, driver, both }

class User extends Equatable {
  final String id;
  final String email;
  final String? phone;
  final String name;
  final String? avatarUrl;
  final UserType userType;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? userMetadata;

  const User({
    required this.id,
    required this.email,
    this.phone,
    required this.name,
    this.avatarUrl,
    required this.userType,
    required this.createdAt,
    required this.updatedAt,
    this.userMetadata,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      email: json['email'] as String,
      phone: json['phone'] as String?,
      name: json['name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      userType: json['user_type'] != null ||
              json['userType'] != null ||
              json['role'] != null
          ? userTypeFromJson(json)
          : UserType.both,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      userMetadata: json['user_metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'phone': phone,
      'name': name,
      'avatar_url': avatarUrl,
      'user_type': userType.name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'user_metadata': userMetadata,
    };
  }

  /// Parse backend role — supports snake_case, camelCase, and uppercase variants
  /// until the API contract is finalised (e.g. `user_type`, `userType`, `role`).
  static UserType parseUserType(String? type) {
    switch (type?.trim().toLowerCase()) {
      case 'driver':
      case 'drivers':
        return UserType.driver;
      case 'both':
      case 'rider_driver':
      case 'rider_and_driver':
        return UserType.both;
      case 'rider':
      case 'riders':
      case 'passenger':
      default:
        return UserType.rider;
    }
  }

  /// Extract role from a backend user JSON map (multiple key aliases).
  /// When the field is absent the user is treated as [UserType.both] so the
  /// dual-choice screen keeps showing until the backend starts sending roles.
  static UserType userTypeFromJson(Map<String, dynamic> json) {
    final raw = json['user_type'] ??
        json['userType'] ??
        json['role'] ??
        json['account_type'] ??
        json['accountType'];
    if (raw == null) return UserType.both;
    if (raw is String && raw.trim().isEmpty) return UserType.both;
    if (raw is String) return parseUserType(raw);
    return UserType.both;
  }

  User copyWith({
    String? id,
    String? email,
    String? phone,
    String? name,
    String? avatarUrl,
    UserType? userType,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? userMetadata,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      userType: userType ?? this.userType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userMetadata: userMetadata ?? this.userMetadata,
    );
  }

  @override
  List<Object?> get props => [id, email, phone, name, avatarUrl, userType, createdAt, updatedAt];
}


