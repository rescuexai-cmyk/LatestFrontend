import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../rescue_theme.dart';

class RescueSelectTile extends StatelessWidget {
  const RescueSelectTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : RescueTheme.cardBg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? RescueTheme.accent : RescueTheme.stroke,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: RescueTheme.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(subtitle!, style: RescueTheme.body.copyWith(fontSize: 13)),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (selected)
                const Icon(Icons.check_circle, color: RescueTheme.accent)
              else
                Icon(Icons.circle_outlined,
                    color: RescueTheme.textMuted.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class RescueYesNoToggle extends StatelessWidget {
  const RescueYesNoToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _chip('Yes', value, () => onChanged(true))),
        const SizedBox(width: 10),
        Expanded(child: _chip('No', !value, () => onChanged(false))),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return Material(
      color: on ? RescueTheme.accent.withValues(alpha: 0.15) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? RescueTheme.accent : RescueTheme.stroke),
          ),
          child: Text(
            label,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              color: on ? RescueTheme.accent : RescueTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class RescueLocationField extends StatelessWidget {
  const RescueLocationField({
    super.key,
    required this.label,
    required this.address,
    required this.onTap,
    this.icon = Icons.location_on_outlined,
  });

  final String label;
  final String address;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: RescueTheme.label),
        const SizedBox(height: 8),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: RescueTheme.stroke),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: RescueTheme.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      address.isEmpty ? 'Tap to choose' : address,
                      style: RescueTheme.body.copyWith(
                        color: address.isEmpty
                            ? RescueTheme.textMuted
                            : RescueTheme.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: RescueTheme.textMuted),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class RescueDualJourneySummary extends StatelessWidget {
  const RescueDualJourneySummary({
    super.key,
    required this.pickup,
    required this.userDrop,
    this.vehicleDrop,
    required this.hasVehicle,
    this.vehicleDropSameAsDrop = true,
  });

  final String pickup;
  final String userDrop;
  final String? vehicleDrop;
  final bool hasVehicle;
  final bool vehicleDropSameAsDrop;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _leg(
          icon: Icons.person_outline,
          title: 'You (Passenger)',
          from: pickup,
          to: userDrop,
        ),
        if (hasVehicle) ...[
          const SizedBox(height: 12),
          _leg(
            icon: Icons.directions_car_outlined,
            title: 'Vehicle',
            from: pickup,
            to: vehicleDropSameAsDrop ? userDrop : (vehicleDrop ?? userDrop),
          ),
        ],
      ],
    );
  }

  Widget _leg({
    required IconData icon,
    required String title,
    required String from,
    required String to,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: RescueTheme.accent),
              const SizedBox(width: 8),
              Text(title, style: RescueTheme.label),
            ],
          ),
          const SizedBox(height: 10),
          Text('From: $from', style: RescueTheme.body.copyWith(fontSize: 13)),
          const SizedBox(height: 4),
          Text('To: $to', style: RescueTheme.body.copyWith(fontSize: 13)),
        ],
      ),
    );
  }
}

class RescuePhotoPickerTile extends StatelessWidget {
  const RescuePhotoPickerTile({
    super.key,
    required this.label,
    required this.path,
    required this.onTap,
  });

  final String label;
  final String? path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: RescueTheme.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: path != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(path!), fit: BoxFit.cover),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.all(4),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo_outlined,
                          color: RescueTheme.textMuted, size: 22),
                      const SizedBox(height: 4),
                      Text(label,
                          style: RescueTheme.body.copyWith(fontSize: 11),
                          textAlign: TextAlign.center),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class RescueStatusCard extends StatelessWidget {
  const RescueStatusCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.two_wheeler,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RescueTheme.stroke),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: RescueTheme.accent.withValues(alpha: 0.12),
            child: Icon(icon, color: RescueTheme.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: RescueTheme.label),
                Text(subtitle, style: RescueTheme.body.copyWith(fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
