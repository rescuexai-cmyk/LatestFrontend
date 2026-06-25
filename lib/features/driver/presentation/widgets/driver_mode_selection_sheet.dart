import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Lets the user pick standard ride-share driver vs personal rescue driver.
class DriverModeSelectionSheet extends StatelessWidget {
  const DriverModeSelectionSheet({
    super.key,
    required this.onRideShareDriver,
    required this.onPersonalRescueDriver,
  });

  final VoidCallback onRideShareDriver;
  final VoidCallback onPersonalRescueDriver;

  static const _cream = Color(0xFFF6EFE4);
  static const _accent = Color(0xFFD4956A);
  static const _textDark = Color(0xFF353535);
  static const _borderBrown = Color(0xFFA89C8A);

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onRideShareDriver,
    required VoidCallback onPersonalRescueDriver,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DriverModeSelectionSheet(
        onRideShareDriver: onRideShareDriver,
        onPersonalRescueDriver: onPersonalRescueDriver,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _borderBrown.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Choose driver type',
            style: GoogleFonts.poppins(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: _textDark,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pick how you want to drive with Raahi.',
            style: GoogleFonts.poppins(fontSize: 13, color: _textDark.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 20),
          _OptionTile(
            icon: Icons.directions_car_outlined,
            title: 'Ride & Earn',
            subtitle: 'Auto, car, or bike — full onboarding with vehicle docs',
            onTap: () {
              Navigator.pop(context);
              onRideShareDriver();
            },
          ),
          const SizedBox(height: 12),
          _OptionTile(
            icon: Icons.emergency_share_outlined,
            title: 'Personal Rescue Driver',
            subtitle: 'Transport riders during rescues — Aadhaar + license only',
            accent: true,
            onTap: () {
              Navigator.pop(context);
              onPersonalRescueDriver();
            },
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accent
                  ? DriverModeSelectionSheet._accent
                  : DriverModeSelectionSheet._borderBrown.withValues(alpha: 0.4),
              width: accent ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: (accent
                          ? DriverModeSelectionSheet._accent
                          : DriverModeSelectionSheet._textDark)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: accent
                      ? DriverModeSelectionSheet._accent
                      : DriverModeSelectionSheet._textDark,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: DriverModeSelectionSheet._textDark.withValues(alpha: 0.65),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
