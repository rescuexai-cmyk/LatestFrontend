import 'package:equatable/equatable.dart';

enum VehicleType { economy, comfort, premium, xl, bike }

class VehicleInfo extends Equatable {
  final String? make;
  final String? model;
  final int? year;
  final String color;
  final String plateNumber;
  final String type;

  const VehicleInfo({
    this.make,
    this.model,
    this.year,
    required this.color,
    required this.plateNumber,
    required this.type,
  });

  factory VehicleInfo.fromJson(Map<String, dynamic> json) {
    return VehicleInfo(
      make: json['make'] as String?,
      model: json['model'] as String?,
      year: json['year'] as int?,
      color: json['color'] as String? ?? 'Unknown',
      plateNumber: json['plateNumber'] as String? ?? json['license_plate'] as String? ?? 'Unknown',
      type: json['type'] as String? ?? json['vehicle_type'] as String? ?? 'economy',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'make': make,
      'model': model,
      'year': year,
      'color': color,
      'plateNumber': plateNumber,
      'type': type,
    };
  }

  String get displayName {
    if (make != null && model != null) {
      return '$make $model';
    }
    return type;
  }

  @override
  List<Object?> get props => [make, model, year, color, plateNumber, type];
}


