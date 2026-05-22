import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../core/models/location.dart';
import '../../../../core/services/maps_service.dart';
import '../../../../core/theme/app_colors.dart';

class AddressSearchInput extends StatefulWidget {
  final String hint;
  final LocationCoordinate? currentLocation;
  final Function(LocationCoordinate, String) onLocationSelected;
  final bool showCurrentLocationButton;
  final bool autoFocus;

  const AddressSearchInput({
    super.key,
    required this.hint,
    this.currentLocation,
    required this.onLocationSelected,
    this.showCurrentLocationButton = false,
    this.autoFocus = false,
  });

  @override
  State<AddressSearchInput> createState() => _AddressSearchInputState();
}

class _AddressSearchInputState extends State<AddressSearchInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<PlaceSuggestion> _suggestions = [];
  bool _isLoading = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _debounceTimer?.cancel();
    
    if (value.length < 3) {
      setState(() => _suggestions = []);
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _searchPlaces(value);
    });
  }

  Future<void> _searchPlaces(String query) async {
    setState(() => _isLoading = true);

    try {
      final suggestions = await mapsService.getPlacesSuggestions(
        query,
        location: widget.currentLocation,
        radius: 50000,
      );
      setState(() => _suggestions = suggestions);
    } catch (e) {
      debugPrint('Error searching places: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectPlace(PlaceSuggestion suggestion) async {
    setState(() => _isLoading = true);

    try {
      final details = await mapsService.getPlaceDetails(suggestion.placeId);
      if (details != null) {
        _controller.text = suggestion.description;
        setState(() => _suggestions = []);
        _focusNode.unfocus();
        widget.onLocationSelected(
          LocationCoordinate(lat: details.lat, lng: details.lng),
          suggestion.description,
        );
      }
    } catch (e) {
      debugPrint('Error getting place details: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _useCurrentLocation() async {
    if (widget.currentLocation == null) return;

    setState(() => _isLoading = true);

    try {
      final address = await mapsService.reverseGeocode(
        widget.currentLocation!.lat,
        widget.currentLocation!.lng,
      );
      
      final displayAddress = address ?? 'Current Location';
      _controller.text = displayAddress;
      setState(() => _suggestions = []);
      widget.onLocationSelected(widget.currentLocation!, displayAddress);
    } catch (e) {
      debugPrint('Error getting current location address: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onTextChanged,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
            suffixIcon: _isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: AppColors.textSecondary),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _suggestions = []);
                        },
                      )
                    : null,
          ),
        ),
        
        if (widget.showCurrentLocationButton && _suggestions.isEmpty && _controller.text.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: InkWell(
              onTap: _useCurrentLocation,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.my_location, size: 20, color: AppColors.secondary),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Use current location',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ),
        
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 250),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final suggestion = _suggestions[index];
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.inputBackground,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.location_on_outlined, size: 20, color: AppColors.textSecondary),
                  ),
                  title: Text(
                    suggestion.mainText,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    suggestion.secondaryText,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _selectPlace(suggestion),
                );
              },
            ),
          ),
      ],
    );
  }
}






