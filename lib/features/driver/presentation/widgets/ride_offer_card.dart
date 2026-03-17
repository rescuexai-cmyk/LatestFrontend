import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

enum RideOfferType { bikeRescue, raahiDriver, golden }

class RideOffer {
  final String id;
  final RideOfferType type;
  final double earning;
  final double pickupDistance;
  final int pickupTime;
  final double dropDistance;
  final int dropTime;
  final String pickupAddress;
  final String dropAddress;

  RideOffer({
    required this.id,
    required this.type,
    required this.earning,
    required this.pickupDistance,
    required this.pickupTime,
    required this.dropDistance,
    required this.dropTime,
    required this.pickupAddress,
    required this.dropAddress,
  });
}

class RideOfferCard extends StatelessWidget {
  final RideOffer offer;
  final VoidCallback onAccept;
  final bool isGolden;

  const RideOfferCard({
    super.key,
    required this.offer,
    required this.onAccept,
    this.isGolden = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGolden ? AppColors.warning : AppColors.border,
          width: isGolden ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isGolden 
                  ? AppColors.warning.withOpacity(0.1) 
                  : AppColors.background,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Icon(
                  offer.type == RideOfferType.bikeRescue 
                      ? Icons.two_wheeler 
                      : Icons.directions_car,
                  size: 16,
                  color: isGolden ? AppColors.accent1 : AppColors.textPrimary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _getTypeLabel(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isGolden ? AppColors.accent1 : AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Earning
                const Text(
                  'Earning',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  '₹${offer.earning.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isGolden ? AppColors.accent1 : AppColors.success,
                  ),
                ),
                
                const SizedBox(height: 12),
                
                // Pickup Distance
                _buildDistanceRow(
                  label: 'Pickup\nDistance',
                  distance: '${offer.pickupDistance} km',
                  time: '${offer.pickupTime} min away',
                  isHighlighted: false,
                ),
                
                const SizedBox(height: 8),
                
                // Drop Distance
                _buildDistanceRow(
                  label: 'Drop\nDistance',
                  distance: '${offer.dropDistance} km',
                  time: '${offer.dropTime} min away',
                  isHighlighted: true,
                ),
                
                const SizedBox(height: 12),
                
                // Pickup & Drop addresses
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Pickup',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            offer.pickupAddress,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Drop',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            offer.dropAddress,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 12),
                
                // Accept Button
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: ElevatedButton(
                    onPressed: onAccept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isGolden ? AppColors.warning : AppColors.error,
                      foregroundColor: isGolden ? AppColors.primary : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          isGolden ? 'Golden Ride' : 'Accept Ride',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          isGolden ? Icons.star : Icons.add_circle_outline,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getTypeLabel() {
    switch (offer.type) {
      case RideOfferType.bikeRescue:
        return 'Bike Rescue';
      case RideOfferType.raahiDriver:
        return 'Raahi - Driver';
      case RideOfferType.golden:
        return 'Golden Ride';
    }
  }

  Widget _buildDistanceRow({
    required String label,
    required String distance,
    required String time,
    required bool isHighlighted,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                distance,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isHighlighted ? AppColors.success : AppColors.textPrimary,
                ),
              ),
              Text(
                time,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact ride offer card for bottom sheet
class CompactRideOfferCard extends StatelessWidget {
  final String type;
  final double earning;
  final VoidCallback onAccept;

  const CompactRideOfferCard({
    super.key,
    required this.type,
    required this.earning,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                type,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                '₹${earning.toStringAsFixed(2)} / hr.',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: onAccept,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Accept Ride',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                SizedBox(width: 4),
                Icon(Icons.add_circle_outline, size: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

