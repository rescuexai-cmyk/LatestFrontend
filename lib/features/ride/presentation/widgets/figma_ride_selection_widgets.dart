import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vibration/vibration.dart';

/// Figma accent / selection border (#CF923D).
const Color figmaRideAccent = Color(0xFFCF923D);

/// Figma modal top corner radius (Frame 1410081769).
const double figmaRideSheetTopRadius = 32;

/// Figma trip-summary row width (Frame 1410081817).
const double figmaTripPillsTotalWidth = 346;

/// Figma vehicle thumb — fits 81px card inner row (61) with 10px vertical padding.
const double figmaVehicleThumbWidth = 88;
const double figmaVehicleThumbHeight = 61;
const double figmaVehicleThumbRadius = 14.1659;

/// Normalizes Google Directions / backend duration strings to always show `N min`
/// (avoids `12M`, `12 mins`, etc., and prevents ellipsis in the stats capsule).
String figmaFormatTripDurationLabel(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '—';
  final lower = t.toLowerCase();
  final minLiteral = RegExp(r'(\d+)\s*m(?:in)?s?\b').firstMatch(lower);
  if (minLiteral != null) return '${minLiteral.group(1)} min';
  final hourMin = RegExp(r'(\d+)\s*h(?:our)?s?\s*(\d+)\s*m').firstMatch(lower);
  if (hourMin != null) {
    final h = int.tryParse(hourMin.group(1)!);
    final m = int.tryParse(hourMin.group(2)!);
    if (h != null && m != null) return '${h * 60 + m} min';
  }
  final hoursOnly = RegExp(r'(\d+)\s*h(?:our)?s?\b').firstMatch(lower);
  if (hoursOnly != null) {
    final h = int.tryParse(hoursOnly.group(1)!);
    if (h != null) return '${h * 60} min';
  }
  final anyDigit = RegExp(r'(\d+)').firstMatch(t);
  if (anyDigit != null) return '${anyDigit.group(1)} min';
  return t;
}

/// Compact distance for the stats capsule (avoids ellipsis from long backend strings).
String figmaFormatTripDistanceLabel(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '—';
  final kmUnit = RegExp(r'([\d.,]+)\s*k\s*m', caseSensitive: false)
      .firstMatch(t.replaceAll(',', ''));
  if (kmUnit != null) {
    final v = double.tryParse(kmUnit.group(1)!);
    if (v != null) {
      if (v >= 100) return '${v.round()} km';
      return '${v.toStringAsFixed(1)} km';
    }
  }
  final bare = RegExp(r'([\d.,]+)').firstMatch(t.replaceAll(',', ''));
  if (bare != null) {
    final v = double.tryParse(bare.group(1)!);
    if (v != null) {
      if (v >= 100) return '${v.round()} km';
      return '${v.toStringAsFixed(1)} km';
    }
  }
  return t;
}

/// Drop-off + distance/time capsules (Frame 1410081818).
class FigmaTripSummaryCapsules extends StatelessWidget {
  const FigmaTripSummaryCapsules({
    super.key,
    required this.dropOffLabel,
    required this.dropOffAddress,
    this.distanceText = '',
    this.durationText = '',
    this.onDropOffTap,
  });

  final String dropOffLabel;
  final String dropOffAddress;
  final String distanceText;
  final String durationText;
  final VoidCallback? onDropOffTap;

  static const _pillShadow = BoxShadow(
    color: Color(0x33000000),
    offset: Offset(0, 4),
    blurRadius: 4,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        // Scale grows past 1.0 so the row uses full ListView width (no side gaps on wide phones).
        final scaleNorm = (avail / figmaTripPillsTotalWidth).clamp(0.85, double.infinity);
        final h = 29.0 * scaleNorm;
        // Figma proportions: 202 + 12 gap + 132 = 346
        final gap = 12.0 * (avail / figmaTripPillsTotalWidth);
        final wDrop = (202.0 / figmaTripPillsTotalWidth) * avail;
        final wStats = math.max(0.0, avail - wDrop - gap);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: wDrop,
                  height: h,
                  child: _DropOffCapsule(
                    label: dropOffLabel,
                    address: dropOffAddress,
                    onTap: onDropOffTap,
                    height: h,
                    scale: scaleNorm,
                  ),
                ),
                SizedBox(width: gap),
                SizedBox(
                  width: wStats,
                  height: h,
                  child: _TripStatsCapsule(
                    distanceText: distanceText,
                    durationText: durationText,
                    height: h,
                    scale: scaleNorm,
                  ),
                ),
              ],
            ),
            SizedBox(height: 14 * scaleNorm),
            Container(
              width: double.infinity,
              height: 1,
              color: const Color(0x1A000000),
            ),
            SizedBox(height: 10 * scaleNorm),
          ],
        );
      },
    );
  }
}

class _DropOffCapsule extends StatelessWidget {
  const _DropOffCapsule({
    required this.label,
    required this.address,
    required this.height,
    required this.scale,
    this.onTap,
  });

  final String label;
  final String address;
  final double height;
  final double scale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(150);
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [FigmaTripSummaryCapsules._pillShadow],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: r,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: r,
          child: Padding(
            padding: EdgeInsets.only(left: 6 * scale, right: 8 * scale),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.location_on,
                    size: 15 * scale, color: figmaRideAccent),
                SizedBox(width: 2 * scale),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 8 * scale,
                    fontWeight: FontWeight.w500,
                    height: 12 / 8,
                    color: const Color(0xFF5B5B5B),
                  ),
                ),
                Container(
                  width: 1,
                  height: 15 * scale,
                  margin: EdgeInsets.symmetric(horizontal: 5 * scale),
                  color: const Color(0xFF929292),
                ),
                Expanded(
                  child: Text(
                    address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w500,
                      height: 18 / 12,
                      color: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TripStatsCapsule extends StatelessWidget {
  const _TripStatsCapsule({
    required this.distanceText,
    required this.durationText,
    required this.height,
    required this.scale,
  });

  final String distanceText;
  final String durationText;
  final double height;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final dist = distanceText.isEmpty
        ? '—'
        : figmaFormatTripDistanceLabel(distanceText);
    final dur = figmaFormatTripDurationLabel(durationText);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(150),
        boxShadow: const [FigmaTripSummaryCapsules._pillShadow],
      ),
      padding: EdgeInsets.symmetric(horizontal: 6 * scale),
      child: Row(
        children: [
          Icon(Icons.route, size: 14 * scale, color: const Color(0xFF929292)),
          SizedBox(width: 3 * scale),
          Flexible(
            child: Text(
              dist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(
                fontSize: 12 * scale,
                fontWeight: FontWeight.w500,
                height: 18 / 12,
                color: Colors.black,
              ),
            ),
          ),
          Container(
            width: 1,
            height: 15 * scale,
            margin: EdgeInsets.symmetric(horizontal: 5 * scale),
            color: const Color(0xFF929292),
          ),
          Icon(Icons.hourglass_empty,
              size: 14 * scale, color: const Color(0xFF929292)),
          SizedBox(width: 3 * scale),
          Text(
            dur,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(
              fontSize: 12 * scale,
              fontWeight: FontWeight.w500,
              height: 18 / 12,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}

/// Figma vehicle row (346×81); selected = 2px #CF923D, unselected = borderless.
class FigmaVehicleOptionCard extends StatelessWidget {
  const FigmaVehicleOptionCard({
    super.key,
    required this.title,
    required this.imageAsset,
    required this.capacity,
    required this.eta,
    required this.priceText,
    required this.isSelected,
    required this.onTap,
    this.isRescue = false,
    this.rescueEyebrow,
    this.paymentNote,
    this.fallbackIcon,
  });

  final String title;
  final String imageAsset;
  final int capacity;
  final String eta;
  final String priceText;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isRescue;
  final String? rescueEyebrow;
  final String? paymentNote;
  final IconData? fallbackIcon;

  static const _cardShadows = [
    BoxShadow(
      color: Color(0x1A000000),
      offset: Offset(0, 4),
      blurRadius: 8,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth;
        final cardW = maxW;

        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Center(
            child: Container(
              width: cardW,
              height: 81,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: _cardShadows,
              ),
              child: Material(
                color: const Color(0xFFF9F8F6),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: isSelected
                      ? const BorderSide(color: figmaRideAccent, width: 2)
                      : BorderSide.none,
                ),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _VehicleThumb(
                          imageAsset: imageAsset,
                          isRescue: isRescue,
                          fallbackIcon: fallbackIcon,
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: math.max(
                            0.0,
                            cardW -
                                20 -
                                figmaVehicleThumbWidth -
                                10,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (isRescue) ...[
                                _RescueTitleBlock(
                                  eyebrow: rescueEyebrow ?? '',
                                  title: title,
                                  priceText: priceText,
                                ),
                              ] else
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: GoogleFonts.poppins(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                          height: 24 / 16,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      priceText,
                                      style: GoogleFonts.inter(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        height: 19 / 16,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              const SizedBox(height: 1),
                              _MetaRow(capacity: capacity, eta: eta),
                              if (paymentNote != null && !isRescue) ...[
                                const SizedBox(height: 5),
                                Text(
                                  paymentNote!,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    height: 17 / 14,
                                    letterSpacing: -0.42,
                                    color: const Color(0xFF5B5B5B),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Rescue: eyebrow Inter 12 / title Poppins 16 + price top-right (Figma Frame 1410081848).
class _RescueTitleBlock extends StatelessWidget {
  const _RescueTitleBlock({
    required this.eyebrow,
    required this.title,
    required this.priceText,
  });

  final String eyebrow;
  final String title;
  final String priceText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (eyebrow.isNotEmpty)
                    Text(
                      eyebrow,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 15 / 12,
                        color: Colors.black,
                      ),
                    ),
                  Text(
                    title,
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      height: 24 / 16,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              priceText,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 19 / 16,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _VehicleThumb extends StatelessWidget {
  const _VehicleThumb({
    required this.imageAsset,
    required this.isRescue,
    this.fallbackIcon,
  });

  final String imageAsset;
  final bool isRescue;
  final IconData? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    const thumbW = figmaVehicleThumbWidth;
    const thumbH = figmaVehicleThumbHeight;
    const r = figmaVehicleThumbRadius;
    final rescueBadgeTop = 53.0 * thumbH / 73.0;

    return SizedBox(
      width: thumbW,
      height: thumbH,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: ColoredBox(
              color: const Color(0xFFF9F8F6),
              child: Image.asset(
                imageAsset,
                width: thumbW,
                height: thumbH,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                errorBuilder: (_, __, ___) => Icon(
                  fallbackIcon ?? Icons.directions_car,
                  size: 32,
                  color: const Color(0xFF929292),
                ),
              ),
            ),
          ),
          if (isRescue)
            Positioned(
              left: 10,
              top: rescueBadgeTop,
              child: Container(
                constraints: const BoxConstraints(minWidth: 68, minHeight: 13),
                padding: const EdgeInsets.symmetric(horizontal: 8.3, vertical: 1.6),
                decoration: BoxDecoration(
                  color: const Color(0xFFB72F2F),
                  borderRadius: BorderRadius.circular(17.47),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Extra Drivers 👍🏻',
                  style: GoogleFonts.poppins(
                    fontSize: 8,
                    fontWeight: FontWeight.w500,
                    height: 12 / 8,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.capacity, required this.eta});

  final int capacity;
  final String eta;

  @override
  Widget build(BuildContext context) {
    final metaStyle = GoogleFonts.inter(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 15 / 12,
      color: const Color(0xFF292D32),
    );

    return Row(
      children: [
        Icon(Icons.people_outline, size: 12, color: const Color(0xFF292D32)),
        const SizedBox(width: 3),
        Text('$capacity', style: metaStyle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('·', style: metaStyle.copyWith(color: Colors.black)),
        ),
        Icon(Icons.access_time, size: 12, color: const Color(0xFF292D32)),
        const SizedBox(width: 3),
        Text(_MetaRow._shortEta(eta), style: metaStyle.copyWith(color: Colors.black)),
      ],
    );
  }

  static String _shortEta(String eta) {
    final t = eta.trim();
    if (t.isEmpty) return '—';
    final match = RegExp(r'(\d+)').firstMatch(t);
    if (match != null) return '${match.group(1)} min';
    return t;
  }
}

/// Single Material glyph — reads as one “>>”, not two squashed chevrons.
class _FigmaSlideThumbChevrons extends StatelessWidget {
  const _FigmaSlideThumbChevrons({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.keyboard_double_arrow_right_rounded,
      size: FigmaSlideToBookButton.thumbSize * 0.56,
      color: color,
    );
  }
}

/// Figma Frame 1410081852 — ~60px pill, 7px inset, thumb fills inner height (centered).
class FigmaSlideToBookButton extends StatefulWidget {
  const FigmaSlideToBookButton({
    super.key,
    required this.onSlideComplete,
    this.enabled = true,
  });

  final VoidCallback onSlideComplete;
  final bool enabled;

  static const Color trackColor = Color(0xFF2E2C2A);
  static const double trackHeight = 60;
  static const double trackPadding = 7;
  static const double thumbSize = trackHeight - (2 * trackPadding);

  @override
  State<FigmaSlideToBookButton> createState() => _FigmaSlideToBookButtonState();
}

class _FigmaSlideToBookButtonState extends State<FigmaSlideToBookButton>
    with SingleTickerProviderStateMixin {
  double _dragPosition = 0;
  bool _isCompleted = false;
  bool _thresholdHapticSent = false;
  late AnimationController _animationController;
  late Animation<double> _resetAnimation;

  static const double _threshold = 0.85;

  double _maxDrag(double innerW) => innerW - FigmaSlideToBookButton.thumbSize;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    if (!widget.enabled || _isCompleted) return;
    _thresholdHapticSent = false;
  }

  void _onPanUpdate(DragUpdateDetails details, double maxDrag) {
    if (!widget.enabled || _isCompleted || maxDrag <= 0) return;
    setState(() {
      _dragPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
    });
    if (!_thresholdHapticSent && _dragPosition / maxDrag >= _threshold) {
      _thresholdHapticSent = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _onPanEnd(DragEndDetails details, double maxDrag) {
    if (!widget.enabled || _isCompleted) return;
    _thresholdHapticSent = false;
    if (maxDrag > 0 && _dragPosition / maxDrag >= _threshold) {
      _completeSlide(maxDrag);
    } else {
      _resetSlider();
    }
  }

  Future<void> _completeSlide(double maxDrag) async {
    setState(() => _isCompleted = true);
    await Vibration.vibrate(duration: 50, amplitude: 128);

    final startPos = _dragPosition;
    _resetAnimation = Tween<double>(begin: startPos, end: maxDrag).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    _resetAnimation.addListener(() {
      if (mounted) setState(() => _dragPosition = _resetAnimation.value);
    });
    await _animationController.forward(from: 0);

    widget.onSlideComplete();

    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) {
      setState(() {
        _isCompleted = false;
        _dragPosition = 0;
      });
    }
  }

  void _resetSlider() {
    final startPos = _dragPosition;
    _resetAnimation = Tween<double>(begin: startPos, end: 0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    _resetAnimation.addListener(() {
      if (mounted) setState(() => _dragPosition = _resetAnimation.value);
    });
    _animationController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final outerW = constraints.maxWidth;
        final innerW = outerW - FigmaSlideToBookButton.trackPadding * 2;
        final maxDrag = _maxDrag(innerW);
        final progress = maxDrag > 0 ? (_dragPosition / maxDrag) : 0.0;
        final textOpacity = (1 - progress * 1.35).clamp(0.0, 1.0);

        const thumb = FigmaSlideToBookButton.thumbSize;

        return Center(
          child: SizedBox(
            width: outerW,
            height: FigmaSlideToBookButton.trackHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.enabled
                    ? FigmaSlideToBookButton.trackColor
                    : FigmaSlideToBookButton.trackColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(
                  FigmaSlideToBookButton.trackHeight / 2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(FigmaSlideToBookButton.trackPadding),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: Opacity(
                        opacity: textOpacity,
                        child: Text(
                          'Slide to Book now!',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            height: 1.0,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _dragPosition,
                      width: thumb,
                      height: thumb,
                      child: Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _onPanStart,
                          onPanUpdate: (d) => _onPanUpdate(d, maxDrag),
                          onPanEnd: (d) => _onPanEnd(d, maxDrag),
                          child: Container(
                            width: thumb,
                            height: thumb,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.102),
                                  offset: const Offset(0, 5.2028),
                                  blurRadius: 10.4056,
                                ),
                              ],
                            ),
                            child: Center(
                              child: _FigmaSlideThumbChevrons(
                                color: FigmaSlideToBookButton.trackColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
