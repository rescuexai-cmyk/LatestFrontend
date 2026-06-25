import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/router/app_routes.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_booking_provider.dart';
import '../../rescue_theme.dart';
import '../widgets/rescue_flow_widgets.dart';
import '../widgets/rescue_widgets.dart';

/// Figma screen 9 — Journey Hub with Journey / Vehicle / Support / Timeline tabs.
class RescueJourneyHubScreen extends ConsumerStatefulWidget {
  const RescueJourneyHubScreen({super.key, this.rescueId});

  final String? rescueId;

  @override
  ConsumerState<RescueJourneyHubScreen> createState() =>
      _RescueJourneyHubScreenState();
}

class _RescueJourneyHubScreenState extends ConsumerState<RescueJourneyHubScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  Timer? _pollTimer;
  RescueProgressSnapshot? _progress;
  List<RescueTimelineEvent> _timelineEvents = [];
  bool _sosTriggered = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final id = widget.rescueId;
      if (id != null && id.isNotEmpty) {
        ref.read(rescueBookingProvider.notifier).setRescueId(id);
      }
      _poll();
      _loadTimeline();
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        _poll();
        _loadTimeline();
      });
    });
  }

  Future<void> _poll() async {
    final id = ref.read(rescueBookingProvider).rescueId;
    if (id == null) return;
    try {
      final p = await ref.read(rescueBookingProvider.notifier).fetchProgress();
      if (!mounted) return;
      setState(() {
        _progress = p;
        _sosTriggered = p.rescue.sosTriggered;
      });
      if (p.rescue.isCompleted) {
        _pollTimer?.cancel();
        if (ref.read(rescueBookingProvider).hasVehicle &&
            !ref.read(rescueBookingProvider).deliveryCompleted) {
          context.go(AppRoutes.rescueDelivery);
        } else {
          context.go(AppRoutes.rescueComplete);
        }
      }
    } catch (_) {}
  }

  Future<void> _loadTimeline() async {
    try {
      final events =
          await ref.read(rescueBookingProvider.notifier).getTimeline();
      if (!mounted) return;
      setState(() => _timelineEvents = events);
    } catch (_) {}
  }

  Future<void> _triggerSOS() async {
    if (_sosTriggered) return;
    try {
      await ref.read(rescueBookingProvider.notifier).triggerSOS(
            notes: 'User triggered SOS from Journey Hub',
          );
      if (!mounted) return;
      setState(() => _sosTriggered = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('SOS triggered — support will contact you shortly')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to trigger SOS: $e')),
      );
    }
  }

  Future<void> _cancelRescue() async {
    final status = _progress?.rescue.status ?? 'PENDING';
    final canCancel = status == 'PENDING' ||
        status == 'DRIVER1_ACCEPTED' ||
        status == 'BOTH_ACCEPTED' ||
        status == 'DRIVERS_EN_ROUTE';

    if (!canCancel) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot cancel — rescue is already in progress'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel rescue?', style: RescueTheme.titleMedium),
        content: Text(
          'Are you sure you want to cancel this rescue? Drivers may already be on their way.',
          style: RescueTheme.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep rescue'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Cancel', style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(rescueBookingProvider.notifier).cancelRescue(
            reason: 'Cancelled by rider from Journey Hub',
          );
      if (!mounted) return;
      ref.read(rescueBookingProvider.notifier).reset();
      context.go(AppRoutes.services);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not cancel rescue. Please try again.')),
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rescueBookingProvider);
    final pickup = s.pickup?.location ?? const LatLng(23.2599, 77.4126);
    final status = _progress?.rescue.status ?? s.summary?.status ?? 'PENDING';
    final stepIdx = rescueTimelineIndexForStatus(status, hasVehicle: s.hasVehicle);

    final canCancel = status == 'PENDING' ||
        status == 'DRIVER1_ACCEPTED' ||
        status == 'BOTH_ACCEPTED' ||
        status == 'DRIVERS_EN_ROUTE';

    return Scaffold(
      backgroundColor: RescueTheme.screenBg,
      appBar: AppBar(
        backgroundColor: RescueTheme.screenBg,
        elevation: 0,
        foregroundColor: RescueTheme.textPrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go(AppRoutes.services);
            }
          },
        ),
        title: Text('Journey Hub', style: RescueTheme.titleMedium),
        actions: [
          if (canCancel)
            TextButton(
              onPressed: _cancelRescue,
              child: Text(
                'Cancel',
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: RescueTheme.accent,
          unselectedLabelColor: RescueTheme.textMuted,
          indicatorColor: RescueTheme.accent,
          tabs: const [
            Tab(text: 'Journey'),
            Tab(text: 'Vehicle'),
            Tab(text: 'Support'),
            Tab(text: 'Timeline'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _journeyTab(pickup, s),
          _vehicleTab(s),
          _supportTab(s),
          _timelineTab(s, stepIdx),
        ],
      ),
    );
  }

  Widget _journeyTab(LatLng pickup, RescueBookingState s) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          height: 180,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: pickup, zoom: 13),
              markers: {Marker(markerId: const MarkerId('p'), position: pickup)},
              zoomControlsEnabled: false,
            ),
          ),
        ),
        const SizedBox(height: 14),
        RescueStatusCard(
          title: 'Passenger journey',
          subtitle: '${_progress?.userDriverName ?? 'Rider'} • ${_progress?.userEtaMin ?? '—'} min ETA',
        ),
        if (s.hasVehicle) ...[
          const SizedBox(height: 10),
          RescueStatusCard(
            title: 'Vehicle journey',
            subtitle:
                '${_progress?.vehicleDriverName ?? 'Driver'} • ${_progress?.vehicleEtaMin ?? '—'} min ETA',
            icon: Icons.directions_car_outlined,
          ),
        ],
      ],
    );
  }

  Widget _vehicleTab(RescueBookingState s) {
    final photos = s.vehicleDetails.photos;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Vehicle: ${s.vehicleDetails.registrationNumber}', style: RescueTheme.label),
        const SizedBox(height: 12),
        if (photos.isEmpty)
          Text('No pickup photos', style: RescueTheme.body)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: photos.entries.map((e) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(e.value), width: 100, height: 100, fit: BoxFit.cover),
              );
            }).toList(),
          ),
        const SizedBox(height: 12),
        Text(
          'Drop: ${s.effectiveVehicleDrop?.address ?? s.userDrop?.address ?? '—'}',
          style: RescueTheme.body,
        ),
      ],
    );
  }

  Widget _supportTab(RescueBookingState s) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        RescueStatusCard(
          title: 'Contact rider',
          subtitle: _progress?.userDriverName ?? s.summary?.driver1Name ?? '—',
          icon: Icons.phone_outlined,
        ),
        if (s.hasVehicle) ...[
          const SizedBox(height: 10),
          RescueStatusCard(
            title: 'Contact vehicle driver',
            subtitle: _progress?.vehicleDriverName ?? s.summary?.driver2Name ?? '—',
            icon: Icons.phone_outlined,
          ),
        ],
        const SizedBox(height: 10),
        RescueStatusCard(
          title: 'Chat with support',
          subtitle: 'Rescue support team',
          icon: Icons.support_agent_outlined,
        ),
        const SizedBox(height: 16),
        if (_sosTriggered)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'SOS triggered — support will contact you shortly',
                    style: RescueTheme.body.copyWith(color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
          )
        else
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _triggerSOS,
            child: const Text('SOS / Emergency'),
          ),
        const SizedBox(height: 16),
        _buildCancelSection(s),
      ],
    );
  }

  Widget _buildCancelSection(RescueBookingState s) {
    final status = _progress?.rescue.status ?? s.summary?.status ?? 'PENDING';
    final canCancel = status == 'PENDING' ||
        status == 'DRIVER1_ACCEPTED' ||
        status == 'BOTH_ACCEPTED' ||
        status == 'DRIVERS_EN_ROUTE';

    if (!canCancel) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: RescueTheme.panelBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: RescueTheme.textMuted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Rescue is in progress and cannot be cancelled',
                style: RescueTheme.body.copyWith(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return OutlinedButton(
      onPressed: _cancelRescue,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        side: BorderSide(color: Colors.red.shade300),
        foregroundColor: Colors.red.shade700,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: const Text('Cancel Rescue'),
    );
  }

  Widget _timelineTab(RescueBookingState s, int currentIdx) {
    if (_timelineEvents.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _timelineEvents.length,
        itemBuilder: (_, i) {
          final event = _timelineEvents[i];
          return ListTile(
            leading: Icon(
              Icons.check_circle,
              color: RescueTheme.success,
            ),
            title: Text(event.title, style: RescueTheme.label),
            subtitle: event.description != null
                ? Text(event.description!,
                    style: RescueTheme.body.copyWith(fontSize: 12))
                : Text(
                    _formatTime(event.createdAt),
                    style: RescueTheme.body.copyWith(fontSize: 12),
                  ),
          );
        },
      );
    }

    final steps = s.hasVehicle
        ? RescueTimelineStep.values
        : [
            RescueTimelineStep.requestReceived,
            RescueTimelineStep.bikeRiderOnWay,
            RescueTimelineStep.driversArrived,
            RescueTimelineStep.journeyStarted,
            RescueTimelineStep.rescueCompleted,
          ];

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: steps.length,
      itemBuilder: (_, i) {
        final done = i <= currentIdx;
        return ListTile(
          leading: Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? RescueTheme.success : RescueTheme.textMuted,
          ),
          title: Text(steps[i].label, style: RescueTheme.label),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
