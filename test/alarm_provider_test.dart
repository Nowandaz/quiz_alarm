import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
        backend.registered[slot(1, d)] = DateTime.now().add(
          Duration(days: 1 + d),
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
      ..registered[slot(1, 0)] = DateTime.now().add(const Duration(hours: 2));
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
