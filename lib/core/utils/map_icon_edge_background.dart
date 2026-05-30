import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image/image.dart' as img;

/// Dark pixels touching the canvas border count as template background plate.
/// Flood-removing them fixes large rectangular black squares behind PNG map icons.
const _kEdgePlateBgMaxChannel = 58;

/// Decode asset, flood-remove edge-connected dark background, resize, encode PNG.
Future<BitmapDescriptor?> bitmapDescriptorRemovingDarkEdgePlate(
  String assetPath, {
  String debugLabel = 'map_icon',
  int outputSize = 120,
}) async {
  try {
    final bytes = await rootBundle.load(assetPath);
    final original = img.decodeImage(bytes.buffer.asUint8List());
    if (original == null) return null;
    var image = original.convert(numChannels: 4);
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return null;

    _floodFillRemoveDarkEdgePlate(image, w, h);

    image = img.copyResize(
      image,
      width: outputSize,
      height: outputSize,
      interpolation: img.Interpolation.cubic,
    );
    final pngBytes = Uint8List.fromList(img.encodePng(image));
    return BitmapDescriptor.fromBytes(pngBytes);
  } catch (e, st) {
    debugPrint('$debugLabel map edge-plate strip failed: $e\n$st');
    return null;
  }
}

bool _isEdgePlatePixel(img.Pixel p) {
  final r = p.r.toInt();
  final g = p.g.toInt();
  final b = p.b.toInt();
  return r <= _kEdgePlateBgMaxChannel &&
      g <= _kEdgePlateBgMaxChannel &&
      b <= _kEdgePlateBgMaxChannel;
}

void _floodFillRemoveDarkEdgePlate(img.Image image, int w, int h) {
  final visited = List<bool>.filled(w * h, false);
  final queue = <int>[];

  void tryPush(int x, int y) {
    if (x < 0 || x >= w || y < 0 || y >= h) return;
    final i = y * w + x;
    if (visited[i]) return;
    if (!_isEdgePlatePixel(image.getPixel(x, y))) return;
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
    if (!visited[i]) continue;
    final x = i % w;
    final y = i ~/ w;
    image.setPixelRgba(x, y, 0, 0, 0, 0);
  }
}
