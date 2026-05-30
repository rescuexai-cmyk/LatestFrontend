import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

class SlideToActionButton extends StatefulWidget {
  final String text;
  final IconData icon;
  final Color backgroundColor;
  final Color sliderColor;
  final VoidCallback onSlideComplete;
  final bool enabled;
  final double height;
  final EdgeInsetsGeometry margin;

  const SlideToActionButton({
    super.key,
    required this.text,
    required this.icon,
    required this.onSlideComplete,
    this.backgroundColor = const Color(0xFF2196F3),
    this.sliderColor = Colors.white,
    this.enabled = true,
    this.height = 60,
    this.margin = const EdgeInsets.symmetric(horizontal: 24),
  });

  @override
  State<SlideToActionButton> createState() => _SlideToActionButtonState();
}

class _SlideToActionButtonState extends State<SlideToActionButton>
    with SingleTickerProviderStateMixin {
  double _dragPosition = 0;
  bool _isDragging = false;
  bool _isCompleted = false;
  late AnimationController _animationController;
  late Animation<double> _resetAnimation;

  /// Thumb slot width (includes horizontal inset padding on the track).
  static const double _sliderWidth = 60;
  static const double _padding = 4;
  static const double _threshold = 0.85;

  double _currentMaxDrag = 0;

  double get _thumbWidth => _sliderWidth - (_padding * 2);

  double _maxDragForTrack(double trackWidth) {
    return (trackWidth - _thumbWidth - (_padding * 2)).clamp(0.0, double.infinity);
  }

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
    setState(() => _isDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!widget.enabled || _isCompleted || _currentMaxDrag <= 0) return;

    setState(() {
      _dragPosition =
          (_dragPosition + details.delta.dx).clamp(0.0, _currentMaxDrag);
    });

    if (_dragPosition / _currentMaxDrag >= _threshold && !_isCompleted) {
      HapticFeedback.mediumImpact();
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (!widget.enabled || _isCompleted || _currentMaxDrag <= 0) return;

    setState(() => _isDragging = false);

    if (_dragPosition / _currentMaxDrag >= _threshold) {
      _completeSlide();
    } else {
      _resetSlider();
    }
  }

  void _completeSlide() async {
    setState(() => _isCompleted = true);

    await Vibration.vibrate(duration: 50, amplitude: 128);

    final startPos = _dragPosition;
    _resetAnimation = Tween<double>(
      begin: startPos,
      end: _currentMaxDrag,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _resetAnimation.addListener(() {
      if (mounted) {
        setState(() => _dragPosition = _resetAnimation.value);
      }
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
    _resetAnimation = Tween<double>(
      begin: startPos,
      end: 0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _resetAnimation.addListener(() {
      if (mounted) {
        setState(() => _dragPosition = _resetAnimation.value);
      }
    });

    _animationController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        color: widget.enabled
            ? widget.backgroundColor
            : widget.backgroundColor.withOpacity(0.5),
        borderRadius: BorderRadius.circular(widget.height / 2),
        boxShadow: [
          BoxShadow(
            color: widget.backgroundColor.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxDrag = _maxDragForTrack(constraints.maxWidth);
          _currentMaxDrag = maxDrag;
          final drag = _dragPosition.clamp(0.0, maxDrag);

          final progress =
              maxDrag > 0 ? (drag / maxDrag).clamp(0.0, 1.0) : 0.0;
          final textOpacity = (1 - progress * 1.5).clamp(0.0, 1.0);

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Center(
                child: Opacity(
                  opacity: textOpacity,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          widget.text,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.sliderColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward_ios,
                        color: widget.sliderColor.withOpacity(0.7),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: _padding + drag,
                top: _padding,
                child: GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: _thumbWidth,
                    height: widget.height - (_padding * 2),
                    decoration: BoxDecoration(
                      color: widget.sliderColor,
                      borderRadius: BorderRadius.circular(
                        (widget.height - (_padding * 2)) / 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              Colors.black.withOpacity(_isDragging ? 0.2 : 0.1),
                          blurRadius: _isDragging ? 8 : 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _isCompleted
                            ? Icon(
                                Icons.check,
                                key: const ValueKey('check'),
                                color: widget.backgroundColor,
                                size: 24,
                              )
                            : Icon(
                                widget.icon,
                                key: const ValueKey('icon'),
                                color: widget.backgroundColor,
                                size: 24,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!_isDragging && _dragPosition == 0 && widget.enabled)
                Positioned(
                  left: _sliderWidth + 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _ShimmerArrows(
                      color: widget.sliderColor.withOpacity(0.5),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ShimmerArrows extends StatefulWidget {
  final Color color;

  const _ShimmerArrows({required this.color});

  @override
  State<_ShimmerArrows> createState() => _ShimmerArrowsState();
}

class _ShimmerArrowsState extends State<_ShimmerArrows>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final delay = index * 0.2;
            final value = ((_animation.value - delay) % 1.0).clamp(0.0, 1.0);
            final opacity =
                (value < 0.5 ? value * 2 : (1 - value) * 2).clamp(0.2, 0.8);

            return Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(
                Icons.chevron_right,
                color: widget.color.withOpacity(opacity),
                size: 18,
              ),
            );
          }),
        );
      },
    );
  }
}
