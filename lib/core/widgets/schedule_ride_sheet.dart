import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shared "schedule for later" bottom sheet (no "ride now" option).
class ScheduleRidePickerSheet extends StatefulWidget {
  final DateTime? currentSchedule;
  final Color accentColor;
  final void Function(DateTime selected) onConfirm;

  const ScheduleRidePickerSheet({
    super.key,
    required this.currentSchedule,
    required this.accentColor,
    required this.onConfirm,
  });

  @override
  State<ScheduleRidePickerSheet> createState() =>
      _ScheduleRidePickerSheetState();
}

class _ScheduleRidePickerSheetState extends State<ScheduleRidePickerSheet> {
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;

  static DateTime _earliestSlot() =>
      DateTime.now().add(const Duration(minutes: 15));

  @override
  void initState() {
    super.initState();
    if (widget.currentSchedule != null) {
      final s = widget.currentSchedule!;
      _selectedDate = DateTime(s.year, s.month, s.day);
      _selectedTime = TimeOfDay(hour: s.hour, minute: s.minute);
    } else {
      final first = _earliestSlot();
      _selectedDate = DateTime(first.year, first.month, first.day);
      _selectedTime = TimeOfDay(hour: first.hour, minute: first.minute);
    }
  }

  DateTime get _combinedDateTime {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );
  }

  bool get _isValidSchedule {
    final combined = _combinedDateTime;
    final minTime = DateTime.now().add(const Duration(minutes: 15));
    return combined.isAfter(minTime);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'When do you want to ride?',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 8),
          Text(
            'Pick a date and time for your ride',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 7)),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: ColorScheme.light(
                              primary: widget.accentColor,
                              onPrimary: Colors.white,
                              surface: Colors.white,
                              onSurface: const Color(0xFF1A1A1A),
                            ),
                          ),
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    );
                    if (date != null && mounted) {
                      setState(() => _selectedDate = date);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today,
                            size: 20, color: Color(0xFF666666)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            DateFormat('EEE, MMM d').format(_selectedDate),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_down,
                            color: Color(0xFF666666)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: _selectedTime,
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: ColorScheme.light(
                              primary: widget.accentColor,
                              onPrimary: Colors.white,
                              surface: Colors.white,
                              onSurface: const Color(0xFF1A1A1A),
                            ),
                          ),
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    );
                    if (time != null && mounted) {
                      setState(() => _selectedTime = time);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time,
                            size: 20, color: Color(0xFF666666)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _selectedTime.format(context),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_down,
                            color: Color(0xFF666666)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (!_isValidSchedule) ...[
            const SizedBox(height: 8),
            Text(
              'Please select a time at least 15 minutes from now',
              style: TextStyle(fontSize: 12, color: Colors.red[600]),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isValidSchedule
                  ? () => widget.onConfirm(_combinedDateTime)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.accentColor,
                disabledBackgroundColor: Colors.grey[300],
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26)),
                elevation: 0,
              ),
              child: const Text(
                'Confirm',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 10),
        ],
      ),
    );
  }
}
