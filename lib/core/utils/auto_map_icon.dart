import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image/image.dart' as img;

/// Slightly taller than wide so the rickshaw reads a bit longer on the map.
const _kAutoWidth = 120;
const _kAutoHeight = 132;

/// Loads auto/rickshaw map icon with a modest vertical stretch (length).
Future<BitmapDescriptor?> loadAutoMapIconProcessed({
  String assetPath = 'assets/map_icons/icon_auto.png',
  String debugLabel = 'auto',
}) async {
  try {
    final bytes = await rootBundle.load(assetPath);
    final decoded = img.decodeImage(bytes.buffer.asUint8List());
    if (decoded == null) return null;
    var image = decoded.convert(numChannels: 4);
    image = img.copyResize(
      image,
      width: _kAutoWidth,
      height: _kAutoHeight,
      interpolation: img.Interpolation.cubic,
    );
    final pngBytes = Uint8List.fromList(img.encodePng(image));
    return BitmapDescriptor.fromBytes(pngBytes);
  } catch (e, st) {
    debugPrint('$debugLabel map icon process failed: $e\n$st');
    return null;
  }
}
