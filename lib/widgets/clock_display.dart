/// The clock on the home screen. Tap it to switch between a digital and an
/// analog face; the choice is remembered. Only this widget rebuilds each
/// second, not the whole alarm list.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/theme_provider.dart';
import '../theme/app_theme.dart';

class ClockDisplay extends StatefulWidget {
  const ClockDisplay({super.key});

  @override
  State<ClockDisplay> createState() => _ClockDisplayState();
}

class _ClockDisplayState extends State<ClockDisplay> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: settings.analogClock
          ? 'Analog clock. Tap for digital'
          : 'Digital clock. Tap for analog',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => settings.setAnalogClock(!settings.analogClock),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: settings.analogClock
              ? SizedBox(
                  key: const ValueKey('analog'),
                  height: 190,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CustomPaint(
                        painter: _AnalogPainter(
                          now: _now,
                          ink: scheme.onSurface,
                          faint: scheme.onSurfaceVariant,
                          accent: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                )
              : Align(
                  key: const ValueKey('digital'),
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _digital(settings.use24Hour, scheme),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _digital(bool use24, ColorScheme scheme) {
    final small = TextStyle(
      fontFamily: AppTheme.display,
      fontSize: 20,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          DateFormat(use24 ? 'HH:mm' : 'h:mm').format(_now),
          style: TextStyle(
            fontFamily: AppTheme.display,
            fontSize: 72,
            height: 1,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
            letterSpacing: -1.5,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Text(DateFormat(':ss').format(_now), style: small),
        if (!use24) ...[
          const SizedBox(width: 6),
          Text(DateFormat('a').format(_now), style: small),
        ],
      ],
    );
  }
}

/// Minimal analog face: hour ticks, two hands and an accent second hand.
class _AnalogPainter extends CustomPainter {
  final DateTime now;
  final Color ink;
  final Color faint;
  final Color accent;
  _AnalogPainter({
    required this.now,
    required this.ink,
    required this.faint,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    Offset at(double turns, double length) {
      final a = turns * 2 * math.pi - math.pi / 2;
      return c + Offset(math.cos(a), math.sin(a)) * length;
    }

    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = faint.withValues(alpha: 0.35),
    );
    for (var i = 0; i < 60; i++) {
      final major = i % 5 == 0;
      canvas.drawLine(
        at(i / 60, r - (major ? 16 : 9)),
        at(i / 60, r - 6),
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = major ? 2.4 : 1
          ..color = major ? ink : faint.withValues(alpha: 0.5),
      );
    }

    final seconds = now.second.toDouble();
    final minutes = now.minute + seconds / 60;
    final hours = now.hour % 12 + minutes / 60;
    Paint hand(double width, Color color) => Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = color;

    canvas.drawLine(c, at(hours / 12, r * 0.5), hand(5, ink));
    canvas.drawLine(c, at(minutes / 60, r * 0.74), hand(3.2, ink));
    canvas.drawLine(
      at(seconds / 60 + 0.5, r * 0.14),
      at(seconds / 60, r * 0.8),
      hand(1.6, accent),
    );
    canvas.drawCircle(c, 5, Paint()..color = accent);
    canvas.drawCircle(c, 2, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_AnalogPainter old) =>
      old.now != now || old.ink != ink || old.accent != accent;
}
