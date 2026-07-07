import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Canvas-drawn map markers for the trip endpoints, Uber-style:
/// - pickup: small dark dot with a white ring and a soft halo
/// - destination: small rounded square "pin" on a short stem
///
/// Drawn at device pixel ratio so they stay crisp on any screen.
class TripEndpointIcons {
  TripEndpointIcons._();

  static const _ink = Color(0xFF1A1A1A);

  /// Small "current position" circle for the pickup point.
  /// Anchor with Offset(0.5, 0.5).
  static Future<BitmapDescriptor> pickupDot({
    required double devicePixelRatio,
    double logicalSize = 26,
  }) async {
    final size = logicalSize * devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);

    // Soft halo
    canvas.drawCircle(
      center,
      size * 0.50,
      Paint()..color = _ink.withValues(alpha: 0.10),
    );
    // White ring
    canvas.drawCircle(
      center,
      size * 0.30,
      Paint()..color = Colors.white,
    );
    // Inner solid dot
    canvas.drawCircle(
      center,
      size * 0.19,
      Paint()..color = _ink,
    );

    return _toDescriptor(recorder, size.ceil(), size.ceil(), devicePixelRatio);
  }

  /// Destination "drop pin": rounded black square with a white dot,
  /// on a short stem. Anchor with Offset(0.5, 1.0) so the stem tip
  /// touches the exact drop coordinate.
  static Future<BitmapDescriptor> dropPin({
    required double devicePixelRatio,
    double logicalWidth = 24,
    double logicalHeight = 38,
  }) async {
    final w = logicalWidth * devicePixelRatio;
    final h = logicalHeight * devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final headSide = w * 0.92;
    final headRect = Rect.fromLTWH((w - headSide) / 2, 0, headSide, headSide);
    final stemWidth = w * 0.12;

    // Stem from head to the anchor point at the bottom.
    canvas.drawRect(
      Rect.fromLTWH((w - stemWidth) / 2, headSide * 0.9, stemWidth,
          h - headSide * 0.9),
      Paint()..color = _ink,
    );
    // Subtle ground shadow at the tip.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w / 2, h - w * 0.04),
        width: w * 0.42,
        height: w * 0.12,
      ),
      Paint()..color = _ink.withValues(alpha: 0.18),
    );
    // Rounded square head.
    canvas.drawRRect(
      RRect.fromRectAndRadius(headRect, Radius.circular(headSide * 0.22)),
      Paint()..color = _ink,
    );
    // White inner dot.
    canvas.drawCircle(
      headRect.center,
      headSide * 0.18,
      Paint()..color = Colors.white,
    );

    return _toDescriptor(recorder, w.ceil(), h.ceil(), devicePixelRatio);
  }

  static Future<BitmapDescriptor> _toDescriptor(
    ui.PictureRecorder recorder,
    int width,
    int height,
    double devicePixelRatio,
  ) async {
    final image = await recorder.endRecording().toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    // imagePixelRatio tells the map the bitmap is drawn at DPR scale, so it
    // renders at the intended logical size instead of raw pixel size.
    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: devicePixelRatio,
    );
  }
}
