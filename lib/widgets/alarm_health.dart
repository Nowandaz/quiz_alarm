/// Checks the phone settings alarms depend on.
///
/// Only two of them stop an alarm outright (notifications and exact
/// alarms); those show as a card on the Alarms tab until fixed. The rest
/// make alarms more dependable and are offered once, quietly, as "Finish
/// setting up alarms": one line the user can open or put away for good.
/// Everything is listed, with its state, on the "Set up alarms" page.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/system_bridge.dart';

class AlarmProblem {
  final String title;
  final String detail;
  final Future<void> Function() fix;

  /// The button's wording ("Fix" unless something else fits better).
  final String action;

  /// True when alarms cannot ring (or ring on time) at all without it.
  final bool critical;
  const AlarmProblem(
    this.title,
    this.detail,
    this.fix, {
    this.action = 'Fix',
    this.critical = false,
  });
}

/// Everything currently stopping alarms from working fully. Empty = fine.
Future<List<AlarmProblem>> findAlarmProblems() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
  final problems = <AlarmProblem>[];

  Future<void> check(
    Future<bool> Function() ok,
    String title,
    String detail,
    Future<void> Function() fix, {
    bool critical = false,
  }) async {
    try {
      if (!await ok()) {
        problems.add(AlarmProblem(title, detail, fix, critical: critical));
      }
    } catch (e) {
      debugPrint('Alarm check "$title" failed: $e');
    }
  }

  Future<void> ask(Permission p) async {
    final result = await p.request();
    if (result.isPermanentlyDenied) await openAppSettings();
  }

  await check(
    () => Permission.notification.isGranted,
    'Notifications are off',
    'Alarms cannot show at all.',
    () => ask(Permission.notification),
    critical: true,
  );
  await check(
    () => Permission.scheduleExactAlarm.isGranted,
    'Exact alarms are off',
    'Alarms may ring late.',
    () => ask(Permission.scheduleExactAlarm),
    critical: true,
  );
  await check(
    SystemBridge.canUseFullScreenIntent,
    'Full-screen alarms are off',
    'The questions will not open by themselves; only a notification shows.',
    () async => SystemBridge.openFullScreenIntentSettings(),
  );
  await check(
    () => Permission.ignoreBatteryOptimizations.isGranted,
    'Battery saving applies to Brain O\' Clock',
    'The phone may delay or skip alarms to save power.',
    () => ask(Permission.ignoreBatteryOptimizations),
  );
  await check(
    () => Permission.systemAlertWindow.isGranted,
    'Cannot open over other apps',
    'If an alarm rings while you use another app, you will have to tap '
        'the notification.',
    () => ask(Permission.systemAlertWindow),
  );
  // Some makers' phones need "autostart" allowed. Android cannot tell the
  // app whether it is, so this line shows until the user has opened the
  // page once (Settings keeps a way back to it).
  try {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(autostartSeenPref) ?? false) &&
        await SystemBridge.needsAutostart()) {
      problems.add(
        AlarmProblem(
          'Allow Brain O\' Clock to start by itself',
          'On this phone, alarms and the 5-minute heads-up can be lost '
              'after a restart unless "Autostart" is switched on for '
              'Brain O\' Clock.',
          () async {
            await SystemBridge.openAutostartSettings();
            await prefs.setBool(autostartSeenPref, true);
          },
          action: 'Open',
        ),
      );
    }
  } catch (e) {
    debugPrint('Autostart check failed: $e');
  }
  return problems;
}

/// Set once the user has been taken to the autostart page.
const String autostartSeenPref = 'autostart_seen';

/// Set when the user put "Finish setting up alarms" away.
const String setupDismissedPref = 'alarm_setup_dismissed';

/// The last time the phone closed a ringing alarm that the user was told
/// about (ms).
const String revivalSeenPref = 'ring_revival_seen';

/// What the Alarms tab says about the phone's settings. Nothing while all
/// is well. Otherwise, in a calm card:
///  - something an alarm cannot ring without: what, with a "Fix" button;
///  - the phone closed a ringing alarm (it was rung again): once, with a
///    way to the settings that stop that;
///  - only optional steps left: one line, which can be put away for good.
/// Checks again whenever the app comes back to the screen.
class AlarmHealthBanner extends StatefulWidget {
  /// Opens the "Set up alarms" page.
  final VoidCallback? onSetUp;
  const AlarmHealthBanner({super.key, this.onSetUp});

  @override
  State<AlarmHealthBanner> createState() => _AlarmHealthBannerState();
}

class _AlarmHealthBannerState extends State<AlarmHealthBanner>
    with WidgetsBindingObserver {
  List<AlarmProblem> _problems = [];
  bool _dismissed = true;
  int _revivedAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final found = await findAlarmProblems();
    var dismissed = false;
    var revivedAt = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissed = prefs.getBool(setupDismissedPref) ?? false;
      final last =
          ((await SystemBridge.ringRevivals())['last_at'] as num?)?.toInt() ??
          0;
      if (last > (prefs.getInt(revivalSeenPref) ?? 0)) revivedAt = last;
    } catch (e) {
      debugPrint('Alarm set-up state could not be read: $e');
    }
    if (!mounted) return;
    setState(() {
      _problems = found;
      _dismissed = dismissed;
      _revivedAt = revivedAt;
    });
  }

  Future<void> _putAway() async {
    setState(() => _dismissed = true);
    (await SharedPreferences.getInstance()).setBool(setupDismissedPref, true);
  }

  Future<void> _sawRevival() async {
    final at = _revivedAt;
    setState(() => _revivedAt = 0);
    (await SharedPreferences.getInstance()).setInt(revivalSeenPref, at);
  }

  Widget _card(BuildContext context, {required List<Widget> children}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = _problems.where((p) => p.critical).toList();
    final optional = _problems.where((p) => !p.critical).length;

    Widget content = const SizedBox(width: double.infinity);
    if (critical.isNotEmpty) {
      content = _card(
        context,
        children: [
          Text(
            critical.length == 1
                ? 'One thing before your alarms can ring'
                : 'Before your alarms can ring',
            style: theme.textTheme.titleMedium,
          ),
          for (final p in critical)
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(p.detail, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    await p.fix();
                    await _check();
                  },
                  child: Text(p.action),
                ),
                const SizedBox(width: 6),
              ],
            ),
          const SizedBox(height: 6),
        ],
      );
    } else if (_revivedAt > 0) {
      content = _card(
        context,
        children: [
          Text(
            'Your phone closed the app while an alarm was ringing',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'We rang it again. A few settings stop your phone doing this.',
            style: theme.textTheme.bodySmall,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _sawRevival, child: const Text('OK')),
              TextButton(
                onPressed: () {
                  _sawRevival();
                  widget.onSetUp?.call();
                },
                child: const Text('Show me'),
              ),
            ],
          ),
        ],
      );
    } else if (optional > 0 && !_dismissed) {
      content = _card(
        context,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Finish setting up alarms',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      optional == 1
                          ? 'One optional step makes them more dependable.'
                          : '$optional optional steps make them more '
                                'dependable.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _putAway,
                child: const Text("Don't show again"),
              ),
              TextButton(
                onPressed: widget.onSetUp,
                child: const Text('Set up'),
              ),
            ],
          ),
        ],
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      alignment: Alignment.topCenter,
      child: content,
    );
  }
}
