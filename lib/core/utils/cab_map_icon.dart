import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'map_icon_edge_background.dart';

/// Cab / sedan top-view asset without the solid black rectangular plate behind the car.
Future<BitmapDescriptor?> loadCabMapIconProcessed(
  String assetPath, {
  String debugLabel = 'cab',
}) {
  return bitmapDescriptorRemovingDarkEdgePlate(
    assetPath,
    debugLabel: debugLabel,
  );
}
