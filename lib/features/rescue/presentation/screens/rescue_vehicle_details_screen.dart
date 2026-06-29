import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

class RescueVehicleDetailsScreen extends ConsumerStatefulWidget {
  const RescueVehicleDetailsScreen({super.key});

  @override
  ConsumerState<RescueVehicleDetailsScreen> createState() =>
      _RescueVehicleDetailsScreenState();
}

class _RescueVehicleDetailsScreenState
    extends ConsumerState<RescueVehicleDetailsScreen> {
  late RescueVehicleCategory _category;
  late RescueTransmission _transmission;
  final _regController = TextEditingController();
  final _issuesController = TextEditingController();
  final _picker = ImagePicker();
  Map<RescuePhotoSlot, String> _photos = {};

  @override
  void initState() {
    super.initState();
    final d = ref.read(rescueBookingProvider).vehicleDetails;
    _category = d.category;
    _transmission = d.transmission;
    _regController.text = d.registrationNumber;
    _issuesController.text = d.issuesNote;
    _photos = Map.from(d.photos);
  }

  @override
  void dispose() {
    _regController.dispose();
    _issuesController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(RescuePhotoSlot slot) async {
    final file = await _picker.pickImage(source: ImageSource.camera);
    if (file == null) return;
    setState(() => _photos[slot] = file.path);
  }

  void _continue() {
    final details = RescueVehicleDetails(
      category: _category,
      registrationNumber: _regController.text.trim(),
      transmission: _transmission,
      issuesNote: _issuesController.text.trim(),
      photos: _photos,
    );
    if (!details.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enter a valid registration number',
              style: RescueTheme.body.copyWith(color: Colors.white)),
          backgroundColor: RescueTheme.accent,
        ),
      );
      return;
    }
    ref.read(rescueBookingProvider.notifier).setVehicleDetails(details);
    context.push(AppRoutes.rescueDestination);
  }

  @override
  Widget build(BuildContext context) {
    return RescueScaffold(
      title: 'Vehicle details',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('Tell us about your vehicle', style: RescueTheme.body),
          const SizedBox(height: 16),
          Text('Vehicle type', style: RescueTheme.label),
          const SizedBox(height: 10),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: RescueVehicleCategory.values.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final cat = RescueVehicleCategory.values[i];
                final sel = _category == cat;
                return GestureDetector(
                  onTap: () => setState(() => _category = cat),
                  child: Container(
                    width: 80,
                    decoration: BoxDecoration(
                      color: sel ? Colors.white : RescueTheme.cardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: sel ? RescueTheme.accent : RescueTheme.stroke,
                        width: sel ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(cat.asset, height: 32, errorBuilder: (_, __, ___) =>
                            Icon(Icons.directions_car, color: RescueTheme.accent)),
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              cat.label,
                              style: RescueTheme.body.copyWith(fontSize: 11),
                              maxLines: 1,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          Text('Registration number', style: RescueTheme.label),
          const SizedBox(height: 8),
          TextField(
            controller: _regController,
            textCapitalization: TextCapitalization.characters,
            decoration: RescueTheme.fieldDecoration('e.g. MP04 XX 1234'),
            style: RescueTheme.label,
          ),
          const SizedBox(height: 18),
          Text('Transmission', style: RescueTheme.label),
          const SizedBox(height: 10),
          SegmentedButton<RescueTransmission>(
            segments: const [
              ButtonSegment(value: RescueTransmission.manual, label: Text('Manual')),
              ButtonSegment(value: RescueTransmission.automatic, label: Text('Automatic')),
            ],
            selected: {_transmission},
            onSelectionChanged: (s) => setState(() => _transmission = s.first),
          ),
          const SizedBox(height: 18),
          Text('Add photos', style: RescueTheme.label),
          const SizedBox(height: 10),
          Row(
            children: [
              RescuePhotoPickerTile(
                label: 'Front',
                path: _photos[RescuePhotoSlot.front],
                onTap: () => _pickPhoto(RescuePhotoSlot.front),
              ),
              const SizedBox(width: 8),
              RescuePhotoPickerTile(
                label: 'Back',
                path: _photos[RescuePhotoSlot.back],
                onTap: () => _pickPhoto(RescuePhotoSlot.back),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              RescuePhotoPickerTile(
                label: 'Left',
                path: _photos[RescuePhotoSlot.left],
                onTap: () => _pickPhoto(RescuePhotoSlot.left),
              ),
              const SizedBox(width: 8),
              RescuePhotoPickerTile(
                label: 'Right',
                path: _photos[RescuePhotoSlot.right],
                onTap: () => _pickPhoto(RescuePhotoSlot.right),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text('Any issues?', style: RescueTheme.label),
          const SizedBox(height: 8),
          TextField(
            controller: _issuesController,
            maxLines: 3,
            decoration: RescueTheme.fieldDecoration(
              'Flat tyre, overheating, damage, etc.',
            ),
            style: RescueTheme.body.copyWith(color: RescueTheme.textPrimary),
          ),
        ],
      ),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          style: RescueTheme.primaryButton,
          onPressed: _continue,
          child: const Text('Continue'),
        ),
      ),
    );
  }
}
