import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/services/places_service.dart';
import '../../../../core/widgets/figma_square_back_button.dart';
import '../../models/rescue_models.dart';
import '../../rescue_theme.dart';

/// Pickup / drop location sheet — Figma “Change Location” behaviour.
Future<RescuePlace?> showRescueLocationPicker(
  BuildContext context, {
  required String title,
  RescuePlace? initial,
  LatLng? bias,
}) {
  return showModalBottomSheet<RescuePlace>(
    context: context,
    isScrollControlled: true,
    backgroundColor: RescueTheme.screenBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _RescueLocationPickerSheet(
      title: title,
      initial: initial,
      bias: bias,
    ),
  );
}

class _RescueLocationPickerSheet extends StatefulWidget {
  const _RescueLocationPickerSheet({
    required this.title,
    this.initial,
    this.bias,
  });

  final String title;
  final RescuePlace? initial;
  final LatLng? bias;

  @override
  State<_RescueLocationPickerSheet> createState() =>
      _RescueLocationPickerSheetState();
}

class _RescueLocationPickerSheetState extends State<_RescueLocationPickerSheet> {
  final _controller = TextEditingController();
  final _places = PlacesService();
  Timer? _debounce;
  List<PlaceSearchResult> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _controller.text = widget.initial!.address;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _places.endSession();
    super.dispose();
  }

  Future<void> _search(String q) async {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _loading = true);
      try {
        final r = await _places.searchPlaces(q, location: widget.bias);
        if (mounted) setState(() => _results = r);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _loading = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition();
      final latLng = LatLng(pos.latitude, pos.longitude);
      var address = 'Current location';
      try {
        final marks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final p = marks.first;
          address = [p.street, p.subLocality, p.locality, p.administrativeArea, p.postalCode]
              .where((e) => e != null && e!.isNotEmpty)
              .join(', ');
        }
      } catch (_) {}
      _places.endSession();
      if (!mounted) return;
      Navigator.pop(
        context,
        RescuePlace(address: address, location: latLng),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(PlaceSearchResult place) async {
    setState(() => _loading = true);
    try {
      LatLng? latLng = place.latLng;
      if (latLng == null) {
        latLng = await _places.getPlaceDetails(place.placeId);
      }
      _places.endSession();
      if (latLng == null || !mounted) return;
      Navigator.pop(
        context,
        RescuePlace(
          address: place.address.isNotEmpty ? place.address : place.name,
          location: latLng,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: RescueTheme.stroke,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
              child: Row(
                children: [
                  FigmaSquareBackButton(onPressed: () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(widget.title, style: RescueTheme.titleMedium),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                onChanged: _search,
                decoration: RescueTheme.fieldDecoration('Search address'),
                style: RescueTheme.label,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Material(
                color: const Color(0xFFF0F8FF),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _loading ? null : _useCurrentLocation,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const Icon(Icons.my_location, color: Color(0xFF4285F4)),
                        const SizedBox(width: 12),
                        Text(
                          'Use current location',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w500,
                            color: RescueTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(color: RescueTheme.accent),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final p = _results[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined, color: RescueTheme.accent),
                    title: Text(p.name, style: RescueTheme.label),
                    subtitle: Text(
                      p.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RescueTheme.body.copyWith(fontSize: 13),
                    ),
                    onTap: () => _select(p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
