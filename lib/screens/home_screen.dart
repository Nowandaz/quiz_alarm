/// The app shell: header, the three tabs (Alarms, Banks, Reports) in a
/// floating navigation bar that hides while scrolling down, and the hook
/// that opens the quiz when an alarm rings.
library;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/alarm_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'alarm_ring_screen.dart';
import 'settings_screen.dart';
import 'tabs/alarm_tab.dart';
import 'tabs/question_bank_tab.dart';
import 'tabs/reports_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  // The bottom bar slides away while scrolling down a page and comes back
  // when scrolling up.
  bool _navHidden = false;
  final List<Widget> _tabs = const [
    AlarmTab(),
    QuestionBankTab(),
    ReportsTab(),
  ];
  static const List<String> _titles = [
    'BrainWake',
    'Question banks',
    'Reports',
  ];

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<AlarmProvider>(context, listen: false);
      // The simulator has no OS permissions to ask for.
      if (!provider.backend.isSimulated) _requestPermissions();

      provider.onAlarmTriggered = (alarm) async {
        if (!mounted) {
          provider.ringScreenClosed();
          return;
        }
        final result = await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AlarmRingScreen(alarm: alarm)),
        );
        if (result == 'snooze' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Snoozed for ${alarm.snoozeMinutes} minutes.'),
            ),
          );
        }
        provider.ringScreenClosed();
      };
    });
  }

  Future<void> _requestPermissions() async {
    try {
      // 1. Request Notification Permission (Required for Android 13+)
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }

      // 2. Request Exact Alarm Permission (Required for Android 12+)
      if (await Permission.scheduleExactAlarm.isDenied) {
        await Permission.scheduleExactAlarm.request();
      }

      // 3. Battery optimization can delay or kill alarms on many phones.
      // Ask once only, so we don't nag on every launch.
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('asked_battery_opt') ?? false)) {
        await prefs.setBool('asked_battery_opt', true);
        if (!await Permission.ignoreBatteryOptimizations.isGranted) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      }
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = Text(_titles[_currentIndex]);

    return Scaffold(
      extendBody: true,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 10, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: const TextStyle(
                          fontFamily: AppTheme.display,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                        child: title,
                      ),
                    ),
                    if (_currentIndex == 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: FilledButton.icon(
                          onPressed: () => showAddTopicDialog(context),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Topic'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                        ),
                      ),
                    if (_currentIndex == 0)
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.axis != Axis.vertical) return false;
                    final hide = n.direction == ScrollDirection.reverse
                        ? true
                        : (n.direction == ScrollDirection.forward
                              ? false
                              : _navHidden);
                    if (hide != _navHidden) setState(() => _navHidden = hide);
                    return false;
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    child: KeyedSubtree(
                      key: ValueKey(_currentIndex),
                      child: _tabs[_currentIndex],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        offset: _navHidden ? const Offset(0, 1.6) : Offset.zero,
        child: SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.45 : 0.10,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) => setState(() {
                _currentIndex = i;
                _navHidden = false;
              }),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.alarm_rounded),
                  label: 'Alarms',
                ),
                NavigationDestination(
                  icon: Icon(Icons.auto_stories_rounded),
                  label: 'Banks',
                ),
                NavigationDestination(
                  icon: Icon(Icons.insights_rounded),
                  label: 'Reports',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
