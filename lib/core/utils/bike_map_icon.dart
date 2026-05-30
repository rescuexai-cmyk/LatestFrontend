import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'map_icon_edge_background.dart';

/// Dark pixels connected to the image border are treated as template background
/// and made transparent (removes the solid black plate around the bike).
Future<BitmapDescriptor?> loadBikeMapIconProcessed(
  String assetPath, {
  String debugLabel = 'bike',
}) {
  return bitmapDescriptorRemovingDarkEdgePlate(
    assetPath,
    debugLabel: debugLabel,
  );
}
