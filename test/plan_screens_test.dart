// The screens that changed with the plans: the Alarms tab's line under
// the clock, the alarm editor (Done and the volume row), the welcome
// screen and locked topics.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/account_screen.dart';
import 'package:quiz_alarm/screens/edit_alarm_screen.dart';
import 'package:quiz_alarm/screens/tabs/alarm_tab.dart';
import 'package:quiz_alarm/screens/unit_screen.dart';
import 'package:quiz_alarm/screens/upgrade_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/alarm_provider.dart';
import 'package:quiz_alarm/services/bank_provider.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/guest_mode.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:quiz_alarm/widgets/lock_prompt.dart';

import 'alarm_provider_test.dart' show FakeBackend, alarm;
import 'helpers.dart';

void main() {
  final plan = Entitlements.instance;
  late AlarmProvider alarms;
  late BankProvider bank;

  /// Starts the app's services (the database needs real time to answer,
  /// hence runAsync) and shows [screen].
  Future<void> show(
    WidgetTester tester,
    Widget screen, {
    List<AlarmItem> having = const [],
    PlanLevel level = PlanLevel.pro,
  }) async {
    // Wide enough for the test font, which is broader than the real one.
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await resetApp();
      plan.setForTest(level);
      alarms = AlarmProvider(backend: FakeBackend());
      await alarms.loaded;
      for (final a in having) {
        await alarms.updateAlarm(a);
      }
      bank = BankProvider();
      await bank.reload();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider.value(value: bank),
          ChangeNotifierProvider.value(value: alarms),
        ],
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );
    await tester.pump();
  }

  tearDown(openAllFeatures);

  /// Taps Done and lets the save finish (it talks to the database, which
  /// needs real time).
  Future<void> tapDone(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Done'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  group('the line under the clock', () {
    testWidgets('no alarms at all', (tester) async {
      await show(tester, const AlarmTab());
      expect(find.text('No alarm is on'), findsOneWidget);
    });

    testWidgets('alarms that are all off', (tester) async {
      await show(
        tester,
        const AlarmTab(),
        having: [alarm(1)..isEnabled = false],
      );
      expect(find.text('No alarm is on'), findsOneWidget);
      expect(find.textContaining('morning quiz'), findsNothing);
    });

    testWidgets('an alarm that is on: only how long until it', (tester) async {
      await show(tester, const AlarmTab(), having: [alarm(1)]);
      final line = tester.widget<Text>(find.textContaining('Next alarm'));
      expect(
        line.data,
        matches(
          RegExp(r'^Next alarm in (less than a minute|\d+ \w+( \d+ \w+)?)$'),
        ),
      );
      expect(find.textContaining('Next:'), findsNothing);
      expect(find.textContaining('· in'), findsNothing);
    });
  });

  group('adding an alarm as a guest', () {
    testWidgets('at three alarms, Add explains and offers an account', (
      tester,
    ) async {
      await show(
        tester,
        const AlarmTab(),
        having: [alarm(1), alarm(2), alarm(3)],
        level: PlanLevel.guest,
      );
      await tester.tap(find.text('Add alarm'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Guests can set 3 alarms. Create a free account for unlimited '
          'alarms.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Create account').last);
      await tester.pumpAndSettle();
      expect(find.byType(AccountScreen), findsOneWidget);
    });

    testWidgets('below the limit the editor opens', (tester) async {
      await show(
        tester,
        const AlarmTab(),
        having: [alarm(1)],
        level: PlanLevel.guest,
      );
      await tester.tap(find.text('Add alarm'));
      await tester.pumpAndSettle();
      expect(find.byType(EditAlarmScreen), findsOneWidget);
    });
  });

  group('the alarm editor', () {
    testWidgets('has exactly one Done, in the app bar', (tester) async {
      await show(tester, const EditAlarmScreen());
      expect(find.text('Done'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Done')),
        findsOneWidget,
      );
      // The old summary card is gone.
      expect(find.textContaining('-minute mercy snooze'), findsNothing);
    });

    testWidgets('Done saves the alarm', (tester) async {
      await show(tester, const EditAlarmScreen());
      await tapDone(tester);
      expect(alarms.alarms, hasLength(1));
      expect(alarms.alarms.single.volume, 1.0);
    });

    testWidgets('on a paid plan the volume is a slider, and is saved', (
      tester,
    ) async {
      final quiet = alarm(4)..volume = 0.6;
      await show(
        tester,
        EditAlarmScreen(existingAlarm: quiet),
        having: [quiet],
      );
      await tester.ensureVisible(find.text('Alarm volume'));
      expect(find.text('60%'), findsOneWidget);
      expect(
        find.text(
          'Rings at this volume and stays locked there. The volume keys '
          'cannot change it while it rings.',
        ),
        findsOneWidget,
      );
      tester.widget<Slider>(find.byType(Slider)).onChanged!(0.3);
      await tester.pump();
      expect(find.text('30%'), findsOneWidget);
      await tapDone(tester);
      expect(alarms.alarms.single.volume, 0.3);
    });

    testWidgets('without one it says Maximum, with a lock that explains', (
      tester,
    ) async {
      final quiet = alarm(4)..volume = 0.6;
      await show(
        tester,
        EditAlarmScreen(existingAlarm: quiet),
        having: [quiet],
        level: PlanLevel.free,
      );
      await tester.ensureVisible(find.text('Alarm volume: Maximum'));
      expect(find.byType(Slider), findsNothing);
      await tester.tap(find.text('Alarm volume: Maximum'));
      await tester.pumpAndSettle();
      expect(
        find.text('Choosing a quieter volume is part of Pro.'),
        findsOneWidget,
      );
      expect(find.text('See plans'), findsOneWidget);
      // The chosen volume is kept for when the plan comes back.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tapDone(tester);
      expect(alarms.alarms.single.volume, 0.6);
    });
  });

  group('the welcome screen', () {
    testWidgets('offers to continue without an account, and remembers it', (
      tester,
    ) async {
      await show(tester, const AccountScreen(welcome: true));
      expect(
        find.text(
          '3 alarms and two starter topics. You can create an account any '
          'time.',
        ),
        findsOneWidget,
      );
      expect(await tester.runAsync(GuestMode.chosen), isFalse);
      final go = find.text('Continue without an account');
      await tester.ensureVisible(go);
      await tester.tap(go);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(await tester.runAsync(GuestMode.chosen), isTrue);
    });

    testWidgets('opened later it has a back button and no such offer', (
      tester,
    ) async {
      await show(tester, const AccountScreen());
      expect(find.text('Continue without an account'), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
    });
  });

  group('a locked topic', () {
    Future<Topic> topic(WidgetTester tester, String id) async =>
        (await tester.runAsync(QuestionRepository.getTopics))!
            .firstWhere((t) => t.id == id);

    testWidgets('shows a lock and "Locked", and explains when tapped', (
      tester,
    ) async {
      await show(tester, const SizedBox(), level: PlanLevel.free);
      final cns = await topic(tester, 'pharm-cns');
      await show(
        tester,
        TopicCard(topic: cns, stats: const TopicStats()),
        level: PlanLevel.free,
      );
      expect(find.text('Locked'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      await tester.tap(find.text(cns.name));
      await tester.pumpAndSettle();
      expect(find.text('This topic is part of Pro.'), findsOneWidget);
      expect(find.text('See plans'), findsOneWidget);
    });

    testWidgets('a guest is asked to create an account for a free topic', (
      tester,
    ) async {
      await show(tester, const SizedBox(), level: PlanLevel.guest);
      final ans = await topic(tester, 'pharm-autonomic');
      await show(
        tester,
        TopicCard(topic: ans, stats: const TopicStats()),
        level: PlanLevel.guest,
      );
      await tester.tap(find.text(ans.name));
      await tester.pumpAndSettle();
      expect(
        find.text('Create a free account to open this topic.'),
        findsOneWidget,
      );
      expect(find.text('Create account'), findsOneWidget);
    });

    testWidgets('an open topic shows its capped count', (tester) async {
      await show(tester, const SizedBox(), level: PlanLevel.guest);
      final general = await topic(tester, 'pharm-general-principles');
      await show(
        tester,
        Builder(
          builder: (context) => TopicCard(
            topic: general,
            stats: context.watch<BankProvider>().statsOf(general.id),
          ),
        ),
        level: PlanLevel.guest,
      );
      expect(find.textContaining('10 questions'), findsOneWidget);
      expect(find.text('Locked'), findsNothing);
    });
  });

  group('a plan that cannot be confirmed', () {
    testWidgets('the banner says so; Check now asks the server', (
      tester,
    ) async {
      const words =
          'Your plan needs checking. Connect to the internet to unlock your '
          'Pro features.';
      await show(
        tester,
        ListenableBuilder(
          listenable: plan,
          builder: (_, _) =>
              plan.needsCheck ? const PlanCheckBanner() : const Text('fine'),
        ),
      );
      // Signed in on Pro, last confirmed eight days ago.
      var clock = DateTime(2026, 11, 1);
      Account.instance.signInForTest();
      plan
        ..setForTest(null)
        ..now = () => clock;
      await plan.apply(
        premium: true,
        tier: 'pro',
        tierName: 'Pro',
        expires: null,
      );
      await tester.pump();
      expect(find.text('fine'), findsOneWidget);
      clock = clock.add(const Duration(days: 8));
      plan.setForTest(null); // tells the screen
      await tester.pump();
      expect(find.text(words), findsOneWidget);
      expect(plan.canSetVolume, isFalse);

      // No internet: it says so and stays.
      Billing.httpClient = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Still could not check'), findsOneWidget);
      expect(find.text(words), findsOneWidget);

      // Back online: the server confirms the plan and the banner goes.
      Billing.httpClient = MockClient(
        (_) async => ok({
          'enabled': true,
          'currency': 'KES',
          'methods': <String>[],
          'tiers': <Object>[],
          'premium': true,
          'tier': 'pro',
          'tier_name': 'Pro',
          'expires': null,
        }),
      );
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.text('fine'), findsOneWidget);
      expect(plan.level, PlanLevel.pro);
    });

    testWidgets('a guest on the plans screen is asked to create an account', (
      tester,
    ) async {
      final asked = <http.Request>[];
      Billing.httpClient = MockClient((request) async {
        asked.add(request);
        return http.Response(jsonEncode({'detail': 'Sign in first.'}), 401);
      });
      await show(tester, const UpgradeScreen(), level: PlanLevel.guest);
      await tester.pumpAndSettle();
      expect(find.text('Create an account first'), findsOneWidget);
      expect(asked, isEmpty, reason: 'nothing is asked without an account');
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountScreen), findsOneWidget);
    });
  });
}
