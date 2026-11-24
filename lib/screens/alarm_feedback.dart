/// "Did your alarm ring as scheduled?" Asks what went wrong and files a
/// report with the technical details attached automatically, so the
/// problem can be investigated without quizzing the user.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../data/alarm_log.dart';
import '../models/models.dart';
import '../services/crash_log.dart';
import '../services/alarm_provider.dart';
import '../services/server_config.dart';
import '../services/system_bridge.dart';
import '../services/theme_provider.dart';

// The prompt for an alarm that rang unanswered lives next door; the home
// screen gets both flows from this file.
export 'missed_alarm_sheet.dart' show showTimedOutPrompt;

/// The choices offered under "What happened?" (code sent to the server,
/// text shown).
const Map<String, String> alarmProblems = {
  'never_rang': 'Alarm never rang',
  'rang_late': 'Alarm rang late',
  'no_sound': 'Alarm rang but had no sound',
  'stopped': 'Alarm stopped unexpectedly',
  'snooze_failed': "Snooze didn't work",
  'other': 'Other',
};

/// Everything worth knowing about the phone and the alarm at this moment.
Future<Map<String, Object?>> collectAlarmDiagnostics(
  AlarmProvider provider, {
  AlarmItem? alarm,
  DateTime? scheduled,
}) async {
  Future<bool?> granted(Permission p) async {
    try {
      return await p.isGranted;
    } catch (_) {
      return null; // not a thing on this platform
    }
  }

  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final events = await AlarmLog.recent(alarmId: alarm?.id, limit: 25);
  final since = scheduled?.subtract(const Duration(hours: 12));
  bool happened(String type) => events.any(
    (e) => e.type == type && (since == null || e.at.isAfter(since)),
  );
  DateTime? lastRang;
  for (final e in events) {
    if (e.type == 'rang') {
      lastRang = e.at;
      break;
    }
  }
  final exits = await SystemBridge.exitReasons();

  return {
    'app_version': ServerConfig.appVersion,
    'device': await SystemBridge.deviceInfo(),
    'scheduled': scheduled?.toIso8601String(),
    'last_actual_ring': lastRang?.toIso8601String(),
    'reported_at': DateTime.now().toIso8601String(),
    'alarm': alarm == null
        ? null
        : {
            'id': alarm.id,
            'time':
                '${alarm.time.hour.toString().padLeft(2, '0')}:'
                '${alarm.time.minute.toString().padLeft(2, '0')}',
            'days': alarm.activeDays,
            'enabled': alarm.isEnabled,
            'snooze_minutes': alarm.snoozeMinutes,
            'custom_ringtone': !alarm.audioPath.startsWith('assets/'),
            'fade_seconds': alarm.fadeDuration,
            'registered_with_phone': provider.registrations(alarm),
          },
    'snoozed_recently': happened('snoozed'),
    'edited_recently': happened('edited'),
    'switched_recently': happened('switched_on') || happened('switched_off'),
    'alarm_service_ringing_now': alarm == null
        ? null
        : await provider.isRingingNow(alarm),
    'simulated_alarms': provider.backend.isSimulated,
    if (android)
      'permissions': {
        'battery_unrestricted': await granted(
          Permission.ignoreBatteryOptimizations,
        ),
        'notifications': await granted(Permission.notification),
        'exact_alarms': await granted(Permission.scheduleExactAlarm),
        'over_other_apps': await granted(Permission.systemAlertWindow),
        'full_screen': await SystemBridge.canUseFullScreenIntent(),
      },
    // Android's own record of why the app last stopped: shows a force
    // stop or a kill to save battery.
    'app_exits': exits.take(3).toList(),
    // What the app noted about its own crashes and errors.
    'android_crash': await SystemBridge.lastCrash(),
    'app_errors': await CrashLog.recent(),
    // How often the phone closed a ringing alarm and it was rung again.
    'ring_revivals': await SystemBridge.ringRevivals(),
    'force_stopped': exits.isEmpty
        ? null
        : exits.take(3).any((e) => e['reason'] == 10 || e['reason'] == 11),
    'recent_events': [
      for (final e in events.take(15))
        {'type': e.type, 'at': e.at.toIso8601String()},
    ],
  };
}

/// Shows the feedback flow. With [missed] it is about a ring the app
/// believes never happened; without, the user opened it from Settings and
/// picks the alarm themselves. [alarmId], [problem] and [scheduled] fill
/// that form in beforehand (used after an alarm rang unanswered and the
/// user says it made no sound).
Future<void> showAlarmFeedback(
  BuildContext context, {
  MissedRing? missed,
  int? alarmId,
  String? problem,
  DateTime? scheduled,
}) async {
  final provider = context.read<AlarmProvider>();
  final use24 = context.read<ThemeProvider>().use24Hour;
  final messenger = ScaffoldMessenger.of(context);

  AlarmItem? alarm;
  final wanted = missed?.alarmId ?? alarmId;
  for (final a in provider.alarms) {
    if (a.id == wanted) alarm = a;
  }
  scheduled = missed?.scheduled ?? scheduled;
  var step = missed != null ? 0 : 1; // 0 = did it ring?, 1 = what happened?
  final note = TextEditingController();

  final sent = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final theme = Theme.of(ctx);
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: step == 0
                    ? [
                        Text(
                          'Did your alarm ring as scheduled?',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${missed!.label.isEmpty ? 'Your alarm' : missed.label} '
                          'was set for ${formatClock(missed.scheduled, use24Hour: use24)}. '
                          'Help us improve Brain O\' Clock.',
                          style: muted,
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: () => Navigator.pop(ctx, 'rang'),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Yes, it rang'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => refresh(() => step = 1),
                          icon: const Icon(Icons.error_outline_rounded),
                          label: const Text("It didn't ring"),
                        ),
                      ]
                    : [
                        Text(
                          'What happened?',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'The technical details (phone model, alarm '
                          'settings, permissions, what the app recorded) are '
                          'attached for you.',
                          style: muted,
                        ),
                        if (missed == null && provider.alarms.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          DropdownButtonFormField<int?>(
                            initialValue: alarm?.id,
                            decoration: const InputDecoration(
                              labelText: 'Which alarm?',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('Not sure'),
                              ),
                              for (final a in provider.alarms)
                                DropdownMenuItem(
                                  value: a.id,
                                  child: Text(
                                    '${formatTimeOfDay(a.time, use24Hour: use24)}  ${a.label}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (id) => refresh(() {
                              alarm = null;
                              for (final a in provider.alarms) {
                                if (a.id == id) alarm = a;
                              }
                            }),
                          ),
                        ],
                        const SizedBox(height: 8),
                        RadioGroup<String>(
                          groupValue: problem,
                          onChanged: (v) => refresh(() => problem = v),
                          child: Column(
                            children: [
                              for (final entry in alarmProblems.entries)
                                RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  value: entry.key,
                                  title: Text(entry.value),
                                ),
                            ],
                          ),
                        ),
                        TextField(
                          controller: note,
                          maxLength: 500,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Anything else? (optional)',
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Says why Send is greyed out.
                        if (problem == null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              'Choose what happened to send the report',
                              textAlign: TextAlign.center,
                              style: muted,
                            ),
                          ),
                        FilledButton(
                          onPressed: problem == null
                              ? null
                              : () => Navigator.pop(ctx, problem),
                          child: const Text('Send report'),
                        ),
                      ],
              ),
            ),
          ),
        );
      },
    ),
  );
  final noteText = note.text.trim();
  note.dispose();
  if (sent == null) return;

  if (sent == 'rang') {
    await AlarmLog.add(
      'report',
      alarmId: missed?.alarmId,
      detail: {
        'rang': true,
        'scheduled': missed?.scheduled.toIso8601String(),
        'note': 'The app thought this ring was missed; the user says it rang.',
      },
      urgent: true,
    );
    return;
  }
  await AlarmLog.add(
    'report',
    alarmId: alarm?.id ?? wanted,
    urgent: true,
    detail: {
      'rang': false,
      'problem': sent,
      'note': noteText,
      'diagnostics': await collectAlarmDiagnostics(
        provider,
        alarm: alarm,
        scheduled: scheduled,
      ),
    },
  );
  messenger.showSnackBar(
    // The report is stored first and uploaded later, so "sent" would
    // not be true without a connection.
    const SnackBar(
      content: Text('Report saved. It is sent as soon as the phone is online.'),
    ),
  );
}
