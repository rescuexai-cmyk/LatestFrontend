import 'package:flutter/material.dart';

/// Detailed fare breakdown data model
class FareBreakdown {
  final double baseFare;
  final double distanceKm;
  final double durationMin;
  final double ratePerKm;
  final double ratePerMin;
  final double distanceFare;
  final double timeFare;
  final double surgeMultiplier;
  final double surgeAmount;
  final double tolls;
  final double airportFee;
  final double waitingCharge;
  final double parkingFees;
  final double extraStopsCharge;
  final double discount;
  final double subtotal;
  final double gstPercent;
  final double gstAmount;
  final double totalFare;
  final String? promoCode;
  final bool minimumFareApplied;

  const FareBreakdown({
    required this.baseFare,
    required this.distanceKm,
    required this.durationMin,
    required this.ratePerKm,
    required this.ratePerMin,
    required this.distanceFare,
    required this.timeFare,
    this.surgeMultiplier = 1.0,
    this.surgeAmount = 0,
    this.tolls = 0,
    this.airportFee = 0,
    this.waitingCharge = 0,
    this.parkingFees = 0,
    this.extraStopsCharge = 0,
    this.discount = 0,
    required this.subtotal,
    this.gstPercent = 5,
    this.gstAmount = 0,
    required this.totalFare,
    this.promoCode,
    this.minimumFareApplied = false,
  });

  factory FareBreakdown.fromJson(Map<String, dynamic> json) {
    return FareBreakdown(
      baseFare: (json['baseFare'] ?? json['startingFee'] ?? 0).toDouble(),
      distanceKm: (json['distanceKm'] ?? json['distance'] ?? 0).toDouble(),
      durationMin: (json['durationMin'] ?? json['estimatedDuration'] ?? json['estimatedDurationMin'] ?? 0).toDouble(),
      ratePerKm: (json['ratePerKm'] ?? json['breakdown']?['ratePerKm'] ?? 0).toDouble(),
      ratePerMin: (json['ratePerMin'] ?? json['breakdown']?['ratePerMin'] ?? 0).toDouble(),
      distanceFare: (json['distanceFare'] ?? 0).toDouble(),
      timeFare: (json['timeFare'] ?? 0).toDouble(),
      surgeMultiplier: (json['surgeMultiplier'] ?? json['breakdown']?['dynamicMultiplier'] ?? 1.0).toDouble(),
      surgeAmount: (json['surgeAmount'] ?? 0).toDouble(),
      tolls: (json['tolls'] ?? json['breakdown']?['tolls'] ?? 0).toDouble(),
      airportFee: (json['airportFee'] ?? json['airportCharge'] ?? json['breakdown']?['airportCharge'] ?? 0).toDouble(),
      waitingCharge: (json['waitingCharge'] ?? json['breakdown']?['waitingCharge'] ?? 0).toDouble(),
      parkingFees: (json['parkingFees'] ?? json['breakdown']?['parkingFees'] ?? 0).toDouble(),
      extraStopsCharge: (json['extraStopsCharge'] ?? json['breakdown']?['extraStopsCharge'] ?? 0).toDouble(),
      discount: (json['discount'] ?? json['breakdown']?['discount'] ?? 0).toDouble(),
      subtotal: (json['subtotal'] ?? json['breakdown']?['subtotal'] ?? json['totalFare'] ?? 0).toDouble(),
      gstPercent: (json['gstPercent'] ?? json['breakdown']?['gstPercent'] ?? 5).toDouble(),
      gstAmount: (json['gstAmount'] ?? json['breakdown']?['gstAmount'] ?? 0).toDouble(),
      totalFare: (json['totalFare'] ?? json['finalFare'] ?? 0).toDouble(),
      promoCode: json['promoCode'],
      minimumFareApplied: json['minimumFareApplied'] ?? json['breakdown']?['minimumFareApplied'] ?? false,
    );
  }
}

/// Reusable fare breakdown widget for booking confirmation, ride receipt, etc.
class FareBreakdownWidget extends StatelessWidget {
  final FareBreakdown breakdown;
  final String? vehicleName;
  final bool showDetailed;
  final bool isReceipt;

  const FareBreakdownWidget({
    super.key,
    required this.breakdown,
    this.vehicleName,
    this.showDetailed = true,
    this.isReceipt = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isReceipt ? Colors.white : const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: isReceipt
            ? [
                BoxShadow(
                  color: Colors.black.withAlpha(13),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 12),
          _buildBaseFareSection(),
          if (showDetailed) ...[
            const SizedBox(height: 8),
            _buildDynamicPricingSection(),
          ],
          if (_hasAdditionalCharges()) ...[
            const Divider(height: 20),
            _buildAdditionalChargesSection(),
          ],
          if (breakdown.discount > 0) ...[
            const Divider(height: 20),
            _buildDiscountSection(),
          ],
          const Divider(height: 20),
          _buildTotalSection(),
          if (breakdown.minimumFareApplied) ...[
            const SizedBox(height: 8),
            _buildMinimumFareNote(),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          isReceipt
              ? 'Fare Receipt'
              : 'Fare Estimate${vehicleName != null ? ' - $vehicleName' : ''}',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        if (!isReceipt)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'TRANSPARENT',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: Color(0xFF4CAF50),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBaseFareSection() {
    return Column(
      children: [
        _buildFareRow('Base Fare', '₹${breakdown.baseFare.toStringAsFixed(0)}'),
        _buildFareRow(
          'Distance (${breakdown.distanceKm.toStringAsFixed(1)} km × ₹${breakdown.ratePerKm.toStringAsFixed(0)})',
          '₹${breakdown.distanceFare.toStringAsFixed(0)}',
        ),
        _buildFareRow(
          'Time (${breakdown.durationMin.toStringAsFixed(0)} min × ₹${breakdown.ratePerMin.toStringAsFixed(1)})',
          '₹${breakdown.timeFare.toStringAsFixed(0)}',
        ),
      ],
    );
  }

  Widget _buildDynamicPricingSection() {
    if (breakdown.surgeMultiplier <= 1.0) return const SizedBox.shrink();

    final surgePercent = ((breakdown.surgeMultiplier - 1) * 100).toStringAsFixed(0);
    return _buildFareRow(
      'Surge (${breakdown.surgeMultiplier.toStringAsFixed(1)}x)',
      '+₹${breakdown.surgeAmount.toStringAsFixed(0)}',
      highlight: true,
    );
  }

  bool _hasAdditionalCharges() {
    return breakdown.tolls > 0 ||
        breakdown.airportFee > 0 ||
        breakdown.waitingCharge > 0 ||
        breakdown.parkingFees > 0 ||
        breakdown.extraStopsCharge > 0;
  }

  Widget _buildAdditionalChargesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Additional Charges',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 6),
        if (breakdown.tolls > 0)
          _buildFareRow('Tolls', '₹${breakdown.tolls.toStringAsFixed(0)}'),
        if (breakdown.airportFee > 0)
          _buildFareRow('Airport Fee', '₹${breakdown.airportFee.toStringAsFixed(0)}'),
        if (breakdown.waitingCharge > 0)
          _buildFareRow('Waiting Charge', '₹${breakdown.waitingCharge.toStringAsFixed(0)}'),
        if (breakdown.parkingFees > 0)
          _buildFareRow('Parking Fees', '₹${breakdown.parkingFees.toStringAsFixed(0)}'),
        if (breakdown.extraStopsCharge > 0)
          _buildFareRow('Extra Stops', '₹${breakdown.extraStopsCharge.toStringAsFixed(0)}'),
      ],
    );
  }

  Widget _buildDiscountSection() {
    return Column(
      children: [
        _buildFareRow(
          breakdown.promoCode != null
              ? 'Discount (${breakdown.promoCode})'
              : 'Discount',
          '-₹${breakdown.discount.toStringAsFixed(0)}',
          isDiscount: true,
        ),
      ],
    );
  }

  Widget _buildTotalSection() {
    return Column(
      children: [
        if (breakdown.gstAmount > 0) ...[
          _buildFareRow('Subtotal', '₹${breakdown.subtotal.toStringAsFixed(0)}'),
          _buildFareRow(
            'GST (${breakdown.gstPercent.toStringAsFixed(0)}%)',
            '₹${breakdown.gstAmount.toStringAsFixed(0)}',
          ),
          const SizedBox(height: 8),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Total',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A1A),
              ),
            ),
            Text(
              '₹${breakdown.totalFare.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Color(0xFFD4956A),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMinimumFareNote() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline, size: 12, color: Color(0xFFE65100)),
          SizedBox(width: 4),
          Text(
            'Minimum fare applied',
            style: TextStyle(
              fontSize: 10,
              color: Color(0xFFE65100),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFareRow(String label, String value, {bool highlight = false, bool isDiscount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: highlight ? const Color(0xFFE65100) : const Color(0xFF666666),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDiscount
                  ? const Color(0xFF4CAF50)
                  : highlight
                      ? const Color(0xFFE65100)
                      : const Color(0xFF1A1A1A),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact fare breakdown for ride cards
class CompactFareBreakdown extends StatelessWidget {
  final double baseFare;
  final double distanceKm;
  final double durationMin;
  final double totalFare;
  final double surgeMultiplier;

  const CompactFareBreakdown({
    super.key,
    required this.baseFare,
    required this.distanceKm,
    required this.durationMin,
    required this.totalFare,
    this.surgeMultiplier = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${distanceKm.toStringAsFixed(1)} km • ${durationMin.toStringAsFixed(0)} min',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF666666),
                ),
              ),
              if (surgeMultiplier > 1.0)
                Text(
                  '${surgeMultiplier.toStringAsFixed(1)}x surge',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFE65100),
                  ),
                ),
            ],
          ),
          Text(
            '₹${totalFare.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFFD4956A),
            ),
          ),
        ],
      ),
    );
  }
}
