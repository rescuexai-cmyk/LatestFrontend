import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import '../../../providers/driver_rides_provider.dart';
import '../controllers/swipe_controller.dart';

class RideCard extends StatefulWidget {
  final RideOffer ride;
  final int stackIndex;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool isTop;
  final int timeoutSeconds;

  const RideCard({
    super.key,
    required this.ride,
    required this.stackIndex,
    required this.onAccept,
    required this.onDecline,
    this.isTop = false,
    this.timeoutSeconds = 15,
  });

  @override
  State<RideCard> createState() => _RideCardState();
}

class _RideCardState extends State<RideCard> with SingleTickerProviderStateMixin {
  late final SwipeController _swipeController;
  late final AnimationController _animationController;
  late Animation<double> _resetAnimation;
  late Animation<Offset> _dismissAnimation;
  
  Timer? _countdownTimer;
  late int _secondsLeft;
  bool _isAnimating = false;
  bool _hasTriggeredHaptic = false;
  bool _isAccepting = false;

  static const _primaryGreen = Color(0xFF2ECC71);
  static const _accentTeal = Color(0xFF1ABC9C);
  static const _textDark = Color(0xFF2C3E50);
  static const _textGrey = Color(0xFF7F8C8D);
  static const _dividerColor = Color(0xFFECF0F1);

  @override
  void initState() {
    super.initState();
    _swipeController = SwipeController();
    _swipeController.addListener(_onSwipeUpdate);
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    
    _secondsLeft = widget.timeoutSeconds;
    if (widget.isTop) {
      _startCountdown();
    }
  }

  @override
  void didUpdateWidget(RideCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isTop && !oldWidget.isTop) {
      _startCountdown();
    } else if (!widget.isTop && oldWidget.isTop) {
      _countdownTimer?.cancel();
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _secondsLeft = widget.timeoutSeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsLeft--;
      });
      if (_secondsLeft <= 0) {
        timer.cancel();
        _handleAutoDecline();
      }
    });
  }

  void _handleAutoDecline() {
    if (!mounted || _isAnimating) return;
    _animateDismiss(SwipeDirection.left);
  }

  void _onSwipeUpdate() {
    if (!mounted) return;
    setState(() {});
    
    if (_swipeController.isPastThreshold && !_hasTriggeredHaptic) {
      _hasTriggeredHaptic = true;
      HapticFeedback.lightImpact();
    } else if (!_swipeController.isPastThreshold && _hasTriggeredHaptic) {
      _hasTriggeredHaptic = false;
    }
  }

  void _onPanStart(DragStartDetails details) {
    if (!widget.isTop || _isAnimating) return;
    _swipeController.onPanStart(details);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!widget.isTop || _isAnimating) return;
    _swipeController.onPanUpdate(details);
  }

  void _onPanEnd(DragEndDetails details) {
    if (!widget.isTop || _isAnimating) return;
    
    final direction = _swipeController.onPanEnd(details);
    
    if (direction != SwipeDirection.none) {
      _animateDismiss(direction);
    } else {
      _animateReset();
    }
  }

  void _animateReset() {
    _isAnimating = true;
    final startDx = _swipeController.dx;
    final startDy = _swipeController.dy;
    
    _resetAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    
    _animationController.reset();
    _animationController.forward().then((_) {
      if (mounted) {
        _swipeController.reset();
        _isAnimating = false;
      }
    });
    
    _resetAnimation.addListener(() {
      if (mounted) {
        final progress = _resetAnimation.value;
        _swipeController.dx = startDx * progress;
        _swipeController.dy = startDy * progress;
        setState(() {});
      }
    });
  }

  Future<void> _animateDismiss(SwipeDirection direction) async {
    _isAnimating = true;
    _countdownTimer?.cancel();
    
    final screenWidth = MediaQuery.of(context).size.width;
    final targetX = direction == SwipeDirection.right ? screenWidth * 1.5 : -screenWidth * 1.5;
    
    final startDx = _swipeController.dx;
    
    _dismissAnimation = Tween<Offset>(
      begin: Offset(startDx, _swipeController.dy),
      end: Offset(targetX, _swipeController.dy),
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutExpo,
      ),
    );
    
    _animationController.duration = const Duration(milliseconds: 180);
    _animationController.reset();
    
    _dismissAnimation.addListener(() {
      if (mounted) {
        _swipeController.dx = _dismissAnimation.value.dx;
        setState(() {});
      }
    });
    
    await _animationController.forward();
    
    if (mounted) {
      if (direction == SwipeDirection.right) {
        await Vibration.vibrate(duration: 50, amplitude: 128);
        widget.onAccept();
      } else {
        await Vibration.vibrate(duration: 30, amplitude: 64);
        widget.onDecline();
      }
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _swipeController.removeListener(_onSwipeUpdate);
    _swipeController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stackScale = 1.0 - (widget.stackIndex * 0.05);
    final stackTranslateY = widget.stackIndex * 10.0;
    
    final swipeScale = widget.isTop ? _swipeController.scale : 1.0;
    final swipeRotation = widget.isTop ? _swipeController.rotation : 0.0;
    final swipeDx = widget.isTop ? _swipeController.dx : 0.0;
    
    final finalScale = stackScale * swipeScale;

    return RepaintBoundary(
      child: Transform.translate(
        offset: Offset(swipeDx, stackTranslateY),
        child: Transform.rotate(
          angle: swipeRotation,
          child: Transform.scale(
            scale: finalScale,
            alignment: Alignment.center,
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: Stack(
                children: [
                  _buildCardContent(),
                  if (widget.isTop) _buildSwipeOverlay(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFD0D0D0),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with vehicle type
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text(
              _getVehicleTypeDisplay(widget.ride.type),
              style: TextStyle(
                color: _textGrey,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          
          // Earning section
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Earning',
                  style: TextStyle(
                    color: _textDark,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '₹${widget.ride.earning.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: _accentTeal,
                    fontSize: 42,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
          
          // Distance metrics
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: _dividerColor, width: 1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _buildDistanceRow(
                    label: 'Pickup\nDistance',
                    distance: widget.ride.pickupDistance,
                    time: widget.ride.pickupTime,
                    isPickup: true,
                  ),
                  Container(height: 1, color: _dividerColor),
                  _buildDistanceRow(
                    label: 'Drop\nDistance',
                    distance: widget.ride.dropDistance,
                    time: widget.ride.dropTime,
                    isPickup: false,
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Divider
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            height: 1,
            color: _dividerColor,
          ),
          
          const SizedBox(height: 16),
          
          // Pickup and Drop addresses - Flexible to adapt to text length
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Pickup
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
                          Flexible(
                            child: Text(
                              widget.ride.pickupAddress,
                              style: const TextStyle(
                                color: _textGrey,
                                fontSize: 12,
                                height: 1.3,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Arrow
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.arrow_forward,
                        color: _textGrey,
                        size: 18,
                      ),
                    ),
                    
                    // Drop
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
                          Flexible(
                            child: Text(
                              widget.ride.dropAddress,
                              style: const TextStyle(
                                color: _textGrey,
                                fontSize: 12,
                                height: 1.3,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 8),
          
          // Swipe hint at bottom
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: _SwipeHintBar(
              secondsLeft: _secondsLeft,
              totalSeconds: widget.timeoutSeconds,
            ),
          ),
        ],
      ),
    );
  }

  String _getVehicleTypeDisplay(String type) {
    final normalized = type.toLowerCase().replaceAll('_', ' ');
    if (normalized.contains('bike') && normalized.contains('rescue')) {
      return 'Bike Rescue';
    } else if (normalized.contains('bike')) {
      return 'Bike';
    } else if (normalized.contains('auto')) {
      return 'Auto';
    } else if (normalized.contains('mini')) {
      return 'Mini';
    } else if (normalized.contains('sedan')) {
      return 'Sedan';
    } else if (normalized.contains('suv')) {
      return 'SUV';
    }
    return type.split('_').map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '').join(' ');
  }

  String _calculateEta(String distanceStr) {
    // Parse distance from string like "1.5 km" or "500 m"
    final cleanStr = distanceStr.toLowerCase().trim();
    double distanceKm = 0;
    
    if (cleanStr.contains('km')) {
      final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
      distanceKm = double.tryParse(numStr) ?? 0;
    } else if (cleanStr.contains('m')) {
      final numStr = cleanStr.replaceAll(RegExp(r'[^0-9.]'), '');
      distanceKm = (double.tryParse(numStr) ?? 0) / 1000;
    } else {
      // Try parsing as plain number (assume km)
      distanceKm = double.tryParse(cleanStr.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
    }
    
    if (distanceKm <= 0) return '0 min';
    
    // Average speed assumption: 20 km/h in city traffic
    const avgSpeedKmh = 20.0;
    final etaMinutes = (distanceKm / avgSpeedKmh * 60).ceil();
    
    if (etaMinutes < 1) return '< 1 min';
    if (etaMinutes == 1) return '1 min';
    if (etaMinutes >= 60) {
      final hours = etaMinutes ~/ 60;
      final mins = etaMinutes % 60;
      return mins > 0 ? '$hours hr $mins min' : '$hours hr';
    }
    return '$etaMinutes min';
  }

  Widget _buildDistanceRow({
    required String label,
    required String distance,
    required String time,
    required bool isPickup,
  }) {
    // Calculate ETA from distance if time is not provided or is "0 min away"
    String displayTime = time;
    if (time.isEmpty || time == '0 min away' || time == '0 min') {
      final eta = _calculateEta(distance);
      displayTime = '$eta away';
    }
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                color: _textDark,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
          Container(
            width: 1,
            height: 30,
            color: _dividerColor,
            margin: const EdgeInsets.symmetric(horizontal: 16),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  distance,
                  style: TextStyle(
                    color: isPickup ? _textDark : _accentTeal,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  displayTime,
                  style: const TextStyle(
                    color: _textGrey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwipeOverlay() {
    final overlayColor = _swipeController.overlayColor;
    final overlayText = _swipeController.overlayText;
    final overlayIcon = _swipeController.overlayIcon;
    
    if (overlayColor == Colors.transparent) {
      return const SizedBox.shrink();
    }
    
    final isAccept = _swipeController.dx > 0;
    
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: isAccept 
              ? _primaryGreen.withOpacity(0.15) 
              : Colors.red.withOpacity(0.15),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Center(
          child: overlayText.isNotEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isAccept ? _primaryGreen : Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        overlayIcon,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      overlayText,
                      style: TextStyle(
                        color: isAccept ? _primaryGreen : Colors.red,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _SwipeHintBar extends StatefulWidget {
  final int secondsLeft;
  final int totalSeconds;

  const _SwipeHintBar({
    required this.secondsLeft,
    required this.totalSeconds,
  });

  @override
  State<_SwipeHintBar> createState() => _SwipeHintBarState();
}

class _SwipeHintBarState extends State<_SwipeHintBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _leftAnimation;
  late Animation<double> _rightAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    _leftAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 0.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    
    _rightAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 8.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (widget.secondsLeft / widget.totalSeconds).clamp(0.0, 1.0);
    final isUrgent = widget.secondsLeft <= 5;
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUrgent ? Colors.red.withOpacity(0.3) : const Color(0xFFE9ECEF),
        ),
      ),
      child: Column(
        children: [
          // Timer progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: const Color(0xFFE9ECEF),
              valueColor: AlwaysStoppedAnimation<Color>(
                isUrgent ? Colors.red : const Color(0xFF2ECC71),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Swipe hints
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Decline hint (left)
              AnimatedBuilder(
                animation: _leftAnimation,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_leftAnimation.value, 0),
                    child: child,
                  );
                },
                child: Row(
                  children: [
                    Icon(
                      Icons.chevron_left,
                      color: Colors.red.shade400,
                      size: 24,
                    ),
                    Icon(
                      Icons.chevron_left,
                      color: Colors.red.shade300,
                      size: 24,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Decline',
                      style: TextStyle(
                        color: Colors.red.shade400,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              
              // Timer in center
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isUrgent ? Colors.red : const Color(0xFF2ECC71),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${widget.secondsLeft}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              
              // Accept hint (right)
              AnimatedBuilder(
                animation: _rightAnimation,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_rightAnimation.value, 0),
                    child: child,
                  );
                },
                child: Row(
                  children: [
                    Text(
                      'Accept',
                      style: TextStyle(
                        color: const Color(0xFF2ECC71),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      color: const Color(0xFF2ECC71).withOpacity(0.7),
                      size: 24,
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: const Color(0xFF2ECC71),
                      size: 24,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

