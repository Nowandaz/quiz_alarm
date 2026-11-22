// The Reports page: short rows that open the rest, a search over the
// topics, and the lock on trends for plans without them.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/history_screen.dart';
import 'package:quiz_alarm/screens/session_screen.dart';
import 'package:quiz_alarm/screens/tabs/reports_tab.dart';
import 'package:quiz_alarm/screens/topic_stats_screen.dart';
import 'package:quiz_alarm/screens/upgrade_screen.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/theme_provider.dart';

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

Future<void> show(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(420, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: Scaffold(body: screen)),
    ),
  );
  await settle(tester);
}

/// Six wrong answers on one topic (so it "needs revision"), three right
/// on another, in one alarm session and one practice session.
Future<void> seed() async {
  final cns = await QuestionRepository.getQuestions('pharm-cns');
  final abx = await QuestionRepository.getQuestions('pharm-antimicrobials');
  final alarm = await QuestionRepository.startSession('alarm', 'Morning');
  for (var i = 0; i < 6; i++) {
    await QuestionRepository.recordAttempt(
      abx[i % abx.length].id,
      correct: false,
      mode: 'alarm',
      sessionId: alarm,
    );
  }
  await QuestionRepository.endSession(alarm, 'dismissed');
  final practice = await QuestionRepository.startSession('bank', 'Revision');
  for (var i = 0; i < 3; i++) {
    await QuestionRepository.recordAttempt(
      cns[i].id,
      correct: true,
      mode: 'bank',
      sessionId: practice,
    );
  }
  await QuestionRepository.endSession(practice, 'finished');
}

void main() {
  setUp(() async {
    await resetApp();
    Billing.resetForTest();
    // The plans screen asks the server; nothing real is ever called.
    Billing.httpClient = MockClient((_) async => http.Response('{}', 503));
  });
  tearDown(() => Entitlements.instance.setForTest(null));

  testWidgets('paid: accuracy, trends and the three rows', (tester) async {
    await tester.runAsync(seed);
    await show(tester, const ReportsTab());

    expect(find.text('Overall accuracy'), findsOneWidget);
    expect(find.text('3 correct out of 9 answered'), findsOneWidget);
    expect(find.text('Trends'), findsOneWidget);
    expect(find.byType(TrendsLockedCard), findsNothing);
    expect(find.text('By topic'), findsOneWidget);
    expect(find.text('2 topics'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('2 sessions'), findsOneWidget);
    // The long lists are no longer on the page itself.
    expect(find.byType(SessionCard), findsNothing);
    expect(find.byType(TopicStatRow), findsNothing);
  });

  testWidgets('"Needs revision" is folded until tapped', (tester) async {
    await tester.runAsync(seed);
    await show(tester, const ReportsTab());

    expect(find.text('Needs revision'), findsOneWidget);
    expect(find.text('1 topic'), findsOneWidget);
    expect(find.text('Antimicrobials'), findsNothing);

    await tester.tap(find.text('Needs revision'));
    await tester.pumpAndSettle();
    expect(find.text('Antimicrobials'), findsOneWidget);
    expect(find.text('0%  (0/6)'), findsOneWidget);
    expect(find.text('Practise'), findsOneWidget);

    await tester.tap(find.text('Needs revision'));
    await tester.pumpAndSettle();
    expect(find.text('Antimicrobials'), findsNothing);
  });

  testWidgets('"By topic" opens a list that can be searched', (tester) async {
    await tester.runAsync(seed);
    await show(tester, const ReportsTab());
    await tester.tap(find.text('By topic'));
    await settle(tester);

    expect(find.byType(TopicStatsScreen), findsOneWidget);
    expect(find.byType(TopicStatRow), findsNWidgets(2));
    expect(find.text('Antimicrobials'), findsOneWidget);
    // The weakest topic is first and carries the word.
    expect(find.text('Practise'), findsOneWidget);
    expect(find.text('0%  (0/6)'), findsOneWidget);
    expect(find.text('100%  (3/3)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ANTIMIC');
    await tester.pump();
    expect(find.byType(TopicStatRow), findsOneWidget);
    expect(find.text('Antimicrobials'), findsOneWidget);

    // The unit's name finds its topics too.
    await tester.enterText(find.byType(TextField), 'pharmacol');
    await tester.pump();
    expect(find.byType(TopicStatRow), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.byType(TopicStatRow), findsNothing);
    expect(find.text('No topic matches'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.byType(TopicStatRow), findsNWidgets(2));
  });

  testWidgets('"History" opens the sessions, and a session its questions', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await show(tester, const ReportsTab());
    await tester.tap(find.text('History'));
    await settle(tester);

    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.byType(SessionCard), findsNWidgets(2));
    await tester.tap(find.text('Alarms'));
    await settle(tester);
    expect(find.byType(SessionCard), findsOneWidget);
    expect(find.text('Morning'), findsOneWidget);

    await tester.tap(find.text('Morning'));
    await settle(tester);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(find.text('Questions it took'), findsOneWidget);
  });

  for (final level in [PlanLevel.guest, PlanLevel.free]) {
    testWidgets('${level.name}: trends and topic figures are locked', (
      tester,
    ) async {
      // Answered while the topics were open (a plan that has ended).
      await tester.runAsync(seed);
      Entitlements.instance.setForTest(level);
      await show(tester, const ReportsTab());

      // Open to everyone.
      expect(find.text('Overall accuracy'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Needs revision'), findsOneWidget);
      // Locked.
      expect(find.text('Trends'), findsNothing);
      expect(
        find.text(
          level == PlanLevel.guest
              ? 'Create a free account and go Pro to see trends.'
              : 'Trends and topic figures are part of Pro.',
        ),
        findsOneWidget,
      );
      // The nudge to practise stays, without the figures.
      await tester.tap(find.text('Needs revision'));
      await tester.pumpAndSettle();
      expect(find.text('Antimicrobials'), findsOneWidget);
      expect(find.text('0%  (0/6)'), findsNothing);

      // The "By topic" row leads to the plans, not to the figures.
      await tester.tap(find.text('By topic'));
      await settle(tester);
      expect(find.byType(TopicStatsScreen), findsNothing);
      expect(find.byType(UpgradeScreen), findsOneWidget);
    });
  }

  testWidgets('"See plans" on the lock opens the plans', (tester) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    await show(tester, const ReportsTab());
    await tester.tap(find.text('See plans'));
    await settle(tester);
    expect(find.byType(UpgradeScreen), findsOneWidget);
  });

  testWidgets('the lock opens by itself when the plan changes', (tester) async {
    await tester.runAsync(seed);
    Entitlements.instance.setForTest(PlanLevel.free);
    await show(tester, const ReportsTab());
    expect(find.byType(TrendsLockedCard), findsOneWidget);

    Entitlements.instance.setForTest(PlanLevel.pro);
    await tester.pump();
    expect(find.byType(TrendsLockedCard), findsNothing);
    expect(find.text('Trends'), findsOneWidget);
  });

  testWidgets('the topic list refuses to show without the plan', (
    tester,
  ) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    await show(
      tester,
      const TopicStatsScreen(topics: [TopicAccuracy('Renal', 4, 1, id: 'x')]),
    );
    expect(find.byType(TopicStatRow), findsNothing);
    expect(find.byType(TrendsLockedCard), findsOneWidget);
  });
}
