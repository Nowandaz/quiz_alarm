/// Small building blocks shared by the screens: the glossy card, the main
/// button, letter badges, pills and the progress ring.
library;

import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// Plain page background (black or white) with a faint sheen at the top.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        gradient: dark
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment(0, -0.2),
                colors: [Color(0xFF141416), Colors.black],
              )
            : null,
      ),
      child: child,
    );
  }
}

/// A raised card with a glossy highlight: polished black in dark mode,
/// soft white in light mode. Used for the "hero" block of a screen.
class GlossCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const GlossCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.45, 1],
          colors: dark
              ? const [Color(0xFF2A2A2E), Color(0xFF111113), Color(0xFF060607)]
              : const [Colors.white, Color(0xFFF7F7F9), Color(0xFFEDEDF1)],
        ),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.6 : 0.08),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// The main call-to-action: a solid pill, white on black in dark mode and
/// black on white in light mode.
class PrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData? icon;
  final String label;
  final double height;
  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      minimumSize: Size(64, height),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      textStyle: const TextStyle(
        fontFamily: AppTheme.body,
        fontWeight: FontWeight.w800,
        fontSize: 16,
      ),
    );
    final text = Text(label, overflow: TextOverflow.ellipsis);
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: text)
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 22),
            label: text,
          );
  }
}

/// "A", "B", "C"... in a small rounded square, for answer options.
class LetterBadge extends StatelessWidget {
  final int index;
  final Color? color;
  const LetterBadge({super.key, required this.index, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        String.fromCharCode(65 + index),
        style: TextStyle(
          fontFamily: AppTheme.display,
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }
}

/// A small rounded label, e.g. "Hard" or "Once".
class Pill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? color;
  const Pill(this.text, {super.key, this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A circular progress ring in the accent colour with "NN%" in the middle.
class ProgressRing extends StatelessWidget {
  final double value; // 0..1
  final double size;
  const ProgressRing({super.key, required this.value, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = value.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: v,
              strokeWidth: 4.5,
              strokeCap: StrokeCap.round,
              color: scheme.primary,
            ),
          ),
          Text(
            '${(v * 100).round()}%',
            style: TextStyle(
              fontFamily: AppTheme.display,
              fontWeight: FontWeight.w700,
              fontSize: size * 0.25,
            ),
          ),
        ],
      ),
    );
  }
}

/// Greeting for [hour] (0-23): good morning / afternoon / evening / night,
/// and between midnight and 5 AM "night owl" or, when [waking] (an alarm
/// was just dismissed), "early bird".
String greetingFor(int hour, {bool waking = false}) {
  if (hour < 5) return waking ? 'Hello, early bird' : 'Hello, night owl';
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  if (hour < 21) return 'Good evening';
  return 'Good night';
}

/// Makes a list item grow and fade in when it appears, and shrink and fade
/// out when [leaving] turns true ([onGone] is called once it has gone).
class AppearDisappear extends StatefulWidget {
  final Widget child;
  final bool leaving;
  final VoidCallback? onGone;
  final bool animateIn;
  const AppearDisappear({
    super.key,
    required this.child,
    this.leaving = false,
    this.onGone,
    this.animateIn = true,
  });

  @override
  State<AppearDisappear> createState() => _AppearDisappearState();
}

class _AppearDisappearState extends State<AppearDisappear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.animateIn ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.leaving) {
      _leave();
    } else {
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(AppearDisappear old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) _leave();
  }

  void _leave() {
    _c.reverse().whenComplete(() {
      if (mounted) widget.onGone?.call();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return SizeTransition(
      sizeFactor: curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: curve, child: widget.child),
    );
  }
}
