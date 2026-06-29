import 'package:flutter/material.dart';
import '../../../../core/models/ride_stop.dart';

/// Vertical pickup → intermediate stop(s) → drop summary for driver screens.
class DriverTripRouteSummary extends StatelessWidget {
  const DriverTripRouteSummary({
    super.key,
    required this.pickupAddress,
    required this.dropAddress,
    this.stops = const [],
    this.compact = false,
    this.highlightDrop = false,
    this.highlightPickup = false,
  });

  final String pickupAddress;
  final String dropAddress;
  final List<RideStop> stops;
  final bool compact;
  final bool highlightDrop;
  final bool highlightPickup;

  static const _textDark = Color(0xFF1A1A1A);
  static const _textGrey = Color(0xFF888888);

  @override
  Widget build(BuildContext context) {
    if (stops.isEmpty) {
      return _simplePickupDropRow();
    }

    final legs = <_Leg>[
      _Leg(
        label: 'Pickup',
        address: pickupAddress,
        dotColor: const Color(0xFFD4956A),
        filled: true,
        emphasize: highlightPickup,
      ),
      ...stops.asMap().entries.map(
            (e) => _Leg(
              label: 'Stop ${e.key + 1}',
              address: e.value.address,
              dotColor: const Color(0xFFCF923D),
              filled: true,
            ),
          ),
      _Leg(
        label: 'Drop',
        address: dropAddress,
        dotColor: const Color(0xFF4CAF50),
        filled: false,
        emphasize: highlightDrop,
      ),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            for (var i = 0; i < legs.length; i++) ...[
              _dot(legs[i]),
              if (i < legs.length - 1)
                Container(
                  width: 2,
                  height: compact ? 16 : 20,
                  color: const Color(0xFFE0E0E0),
                ),
            ],
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < legs.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i < legs.length - 1 ? (compact ? 10 : 14) : 0),
                  child: _legText(legs[i]),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dot(_Leg leg) {
    const size = 10.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: leg.filled ? leg.dotColor : Colors.transparent,
        shape: BoxShape.circle,
        border: leg.filled ? null : Border.all(color: leg.dotColor, width: 2),
      ),
    );
  }

  Widget _legText(_Leg leg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          leg.label,
          style: TextStyle(
            color: _textDark,
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          leg.address,
          style: TextStyle(
            color: leg.emphasize ? _textDark : _textGrey,
            fontSize: compact ? 11 : 12,
            height: 1.3,
            fontWeight: leg.emphasize ? FontWeight.w600 : FontWeight.normal,
          ),
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _simplePickupDropRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Pickup',
                  style: TextStyle(
                    color: _textDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  pickupAddress,
                  style: const TextStyle(
                    color: _textGrey,
                    fontSize: 12,
                    height: 1.3,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, color: _textGrey, size: 18),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Drop',
                  style: TextStyle(
                    color: _textDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  dropAddress,
                  style: const TextStyle(
                    color: _textGrey,
                    fontSize: 12,
                    height: 1.3,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Leg {
  const _Leg({
    required this.label,
    required this.address,
    required this.dotColor,
    required this.filled,
    this.emphasize = false,
  });

  final String label;
  final String address;
  final Color dotColor;
  final bool filled;
  final bool emphasize;
}

/// Small badge for multi-stop offers (e.g. ride card header).
class DriverMultiStopBadge extends StatelessWidget {
  const DriverMultiStopBadge({super.key, required this.stopCount});

  final int stopCount;

  @override
  Widget build(BuildContext context) {
    if (stopCount <= 0) return const SizedBox.shrink();
    final label = stopCount == 1 ? '1 stop' : '$stopCount stops';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCF923D)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.add_location_alt, size: 12, color: Color(0xFFCF923D)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFCF923D),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
