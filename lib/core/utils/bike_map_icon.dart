import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image/image.dart' as img;

/// Dark pixels connected to the image border are treated as template background
/// and made transparent (removes the solid black plate around the bike).
const _kFloodBgMaxChannel = 58;

/// Output size to match other vehicle map icons.
const _kMapIconSize = 120;

/// Removes black / near-black regions connected to the canvas edge (flood fill).
/// This fixes large rectangular black backgrounds that column-trimming missed.
Future<BitmapDescriptor?> loadBikeMapIconProcessed(
  String assetPath, {
  String debugLabel = 'bike',
}) async {
  try {
    final bytes = await rootBundle.load(assetPath);
    final original = img.decodeImage(bytes.buffer.asUint8List());
    if (original == null) return null;
    var image = original.convert(numChannels: 4);
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return null;

    _floodFillRemoveEdgeBackground(image, w, h);

    image = img.copyResize(
      image,
      width: _kMapIconSize,
      height: _kMapIconSize,
      interpolation: img.Interpolation.cubic,
    );
    final pngBytes = Uint8List.fromList(img.encodePng(image));
    return BitmapDescriptor.fromBytes(pngBytes);
  } catch (e, st) {
    debugPrint('$debugLabel map icon process failed: $e\n$st');
    return null;
  }
}

bool _isFloodBackground(img.Pixel p) {
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  return r <= _kFloodBgMaxChannel &&
      g <= _kFloodBgMaxChannel &&
      b <= _kFloodBgMaxChannel;
}

/// 4-connected flood from all border pixels through dark "background" pixels.
void _floodFillRemoveEdgeBackground(img.Image image, int w, int h) {
  final visited = List<bool>.filled(w * h, false);
  final queue = <int>[];

  void tryPush(int x, int y) {
    if (x < 0 || x >= w || y < 0 || y >= h) return;
    final i = y * w + x;
    if (visited[i]) return;
    if (!_isFloodBackground(image.getPixel(x, y))) return;
    visited[i] = true;
    queue.add(i);
  }

  for (var x = 0; x < w; x++) {
    tryPush(x, 0);
    tryPush(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    tryPush(0, y);
    tryPush(w - 1, y);
  }

  var qi = 0;
  while (qi < queue.length) {
    final i = queue[qi++];
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) tryPush(x - 1, y);
    if (x < w - 1) tryPush(x + 1, y);
    if (y > 0) tryPush(x, y - 1);
    if (y < h - 1) tryPush(x, y + 1);
  }

  for (var i = 0; i < visited.length; i++) {
    if (visited[i]) {
      final x = i % w;
      final y = i ~/ w;
      image.setPixelRgba(x, y, 0, 0, 0, 0);
    }
  }
}
