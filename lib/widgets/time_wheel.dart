/// Scroll-wheel time picker with two-digit numbers (00, 01, ... 09), in
/// 24-hour or 12-hour (AM/PM) form.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

class TimeWheel extends StatefulWidget {
  final TimeOfDay initial;
  final bool use24Hour;
  final ValueChanged<TimeOfDay> onChanged;

  const TimeWheel({
    super.key,
    required this.initial,
    required this.use24Hour,
    required this.onChanged,
  });

  @override
  State<TimeWheel> createState() => _TimeWheelState();
}

class _TimeWheelState extends State<TimeWheel> {
  late int _hour = widget.initial.hour; // always 0-23
  late int _minute = widget.initial.minute;

  late final FixedExtentScrollController _hourCtrl =
      FixedExtentScrollController(
        initialItem: widget.use24Hour ? _hour : (_hour % 12),
      );
  late final FixedExtentScrollController _minuteCtrl =
      FixedExtentScrollController(initialItem: _minute);
  late final FixedExtentScrollController _periodCtrl =
      FixedExtentScrollController(initialItem: _hour < 12 ? 0 : 1);

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _periodCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(TimeOfDay(hour: _hour, minute: _minute));

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: AppTheme.display,
      fontSize: 28,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget wheel({
      required FixedExtentScrollController controller,
      required int count,
      required String Function(int) label,
      required ValueChanged<int> onSelected,
      bool looping = true,
      double width = 76,
    }) => SizedBox(
      width: width,
      child: CupertinoPicker(
        scrollController: controller,
        itemExtent: 44,
        looping: looping,
        selectionOverlay: const SizedBox.shrink(),
        onSelectedItemChanged: onSelected,
        children: [
          for (var i = 0; i < count; i++)
            Center(child: Text(label(i), style: style)),
        ],
      ),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        // One highlight bar behind all the wheels.
        Container(
          height: 46,
          margin: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            wheel(
              controller: _hourCtrl,
              count: widget.use24Hour ? 24 : 12,
              // 12-hour clocks show 12 where the index is 0.
              label: (i) => _two(widget.use24Hour ? i : (i == 0 ? 12 : i)),
              onSelected: (i) {
                _hour = widget.use24Hour
                    ? i
                    : (i % 12) + (_hour >= 12 ? 12 : 0);
                _emit();
              },
            ),
            Text(':', style: style),
            wheel(
              controller: _minuteCtrl,
              count: 60,
              label: _two,
              onSelected: (i) {
                _minute = i;
                _emit();
              },
            ),
            if (!widget.use24Hour)
              wheel(
                controller: _periodCtrl,
                count: 2,
                looping: false,
                width: 70,
                label: (i) => i == 0 ? 'AM' : 'PM',
                onSelected: (i) {
                  _hour = (_hour % 12) + (i == 1 ? 12 : 0);
                  _emit();
                },
              ),
          ],
        ),
      ],
    );
  }
}
