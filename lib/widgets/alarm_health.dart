/// Checks the phone settings alarms depend on and shows a warning on the
/// home screen while any of them is off, with a button to fix each one.
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
  const AlarmProblem(this.title, this.detail, this.fix, {this.action = 'Fix'});
}

/// Everything currently stopping alarms from working fully. Empty = fine.
Future<List<AlarmProblem>> findAlarmProblems() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
  final problems = <AlarmProblem>[];

  Future<void> check(
    Future<bool> Function() ok,
    String title,
    String detail,
    Future<void> Function() fix,
  ) async {
    try {
      if (!await ok()) problems.add(AlarmProblem(title, detail, fix));
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
  );
  await check(
    () => Permission.scheduleExactAlarm.isGranted,
    'Exact alarms are off',
    'Alarms may ring late.',
    () => ask(Permission.scheduleExactAlarm),
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

/// The warning card. Shows nothing while everything is allowed. Checks
/// again whenever the app comes back to the screen (e.g. from Settings).
class AlarmHealthBanner extends StatefulWidget {
  const AlarmHealthBanner({super.key});

  @override
  State<AlarmHealthBanner> createState() => _AlarmHealthBannerState();
}

class _AlarmHealthBannerState extends State<AlarmHealthBanner>
    with WidgetsBindingObserver {
  List<AlarmProblem> _problems = [];

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
    if (mounted) setState(() => _problems = found);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      alignment: Alignment.topCenter,
      child: _problems.isEmpty
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.error.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: scheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your alarms may not work properly',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final p in _problems)
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
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  p.detail,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            await p.fix();
                            await _check();
                          },
                          child: Text(p.action),
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}
