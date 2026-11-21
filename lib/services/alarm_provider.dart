/// Holds the list of alarms, keeps the system alarms in step with it and
/// tells the UI when one starts ringing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/alarm_log.dart';
import '../data/question_repository.dart';
import '../models/models.dart';
import 'alarm_backend.dart';
import 'question_service.dart';
import 'sync_service.dart';
import 'system_bridge.dart';
import 'theme_provider.dart';

/// Next time an alarm should fire, strictly after [now].
/// An empty [activeDays] means "ring once" (next occurrence of [time]).
/// Days use DateTime.weekday numbering: 1 = Monday ... 7 = Sunday.
DateTime calculateNextTrigger(
  TimeOfDay time,
  List<int> activeDays,
  DateTime now,
) {
  var candidate = DateTime(
    now.year,
    now.month,
    now.day,
    time.hour,
    time.minute,
  );
  if (!candidate.isAfter(now)) {
    candidate = DateTime(
      now.year,
      now.month,
      now.day + 1,
      time.hour,
      time.minute,
    );
  }
  if (activeDays.isEmpty) return candidate;

  // Build each day from calendar fields (not +24h) so DST changes
  // can't shift the wall-clock time.
  while (!activeDays.contains(candidate.weekday)) {
    candidate = DateTime(
      candidate.year,
      candidate.month,
      candidate.day + 1,
      time.hour,
      time.minute,
    );
  }
  return candidate;
}

/// "in 7 hours 5 minutes" style text for the gap between [now] and [next].
String describeTimeUntil(DateTime next, DateTime now) {
  final diff = next.difference(now);
  final days = diff.inDays;
  final hours = diff.inHours % 24;
  final minutes = diff.inMinutes % 60;
  if (diff.inMinutes < 1) return 'in less than a minute';
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
  final parts = [
    if (days > 0) unit(days, 'day'),
    if (hours > 0) unit(hours, 'hour'),
    if (minutes > 0 && days == 0) unit(minutes, 'minute'),
  ];
  return 'in ${parts.join(' ')}';
}

/// The day of [when] as people say it: "today", "tomorrow", otherwise the
/// weekday name ("Monday").
String describeDay(DateTime when, DateTime now) {
  // Calendar days apart, so 11 PM to 1 AM counts as "tomorrow".
  final days = DateTime(
    when.year,
    when.month,
    when.day,
  ).difference(DateTime(now.year, now.month, now.day)).inHours;
  if (days < 12) return 'today';
  if (days < 36) return 'tomorrow';
  const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return names[when.weekday - 1];
}

/// "Alarm set for tomorrow 8:13 AM, in 23 hours 59 minutes": shown after
/// an alarm is saved or switched on, so the user sees when it will ring.
String describeAlarmSet(
  DateTime next,
  DateTime now, {
  required bool use24Hour,
}) =>
    'Alarm set for ${describeDay(next, now)} '
    '${formatClock(next, use24Hour: use24Hour)}, '
    '${describeTimeUntil(next, now)}';

/// A ring that was due but, as far as this phone can tell, never
/// happened. The home screen asks the user about it.
class MissedRing {
  final int alarmId;
  final String label;
  final DateTime scheduled;
  const MissedRing({
    required this.alarmId,
    required this.label,
    required this.scheduled,
  });
}

class AlarmProvider extends ChangeNotifier {
  final AlarmBackend backend;

  List<AlarmItem> alarms = [];
  bool isAlarmRinging = false;

  final Completer<void> _loaded = Completer<void>();

  /// Completes once saved alarms have been read from storage.
  Future<void> get loaded => _loaded.future;

  /// Alarms that rang while another one was on screen, or before the UI
  /// was ready (app woken from a killed state).
  final List<AlarmItem> _waiting = [];
  Function(AlarmItem)? _onAlarmTriggered;
  StreamSubscription<AlarmRing>? _ringSubscription;

  set onAlarmTriggered(Function(AlarmItem)? callback) {
    _onAlarmTriggered = callback;
    _showNextWaiting();
  }

  AlarmProvider({AlarmBackend? backend})
    : backend = backend ?? AlarmBackend.forPlatform() {
    _loadAlarms().then((_) => unawaited(refillQuestionBank()));
    _ringSubscription = this.backend.rings.listen(_onRing);
    SyncService.onAlarmsRestored = _loadAlarms;
  }

  /// Asks the AI for fresh questions on the alarms' topics when they are
  /// running low, so nothing needs the network at ring time. Safe to call
  /// often; does nothing when signed out.
  Future<void> refillQuestionBank() async {
    try {
      await loaded;
      if (alarms.isEmpty) return;
      // An alarm with no topics means "any topic".
      final selectors = alarms.any((a) => a.topics.isEmpty)
          ? const <String>[]
          : alarms.expand((a) => a.topics).toSet().toList();
      final result = await QuestionService.topUp(selectors);
      if (result.error != null) {
        debugPrint('Question top-up failed: ${result.error}');
      }
    } catch (e) {
      debugPrint('Question top-up failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // System registrations.
  //
  // One alarm in the list is registered with the phone under several ids
  // ("slots"), all derived from the alarm's own id:
  //   id*10 + 0      a ring-once alarm
  //   id*10 + 1..7   a repeating alarm: one registration per weekday,
  //                  each at that weekday's next occurrence
  //   id*10 + 8      a running snooze
  //   id*10 + 9      a test ring from the simulator
  // Because every weekday is registered separately, missing one (phone
  // off, alarm dropped as too late) never stops the other days from
  // ringing, and nothing has to ring late to keep the schedule alive.
  // (Versions before this registered the bare id; those are cleaned up.)
  // ------------------------------------------------------------------
  static const int _onceSlot = 0;
  static const int _snoozeSlot = 8;
  static const int _testSlot = 9;

  int _slotId(AlarmItem a, int slot) => a.id * 10 + slot;

  /// The alarm a system registration belongs to, or null.
  AlarmItem? _alarmFor(int systemId) {
    for (final a in alarms) {
      if (a.id == systemId) return a; // registered by an older version
    }
    for (final a in alarms) {
      if (a.id == systemId ~/ 10) return a;
    }
    return null;
  }

  // Alarm id -> the system ids of it that are ringing right now.
  final Map<int, Set<int>> _ringingIds = {};

  Future<void> _onRing(AlarmRing ring) async {
    // On a cold start the ring event can arrive before storage is read.
    // Wait, so we match the real alarm instead of the generic fallback.
    await loaded;

    final known = _alarmFor(ring.id);
    final matched =
        known ??
        AlarmItem(
          id: ring.id,
          time: TimeOfDay.now(),
          topics: const [],
          activeDays: const [],
          label: ring.title,
        );
    _ringingIds.putIfAbsent(matched.id, () => {}).add(ring.id);
    final isTest = known != null && ring.id == _slotId(known, _testSlot);
    if (!isTest) {
      final isSnooze = known != null && ring.id == _slotId(known, _snoozeSlot);
      // A fresh ring (not a snooze coming back) starts the count again.
      if (!isSnooze) await _setSnoozeCount(matched.id, 0);
      final due = isSnooze ? null : await _takeExpected(matched.id);
      unawaited(
        AlarmLog.add(
          'rang',
          alarmId: matched.id,
          detail: {
            'system_id': ring.id,
            'after_snooze': isSnooze,
            'scheduled': ?due?.toIso8601String(),
            'late_seconds': ?(due == null
                ? null
                : DateTime.now().difference(due).inSeconds),
            'known_alarm': known != null,
          },
        ),
      );
      unawaited(SystemBridge.cancelPreAlarm(matched.id));
    }

    // The quiz comes first; nothing below may stop it from opening.
    if (!_waiting.any((a) => a.id == matched.id)) _waiting.add(matched);
    _showNextWaiting();

    // A "ring once" alarm has now fired: turn it off so it can never
    // be rescheduled for tomorrow.
    if (matched.activeDays.isEmpty && matched.isEnabled && !isTest) {
      matched.isEnabled = false;
      try {
        await saveAlarms();
      } catch (e) {
        debugPrint('Could not save the alarm list: $e');
      }
    }
  }

  void _showNextWaiting() {
    if (isAlarmRinging || _waiting.isEmpty || _onAlarmTriggered == null) return;
    isAlarmRinging = true;
    _onAlarmTriggered!(_waiting.removeAt(0));
  }

  /// The ring screen calls this when it closes. Shows the next alarm if
  /// another one started ringing meanwhile.
  void ringScreenClosed() {
    isAlarmRinging = false;
    _showNextWaiting();
  }

  Future<AlarmRequest> _request(
    AlarmItem alarm,
    DateTime when, {
    required int systemId,
    String? title,
    String? body,
  }) async {
    final name = alarm.label.isEmpty ? 'Quiz Alarm' : alarm.label;
    var topics = 'your topics';
    try {
      topics = await QuestionRepository.describeSelection(alarm.topics);
    } catch (_) {}
    return AlarmRequest(
      id: systemId,
      dateTime: when,
      audioPath: alarm.audioPath,
      vibrate: alarm.vibrate,
      // Always the loudest the phone can go, whatever its volume is set to.
      volume: 1.0,
      fadeDuration: alarm.fadeDuration,
      title: title ?? name,
      body:
          body ??
          'Answer ${alarm.requiredStreak} in a row ($topics) to dismiss!',
    );
  }

  bool _registered(int systemId, DateTime now) {
    final t = backend.scheduledTime(systemId);
    return t != null && t.isAfter(now);
  }

  /// Cancels a registration if there is one. With [keepRinging] a ringing
  /// one is left alone.
  Future<void> _cancel(int systemId, {bool keepRinging = false}) async {
    final ringing = await backend.isRinging(systemId);
    if (ringing && keepRinging) return;
    if (ringing || backend.scheduledTime(systemId) != null) {
      await backend.stop(systemId);
    }
  }

  /// When [alarm] will next ring according to the phone (including a
  /// running snooze), or null if nothing is registered.
  ///
  /// A switched-off alarm counts only through its snooze: anything else
  /// still registered for it is a leftover and must not show as "next".
  DateTime? nextRing(AlarmItem alarm) {
    if (!alarm.isEnabled) return snoozedUntil(alarm);
    final now = DateTime.now();
    DateTime? best;
    for (final id in [
      alarm.id,
      for (var s = 0; s <= 8; s++) _slotId(alarm, s),
    ]) {
      final t = backend.scheduledTime(id);
      if (t != null && t.isAfter(now) && (best == null || t.isBefore(best))) {
        best = t;
      }
    }
    return best;
  }

  /// For problem reports: what the phone has registered for [alarm]
  /// (slot name -> time).
  Map<String, String> registrations(AlarmItem alarm) {
    const names = [
      'once',
      'mon',
      'tue',
      'wed',
      'thu',
      'fri',
      'sat',
      'sun',
      'snooze',
    ];
    return {
      for (var s = 0; s <= 8; s++)
        if (backend.scheduledTime(_slotId(alarm, s)) != null)
          names[s]: backend.scheduledTime(_slotId(alarm, s))!.toIso8601String(),
    };
  }

  /// For problem reports: whether any part of [alarm] is sounding now.
  Future<bool> isRingingNow(AlarmItem alarm) async {
    for (var s = 0; s <= 8; s++) {
      if (await backend.isRinging(_slotId(alarm, s))) return true;
    }
    return false;
  }

  // ------------------------------------------------------------------
  // How often the current ring of an alarm has been snoozed. A snoozed
  // alarm cannot simply be switched off (or deleted) on the Alarms tab:
  // that would be a way round the quiz after a single snooze. Only after
  // [snoozesBeforeTurnOff] snoozes may it be switched off there. Kept in
  // preferences, because the app is often closed between a snooze and
  // its ring.
  // ------------------------------------------------------------------
  static const int snoozesBeforeTurnOff = 2;
  static const String _snoozeCountPref = 'alarm_snooze_counts';
  Map<String, dynamic> _snoozeCounts = {};

  int snoozeCount(int alarmId) => (_snoozeCounts['$alarmId'] as int?) ?? 0;

  /// Shown when someone tries to switch off a snoozed alarm too early.
  static const String snoozeLockMessage = 'Snooze once more to turn this off.';

  /// True when [alarm] has been snoozed often enough to be switched off
  /// without finishing the quiz.
  bool canTurnOff(AlarmItem alarm) =>
      snoozeCount(alarm.id) >= snoozesBeforeTurnOff;

  /// True while [alarm] is snoozed and may not be switched off or deleted
  /// yet.
  bool lockedBySnooze(AlarmItem alarm) =>
      snoozedUntil(alarm) != null && !canTurnOff(alarm);

  Future<void> _setSnoozeCount(int alarmId, int count) async {
    if (count <= 0) {
      if (_snoozeCounts.remove('$alarmId') == null) return;
    } else {
      _snoozeCounts['$alarmId'] = count;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_snoozeCountPref, jsonEncode(_snoozeCounts));
    } catch (_) {}
  }

  /// When a running snooze of [alarm] will ring, or null.
  DateTime? snoozedUntil(AlarmItem alarm) {
    final t = backend.scheduledTime(_slotId(alarm, _snoozeSlot));
    return t != null && t.isAfter(DateTime.now()) ? t : null;
  }

  /// The next scheduled ring, leaving a running snooze aside.
  DateTime? _nextMainRing(AlarmItem alarm) {
    final now = DateTime.now();
    DateTime? best;
    for (final id in [
      alarm.id,
      for (var s = 0; s <= 7; s++) _slotId(alarm, s),
    ]) {
      final t = backend.scheduledTime(id);
      if (t != null && t.isAfter(now) && (best == null || t.isBefore(best))) {
        best = t;
      }
    }
    return best;
  }

  // ------------------------------------------------------------------
  // What should happen next, remembered outside the alarm system, so a
  // ring that never came can be noticed (see _findMissed).
  // ------------------------------------------------------------------
  static const String _expectedPref = 'alarm_expected';

  /// Rings that were due but did not happen; the home screen asks the
  /// user about each and then calls [missedHandled].
  final List<MissedRing> missed = [];

  void missedHandled(MissedRing ring) {
    missed.remove(ring);
    notifyListeners();
  }

  Future<Map<String, dynamic>> _readExpected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (jsonDecode(prefs.getString(_expectedPref) ?? '{}') as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeExpected(Map<String, dynamic> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_expectedPref, jsonEncode(map));
    } catch (_) {}
  }

  /// Removes and returns the ring that was expected of an alarm.
  Future<DateTime?> _takeExpected(int alarmId) async {
    final map = await _readExpected();
    final ms = map.remove('$alarmId');
    if (ms == null) return null;
    await _writeExpected(map);
    return DateTime.fromMillisecondsSinceEpoch(ms as int);
  }

  /// After anything that changes when [alarm] rings: remembers the next
  /// ring, notes it in the diary and moves the heads-up notification.
  Future<void> _afterArming(AlarmItem alarm) async {
    try {
      final next = _nextMainRing(alarm);
      final map = await _readExpected();
      final before = map['${alarm.id}'];
      // A ring that is due this very moment (the app may have been started
      // BY it) is still to be matched with its "rang" entry: keep it.
      if (before is int) {
        final late = DateTime.now().millisecondsSinceEpoch - before;
        if (late >= 0 && late < const Duration(minutes: 3).inMilliseconds) {
          await _syncHeadsUp(alarm, next);
          return;
        }
      }
      if (next == null) {
        map.remove('${alarm.id}');
      } else {
        map['${alarm.id}'] = next.millisecondsSinceEpoch;
      }
      if (before != map['${alarm.id}']) {
        await _writeExpected(map);
        if (next != null) {
          unawaited(
            AlarmLog.add(
              'scheduled',
              alarmId: alarm.id,
              detail: {'for': next.toIso8601String()},
            ),
          );
        }
      }
      await _syncHeadsUp(alarm, next);
    } catch (e) {
      debugPrint('Could not note the next ring of ${alarm.id}: $e');
    }
  }

  /// How long before an alarm the heads-up notification arrives.
  static const Duration headsUpLead = Duration(minutes: 5);

  /// Places (or removes) the "alarm in 5 minutes" notification, which
  /// vibrates once and offers to skip the alarm for someone already up.
  Future<void> _syncHeadsUp(AlarmItem alarm, DateTime? next) async {
    final prefs = await SharedPreferences.getInstance();
    final wanted = prefs.getBool('headsUp') ?? true;
    final at = next?.subtract(headsUpLead);
    if (!wanted ||
        !alarm.isEnabled ||
        at == null ||
        !at.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
      await SystemBridge.cancelPreAlarm(alarm.id);
      return;
    }
    final name = alarm.label.isEmpty ? 'Alarm' : alarm.label;
    final time = formatClock(
      next!,
      use24Hour: prefs.getBool('use24Hour') ?? false,
    );
    await SystemBridge.schedulePreAlarm(
      alarm.id,
      at: at,
      ringAt: next,
      title: 'Alarm in ${headsUpLead.inMinutes} minutes',
      body: '$name at $time. Already up? Tap Skip to cancel this one.',
    );
  }

  /// Re-places every heads-up notification (after the setting changed).
  Future<void> refreshHeadsUps() async {
    for (final a in alarms) {
      await _syncHeadsUp(a, _nextMainRing(a));
    }
  }

  /// Notices rings that were due while the app was not running and, as
  /// far as the diary shows, never happened.
  Future<void> _findMissed() async {
    try {
      final map = await _readExpected();
      final now = DateTime.now();
      var changed = false;
      for (final a in alarms) {
        final ms = map['${a.id}'];
        if (ms == null) continue;
        final due = DateTime.fromMillisecondsSinceEpoch(ms as int);
        // Still to come, or due so recently that it may be sounding now.
        if (now.difference(due) < const Duration(minutes: 3)) continue;
        map.remove('${a.id}');
        changed = true;
        var ringing = false;
        for (var s = 0; s <= 8; s++) {
          ringing = ringing || await backend.isRinging(_slotId(a, s));
        }
        final rang = (await AlarmLog.recent(alarmId: a.id, limit: 40)).any(
          (e) =>
              e.type == 'rang' &&
              e.at.isAfter(due.subtract(const Duration(minutes: 1))),
        );
        if (ringing || rang) continue;
        missed.add(MissedRing(alarmId: a.id, label: a.label, scheduled: due));
        unawaited(
          AlarmLog.add(
            'missed',
            alarmId: a.id,
            urgent: true,
            detail: {
              'scheduled': due.toIso8601String(),
              'noticed_after_minutes': now.difference(due).inMinutes,
            },
          ),
        );
      }
      if (changed) await _writeExpected(map);
    } catch (e) {
      debugPrint('Could not check for missed alarms: $e');
    }
  }

  /// Brings the phone's registrations in line with [alarm].
  ///
  /// With [onlyMissing] (used when the app starts) registrations that are
  /// already in place, ringing, or about to sound are left untouched:
  /// registering again would silence a ringing alarm.
  Future<void> _scheduleNativeAlarm(
    AlarmItem alarm, {
    bool onlyMissing = false,
    bool atStartup = false,
  }) async {
    final now = DateTime.now();
    // A skipped ring: nothing is scheduled up to and including it.
    final skip = alarm.skipUntil;
    final from = skip != null && skip.isAfter(now) ? skip : now;
    final wanted = <int, DateTime>{}; // slot -> when
    if (alarm.isEnabled) {
      if (alarm.activeDays.isEmpty) {
        wanted[_onceSlot] = calculateNextTrigger(alarm.time, const [], from);
      } else {
        for (final day in alarm.activeDays.toSet()) {
          if (day < 1 || day > 7) continue;
          wanted[day] = calculateNextTrigger(alarm.time, [day], from);
        }
      }
    }

    // Remove what is no longer wanted: days that were unticked, the
    // ring-once slot and the old-style registration. A running snooze is
    // never touched here: editing an alarm must not cancel it (only
    // switching the alarm off does, see setEnabled).
    await _cancel(alarm.id, keepRinging: onlyMissing);
    for (var slot = 0; slot <= 7; slot++) {
      if (!wanted.containsKey(slot)) {
        await _cancel(_slotId(alarm, slot), keepRinging: onlyMissing);
      }
    }

    final dueToday = DateTime(
      now.year,
      now.month,
      now.day,
      alarm.time.hour,
      alarm.time.minute,
    );
    final sinceDue = now.difference(dueToday);
    final justDue =
        !sinceDue.isNegative && sinceDue < const Duration(minutes: 2);

    for (final entry in wanted.entries) {
      final id = _slotId(alarm, entry.key);
      // Registering a slot again silences it, so one that is sounding, or
      // waiting its turn behind another ringing alarm, is never touched.
      // (It is brought up to date when it is dismissed.)
      if (await backend.isRinging(id) || await backend.isWaiting(id)) continue;
      if (onlyMissing) {
        // In place already, at the right moment. A registration at the
        // WRONG moment (the time zone changed, or an earlier edit only
        // half succeeded) is corrected.
        if (_registered(id, now) &&
            backend.scheduledTime(id)!.isAtSameMomentAs(entry.value)) {
          continue;
        }
        // At app start: came due in the last two minutes, so it is about
        // to sound. (After a dismissal the same slot must be re-armed.)
        if (atStartup &&
            justDue &&
            (entry.key == _onceSlot || entry.key == now.weekday)) {
          continue;
        }
      }
      await backend.set(await _request(alarm, entry.value, systemId: id));
    }
    await _afterArming(alarm);
  }

  /// Arms [alarm] with the system. A failure is logged, not thrown: the
  /// alarm list must still be saved and shown.
  Future<void> _arm(AlarmItem alarm, {bool onlyMissing = false}) async {
    try {
      await _scheduleNativeAlarm(alarm, onlyMissing: onlyMissing);
    } catch (e) {
      debugPrint('Could not schedule alarm ${alarm.id}: $e');
    }
  }

  // Changes to the phone's registrations run one after another. Two at
  // once (a quick toggle right after an edit, say) would interleave their
  // many small steps and leave a mix of both behind.
  Future<void> _chain = Future<void>.value();

  Future<T> _oneAtATime<T>(Future<T> Function() work) {
    final result = _chain.then((_) => work());
    _chain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Stops every registration of [alarm], whatever state it is in. The
  /// ring screen's last resort when a normal dismissal fails.
  Future<void> forceStop(AlarmItem alarm) async {
    _ringingIds.remove(alarm.id);
    for (final id in [
      alarm.id,
      for (var s = 0; s <= 9; s++) _slotId(alarm, s),
    ]) {
      try {
        if (await backend.isRinging(id)) await backend.stop(id);
      } catch (e) {
        debugPrint('Could not stop $id: $e');
      }
    }
  }

  /// Alarms are listed by time of day, earliest first, on or off.
  void _sort() {
    alarms.sort((a, b) {
      final byTime = (a.time.hour * 60 + a.time.minute).compareTo(
        b.time.hour * 60 + b.time.minute,
      );
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  Future<void> addAlarm(AlarmItem alarm) => _oneAtATime(() async {
    alarm.activeDays = alarm.activeDays.toSet().toList()..sort();
    alarms.add(alarm);
    _sort();
    notifyListeners(); // show it at once; arming takes a moment
    await _arm(alarm);
    unawaited(
      AlarmLog.add('created', alarmId: alarm.id, detail: _summary(alarm)),
    );
    await saveAlarms();
    unawaited(refillQuestionBank());
  });

  Future<void> updateAlarm(AlarmItem alarm) => _oneAtATime(() async {
    alarm.activeDays = alarm.activeDays.toSet().toList()..sort();
    final index = alarms.indexWhere((a) => a.id == alarm.id);
    if (index != -1) {
      final old = alarms[index];
      // A skipped ring stays skipped unless the alarm's time or days moved.
      final sameDays =
          old.activeDays.toSet().length == alarm.activeDays.length &&
          old.activeDays.toSet().containsAll(alarm.activeDays);
      if (old.time == alarm.time && sameDays) {
        alarm.skipUntil ??= old.skipUntil;
      }
      alarms[index] = alarm;
    } else {
      alarms.add(alarm);
    }
    _sort();
    notifyListeners(); // show it at once; arming takes a moment
    await _arm(alarm);
    unawaited(
      AlarmLog.add(
        'edited',
        alarmId: alarm.id,
        detail: {
          ..._summary(alarm),
          'snooze_running': snoozedUntil(alarm) != null,
        },
      ),
    );
    await saveAlarms();
    unawaited(refillQuestionBank());
  });

  Map<String, Object?> _summary(AlarmItem a) => {
    'time':
        '${a.time.hour.toString().padLeft(2, '0')}:'
        '${a.time.minute.toString().padLeft(2, '0')}',
    'days': a.activeDays,
    'enabled': a.isEnabled,
    'streak': a.requiredStreak,
    'snooze_minutes': a.snoozeMinutes,
  };

  /// The switch on an alarm's card. Switching off also cancels a running
  /// snooze: after this nothing of the alarm will ring.
  ///
  /// Returns false, changing nothing, when switching off is refused because
  /// the alarm is snoozed and has not been snoozed twice yet (see
  /// [lockedBySnooze]).
  Future<bool> setEnabled(AlarmItem card, bool on) => _oneAtATime(() async {
    // The card may still hold the alarm as it was before an edit.
    final alarm = alarms.firstWhere((a) => a.id == card.id, orElse: () => card);
    if (!alarms.contains(alarm)) return true; // deleted meanwhile
    if (!on && lockedBySnooze(alarm)) {
      notifyListeners(); // puts the switch back
      return false;
    }
    alarm.isEnabled = on;
    alarm.skipUntil = null;
    notifyListeners();
    if (!on) {
      try {
        await _cancel(_slotId(alarm, _snoozeSlot));
      } catch (e) {
        debugPrint('Could not cancel the snooze of ${alarm.id}: $e');
      }
    }
    await _arm(alarm);
    unawaited(
      AlarmLog.add(
        on ? 'switched_on' : 'switched_off',
        alarmId: alarm.id,
        detail: {'snoozes': snoozeCount(alarm.id)},
      ),
    );
    if (!on) await _setSnoozeCount(alarm.id, 0);
    await saveAlarms();
    return true;
  });

  /// Skips the next ring only (the heads-up notification's "Skip"): a
  /// running snooze is cancelled, a ring-once alarm is switched off, a
  /// repeating alarm misses one day and carries on. Returns a sentence
  /// saying what was done, or null if there was nothing to skip.
  ///
  /// [ringAt] is the ring the heads-up notification was about. If that is
  /// no longer the alarm's next ring (the notification was tapped late,
  /// after the alarm started, or after it was changed) nothing is skipped:
  /// a stale tap must never silence a ringing alarm or eat tomorrow's.
  Future<String?> skipNext(int alarmId, {DateTime? ringAt}) =>
      _oneAtATime(() async {
        await loaded;
        final i = alarms.indexWhere((a) => a.id == alarmId);
        if (i == -1) return null;
        final alarm = alarms[i];
        if (await isRingingNow(alarm)) return null;
        final snooze = ringAt == null ? snoozedUntil(alarm) : null;
        final next = _nextMainRing(alarm);
        if (snooze == null && next == null) return null;
        if (ringAt != null &&
            (next == null ||
                next.difference(ringAt).abs() > const Duration(minutes: 1))) {
          return null;
        }
        String done;
        if (snooze != null) {
          await _cancel(_slotId(alarm, _snoozeSlot));
          done = 'Snooze cancelled.';
        } else if (alarm.activeDays.isEmpty) {
          alarm.isEnabled = false;
          await _arm(alarm);
          done = 'Alarm switched off.';
        } else {
          alarm.skipUntil = next;
          await _arm(alarm);
          final after = _nextMainRing(alarm);
          done = after == null
              ? 'Skipped.'
              : 'Skipped. It rings next '
                    '${describeTimeUntil(after, DateTime.now())}.';
        }
        unawaited(
          AlarmLog.add(
            'skipped',
            alarmId: alarm.id,
            detail: {'was_due': (snooze ?? next)!.toIso8601String()},
          ),
        );
        await saveAlarms();
        return done;
      });

  Future<int> deleteAlarm(int id) => deleteAlarms([id]);

  /// Deletes several alarms at once (multi-select on the Alarms tab).
  /// A snoozed alarm that may not be switched off yet is not deleted
  /// either; returns how many were kept for that reason.
  Future<int> deleteAlarms(Iterable<int> ids) => _oneAtATime(() async {
    final asked = ids.toSet();
    final locked = {
      for (final a in alarms)
        if (asked.contains(a.id) && lockedBySnooze(a)) a.id,
    };
    final wanted = asked.difference(locked);
    final gone = alarms.where((a) => wanted.contains(a.id)).toList();
    alarms.removeWhere((a) => wanted.contains(a.id));
    notifyListeners(); // gone from the list at once
    for (final a in gone) {
      try {
        await _cancel(a.id);
        for (var slot = 0; slot <= 9; slot++) {
          await _cancel(_slotId(a, slot));
        }
      } catch (e) {
        debugPrint('Could not cancel alarm ${a.id}: $e');
      }
      _ringingIds.remove(a.id);
      await _takeExpected(a.id);
      await SystemBridge.cancelPreAlarm(a.id);
      unawaited(AlarmLog.add('deleted', alarmId: a.id));
    }
    await saveAlarms();
    return locked.length;
  });

  /// Silences whatever of [alarm] is ringing. Returns the system ids that
  /// were ringing.
  Future<Set<int>> _silence(AlarmItem alarm) async {
    final ringing = _ringingIds.remove(alarm.id) ?? <int>{};
    if (ringing.isEmpty && alarms.any((a) => a.id == alarm.id)) {
      // Not told which registration rang (should not happen): find it.
      for (final id in [
        alarm.id,
        for (var s = 0; s <= 9; s++) _slotId(alarm, s),
      ]) {
        if (await backend.isRinging(id)) ringing.add(id);
      }
    }
    if (ringing.isEmpty) ringing.add(alarm.id);
    for (final id in ringing) {
      await backend.stop(id);
    }
    return ringing;
  }

  Future<void> dismissAlarm(AlarmItem alarm) async {
    final inList = alarms.any((a) => a.id == alarm.id);
    final ringing = await _silence(alarm);
    if (inList && ringing.every((id) => id == _slotId(alarm, _testSlot))) {
      return; // a simulator test ring: the real schedule was never touched
    }
    unawaited(
      AlarmLog.add(
        'dismissed',
        alarmId: alarm.id,
        detail: {'snoozes': snoozeCount(alarm.id)},
      ),
    );
    await _setSnoozeCount(alarm.id, 0);
    if (inList && alarm.isEnabled && alarm.activeDays.isNotEmpty) {
      // Registers the weekday that just rang for next week; the other
      // days are already in place.
      await _arm(alarm, onlyMissing: true);
    } else {
      alarm.isEnabled = false;
      // Nothing of a switched-off alarm may stay registered (an old
      // weekday slot would otherwise ring, and show as the next alarm).
      // An alarm that is not in the list has no slots of its own.
      if (inList) {
        try {
          await _cancel(alarm.id);
          for (var slot = 0; slot <= _snoozeSlot; slot++) {
            await _cancel(_slotId(alarm, slot));
          }
        } catch (e) {
          debugPrint('Could not clear alarm ${alarm.id}: $e');
        }
      }
      await saveAlarms();
    }
    unawaited(refillQuestionBank());
  }

  /// Silences [alarm] and rings it again after its own snooze length.
  /// Returns when it will ring.
  Future<DateTime> snoozeAlarm(AlarmItem alarm) async {
    final inList = alarms.any((a) => a.id == alarm.id);
    final ringing = await _silence(alarm);
    if (inList && alarm.isEnabled && alarm.activeDays.isNotEmpty) {
      await _arm(alarm, onlyMissing: true); // next week's ring of this day
    }
    final until = DateTime.now().add(Duration(minutes: alarm.snoozeMinutes));
    await _setSnoozeCount(alarm.id, snoozeCount(alarm.id) + 1);
    unawaited(
      AlarmLog.add(
        'snoozed',
        alarmId: alarm.id,
        detail: {'until': until.toIso8601String()},
      ),
    );
    await backend.set(
      await _request(
        alarm,
        until,
        systemId: inList ? _slotId(alarm, _snoozeSlot) : ringing.first,
        title: '${alarm.label} (Snoozed)',
        body:
            'Snooze ended! Answer ${alarm.requiredStreak} in a row to dismiss.',
      ),
    );
    notifyListeners();
    return until;
  }

  /// Makes [alarm] ring [after] from now without touching its schedule
  /// (used by the simulator's "Ring now" button).
  Future<void> ringSoon(
    AlarmItem alarm, {
    Duration after = const Duration(seconds: 3),
  }) async {
    await backend.set(
      await _request(
        alarm,
        DateTime.now().add(after),
        systemId: _slotId(alarm, _testSlot),
      ),
    );
  }

  Future<void> _loadAlarms() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('saved_alarms');
      if (raw == null) return;

      final loadedAlarms = <AlarmItem>[];
      try {
        for (final e in jsonDecode(raw) as List) {
          try {
            loadedAlarms.add(AlarmItem.fromJson(e as Map<String, dynamic>));
          } catch (err) {
            debugPrint('Skipping unreadable alarm: $err');
          }
        }
      } catch (err) {
        debugPrint('Saved alarms unreadable: $err');
      }
      alarms = loadedAlarms;
      try {
        _snoozeCounts = (jsonDecode(
          prefs.getString(_snoozeCountPref) ?? '{}',
        ) as Map).cast<String, dynamic>();
      } catch (_) {
        _snoozeCounts = {};
      }
      _sort();
      await _findMissed();

      var changed = false;
      final now = DateTime.now();
      for (final a in alarms.where((a) => a.isEnabled)) {
        try {
          if (a.activeDays.isEmpty) {
            // A "ring once" alarm that is neither registered, ringing nor
            // about to sound has fired or was missed. Registering it again
            // would push it to tomorrow, so switch it off instead.
            final once = _slotId(a, _onceSlot);
            final due = DateTime(
              now.year,
              now.month,
              now.day,
              a.time.hour,
              a.time.minute,
            );
            final late = now.difference(due);
            final alive =
                _registered(once, now) ||
                _registered(a.id, now) ||
                await backend.isRinging(once) ||
                await backend.isRinging(a.id) ||
                (!late.isNegative && late < const Duration(minutes: 2));
            if (!alive) {
              a.isEnabled = false;
              changed = true;
              continue;
            }
          }
          // Fills in whatever is missing (a weekday that was dropped while
          // the phone was off, or everything after an app update) without
          // disturbing a ringing alarm or a snooze.
          await _scheduleNativeAlarm(a, onlyMissing: true, atStartup: true);
        } catch (err) {
          debugPrint('Could not restore alarm ${a.id}: $err');
        }
      }
      if (changed) {
        await saveAlarms();
      } else {
        notifyListeners();
      }
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  Future<void> saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'saved_alarms',
      jsonEncode(alarms.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
    SyncService.schedule(); // keeps the server's backup of the alarms fresh
  }

  @override
  void dispose() {
    _ringSubscription?.cancel();
    super.dispose();
  }
}
