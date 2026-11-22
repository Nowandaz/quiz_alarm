// An alarm that rang unanswered: the ring screen closes by itself, and
// the next time the app is open it asks why ("You missed your alarm").
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/alarm_feedback.dart';
import 'package:quiz_alarm/screens/alarm_ring_screen.dart';
import 'package:quiz_alarm/services/alarm_backend.dart';
import 'package:quiz_alarm/services/alarm_provider.dart';
import 'package:quiz_alarm/services/system_bridge.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:quiz_alarm/widgets/alarm_health.dart';

import 'alarm_provider_test.dart' show FakeBackend, alarm, saved;
import 'helpers.dart';

/// Lets the database answer and the screen redraw.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Map<String, Object> pending(TimedOutRing ring) => {
  'alarm_timed_out': jsonEncode([ring.toJson()]),
};

TimedOutRing missedRing({
  double volume = 1.0,
  bool vibrate = true,
  bool started = false,
}) => TimedOutRing(
  alarmId: 41,
  label: 'Morning',
  scheduled: DateTime(2026, 3, 2, 7, 0),
  rangSeconds: 600,
  started: started,
  volume: volume,
  vibrate: vibrate,
);

void main() {
  late List<String> played;

  setUp(() {
    played = [];
    AlarmRingScreen.debugOnSfx = played.add;
    AlarmProvider.showNotice = ({
      required int id,
      required String title,
      required String body,
    }) async => true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });
  tearDown(() {
    AlarmRingScreen.debugOnSfx = null;
    AlarmProvider.showNotice = SystemBridge.showNotice;
  });

  Widget app(AlarmProvider provider, Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider.value(value: provider),
    ],
    child: MaterialApp(home: home),
  );

  testWidgets('the ring screen closes by itself when the alarm gives up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final report = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is! MissingPluginException) report?.call(details);
    };

    final a = alarm(41);
    final backend = FakeBackend();
    late AlarmProvider provider;
    await tester.runAsync(() async {
      await resetApp(prefs: saved([a]));
      provider = AlarmProvider(
        backend: backend,
        untouchedLimit: const Duration(milliseconds: 1500),
        idleLimit: const Duration(milliseconds: 3000),
      );
      await provider.loaded;
    });
    final ringing = provider.alarms.single;

    Object? result = 'open';
    await tester.pumpWidget(
      app(
        provider,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<Object?>(
                  MaterialPageRoute(
                    builder: (_) => AlarmRingScreen(alarm: ringing),
                  ),
                );
              },
              child: const Text('home'),
            ),
          ),
        ),
      ),
    );
    final id = 41 * 10 + DateTime.now().weekday;
    backend.ringing.add(id);
    backend.controller.add(AlarmRing(id, 'ring'));
    await tester.tap(find.text('home'));
    await settle(tester);
    expect(find.byType(AlarmRingScreen), findsOneWidget);
    expect(backend.ringing, isNotEmpty);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1600)),
    );
    await settle(tester);
    expect(find.byType(AlarmRingScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(result, 'timed_out');
    expect(backend.ringing, isEmpty);
    expect(played, isEmpty);
    expect(provider.timedOut.single.alarmId, 41);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    FlutterError.onError = report;
  });

  testWidgets('the test alarm screen closes quietly after the same limit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final report = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is! MissingPluginException) report?.call(details);
    };
    late AlarmProvider provider;
    await tester.runAsync(() async {
      await resetApp();
      provider = AlarmProvider(backend: FakeBackend());
      await provider.loaded;
    });
    await tester.pumpWidget(
      app(
        provider,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<Object?>(
                MaterialPageRoute(
                  builder: (_) =>
                      AlarmRingScreen(alarm: alarm(42), preview: true),
                ),
              ),
              child: const Text('home'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await settle(tester);
    expect(find.byType(AlarmRingScreen), findsOneWidget);
    await tester.pump(
      AlarmProvider.untouchedRingLimit - const Duration(seconds: 30),
    );
    expect(find.byType(AlarmRingScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await settle(tester);
    expect(find.byType(AlarmRingScreen), findsNothing);
    expect(provider.timedOut, isEmpty);
    expect(played, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    FlutterError.onError = report;
  });

  /// Opens the prompt for [ring] over an empty page.
  Future<AlarmProvider> prompt(
    WidgetTester tester,
    TimedOutRing ring, {
    AlarmItem? item,
    List<AlarmProblem> problems = const [],
  }) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late AlarmProvider provider;
    await tester.runAsync(() async {
      await resetApp(
        prefs: {
          ...saved([?item]),
          ...pending(ring),
        },
      );
      provider = AlarmProvider(backend: FakeBackend());
      await provider.loaded;
    });
    await tester.pumpWidget(
      app(
        provider,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTimedOutPrompt(
                context,
                provider.timedOut.first,
                findProblems: () async => problems,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    return provider;
  }

  Future<AlarmEvent> reason(WidgetTester tester) async {
    final events = await tester.runAsync(() => AlarmLog.recent(alarmId: 41));
    return events!.firstWhere((e) => e.type == 'timed_out_reason');
  }

  testWidgets('low volume is named and raised with one tap; the reason is '
      'noted and the record cleared', (tester) async {
    final provider = await prompt(
      tester,
      missedRing(volume: 0.4),
      item: alarm(41)..volume = 0.4,
    );
    expect(find.text('You missed your 7:00 AM alarm'), findsOneWidget);
    expect(
      find.text('It rang for 10 minutes and was not answered.'),
      findsOneWidget,
    );
    expect(find.text('It was set to ring at 40% volume.'), findsOneWidget);
    expect(find.text('Everything looked right on the phone.'), findsNothing);

    await tester.tap(find.text('Raise to 100%'));
    await settle(tester);
    expect(provider.alarms.single.volume, 1.0);
    expect(find.text('Raise to 100%'), findsNothing);
    expect(provider.timedOut, hasLength(1)); // not answered yet

    await tester.tap(find.text('I ignored it'));
    await settle(tester);
    expect(find.text('What happened?'), findsNothing);
    expect(provider.timedOut, isEmpty);
    final entry = await reason(tester);
    expect(entry.detail, {
      'reason': 'ignored',
      'low_volume': true,
      'missing_permissions': <dynamic>[],
    });
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('nothing wrong: says so, and suggests something after "I '
      'slept through it" at full volume', (tester) async {
    final provider = await prompt(tester, missedRing(), item: alarm(41));
    expect(find.text('Everything looked right on the phone.'), findsOneWidget);
    expect(find.textContaining('volume.'), findsNothing);
    expect(find.text('Raise to 100%'), findsNothing);

    await tester.tap(find.text('I slept through it'));
    await settle(tester);
    expect(find.textContaining('Try a different ringtone'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await settle(tester);
    expect(provider.timedOut, isEmpty);
    expect((await reason(tester)).detail['reason'], 'slept');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('missing permissions and vibration are shown with their '
      'fixes; started rings say so', (tester) async {
    var fixed = 0;
    final provider = await prompt(
      tester,
      missedRing(vibrate: false, started: true),
      item: alarm(41)..vibrate = false,
      problems: [
        AlarmProblem(
          'Notifications are off',
          'Alarms cannot show at all.',
          () async => fixed++,
        ),
      ],
    );
    expect(
      find.text('It rang for 10 minutes. The questions were not finished.'),
      findsOneWidget,
    );
    expect(find.text('Notifications are off'), findsOneWidget);
    expect(find.text('Everything looked right on the phone.'), findsNothing);
    await tester.tap(find.text('Fix'));
    await settle(tester);
    expect(fixed, 1);

    expect(find.text('Vibration was off for this alarm.'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await settle(tester);
    expect(provider.alarms.single.vibrate, isTrue);

    await tester.tap(find.text('My phone was not near me'));
    await settle(tester);
    final entry = await reason(tester);
    expect(entry.detail['reason'], 'phone_away');
    expect(entry.detail['low_volume'], isFalse);
    expect(entry.detail['missing_permissions'], ['Notifications are off']);
    expect(provider.timedOut, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('"no sound" opens the problem report, filled in', (tester) async {
    await prompt(tester, missedRing(), item: alarm(41));
    await tester.tap(find.text('It did not ring / no sound'));
    await settle(tester);
    expect(find.text('Send report'), findsOneWidget);
    final send = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send report'),
    );
    expect(send.onPressed, isNotNull); // "no sound" is chosen already
    expect((await reason(tester)).detail['reason'], 'no_sound');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
}
