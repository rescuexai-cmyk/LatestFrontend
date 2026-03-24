import 'package:flutter/material.dart';

enum SwipeDirection { none, left, right }

class SwipeController extends ChangeNotifier {
  double dx = 0;
  double dy = 0;
  bool _isDragging = false;
  bool _hasTriggered = false;
  SwipeDirection _direction = SwipeDirection.none;
  
  static const double threshold = 120.0;
  static const double maxRotation = 0.05;
  static const double maxScaleReduction = 0.05;
  bool get isDragging => _isDragging;
  bool get hasTriggered => _hasTriggered;
  SwipeDirection get direction => _direction;
  
  double get rotation => (dx / 400) * maxRotation;
  
  double get scale => 1.0 - ((dx.abs() / 1000).clamp(0.0, maxScaleReduction));
  
  double get progress => (dx.abs() / threshold).clamp(0.0, 1.0);
  
  bool get isPastThreshold => dx.abs() >= threshold;
  
  SwipeDirection get pendingDirection {
    if (dx >= threshold) return SwipeDirection.right;
    if (dx <= -threshold) return SwipeDirection.left;
    return SwipeDirection.none;
  }
  
  Color get overlayColor {
    if (dx > 20) {
      return Colors.green.withOpacity((progress * 0.3).clamp(0.0, 0.3));
    } else if (dx < -20) {
      return Colors.red.withOpacity((progress * 0.3).clamp(0.0, 0.3));
    }
    return Colors.transparent;
  }
  
  String get overlayText {
    if (dx >= threshold) return 'ACCEPT';
    if (dx <= -threshold) return 'DECLINE';
    return '';
  }
  
  IconData? get overlayIcon {
    if (dx >= threshold) return Icons.check_circle;
    if (dx <= -threshold) return Icons.cancel;
    return null;
  }

  void onPanStart(DragStartDetails details) {
    _isDragging = true;
    _hasTriggered = false;
    notifyListeners();
  }

  void onPanUpdate(DragUpdateDetails details) {
    dx += details.delta.dx;
    dy += details.delta.dy;
    
    if (!_hasTriggered && isPastThreshold) {
      _hasTriggered = true;
    }
    
    notifyListeners();
  }

  SwipeDirection onPanEnd(DragEndDetails details) {
    _isDragging = false;
    
    if (isPastThreshold) {
      _direction = pendingDirection;
      notifyListeners();
      return _direction;
    }
    
    _direction = SwipeDirection.none;
    notifyListeners();
    return SwipeDirection.none;
  }

  void reset() {
    dx = 0;
    dy = 0;
    _isDragging = false;
    _hasTriggered = false;
    _direction = SwipeDirection.none;
    notifyListeners();
  }

  void setDismissPosition(SwipeDirection direction, double screenWidth) {
    dx = direction == SwipeDirection.right ? screenWidth : -screenWidth;
    _direction = direction;
    notifyListeners();
  }
}
