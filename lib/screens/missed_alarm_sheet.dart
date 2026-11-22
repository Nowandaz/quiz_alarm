/// "You missed your 7:00 AM alarm": asked the next time the app is open
/// after an alarm rang unanswered and stopped by itself. Works out what
/// may have gone wrong (low volume, a missing permission, vibration off),
/// offers a one-tap fix for each and asks the user what happened.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/alarm_log.dart';
import '../models/models.dart';
import '../services/alarm_provider.dart';
import '../services/theme_provider.dart';
import '../widgets/alarm_health.dart';
import 'alarm_feedback.dart';

/// The answers offered under "What happened?" (code kept in the diary,
/// text shown).
const Map<String, String> timedOutReasons = {
  'slept': 'I slept through it',
  'phone_away': 'My phone was not near me',
  'no_sound': 'It did not ring / no sound',
  'ignored': 'I ignored it',
};

/// An alarm that rang quieter than this may simply not have been heard.
const double lowAlarmVolume = 0.7;

/// Asks about [ring], notes the answer in the diary and clears [ring]
/// from the provider's list, whatever the user does with the sheet.
/// [findProblems] is the phone-settings check (replaced in tests).
Future<void> showTimedOutPrompt(
  BuildContext context,
  TimedOutRing ring, {
  Future<List<AlarmProblem>> Function() findProblems = findAlarmProblems,
}) async {
  final provider = context.read<AlarmProvider>();
  // What was not allowed when the sheet opened (before any fix).
  var missing = const <String>[];
  final reason = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TimedOutSheet(
      ring: ring,
      findProblems: findProblems,
      onFirstCheck: (titles) => missing = titles,
    ),
  );
  await AlarmLog.add(
    'timed_out_reason',
    alarmId: ring.alarmId,
    detail: {
      'reason': reason ?? 'not_said',
      'low_volume': ring.volume < lowAlarmVolume,
      'missing_permissions': missing,
    },
  );
  await provider.timedOutHandled(ring);
  if (reason == 'no_sound' && context.mounted) {
    await showAlarmFeedback(
      context,
      alarmId: ring.alarmId,
      problem: 'no_sound',
      scheduled: ring.scheduled,
    );
  }
}

class _TimedOutSheet extends StatefulWidget {
  final TimedOutRing ring;
  final Future<List<AlarmProblem>> Function() findProblems;
  final void Function(List<String> titles) onFirstCheck;
  const _TimedOutSheet({
    required this.ring,
    required this.findProblems,
    required this.onFirstCheck,
  });

  @override
  State<_TimedOutSheet> createState() => _TimedOutSheetState();
}

class _TimedOutSheetState extends State<_TimedOutSheet>
    with WidgetsBindingObserver {
  /// Null until the phone's settings have been checked.
  List<AlarmProblem>? _problems;
  bool _volumeRaised = false;
  bool _vibrationOn = false;

  /// Set once "I slept through it" was chosen for an alarm that was at
  /// full volume already: a suggestion is shown before the sheet closes.
  bool _tip = false;

  TimedOutRing get _ring => widget.ring;

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
    // Back from the phone's settings: what is still missing?
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    var found = const <AlarmProblem>[];
    try {
      found = await widget.findProblems();
    } catch (e) {
      debugPrint('Alarm settings check failed: $e');
    }
    if (_problems == null) {
      widget.onFirstCheck([for (final p in found) p.title]);
    }
    if (mounted) setState(() => _problems = found);
  }

  /// The alarm this is about, if it still exists.
  AlarmItem? _alarm(AlarmProvider provider) {
    for (final a in provider.alarms) {
      if (a.id == _ring.alarmId) return a;
    }
    return null;
  }

  Future<void> _change(void Function(AlarmItem alarm) change) async {
    final provider = context.read<AlarmProvider>();
    final alarm = _alarm(provider);
    if (alarm == null) return;
    change(alarm);
    await provider.updateAlarm(alarm);
  }

  void _choose(String code) {
    if (code == 'slept' && _ring.volume >= 0.995 && !_tip) {
      setState(() => _tip = true);
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final use24 = context.watch<ThemeProvider>().use24Hour;
    final alarm = _alarm(context.watch<AlarmProvider>());
    final lowVolume = _ring.volume < lowAlarmVolume;
    final vibrationOff = !_ring.vibrate;
    final problems = _problems;
    final nothingWrong =
        problems != null && problems.isEmpty && !lowVolume && !vibrationOff;

    Widget cause(
      String text, {
      String? detail,
      String? action,
      VoidCallback? onFix,
    }) => Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (detail != null)
                  Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
        if (action != null) TextButton(onPressed: onFix, child: Text(action)),
      ],
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'You missed your '
                '${formatClock(_ring.scheduled, use24Hour: use24)} alarm',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(_ring.summary, style: muted),
              const SizedBox(height: 12),
              if (lowVolume)
                _volumeRaised
                    ? cause('The volume is now 100%.')
                    : cause(
                        'It was set to ring at '
                        '${(_ring.volume * 100).round()}% volume.',
                        action: alarm == null ? null : 'Raise to 100%',
                        onFix: () {
                          setState(() => _volumeRaised = true);
                          _change((a) => a.volume = 1.0);
                        },
                      ),
              for (final p in problems ?? const <AlarmProblem>[])
                cause(
                  p.title,
                  detail: p.detail,
                  action: p.action,
                  onFix: () async {
                    await p.fix();
                    await _check();
                  },
                ),
              if (vibrationOff)
                _vibrationOn
                    ? cause('Vibration is now on.')
                    : cause(
                        'Vibration was off for this alarm.',
                        action: alarm == null || alarm.vibrate
                            ? null
                            : 'Turn on',
                        onFix: () {
                          setState(() => _vibrationOn = true);
                          _change((a) => a.vibrate = true);
                        },
                      ),
              if (nothingWrong)
                Text('Everything looked right on the phone.', style: muted),
              const SizedBox(height: 14),
              if (_tip) ...[
                Text(
                  'It was already at full volume. Try a different ringtone, '
                  'or put the phone further from your bed.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'slept'),
                  child: const Text('OK'),
                ),
              ] else ...[
                Text('What happened?', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                for (final entry in timedOutReasons.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: OutlinedButton(
                      onPressed: () => _choose(entry.key),
                      child: Text(entry.value),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
