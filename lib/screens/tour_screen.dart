/// The walk-through shown the first time the app is opened (and again from
/// Settings > "Show the tour"). A few swipeable pages explain what the app
/// does; the last one says which permissions alarms need.
library;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/app_widgets.dart';

class _TourPage {
  final IconData icon;
  final String title;
  final String body;
  final List<(IconData, String)> points;
  const _TourPage(this.icon, this.title, this.body, [this.points = const []]);
}

class TourScreen extends StatefulWidget {
  /// Adds the last page about alarm permissions (real phones only).
  final bool showPermissions;
  const TourScreen({super.key, this.showPermissions = true});

  static const String _seenPref = 'tour_seen';

  /// True until the tour has been finished or skipped once.
  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_seenPref) ?? false);
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seenPref, true);
  }

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  late final List<_TourPage> _pages = [
    const _TourPage(
      Icons.alarm_rounded,
      'Welcome to BrainWake',
      'The alarm you can only switch off by answering revision questions. '
          'You wake up, and you revise.',
    ),
    const _TourPage(
      Icons.add_alarm_rounded,
      'Set an alarm',
      'Tap "Add Alarm" on the Alarms tab.',
      [
        (Icons.schedule_rounded, 'Pick the time and the days it repeats'),
        (Icons.menu_book_rounded, 'Choose the topics it will ask about'),
        (
          Icons.bolt_rounded,
          'Choose how many correct answers in a row it takes',
        ),
        (Icons.music_note_rounded, 'Pick a ringtone or upload your own'),
      ],
    ),
    const _TourPage(
      Icons.notifications_active_rounded,
      'When it rings',
      'The questions open by themselves, at full volume.',
      [
        (
          Icons.check_circle_rounded,
          'Answer the set number in a row to stop it',
        ),
        (
          Icons.restart_alt_rounded,
          'A wrong answer restarts the count and shows you why',
        ),
        (Icons.snooze_rounded, 'Five wrong in a row unlocks the snooze'),
      ],
    ),
    const _TourPage(
      Icons.auto_stories_rounded,
      'Question banks',
      'The same questions are there to study any time, on the Banks tab.',
      [
        (
          Icons.play_arrow_rounded,
          'Practise: choose topics and how many questions',
        ),
        (Icons.image_rounded, 'Some questions show a picture to identify'),
        (Icons.lightbulb_rounded, 'Every answer comes with an explanation'),
        (Icons.wifi_off_rounded, 'Works without internet'),
      ],
    ),
    const _TourPage(
      Icons.insights_rounded,
      'See your progress',
      'The Reports tab keeps track for you.',
      [
        (Icons.percent_rounded, 'Your accuracy overall and per topic'),
        (Icons.timer_rounded, 'How long alarms take you to switch off'),
        (
          Icons.history_rounded,
          'Every past alarm and session, question by question',
        ),
      ],
    ),
    if (widget.showPermissions)
      const _TourPage(
        Icons.verified_user_rounded,
        'Let your alarms through',
        'Next, your phone will ask a few questions. Please allow them, or '
            'alarms may be late, silent or hidden.',
        [
          (Icons.notifications_rounded, 'Notifications and exact alarms'),
          (Icons.battery_charging_full_rounded, 'No battery restrictions'),
          (Icons.fullscreen_rounded, 'Full-screen alarms over the lock screen'),
          (Icons.layers_rounded, 'Opening over other apps'),
        ],
      ),
  ];

  bool get _last => _page == _pages.length - 1;

  Future<void> _finish() async {
    await TourScreen.markSeen();
    if (mounted) Navigator.of(context).pop();
  }

  void _next() {
    if (_last) {
      _finish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: AppBackground(
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 12, 0),
                    child: TextButton(
                      onPressed: _finish,
                      child: Text(_last ? '' : 'Skip'),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _pages.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, i) => _pageView(_pages[i], theme),
                  ),
                ),
                // Page dots.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _pages.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _page ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _page
                              ? scheme.onSurface
                              : scheme.onSurface.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      onPressed: _next,
                      label: _last ? 'Get started' : 'Next',
                      icon: _last
                          ? Icons.check_rounded
                          : Icons.arrow_forward_rounded,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageView(_TourPage page, ThemeData theme) {
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Center(
            child: GlossCard(
              padding: const EdgeInsets.all(34),
              child: Icon(page.icon, size: 64, color: scheme.onSurface),
            ),
          ),
          const SizedBox(height: 36),
          Text(page.title, style: theme.textTheme.headlineMedium),
          const SizedBox(height: 10),
          Text(
            page.body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          for (final (icon, text) in page.points)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, size: 19, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
