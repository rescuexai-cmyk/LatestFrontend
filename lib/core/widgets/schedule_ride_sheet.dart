import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'figma_square_back_button.dart';

/// Shared "schedule for later" bottom sheet — Figma: mandala + gradient, 3-column wheel.
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

  /// Figma schedule header: gray mandala on white, fade to white (crop bottom in UI).
  static const String sheetBgAsset = 'assets/images/schedule_ride_mandala_bg.png';

  @override
  State<ScheduleRidePickerSheet> createState() =>
      _ScheduleRidePickerSheetState();
}

class _ScheduleRidePickerSheetState extends State<ScheduleRidePickerSheet> {
  late List<DateTime> _dates;
  late FixedExtentScrollController _dateCtrl;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;
  late FixedExtentScrollController _amPmCtrl;

  int _dateIndex = 0;
  int _hourIndex = 0; // 0 → 1 o'clock ... 11 → 12 o'clock
  int _minuteIndex = 0;
  int _amPmIndex = 0; // 0 AM, 1 PM

  bool _showValidationBanner = true;

  /// Figma frame ~381×139; center row 16px/500 #111111, others 14px/400 #AAAAAA.
  static const double _figmaPickerFrameWidth = 381;
  /// Taller row = more space between selected text and the #CCCCCC lines (Figma-style inset).
  static const double _wheelItemExtent = 44;
  static const double _wheelHeight = 165;

  static DateTime _earliestSlot() =>
      DateTime.now().add(const Duration(minutes: 15));

  static int _toHour24(int h12, int amPm) {
    if (amPm == 0) {
      return h12 == 12 ? 0 : h12;
    }
    return h12 == 12 ? 12 : h12 + 12;
  }

  DateTime get _combinedDateTime {
    final d = _dates[_dateIndex];
    final h24 = _toHour24(_hourIndex + 1, _amPmIndex);
    return DateTime(d.year, d.month, d.day, h24, _minuteIndex);
  }

  bool get _isValidSchedule {
    final combined = _combinedDateTime;
    final minTime = DateTime.now().add(const Duration(minutes: 15));
    return combined.isAfter(minTime);
  }

  void _nudgeToValidTime() {
    if (_isValidSchedule) return;
    final minTime = DateTime.now().add(const Duration(minutes: 15));
    final d = _dates[_dateIndex];
    final sameDay = d.year == minTime.year &&
        d.month == minTime.month &&
        d.day == minTime.day;
    if (!sameDay) return;

    var h = minTime.hour;
    final m = minTime.minute;
    var ap = h >= 12 ? 1 : 0;
    var h12 = h % 12;
    if (h12 == 0) h12 = 12;

    setState(() {
      _minuteIndex = m;
      _hourIndex = h12 - 1;
      _amPmIndex = ap;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hourCtrl.jumpToItem(_hourIndex);
      _minuteCtrl.jumpToItem(_minuteIndex);
      _amPmCtrl.jumpToItem(_amPmIndex);
    });
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _dates = List.generate(
      8,
      (i) => today.add(Duration(days: i)),
    );

    final target = widget.currentSchedule != null &&
            widget.currentSchedule!.isAfter(_earliestSlot())
        ? widget.currentSchedule!
        : _earliestSlot();

    _dateIndex = _dates.indexWhere(
      (d) =>
          d.year == target.year &&
          d.month == target.month &&
          d.day == target.day,
    );
    if (_dateIndex < 0) _dateIndex = 0;

    final h24 = target.hour;
    final m = target.minute;
    if (h24 == 0) {
      _hourIndex = 11;
      _amPmIndex = 0;
    } else if (h24 < 12) {
      _hourIndex = h24 - 1;
      _amPmIndex = 0;
    } else if (h24 == 12) {
      _hourIndex = 11;
      _amPmIndex = 1;
    } else {
      _hourIndex = h24 - 13;
      _amPmIndex = 1;
    }
    _minuteIndex = m.clamp(0, 59);

    _dateCtrl = FixedExtentScrollController(initialItem: _dateIndex);
    _hourCtrl = FixedExtentScrollController(initialItem: _hourIndex);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minuteIndex);
    _amPmCtrl = FixedExtentScrollController(initialItem: _amPmIndex);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nudgeToValidTime();
    });
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _amPmCtrl.dispose();
    super.dispose();
  }

  void _onAnyWheelChanged() {
    setState(() {
      if (!_isValidSchedule) {
        _showValidationBanner = true;
      } else {
        _showValidationBanner = false;
      }
    });
    if (!_isValidSchedule) {
      _nudgeToValidTime();
    }
  }

  Future<void> _openCalendarPicker() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dates[_dateIndex],
      firstDate: _dates.first,
      lastDate: _dates.last,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: widget.accentColor,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: const Color(0xFF111111),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (date == null || !mounted) return;
    final idx = _dates.indexWhere(
      (d) =>
          d.year == date.year &&
          d.month == date.month &&
          d.day == date.day,
    );
    if (idx < 0) return;
    setState(() => _dateIndex = idx);
    _dateCtrl.animateToItem(
      idx,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _onAnyWheelChanged();
  }

  Widget _wheelColumn({
    required FixedExtentScrollController controller,
    required int itemCount,
    required int selectedIndex,
    required Widget Function(int index, bool selected) builder,
    required ValueChanged<int> onChanged,
  }) {
    return SizedBox(
      height: _wheelHeight,
      child: ListWheelScrollView.useDelegate(
        controller: controller,
        itemExtent: _wheelItemExtent,
        diameterRatio: 1.32,
        perspective: 0.00135,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) {
          onChanged(i);
          _onAnyWheelChanged();
        },
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: itemCount,
          builder: (context, index) {
            final selected = index == selectedIndex;
            return Center(child: builder(index, selected));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final mandalaClipHeight = size.height * 0.44;
    /// Pull art up past the grab handle so the dark top strip is covered by mandala.
    const mandalaNudgeUp = 32.0;
    final mandalaLayerHeight = mandalaClipHeight + mandalaNudgeUp;
    final pickerContentW = math.max(0.0, size.width - 32);
    final gapDateToTime = pickerContentW * 30 / _figmaPickerFrameWidth;
    final gapTimeToAmPm = pickerContentW * 21 / _figmaPickerFrameWidth;
    final pickerDividerH =
        1 / MediaQuery.devicePixelRatioOf(context); // ~Figma 0.41px line

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: Container(
          decoration: BoxDecoration(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(32)),
            // Subtle; mandala PNG carries most of the header art.
            gradient: const LinearGradient(
              begin: Alignment(-0.02, -1),
              end: Alignment(0.02, 0.35),
              colors: [
                Color(0xFFF2F2F2),
                Color(0xFFFFFFFF),
              ],
              stops: [0.0, 0.35],
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x26000000),
                offset: Offset(0, -4),
                blurRadius: 19.75,
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                top: -mandalaNudgeUp,
                left: 0,
                right: 0,
                height: mandalaLayerHeight,
                child: IgnorePointer(
                  child: ClipRect(
                    child: SizedBox(
                      width: size.width,
                      height: mandalaLayerHeight,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        alignment: Alignment.topCenter,
                        children: [
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Image.asset(
                              ScheduleRidePickerSheet.sheetBgAsset,
                              width: size.width,
                              fit: BoxFit.fitWidth,
                              alignment: Alignment.topCenter,
                              filterQuality: FilterQuality.high,
                              errorBuilder: (_, __, ___) =>
                                  const ColoredBox(color: Colors.transparent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 49,
                    height: 3,
                    decoration: BoxDecoration(
                      color: const Color(0xFF424242),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 16, 0),
                  child: Row(
                    children: [
                      FigmaSquareBackButton(
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      const Expanded(
                        child: Text(
                          'Schedule Ride',
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w500,
                            fontSize: 16,
                            height: 24 / 16,
                            color: Color(0xFF010101),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x80EDEDED),
                          borderRadius: BorderRadius.circular(200),
                          border: Border.all(
                            color: const Color(0x80CBC6BB),
                            width: 0.92,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.access_time_rounded,
                                size: 15,
                                color: Color(0xFF000000),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Later',
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontSize: 14,
                                  height: 21 / 14,
                                  letterSpacing: -0.42,
                                  color: Colors.black.withValues(alpha: 0.95),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 18,
                                color: Colors.black.withValues(alpha: 0.85),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const Padding(
                  padding: EdgeInsets.only(left: 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pick up at',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w500,
                          fontSize: 16,
                          height: 24 / 16,
                          color: Color(0xFF000000),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Pick a Date and Time for your ride',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w400,
                          fontSize: 14,
                          height: 21 / 14,
                          color: Color(0xFF5B5B5B),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: _wheelHeight,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      alignment: Alignment.center,
                      children: [
                        Padding(
                          padding: EdgeInsets.zero,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                            Expanded(
                              flex: 103,
                              child: _wheelColumn(
                                controller: _dateCtrl,
                                itemCount: _dates.length,
                                selectedIndex: _dateIndex,
                                onChanged: (i) => _dateIndex = i,
                                builder: (idx, sel) {
                                  final t = DateFormat('EEE d MMM')
                                      .format(_dates[idx]);
                                  return Text(
                                    t,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontWeight: sel
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                      fontSize: sel ? 16 : 14,
                                      height: sel ? 24 / 16 : 21 / 14,
                                      color: sel
                                          ? const Color(0xFF111111)
                                          : const Color(0xFFAAAAAA),
                                    ),
                                  );
                                },
                              ),
                            ),
                            SizedBox(width: gapDateToTime),
                            Expanded(
                              flex: 122,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _wheelColumn(
                                      controller: _hourCtrl,
                                      itemCount: 12,
                                      selectedIndex: _hourIndex,
                                      onChanged: (i) => _hourIndex = i,
                                      builder: (idx, sel) => Text(
                                        '${idx + 1}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontFamily: 'Poppins',
                                          fontWeight: sel
                                              ? FontWeight.w500
                                              : FontWeight.w400,
                                          fontSize: sel ? 16 : 14,
                                          height: sel ? 24 / 16 : 21 / 14,
                                          color: sel
                                              ? const Color(0xFF111111)
                                              : const Color(0xFFAAAAAA),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 2),
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: Text(
                                        ':',
                                        style: TextStyle(
                                          fontFamily: 'Poppins',
                                          fontWeight: FontWeight.w500,
                                          fontSize: 16,
                                          height: 24 / 16,
                                          color: const Color(0xFF111111),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: _wheelColumn(
                                      controller: _minuteCtrl,
                                      itemCount: 60,
                                      selectedIndex: _minuteIndex,
                                      onChanged: (i) => _minuteIndex = i,
                                      builder: (idx, sel) => Text(
                                        idx.toString().padLeft(2, '0'),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontFamily: 'Poppins',
                                          fontWeight: sel
                                              ? FontWeight.w500
                                              : FontWeight.w400,
                                          fontSize: sel ? 16 : 14,
                                          height: sel ? 24 / 16 : 21 / 14,
                                          color: sel
                                              ? const Color(0xFF111111)
                                              : const Color(0xFFAAAAAA),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(width: gapTimeToAmPm),
                            Expanded(
                              flex: 49,
                              child: _wheelColumn(
                                controller: _amPmCtrl,
                                itemCount: 2,
                                selectedIndex: _amPmIndex,
                                onChanged: (i) => _amPmIndex = i,
                                builder: (idx, sel) => Text(
                                  idx == 0 ? 'am' : 'pm',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: sel
                                        ? FontWeight.w500
                                        : FontWeight.w400,
                                    fontSize: sel ? 16 : 14,
                                    height: sel ? 24 / 16 : 21 / 14,
                                    color: sel
                                        ? const Color(0xFF111111)
                                        : const Color(0xFFAAAAAA),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IgnorePointer(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ColoredBox(
                                    color: const Color(0xFFCCCCCC),
                                    child: SizedBox(height: pickerDividerH),
                                  ),
                                ),
                                SizedBox(height: _wheelItemExtent),
                                SizedBox(
                                  width: double.infinity,
                                  child: ColoredBox(
                                    color: const Color(0xFFCCCCCC),
                                    child: SizedBox(height: pickerDividerH),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 22),
                  child: InkWell(
                    onTap: _openCalendarPicker,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.calendar_today_outlined,
                            size: 20,
                            color: Color(0xFF000000),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'or pickup in calendar',
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              fontSize: 14,
                              height: 21 / 14,
                              decoration: TextDecoration.underline,
                              color: Colors.black.withValues(alpha: 0.95),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!_isValidSchedule && _showValidationBanner) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 4,
                          top: 5,
                          bottom: 5,
                        ),
                        decoration: BoxDecoration(
                          color:
                              const Color.fromRGBO(209, 69, 68, 0.1),
                          borderRadius: BorderRadius.circular(172),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Please Select a time at least 15 mins from now',
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w400,
                                  fontSize: 14,
                                  height: 21 / 14,
                                  color: Color(0xFFD14544),
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: () =>
                                  setState(() => _showValidationBanner = false),
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: Center(
                                  child: Container(
                                    width: 24,
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: const Color.fromRGBO(
                                          209, 69, 68, 0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Color(0xFFD14544),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Material(
                  color: Colors.white,
                  elevation: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          offset: const Offset(0, -3.92),
                          blurRadius: 19.75,
                        ),
                      ],
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          6,
                          16,
                          8,
                        ),
                        child: Material(
                          color: const Color(0xFF000000),
                          borderRadius: BorderRadius.circular(280),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(280),
                            onTap: _isValidSchedule
                                ? () =>
                                    widget.onConfirm(_combinedDateTime)
                                : null,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 150),
                              opacity: _isValidSchedule ? 1 : 0.4,
                              child: Container(
                                width: double.infinity,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 15),
                                alignment: Alignment.center,
                                child: const Text(
                                  'Next',
                                  style: TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w500,
                                    fontSize: 16.649,
                                    height: 25 / 16.649,
                                    color: Color(0xFFFFFFFF),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
