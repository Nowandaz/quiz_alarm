/// The app's own look, drawn in code so it stays sharp at any size and
/// follows the phone's accent colour: the logo mark, the dial that
/// decorates the sign-in screen, and Google's "G" for its sign-in button.
library;

import 'dart:math';

import 'package:material_ui/material_ui.dart';

/// The logo: an alarm clock whose hands form a tick, because the alarm
/// stops when the answer is right.
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(scheme.primary, Colors.white, 0.28)!,
            scheme.primary,
            Color.lerp(scheme.primary, Colors.black, 0.25)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.45),
            blurRadius: size * 0.5,
            offset: Offset(0, size * 0.14),
          ),
        ],
      ),
      child: CustomPaint(painter: _MarkPainter(scheme.onPrimary)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final Color ink;
  const _MarkPainter(this.ink);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s * 0.54);
    final r = s * 0.25;
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(c, r, line); // the clock face
    // The two bells.
    for (final side in const [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(c.dx + side * s * 0.30, c.dy - s * 0.25),
        Offset(c.dx + side * s * 0.20, c.dy - s * 0.33),
        line,
      );
    }
    // The hands, as a tick.
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - r * 0.45, c.dy + r * 0.02)
        ..lineTo(c.dx - r * 0.08, c.dy + r * 0.38)
        ..lineTo(c.dx + r * 0.50, c.dy - r * 0.36),
      line,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.ink != ink;
}

/// A large, faint clock dial with a soft glow, for the top of the sign-in
/// screen.
class BrandDial extends StatelessWidget {
  const BrandDial({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: CustomPaint(
        painter: _DialPainter(accent: scheme.primary, ink: scheme.onSurface),
        size: Size.infinite,
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final Color accent;
  final Color ink;
  const _DialPainter({required this.accent, required this.ink});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.86, size.height * 0.16);
    final r = size.width * 0.62;

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.30),
            accent.withValues(alpha: 0.08),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = ink.withValues(alpha: 0.10);
    for (final f in const [0.42, 0.62, 0.82]) {
      canvas.drawCircle(c, r * f, ring);
    }
    // Minute marks on the middle ring; every fifth one is longer.
    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..color = ink.withValues(alpha: 0.22);
    for (var i = 0; i < 60; i++) {
      final a = i * pi / 30;
      final long = i % 5 == 0;
      final from = r * (long ? 0.555 : 0.585);
      tick.strokeWidth = long ? 2.2 : 1.1;
      canvas.drawLine(
        c + Offset(cos(a), sin(a)) * from,
        c + Offset(cos(a), sin(a)) * (r * 0.62),
        tick,
      );
    }
    // Hands pointing at "time to get up".
    final hand = Paint()
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.85);
    hand.strokeWidth = 4;
    canvas.drawLine(c, c + Offset(cos(2.45), sin(2.45)) * (r * 0.30), hand);
    hand.strokeWidth = 2.5;
    canvas.drawLine(c, c + Offset(cos(1.75), sin(1.75)) * (r * 0.46), hand);
    canvas.drawCircle(c, 6, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.accent != accent || old.ink != ink;
}

/// Google's four-colour "G", for the "Continue with Google" button.
class GoogleLogo extends StatelessWidget {
  final double size;
  const GoogleLogo({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: const CustomPaint(painter: _GooglePainter()),
  );
}

class _GooglePainter extends CustomPainter {
  const _GooglePainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final w = s * 0.2; // thickness of the letter
    final c = Offset(s / 2, s / 2);
    final arcs = Rect.fromCircle(center: c, radius: (s - w) / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    double rad(double degrees) => degrees * pi / 180;
    void arc(Color color, double from, double to) => canvas.drawArc(
      arcs,
      rad(from),
      rad(to - from),
      false,
      paint..color = color,
    );

    // Angles run clockwise from 3 o'clock.
    arc(_red, 196, 318);
    arc(_yellow, 148, 198);
    arc(_green, 44, 150);
    arc(_blue, 0, 46);
    // The bar of the G.
    canvas.drawRect(
      Rect.fromLTRB(
        c.dx - s * 0.02,
        c.dy - w / 2,
        // Ends where the outer edge of the ring is at this height.
        c.dx + sqrt(s * s / 4 - w * w / 4),
        c.dy + w / 2,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(_GooglePainter old) => false;
}
