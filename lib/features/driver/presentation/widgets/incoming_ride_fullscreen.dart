import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

class IncomingRideData {
  final String rideId;
  final String pickup;
  final String drop;
  final String distance;
  final String fare;
  final String? riderName;

  const IncomingRideData({
    required this.rideId,
    required this.pickup,
    required this.drop,
    required this.distance,
    required this.fare,
    this.riderName,
  });
}

class IncomingRideFullscreen extends StatefulWidget {
  final IncomingRideData data;
  final int timeoutSeconds;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;

  const IncomingRideFullscreen({
    super.key,
    required this.data,
    required this.onAccept,
    required this.onDecline,
    this.timeoutSeconds = 10,
  });

  @override
  State<IncomingRideFullscreen> createState() => _IncomingRideFullscreenState();
}

class _IncomingRideFullscreenState extends State<IncomingRideFullscreen> {
  Timer? _countdownTimer;
  Timer? _alertTimer;
  late int _secondsLeft;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.timeoutSeconds;
    _startCountdown();
    _startUrgencyAlert();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _secondsLeft -= 1;
      });
      if (_secondsLeft <= 0) {
        _handleDecline(auto: true);
      }
    });
  }

  void _startUrgencyAlert() {
    _alertTimer?.cancel();
    _emitAlertPulse();
    _alertTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      _emitAlertPulse();
    });
  }

  Future<void> _emitAlertPulse() async {
    if (!mounted || _busy) return;
    SystemSound.play(SystemSoundType.alert);
    final canVibrate = await Vibration.hasVibrator();
    if (canVibrate) {
      await Vibration.vibrate(duration: 260);
    }
  }

  void _stopAlerting() {
    _countdownTimer?.cancel();
    _alertTimer?.cancel();
    Vibration.cancel();
  }

  Future<void> _handleAccept() async {
    if (_busy) return;
    setState(() => _busy = true);
    _stopAlerting();
    await widget.onAccept();
    if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
  }

  Future<void> _handleDecline({bool auto = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    _stopAlerting();
    await widget.onDecline();
    if (mounted) Navigator.of(context, rootNavigator: true).pop(!auto);
  }

  @override
  void dispose() {
    _stopAlerting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_secondsLeft / widget.timeoutSeconds).clamp(0.0, 1.0);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF131313),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.notifications_active,
                        color: Color(0xFFD4956A), size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'New Ride Request',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD4956A),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_secondsLeft}s',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Color(0xFFD4956A)),
                  ),
                ),
                const SizedBox(height: 24),
                _detailCard(
                  icon: Icons.my_location,
                  label: 'Pickup',
                  value: widget.data.pickup,
                ),
                const SizedBox(height: 12),
                _detailCard(
                  icon: Icons.location_on,
                  label: 'Drop',
                  value: widget.data.drop,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _metricChip(
                        label: 'Distance',
                        value: widget.data.distance,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _metricChip(
                        label: 'Fare',
                        value: widget.data.fare,
                        emphasized: true,
                      ),
                    ),
                  ],
                ),
                if (widget.data.riderName != null &&
                    widget.data.riderName!.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _metricChip(label: 'Rider', value: widget.data.riderName!),
                ],
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _busy ? null : _handleAccept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD4956A),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: Colors.white),
                          )
                        : const Text(
                            'ACCEPT',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _handleDecline,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('DECLINE',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFD4956A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricChip({
    required String label,
    required String value,
    bool emphasized = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: emphasized
            ? const Color(0xFFD4956A).withOpacity(0.20)
            : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: emphasized ? const Color(0xFFD4956A) : Colors.white12),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: emphasized ? const Color(0xFFFFD0AA) : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
