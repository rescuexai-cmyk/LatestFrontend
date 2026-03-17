import 'package:flutter/material.dart';
import '../../../../core/models/driver.dart';
import '../../../../core/models/location.dart';
import '../../../../core/models/ride.dart';
import '../../../../core/services/maps_service.dart';
import '../../../../core/theme/app_colors.dart';
import 'address_search_input.dart';

enum BookingStep { pickup, destination, booking }

class RideType {
  final String id;
  final String name;
  final IconData icon;
  final String description;
  final int capacity;
  final double priceMultiplier;
  final int eta;
  final bool available;
  final int availableDrivers;
  final Driver? closestDriver;
  final double? averageRating;
  final bool isFastest;

  const RideType({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.capacity,
    required this.priceMultiplier,
    this.eta = 5,
    this.available = false,
    this.availableDrivers = 0,
    this.closestDriver,
    this.averageRating,
    this.isFastest = false,
  });
}

class RideBookingCard extends StatefulWidget {
  final bool isVisible;
  final VoidCallback onClose;
  final Function(LocationCoordinate, String) onPickupSelect;
  final Function(LocationCoordinate, String) onDestinationSelect;
  final Function(String, FareEstimate) onRideBooking;
  final LocationCoordinate? pickupLocation;
  final LocationCoordinate? destinationLocation;
  final String pickupAddress;
  final String destinationAddress;
  final LocationCoordinate? currentLocation;
  final List<Driver> availableDrivers;
  final bool isLoadingDrivers;

  const RideBookingCard({
    super.key,
    required this.isVisible,
    required this.onClose,
    required this.onPickupSelect,
    required this.onDestinationSelect,
    required this.onRideBooking,
    this.pickupLocation,
    this.destinationLocation,
    this.pickupAddress = '',
    this.destinationAddress = '',
    this.currentLocation,
    this.availableDrivers = const [],
    this.isLoadingDrivers = false,
  });

  @override
  State<RideBookingCard> createState() => _RideBookingCardState();
}

class _RideBookingCardState extends State<RideBookingCard> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  
  BookingStep _currentStep = BookingStep.pickup;
  String _selectedRideType = 'economy';
  Map<String, FareEstimate> _fareEstimates = {};
  List<RideType> _rideTypes = [];
  bool _isLoading = false;

  static const List<RideType> _baseRideTypes = [
    RideType(id: 'bike', name: 'RideBike', icon: Icons.two_wheeler, description: 'Quick and affordable bike rides', capacity: 1, priceMultiplier: 0.6),
    RideType(id: 'economy', name: 'RideGo', icon: Icons.directions_car, description: 'Affordable everyday rides', capacity: 4, priceMultiplier: 1.0),
    RideType(id: 'comfort', name: 'RideComfort', icon: Icons.directions_car_filled, description: 'Newer cars with extra legroom', capacity: 4, priceMultiplier: 1.3),
    RideType(id: 'premium', name: 'RidePremium', icon: Icons.diamond, description: 'High-end cars and top drivers', capacity: 4, priceMultiplier: 1.8),
    RideType(id: 'xl', name: 'RideXL', icon: Icons.airport_shuttle, description: 'Larger vehicles for groups', capacity: 6, priceMultiplier: 1.5),
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOut));

    if (widget.isVisible) {
      _animationController.forward();
    }
    _generateRideTypes();
  }

  @override
  void didUpdateWidget(RideBookingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    }

    if (widget.pickupLocation != oldWidget.pickupLocation ||
        widget.destinationLocation != oldWidget.destinationLocation) {
      _updateStep();
      if (widget.pickupLocation != null && widget.destinationLocation != null) {
        _calculateFareEstimates();
      }
    }

    if (widget.availableDrivers != oldWidget.availableDrivers) {
      _generateRideTypes();
    }
  }

  void _updateStep() {
    if (widget.pickupLocation != null && widget.destinationLocation != null) {
      setState(() => _currentStep = BookingStep.booking);
    } else if (widget.pickupLocation != null) {
      setState(() => _currentStep = BookingStep.destination);
    } else {
      setState(() => _currentStep = BookingStep.pickup);
    }
  }

  void _generateRideTypes() {
    final generatedTypes = _baseRideTypes.map((baseType) {
      final driversForType = widget.availableDrivers.where((d) => 
        d.vehicleInfo?.type.toLowerCase() == baseType.id || baseType.id == 'economy'
      ).toList();

      final avgRating = driversForType.isNotEmpty
          ? driversForType.map((d) => d.rating).reduce((a, b) => a + b) / driversForType.length
          : 4.0;

      return RideType(
        id: baseType.id,
        name: baseType.name,
        icon: baseType.icon,
        description: baseType.description,
        capacity: baseType.capacity,
        priceMultiplier: baseType.priceMultiplier,
        eta: 5,
        available: driversForType.isNotEmpty,
        availableDrivers: driversForType.length,
        closestDriver: driversForType.isNotEmpty ? driversForType.first : null,
        averageRating: avgRating,
        isFastest: baseType.id == 'bike' && driversForType.isNotEmpty,
      );
    }).toList();

    setState(() {
      _rideTypes = generatedTypes;
      final firstAvailable = generatedTypes.firstWhere((rt) => rt.available, orElse: () => generatedTypes.first);
      _selectedRideType = firstAvailable.id;
    });
  }

  Future<void> _calculateFareEstimates() async {
    if (widget.pickupLocation == null || widget.destinationLocation == null) return;

    setState(() => _isLoading = true);

    try {
      final directions = await mapsService.getDirections(
        widget.pickupLocation!,
        widget.destinationLocation!,
      );

      if (directions != null) {
        final estimates = <String, FareEstimate>{};
        for (final rideType in _rideTypes) {
          final baseEstimate = mapsService.calculateFareEstimate(
            directions.distanceValue.toDouble(),
            directions.durationValue.toDouble(),
            rideType: rideType.id,
          );
          estimates[rideType.id] = FareEstimate(
            rideType: rideType.id,
            baseFare: baseEstimate.baseFare,
            distanceFare: baseEstimate.distanceFare * rideType.priceMultiplier,
            timeFare: baseEstimate.timeFare * rideType.priceMultiplier,
            subtotal: baseEstimate.subtotal * rideType.priceMultiplier,
            taxes: baseEstimate.taxes * rideType.priceMultiplier,
            total: baseEstimate.total * rideType.priceMultiplier,
            currency: baseEstimate.currency,
            estimatedDistance: baseEstimate.estimatedDistance,
            estimatedDuration: baseEstimate.estimatedDuration,
            distance: baseEstimate.distance,
            estimatedTime: baseEstimate.estimatedTime,
          );
        }
        setState(() => _fareEstimates = estimates);
      }
    } catch (e) {
      debugPrint('Error calculating fares: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _handleBookRide() {
    final selectedFare = _fareEstimates[_selectedRideType];
    if (selectedFare != null) {
      widget.onRideBooking(_selectedRideType, selectedFare);
    }
  }

  String _formatPrice(double price) => '₹${price.round()}';
  String _formatETA(int minutes) => '$minutes min';

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) return const SizedBox.shrink();

    return SlideTransition(
      position: _slideAnimation,
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(),
            _buildHeader(),
            Flexible(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          if (_currentStep == BookingStep.booking)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _currentStep = BookingStep.destination),
            ),
          Expanded(
            child: Text(
              'Book a Ride',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_currentStep) {
      case BookingStep.pickup:
        return _buildPickupStep();
      case BookingStep.destination:
        return _buildDestinationStep();
      case BookingStep.booking:
        return _buildBookingStep();
    }
  }

  Widget _buildPickupStep() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Where are you?', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          AddressSearchInput(
            hint: 'Enter pickup location',
            currentLocation: widget.currentLocation,
            onLocationSelected: widget.onPickupSelect,
            showCurrentLocationButton: true,
          ),
        ],
      ),
    );
  }

  Widget _buildDestinationStep() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 12, height: 12, decoration: const BoxDecoration(color: AppColors.pickupMarker, shape: BoxShape.circle)),
              const SizedBox(width: 16),
              Expanded(child: Text(widget.pickupAddress.isNotEmpty ? widget.pickupAddress : 'Pickup location', overflow: TextOverflow.ellipsis)),
            ],
          ),
          Container(margin: const EdgeInsets.only(left: 5), width: 2, height: 20, color: AppColors.border),
          Row(
            children: [
              Container(width: 12, height: 12, decoration: const BoxDecoration(color: AppColors.dropoffMarker, shape: BoxShape.circle)),
              const SizedBox(width: 16),
              Expanded(
                child: AddressSearchInput(
                  hint: 'Where to?',
                  currentLocation: widget.pickupLocation,
                  onLocationSelected: widget.onDestinationSelect,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBookingStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Choose a ride', style: Theme.of(context).textTheme.titleLarge),
              if (widget.isLoadingDrivers)
                Row(
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.secondary)),
                    const SizedBox(width: 8),
                    Text('Updating...', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.secondary)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          ..._rideTypes.map((rideType) => _buildRideTypeCard(rideType)),
          if (_fareEstimates[_selectedRideType] != null) ...[
            const SizedBox(height: 20),
            _buildFareBreakdown(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _handleBookRide,
                child: Text('Book ${_rideTypes.firstWhere((rt) => rt.id == _selectedRideType).name}'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRideTypeCard(RideType rideType) {
    final isSelected = _selectedRideType == rideType.id;
    final fareEstimate = _fareEstimates[rideType.id];

    return GestureDetector(
      onTap: rideType.available ? () => setState(() => _selectedRideType = rideType.id) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.secondary.withOpacity(0.05) : Colors.white,
          border: Border.all(color: isSelected ? AppColors.secondary : AppColors.border, width: isSelected ? 2 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Opacity(
          opacity: rideType.available ? 1 : 0.5,
          child: Row(
            children: [
              Stack(
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(color: AppColors.inputBackground, borderRadius: BorderRadius.circular(24)),
                    child: Icon(rideType.icon, size: 28, color: isSelected ? AppColors.secondary : AppColors.textSecondary),
                  ),
                  if (rideType.availableDrivers > 0)
                    Positioned(
                      top: -4, right: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(10)),
                        child: Text('${rideType.availableDrivers}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(rideType.name, style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? AppColors.secondary : AppColors.textPrimary)),
                        if (rideType.isFastest) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(4)),
                            child: const Text('FASTEST', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                          ),
                        ],
                        const Spacer(),
                        if (rideType.averageRating != null)
                          Row(
                            children: [
                              const Icon(Icons.star, size: 12, color: AppColors.starYellow),
                              const SizedBox(width: 2),
                              Text(rideType.averageRating!.toStringAsFixed(1), style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                      ],
                    ),
                    Text(rideType.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text('${rideType.capacity} seats', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textHint)),
                        if (rideType.available && rideType.eta > 0) ...[
                          const Text(' • ', style: TextStyle(color: AppColors.textHint)),
                          Text(_formatETA(rideType.eta), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.secondary, fontWeight: FontWeight.w500)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_isLoading)
                    Text('...', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textHint))
                  else if (fareEstimate != null)
                    Text(_formatPrice(fareEstimate.total), style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? AppColors.secondary : AppColors.textPrimary))
                  else
                    Text('N/A', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textHint)),
                  Text(
                    rideType.available ? '${rideType.availableDrivers} available' : 'No drivers',
                    style: TextStyle(fontSize: 12, color: rideType.available ? AppColors.success : AppColors.error),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFareBreakdown() {
    final fare = _fareEstimates[_selectedRideType]!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.inputBackground, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fare Breakdown', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _buildFareRow('Base fare', fare.baseFare),
          _buildFareRow('Distance', fare.distanceFare),
          _buildFareRow('Time', fare.timeFare),
          _buildFareRow('Taxes', fare.taxes),
          const Divider(),
          _buildFareRow('Total', fare.total, isTotal: true),
        ],
      ),
    );
  }

  Widget _buildFareRow(String label, double value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal)),
          Text(_formatPrice(value), style: TextStyle(fontWeight: isTotal ? FontWeight.w600 : FontWeight.w500)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}






