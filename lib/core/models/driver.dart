import 'package:equatable/equatable.dart';
import 'location.dart';
import 'vehicle.dart';

enum DriverStatus { available, busy, offline, onRide }

class Driver extends Equatable {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final VehicleInfo? vehicleInfo;
  final String? licenseNumber;
  final bool isVerified;
  final bool isAvailable;
  final LocationCoordinate? currentLocation;
  final double rating;
  final int totalRides;
  final DriverStatus status;
  final String? avatar;
  final double? heading;
  final int? eta; // Estimated time of arrival in minutes

  const Driver({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.vehicleInfo,
    this.licenseNumber,
    this.isVerified = false,
    this.isAvailable = false,
    this.currentLocation,
    this.rating = 4.0,
    this.totalRides = 0,
    this.status = DriverStatus.offline,
    this.avatar,
    this.heading,
    this.eta,
  });

  factory Driver.fromJson(Map<String, dynamic> json) {
    final userJson =
        json['user'] is Map<String, dynamic> ? json['user'] as Map<String, dynamic> : null;
    final nestedPhone = userJson?['phone']?.toString() ?? userJson?['phoneNumber']?.toString();
    final topLevelPhone = json['phone']?.toString() ?? json['phoneNumber']?.toString();
    final phone = _pickPreferredPhone(nestedPhone, topLevelPhone);

    return Driver(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: phone,
      email: json['email'] as String?,
      vehicleInfo: json['vehicle_info'] != null
          ? VehicleInfo.fromJson(json['vehicle_info'] as Map<String, dynamic>)
          : null,
      licenseNumber: json['license_number'] as String?,
      isVerified: json['is_verified'] as bool? ?? false,
      isAvailable: json['is_available'] as bool? ?? false,
      currentLocation: json['current_location'] != null
          ? LocationCoordinate.fromJson(json['current_location'] as Map<String, dynamic>)
          : null,
      rating: (json['rating'] as num?)?.toDouble() ?? 4.0,
      totalRides: json['total_rides'] as int? ?? 0,
      status: _parseStatus(json['status'] as String?),
      avatar: json['avatar'] as String?,
      heading: (json['heading'] as num?)?.toDouble(),
      eta: json['eta'] as int?,
    );
  }

  static String? _pickPreferredPhone(String? primary, String? secondary) {
    final a = primary?.trim();
    final b = secondary?.trim();
    if (a != null && a.isNotEmpty && !_isLikelyPlaceholderPhone(a)) return a;
    if (b != null && b.isNotEmpty && !_isLikelyPlaceholderPhone(b)) return b;
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    return null;
  }

  static bool _isLikelyPlaceholderPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return false;
    final core = digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
    return core == '9999999999' || core == '9876543210' || RegExp(r'^(\d)\1{9}$').hasMatch(core);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'vehicle_info': vehicleInfo?.toJson(),
      'license_number': licenseNumber,
      'is_verified': isVerified,
      'is_available': isAvailable,
      'current_location': currentLocation?.toJson(),
      'rating': rating,
      'total_rides': totalRides,
      'status': status.name,
      'avatar': avatar,
      'heading': heading,
      'eta': eta,
    };
  }

  static DriverStatus _parseStatus(String? status) {
    switch (status) {
      case 'available':
        return DriverStatus.available;
      case 'busy':
        return DriverStatus.busy;
      case 'on_ride':
        return DriverStatus.onRide;
      default:
        return DriverStatus.offline;
    }
  }

  Driver copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    VehicleInfo? vehicleInfo,
    String? licenseNumber,
    bool? isVerified,
    bool? isAvailable,
    LocationCoordinate? currentLocation,
    double? rating,
    int? totalRides,
    DriverStatus? status,
    String? avatar,
    double? heading,
    int? eta,
  }) {
    return Driver(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      vehicleInfo: vehicleInfo ?? this.vehicleInfo,
      licenseNumber: licenseNumber ?? this.licenseNumber,
      isVerified: isVerified ?? this.isVerified,
      isAvailable: isAvailable ?? this.isAvailable,
      currentLocation: currentLocation ?? this.currentLocation,
      rating: rating ?? this.rating,
      totalRides: totalRides ?? this.totalRides,
      status: status ?? this.status,
      avatar: avatar ?? this.avatar,
      heading: heading ?? this.heading,
      eta: eta ?? this.eta,
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        phone,
        vehicleInfo,
        isVerified,
        currentLocation,
        rating,
        status,
      ];
}


