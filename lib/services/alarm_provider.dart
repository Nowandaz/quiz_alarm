/// Holds the list of alarms, keeps the system alarms in step with it and
/// tells the UI when one starts ringing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import 'alarm_backend.dart';
import 'question_service.dart';
import 'sync_service.dart';

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

    // A "ring once" alarm has now fired: turn it off so it can never
    // be rescheduled for tomorrow.
    if (matched.activeDays.isEmpty && matched.isEnabled && !isTest) {
      matched.isEnabled = false;
      await saveAlarms();
    }

    if (!_waiting.any((a) => a.id == matched.id)) _waiting.add(matched);
    _showNextWaiting();
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
  DateTime? nextRing(AlarmItem alarm) {
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
    final wanted = <int, DateTime>{}; // slot -> when
    if (alarm.isEnabled) {
      if (alarm.activeDays.isEmpty) {
        wanted[_onceSlot] = calculateNextTrigger(alarm.time, const [], now);
      } else {
        for (final day in alarm.activeDays.toSet()) {
          if (day < 1 || day > 7) continue;
          wanted[day] = calculateNextTrigger(alarm.time, [day], now);
        }
      }
    }

    // Remove what is no longer wanted: days that were unticked, the
    // ring-once slot, the old-style registration, and (when the alarm is
    // switched off) a running snooze.
    await _cancel(alarm.id, keepRinging: onlyMissing);
    for (var slot = 0; slot <= 7; slot++) {
      if (!wanted.containsKey(slot)) {
        await _cancel(_slotId(alarm, slot), keepRinging: onlyMissing);
      }
    }
    if (!alarm.isEnabled) await _cancel(_slotId(alarm, _snoozeSlot));

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
      if (onlyMissing) {
        if (await backend.isRinging(id)) continue;
        if (_registered(id, now)) continue;
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

  Future<void> addAlarm(AlarmItem alarm) async {
    alarms.add(alarm);
    await _arm(alarm);
    await saveAlarms();
    unawaited(refillQuestionBank());
  }

  Future<void> updateAlarm(AlarmItem alarm) async {
    final index = alarms.indexWhere((a) => a.id == alarm.id);
    if (index != -1) {
      alarms[index] = alarm;
    } else {
      alarms.add(alarm);
    }
    await _arm(alarm);
    await saveAlarms();
    unawaited(refillQuestionBank());
  }

  Future<void> deleteAlarm(int id) => deleteAlarms([id]);

  /// Deletes several alarms at once (multi-select on the Alarms tab).
  Future<void> deleteAlarms(Iterable<int> ids) async {
    final wanted = ids.toSet();
    final gone = alarms.where((a) => wanted.contains(a.id)).toList();
    alarms.removeWhere((a) => wanted.contains(a.id));
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
    }
    await saveAlarms();
  }

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
    if (inList && alarm.isEnabled && alarm.activeDays.isNotEmpty) {
      // Registers the weekday that just rang for next week; the other
      // days are already in place.
      await _arm(alarm, onlyMissing: true);
    } else {
      alarm.isEnabled = false;
      await saveAlarms();
    }
    unawaited(refillQuestionBank());
  }

  /// Silences [alarm] and rings it again after its own snooze length.
  Future<void> snoozeAlarm(AlarmItem alarm) async {
    final inList = alarms.any((a) => a.id == alarm.id);
    final ringing = await _silence(alarm);
    if (inList && alarm.isEnabled && alarm.activeDays.isNotEmpty) {
      await _arm(alarm, onlyMissing: true); // next week's ring of this day
    }
    await backend.set(
      await _request(
        alarm,
        DateTime.now().add(Duration(minutes: alarm.snoozeMinutes)),
        systemId: inList ? _slotId(alarm, _snoozeSlot) : ringing.first,
        title: '${alarm.label} (Snoozed)',
        body:
            'Snooze ended! Answer ${alarm.requiredStreak} in a row to dismiss.',
      ),
    );
    notifyListeners();
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
