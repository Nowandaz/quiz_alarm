/// The interactive tour: dims the real screen, cuts a spotlight around one
/// element at a time and explains it in a small card. Steps can switch
/// tabs before they point at something.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keys of the elements the tour points at. The screens attach them.
class TourKeys {
  static final GlobalKey clock = GlobalKey(debugLabel: 'tour-clock');
  static final GlobalKey addAlarm = GlobalKey(debugLabel: 'tour-add-alarm');
  static final GlobalKey testQuiz = GlobalKey(debugLabel: 'tour-test-quiz');
  static final GlobalKey settings = GlobalKey(debugLabel: 'tour-settings');
  static final GlobalKey navBanks = GlobalKey(debugLabel: 'tour-nav-banks');
  static final GlobalKey practise = GlobalKey(debugLabel: 'tour-practise');
  static final GlobalKey firstUnit = GlobalKey(debugLabel: 'tour-first-unit');
  static final GlobalKey navReports = GlobalKey(debugLabel: 'tour-nav-reports');
  static final GlobalKey reportsHero = GlobalKey(debugLabel: 'tour-reports');
}

class CoachStep {
  /// The element to spotlight. Null (or not on screen) = no spotlight,
  /// the card is shown in the middle.
  final GlobalKey? target;
  final String title;
  final String body;

  /// Runs before the step is shown, e.g. to switch tab.
  final FutureOr<void> Function()? before;

  const CoachStep({
    required this.title,
    required this.body,
    this.target,
    this.before,
  });
}

class AppTour {
  static const String _seenPref = 'tour_seen';

  /// True until the tour has been offered once.
  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_seenPref) ?? false);
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seenPref, true);
  }

  /// Runs [steps] over the current screen. Completes when the tour is
  /// finished or skipped.
  static Future<void> run(BuildContext context, List<CoachStep> steps) {
    final done = Completer<void>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CoachOverlay(
        steps: steps,
        onDone: () {
          entry.remove();
          if (!done.isCompleted) done.complete();
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return done.future;
  }
}

class _CoachOverlay extends StatefulWidget {
  final List<CoachStep> steps;
  final VoidCallback onDone;
  const _CoachOverlay({required this.steps, required this.onDone});

  @override
  State<_CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<_CoachOverlay> {
  int _index = 0;
  Rect? _hole;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _show(0);
  }

  Future<void> _show(int index) async {
    setState(() {
      _index = index;
      _ready = false;
    });
    final step = widget.steps[index];
    await step.before?.call();
    // Let a tab switch or scroll settle before measuring.
    await Future<void>.delayed(const Duration(milliseconds: 380));
    if (!mounted) return;

    Rect? rect;
    final target = step.target?.currentContext;
    if (target != null && target.mounted) {
      try {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: const Duration(milliseconds: 200),
        );
      } catch (_) {}
      if (!mounted || !target.mounted) return;
      final box = target.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        rect = (box.localToGlobal(Offset.zero) & box.size).inflate(8);
      }
    }
    setState(() {
      _hole = rect;
      _ready = true;
    });
  }

  void _next() {
    if (!_ready) return;
    if (_index >= widget.steps.length - 1) {
      widget.onDone();
    } else {
      _show(_index + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final step = widget.steps[_index];
    final hole = _hole;
    final last = _index == widget.steps.length - 1;

    // The card goes below the spotlight when the spotlight is in the top
    // half of the screen, above it otherwise.
    final below = hole == null || hole.center.dy < size.height / 2;

    final card = Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 12,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(step.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              step.body,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${_index + 1} of ${widget.steps.length}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                if (!last)
                  TextButton(
                    onPressed: widget.onDone,
                    child: const Text('Skip tour'),
                  ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _next,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  child: Text(last ? 'Done' : 'Next'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Dim everything except the spotlight; taps anywhere move on.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _next,
              child: TweenAnimationBuilder<Rect?>(
                tween: RectTween(end: hole ?? Rect.zero),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                builder: (context, rect, _) => CustomPaint(
                  painter: _SpotlightPainter(
                    hole: (_ready && hole != null) ? rect : null,
                    ring: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
          if (_ready)
            Positioned(
              left: 16,
              right: 16,
              top: hole == null
                  ? size.height * 0.36
                  : (below ? hole.bottom + 14 : null),
              bottom: (hole != null && !below)
                  ? size.height - hole.top + 14
                  : null,
              child: SafeArea(
                minimum: EdgeInsets.only(
                  top: padding.top + 8,
                  bottom: padding.bottom + 8,
                ),
                child: card,
              ),
            ),
        ],
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? hole;
  final Color ring;
  _SpotlightPainter({required this.hole, required this.ring});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.78);
    final h = hole;
    if (h == null || h.isEmpty) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    final shape = RRect.fromRectAndRadius(h, const Radius.circular(22));
    // Even-odd fill: the rounded rectangle inside the full-screen
    // rectangle is left clear, so the element shows at full brightness.
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(shape),
      dim,
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.ring != ring;
}
