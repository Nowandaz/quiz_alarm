// The flag on each question in the history, and the sheet it opens.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/flag_store.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/flag_sheet.dart';
import 'package:quiz_alarm/screens/practice_results.dart';
import 'package:quiz_alarm/screens/session_screen.dart';
import 'package:quiz_alarm/services/account.dart';
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
      child: MaterialApp(home: screen),
    ),
  );
  await settle(tester);
}

/// One practice session with a single answered question.
Future<(StudySession, Question)> oneSession() async {
  final q = (await QuestionRepository.getQuestions('pharm-cns')).first;
  final id = await QuestionRepository.startSession('bank', 'Revision');
  await QuestionRepository.recordAttempt(
    q.id,
    correct: false,
    mode: 'bank',
    sessionId: id,
    userAnswer: 'no idea',
  );
  await QuestionRepository.endSession(id, 'finished');
  return ((await QuestionRepository.getSessions()).single, q);
}

void main() {
  late List<http.Request> sent;

  setUp(() async {
    await resetApp(signedIn: true);
    sent = [];
    FlagStore.httpClient = MockClient((request) async {
      sent.add(request);
      return http.Response('', 201);
    });
  });

  testWidgets('flag a question in the history, with a reason and a note', (
    tester,
  ) async {
    final (session, q) = (await tester.runAsync(oneSession))!;
    await show(tester, SessionScreen(session: session));

    expect(find.text('Flagged for review'), findsNothing);
    await tester.tap(find.byTooltip('Flag this question for review'));
    await tester.pumpAndSettle();

    expect(find.text('Flag this question for review'), findsOneWidget);
    for (final label in [
      'The answer is wrong',
      'The question is unclear',
      'Spelling or typo',
      'Picture is wrong or missing',
      'Something else',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // Signed in: no "sign in" note.
    expect(find.text(flagSignInNote), findsNothing);
    // Nothing can be sent before a reason is picked.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text('The answer is wrong'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'It should be B.');
    await tester.tap(find.text('Send'));
    await settle(tester);

    expect(find.text('Flagged for review'), findsOneWidget);
    final flag = (await tester.runAsync(() => FlagStore.get(q.id)))!;
    expect(flag.reason, 'wrong_answer');
    expect(flag.note, 'It should be B.');
    expect(flag.questionText, q.questionText);
    // It went to the reviewers straight away, so it cannot be taken back.
    expect(sent, hasLength(1));
    expect(flag.synced, 1);

    await tester.tap(find.text('Flagged for review'));
    await tester.pumpAndSettle();
    expect(find.text('Remove flag'), findsNothing);
    expect(
      find.text('It has been sent to the reviewers. Thank you.'),
      findsOneWidget,
    );
  });

  testWidgets('a guest\'s flag stays on the phone and can be removed', (
    tester,
  ) async {
    final (session, q) = (await tester.runAsync(oneSession))!;
    Account.instance.resetForTest(); // signed out
    await show(tester, SessionScreen(session: session));

    await tester.tap(find.byTooltip('Flag this question for review'));
    await tester.pumpAndSettle();
    expect(find.text(flagSignInNote), findsOneWidget);
    await tester.tap(find.text('Spelling or typo'));
    await tester.pump();
    await tester.tap(find.text('Send'));
    await settle(tester);

    expect(find.text('Flagged for review'), findsOneWidget);
    expect(sent, isEmpty);
    expect((await tester.runAsync(() => FlagStore.get(q.id)))!.synced, 0);

    await tester.tap(find.text('Flagged for review'));
    await tester.pumpAndSettle();
    expect(find.text(flagSignInNote), findsOneWidget);
    await tester.tap(find.text('Remove flag'));
    await settle(tester);
    expect(find.text('Flagged for review'), findsNothing);
    expect(await tester.runAsync(() => FlagStore.get(q.id)), isNull);
  });

  testWidgets('the results of a practice session have the flag too', (
    tester,
  ) async {
    final (_, q) = (await tester.runAsync(oneSession))!;
    await show(
      tester,
      PracticeResultsScreen(
        title: 'Practice',
        results: [PracticeResult(q, 'no idea', false)],
      ),
    );
    await tester.tap(find.byTooltip('Flag this question for review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else'));
    await tester.pump();
    await tester.tap(find.text('Send'));
    await settle(tester);
    expect(find.text('Flagged for review'), findsOneWidget);
  });
}
