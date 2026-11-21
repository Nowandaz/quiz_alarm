import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/alarm_backend.dart';
import 'package:quiz_alarm/services/alarm_provider.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

/// Records what the provider asks the system to do.
class FakeBackend implements AlarmBackend {
  final Map<int, DateTime> registered = {};
  final Set<int> ringing = {};
  final List<int> setCalls = [];
  final List<int> stopCalls = [];
  bool failSet = false;
  final StreamController<AlarmRing> controller = StreamController<AlarmRing>();

  @override
  bool get isSimulated => true;
  @override
  Future<void> init() async {}
  @override
  Stream<AlarmRing> get rings => controller.stream;
  @override
  Future<void> set(AlarmRequest request) async {
    if (failSet) throw StateError('arming failed');
    setCalls.add(request.id);
    ringing.remove(request.id);
    registered[request.id] = request.dateTime;
  }

  @override
  Future<void> stop(int id) async {
    stopCalls.add(id);
    ringing.remove(id);
    registered.remove(id);
  }

  @override
  Future<bool> isRinging(int id) async => ringing.contains(id);

  /// Due, but waiting behind another ringing alarm.
  final Set<int> waiting = {};
  @override
  Future<bool> isWaiting(int id) async => waiting.contains(id);
  @override
  DateTime? scheduledTime(int id) => registered[id];
}

AlarmItem alarm(int id, {List<int> days = const [1, 2, 3, 4, 5, 6, 7]}) =>
    AlarmItem(
      id: id,
      time: const TimeOfDay(hour: 7, minute: 0),
      topics: const [],
      activeDays: days,
    );

Map<String, Object> saved(List<AlarmItem> alarms) => {
  'saved_alarms': jsonEncode(alarms.map((a) => a.toJson()).toList()),
};

void main() {
  // System ids: alarm id * 10 + slot (0 once, 1-7 weekday, 8 snooze, 9 test).
  int slot(int id, int n) => id * 10 + n;
  final today = DateTime.now().weekday;

  test('a repeating alarm registers every chosen weekday separately', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    await provider.addAlarm(alarm(5, days: const [1, 3, 5]));

    expect(backend.registered.keys.toSet(), {
      slot(5, 1),
      slot(5, 3),
      slot(5, 5),
    });
    for (final day in [1, 3, 5]) {
      final when = backend.registered[slot(5, day)]!;
      expect(when.weekday, day);
      expect(when.hour, 7);
      expect(when.isAfter(DateTime.now()), isTrue);
    }

    // Unticking a day removes just that registration.
    await provider.updateAlarm(alarm(5, days: const [1, 5]));
    expect(backend.registered.keys.toSet(), {slot(5, 1), slot(5, 5)});

    // Switching it off removes them all.
    await provider.updateAlarm(alarm(5, days: const [1, 5])..isEnabled = false);
    expect(backend.registered, isEmpty);
  });

  test('a weekday lost while the phone was off is restored; nothing else '
      'is touched', () async {
    await resetApp(prefs: saved([alarm(1)]));
    final backend = FakeBackend();
    // Every day is registered except one that was dropped at boot.
    final lost = today % 7 + 1; // tomorrow
    for (var d = 1; d <= 7; d++) {
      if (d != lost) {
        backend.registered[slot(1, d)] = calculateNextTrigger(
          const TimeOfDay(hour: 7, minute: 0),
          [d],
          DateTime.now(),
        );
      }
    }
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;

    expect(backend.setCalls, [slot(1, lost)]);
    expect(backend.stopCalls, isEmpty);
  });

  test(
    'opening the app never re-registers a ringing or snoozed alarm',
    () async {
      await resetApp(
        prefs: saved([
          alarm(1, days: [today]),
        ]),
      );
      final backend = FakeBackend()
        ..ringing.add(slot(1, today)) // ringing right now
        ..registered[slot(1, 8)] = DateTime.now().add(
          const Duration(minutes: 4),
        );
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;

      expect(backend.setCalls, isEmpty);
      expect(backend.stopCalls, isEmpty);
      expect(backend.ringing, contains(slot(1, today)));
    },
  );

  test('registrations made by the previous app version are replaced', () async {
    await resetApp(
      prefs: saved([
        alarm(1, days: const [2]),
      ]),
    );
    final backend = FakeBackend()
      ..registered[1] = DateTime.now().add(const Duration(hours: 3));
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;

    expect(backend.registered.keys.toSet(), {slot(1, 2)});
  });

  test(
    'a ring-once alarm that is no longer registered is switched off',
    () async {
      await resetApp(prefs: saved([alarm(1, days: const [])]));
      final backend = FakeBackend();
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;

      expect(backend.setCalls, isEmpty);
      expect(provider.alarms.single.isEnabled, isFalse);
    },
  );

  test('a ring-once alarm that is still registered is left alone', () async {
    await resetApp(prefs: saved([alarm(1, days: const [])]));
    final backend = FakeBackend()
      ..registered[slot(1, 0)] = calculateNextTrigger(
        const TimeOfDay(hour: 7, minute: 0),
        const [],
        DateTime.now(),
      );
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;

    expect(backend.setCalls, isEmpty);
    expect(provider.alarms.single.isEnabled, isTrue);
  });

  test('rings reach the UI one at a time, even before it is ready', () async {
    await resetApp(prefs: saved([alarm(1), alarm(2, days: const [])]));
    final backend = FakeBackend()
      ..registered[slot(2, 0)] = DateTime.now().add(const Duration(hours: 1));
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;

    backend.controller.add(AlarmRing(slot(1, today), 'one'));
    backend.controller.add(AlarmRing(slot(2, 0), 'two'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final shown = <int>[];
    provider.onAlarmTriggered = (a) => shown.add(a.id);
    expect(shown, [1]);
    expect(provider.isAlarmRinging, isTrue);

    provider.ringScreenClosed();
    expect(shown, [1, 2]);
    // The ring-once alarm switched itself off when it fired.
    expect(provider.alarms.firstWhere((a) => a.id == 2).isEnabled, isFalse);
  });

  test('dismissing re-arms only the day that rang, for next week', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(7);
    await provider.addAlarm(a);
    final before = Map.of(backend.registered);

    // Today's registration fires.
    final id = slot(7, today);
    backend.registered.remove(id);
    backend.ringing.add(id);
    backend.controller.add(AlarmRing(id, 'ring'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    backend.setCalls.clear();

    await provider.dismissAlarm(a);
    expect(backend.ringing, isEmpty);
    expect(backend.setCalls, [id]);
    expect(backend.registered[id]!.weekday, today);
    expect(backend.registered[id]!.isAfter(DateTime.now()), isTrue);
    // The other six days were not touched.
    for (final e in before.entries.where((e) => e.key != id)) {
      expect(backend.registered[e.key], e.value);
    }
    expect(a.isEnabled, isTrue);
  });

  test('snooze uses its own registration and the alarm length', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(7)..snoozeMinutes = 10;
    await provider.addAlarm(a);

    final id = slot(7, today);
    backend.registered.remove(id);
    backend.ringing.add(id);
    backend.controller.add(AlarmRing(id, 'ring'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await provider.snoozeAlarm(a);
    expect(backend.ringing, isEmpty);
    final snoozeAt = backend.registered[slot(7, 8)]!;
    expect(
      snoozeAt.difference(DateTime.now()).inMinutes,
      inInclusiveRange(9, 10),
    );
    // Next week's ring of today is already in place, and the snooze is
    // what the Alarms tab reports as the next ring.
    expect(backend.registered[id], isNotNull);
    expect(provider.nextRing(a), snoozeAt);
  });

  // Rings alarm [a] through the given slot, as the phone would.
  Future<void> ring(FakeBackend backend, AlarmItem a, int n) async {
    final id = slot(a.id, n);
    backend.registered.remove(id);
    backend.ringing.add(id);
    backend.controller.add(AlarmRing(id, 'ring'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('editing a snoozed ring-once alarm keeps the snooze (it used to be '
      'cancelled, so the alarm never rang again)', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(21, days: const []);
    await provider.addAlarm(a);
    await ring(backend, a, 0);
    expect(a.isEnabled, isFalse, reason: 'a ring-once alarm is used up');

    final until = await provider.snoozeAlarm(a);
    expect(provider.snoozedUntil(a), until);

    // The user opens the alarm and changes its difficulty.
    final edited = AlarmItem.fromJson(a.toJson())..requiredStreak = 5;
    await provider.updateAlarm(edited);
    expect(backend.registered[slot(21, 8)], until, reason: 'still snoozed');
    expect(provider.snoozedUntil(edited), until);
  });

  test('switching a snoozed alarm on leaves the snooze; switching it off '
      'cancels everything', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(22);
    await provider.addAlarm(a);
    await ring(backend, a, today);
    await provider.snoozeAlarm(a);

    await provider.setEnabled(a, true);
    expect(backend.registered[slot(22, 8)], isNotNull);

    await provider.setEnabled(a, false);
    expect(backend.registered.keys.where((id) => id ~/ 10 == 22), isEmpty);
    expect(provider.snoozedUntil(a), isNull);
  });

  test('alarms are kept in order of time of day, on or off', () async {
    await resetApp();
    final provider = AlarmProvider(backend: FakeBackend());
    await provider.loaded;
    AlarmItem at(int id, int hour, {bool on = true}) => AlarmItem(
      id: id,
      time: TimeOfDay(hour: hour, minute: 0),
      topics: const [],
      isEnabled: on,
    );
    await provider.addAlarm(at(1, 9));
    await provider.addAlarm(at(2, 6));
    await provider.addAlarm(at(3, 1, on: false));
    expect(provider.alarms.map((a) => a.id), [3, 2, 1]);

    // Moving an alarm's time moves it in the list.
    await provider.updateAlarm(at(1, 4));
    expect(provider.alarms.map((a) => a.id), [3, 1, 2]);
  });

  test(
    'skipping the next ring of a repeating alarm misses one day only',
    () async {
      await resetApp();
      final backend = FakeBackend();
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;
      final a = alarm(23);
      await provider.addAlarm(a);
      final first = provider.nextRing(a)!;

      expect(await provider.skipNext(23), startsWith('Skipped'));
      final second = provider.nextRing(a)!;
      expect(second.isAfter(first), isTrue);
      expect(second.difference(first).inHours, inInclusiveRange(23, 25));
      expect(a.isEnabled, isTrue);
      // The skipped weekday comes back the week after.
      expect(
        backend.registered[slot(23, first.weekday)]!.difference(first).inDays,
        7,
      );

      // Skipping a ring-once alarm switches it off.
      final once = alarm(24, days: const []);
      await provider.addAlarm(once);
      expect(await provider.skipNext(24), 'Alarm switched off.');
      expect(once.isEnabled, isFalse);
      expect(await provider.skipNext(999), isNull);
    },
  );

  test('a late or stale tap on Skip never silences a ringing alarm or '
      'skips the wrong day', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(31);
    await provider.addAlarm(a);
    final first = provider.nextRing(a)!;

    // Tapped for a ring that is not the next one any more.
    expect(
      await provider.skipNext(
        31,
        ringAt: first.subtract(const Duration(days: 1)),
      ),
      isNull,
    );
    expect(provider.nextRing(a), first);

    // Tapped after the alarm has started: nothing is touched.
    await ring(backend, a, first.weekday);
    final before = Map.of(backend.registered);
    expect(await provider.skipNext(31, ringAt: first), isNull);
    expect(backend.ringing, {slot(31, first.weekday)});
    expect(backend.registered, before);

    // The right tap at the right time works.
    await provider.dismissAlarm(a);
    final next = provider.nextRing(a)!;
    expect(await provider.skipNext(31, ringAt: next), startsWith('Skipped'));
  });

  test('editing an alarm while it rings does not silence it', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(32);
    await provider.addAlarm(a);
    await ring(backend, a, today);
    await provider.updateAlarm(
      AlarmItem.fromJson(a.toJson())..label = 'New name',
    );
    expect(backend.ringing, {slot(32, today)});
  });

  test('an alarm waiting behind a ringing one survives the app being '
      'opened', () async {
    final a = alarm(33);
    await resetApp(prefs: saved([a]));
    final backend = FakeBackend()..waiting.add(slot(33, today));
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    expect(backend.setCalls, isNot(contains(slot(33, today))));
    expect(backend.setCalls.length, 6, reason: 'the other six days are set');
  });

  test('a registration at the wrong moment is corrected when the app '
      'starts (time zone change, half-failed edit)', () async {
    final a = alarm(34);
    await resetApp(prefs: saved([a]));
    final backend = FakeBackend();
    final wrong = DateTime.now().add(const Duration(days: 2, hours: 3));
    backend.registered[slot(34, wrong.weekday)] = wrong;
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final fixed = backend.registered[slot(34, wrong.weekday)]!;
    expect(fixed.hour, 7);
    expect(fixed.minute, 0);
  });

  test('re-ticking a day in the editor keeps a skipped ring skipped', () async {
    await resetApp();
    final provider = AlarmProvider(backend: FakeBackend());
    await provider.loaded;
    final a = alarm(35, days: const [1, 2, 3, 4, 5, 6, 7]);
    await provider.addAlarm(a);
    await provider.skipNext(35);
    final skipped = provider.nextRing(a)!;
    // The editor hands the days back in a different order.
    final edited = AlarmItem.fromJson(a.toJson())
      ..activeDays = [1, 2, 4, 5, 6, 7, 3]
      ..skipUntil = null
      ..label = 'Renamed';
    await provider.updateAlarm(edited);
    expect(provider.nextRing(edited), skipped);
    expect(provider.alarms.single.activeDays, [1, 2, 3, 4, 5, 6, 7]);
  });

  test('a switch tapped on a card from before an edit acts on the '
      'edited alarm', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final old = alarm(36);
    await provider.addAlarm(old);
    final edited = AlarmItem.fromJson(old.toJson())
      ..time = const TimeOfDay(hour: 9, minute: 30);
    // Both at once, as a quick tap after saving would do.
    await Future.wait([
      provider.updateAlarm(edited),
      provider.setEnabled(old, false),
    ]);
    expect(provider.alarms.single.isEnabled, isFalse);
    expect(provider.alarms.single.time.hour, 9);
    expect(backend.registered.keys.where((id) => id ~/ 10 == 36), isEmpty);
  });

  test('a ring that never came is noticed and put in the diary', () async {
    final a = alarm(25);
    final due = DateTime.now().subtract(const Duration(hours: 2));
    await resetApp(
      prefs: {
        ...saved([a]),
        'alarm_expected': jsonEncode({'25': due.millisecondsSinceEpoch}),
      },
    );
    final provider = AlarmProvider(backend: FakeBackend());
    await provider.loaded;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(provider.missed.single.alarmId, 25);
    expect(
      provider.missed.single.scheduled.millisecondsSinceEpoch,
      due.millisecondsSinceEpoch,
    );
    final events = await AlarmLog.recent(alarmId: 25);
    expect(events.map((e) => e.type), contains('missed'));
    // It is rescheduled, and asked about only once.
    expect(provider.nextRing(a), isNotNull);
    provider.missedHandled(provider.missed.single);
    expect(provider.missed, isEmpty);
  });

  test('a ring that did happen is not reported as missed', () async {
    await resetApp();
    final backend = FakeBackend();
    var provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(26);
    await provider.addAlarm(a);
    await ring(backend, a, today);
    await provider.dismissAlarm(a);
    final types = (await AlarmLog.recent(alarmId: 26)).map((e) => e.type);
    expect(types, containsAll(['created', 'scheduled', 'rang', 'dismissed']));

    // The app is opened again (same phone, so the same registrations).
    provider = AlarmProvider(
      backend: FakeBackend()..registered.addAll(backend.registered),
    );
    await provider.loaded;
    expect(provider.missed, isEmpty);
  });

  test('deleting several alarms removes all their registrations', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    await provider.addAlarm(alarm(1));
    await provider.addAlarm(alarm(2, days: const []));
    await provider.addAlarm(alarm(3, days: const [1]));

    await provider.deleteAlarms([1, 2]);
    expect(provider.alarms.map((a) => a.id), [3]);
    expect(backend.registered.keys.toSet(), {slot(3, 1)});
  });

  test('a simulator test ring leaves a ring-once alarm switched on', () async {
    await resetApp();
    final backend = FakeBackend();
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    final a = alarm(9, days: const []);
    await provider.addAlarm(a);
    final real = backend.registered[slot(9, 0)]!;

    await provider.ringSoon(a, after: const Duration(milliseconds: 1));
    backend.registered.remove(slot(9, 9));
    backend.ringing.add(slot(9, 9));
    backend.controller.add(AlarmRing(slot(9, 9), 'test'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.isEnabled, isTrue);

    await provider.dismissAlarm(a);
    expect(a.isEnabled, isTrue);
    expect(backend.ringing, isEmpty);
    expect(backend.registered[slot(9, 0)], real); // untouched
  });

  test('simulated backend rings, reports and stops', () async {
    await resetApp();
    final backend = SimulatedAlarmBackend(playSound: false);
    await backend.init();
    final rings = <int>[];
    final sub = backend.rings.listen((r) => rings.add(r.id));

    await backend.set(
      AlarmRequest(
        id: 5,
        dateTime: DateTime.now().add(const Duration(milliseconds: 30)),
        audioPath: 'assets/sounds/alarm.mp3',
        title: 't',
        body: 'b',
      ),
    );
    expect(backend.scheduledTime(5), isNotNull);
    expect(await backend.isRinging(5), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(rings, [5]);
    expect(await backend.isRinging(5), isTrue);

    await backend.stop(5);
    expect(await backend.isRinging(5), isFalse);
    expect(backend.scheduledTime(5), isNull);
    await sub.cancel();
  });

  test('a failure to arm an alarm still saves and shows it', () async {
    await resetApp();
    final backend = FakeBackend()..failSet = true;
    final provider = AlarmProvider(backend: backend);
    await provider.loaded;
    await provider.addAlarm(alarm(4));
    expect(provider.alarms.single.id, 4);
  });

  test('difficulty and snooze length are saved; old alarms get defaults', () {
    final a = alarm(1)
      ..requiredStreak = 9
      ..snoozeMinutes = 3;
    final back = AlarmItem.fromJson(a.toJson());
    expect(back.requiredStreak, 9);
    expect(back.snoozeMinutes, 3);

    final old = a.toJson()
      ..remove('requiredStreak')
      ..remove('snoozeMinutes');
    expect(AlarmItem.fromJson(old).requiredStreak, 2);
    expect(AlarmItem.fromJson(old).snoozeMinutes, 5);

    // Out-of-range values from a bad file are pulled back into range.
    final bad = a.toJson()
      ..['requiredStreak'] = 99
      ..['snoozeMinutes'] = 7;
    expect(AlarmItem.fromJson(bad).requiredStreak, 15);
    expect(AlarmItem.fromJson(bad).snoozeMinutes, 5);

    expect(AlarmItem.difficultyName(2), 'Easy');
    expect(AlarmItem.difficultyName(3), 'Medium');
    expect(AlarmItem.difficultyName(5), 'Hard');
    expect(AlarmItem.difficultyName(12), 'Custom');
  });
}
