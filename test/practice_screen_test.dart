// Practice: typed answers are marked on the phone with a spelling hint,
// and the AI tutor is locked on plans without it.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/practice_screen.dart';
import 'package:quiz_alarm/services/entitlements.dart';

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

/// Stores one typed question and opens a practice session on it.
Future<void> practise(
  WidgetTester tester, {
  required String answer,
  List<String> alts = const [],
  String explanation = 'Because.',
  bool aiTutor = false,
}) async {
  final q = await tester.runAsync(() async {
    final topic = (await QuestionRepository.getTopics()).first;
    final q = Question(
      id: 'typed-1',
      topicId: topic.id,
      topic: topic.name,
      type: QuestionType.saq,
      questionText: 'Antidote for paracetamol overdose?',
      correctAnswer: answer,
      altAnswers: alts,
      explanation: explanation,
    );
    await QuestionRepository.addQuestion(q);
    return q;
  });
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: PracticeScreen(
        title: 'Practice',
        selectors: const [],
        questions: [q!],
        aiTutor: aiTutor,
      ),
    ),
  );
  await settle(tester);
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('Check'));
  await settle(tester);
}

void main() {
  setUp(() => resetApp(signedIn: true));
  tearDown(() => Entitlements.instance.setForTest(null));

  testWidgets('a typo is forgiven and the right spelling is shown', (
    tester,
  ) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    final requests = fakeAi((_) => ok({'correct': false, 'feedback': 'x'}));
    await practise(tester, answer: 'N-acetylcysteine (NAC)', aiTutor: true);
    await type(tester, 'n acetyl cystine');

    expect(find.text('Correct!'), findsOneWidget);
    expect(find.text('Spelling: N-acetylcysteine'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('a part left out is named, and the answer stays wrong', (
    tester,
  ) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    await practise(
      tester,
      answer: 'Metabolic acidosis + respiratory alkalosis',
    );
    await type(tester, 'metabolic acidosis');

    expect(find.text('Not quite'), findsOneWidget);
    expect(find.text('Missing: respiratory alkalosis'), findsOneWidget);
  });

  for (final level in [PlanLevel.guest, PlanLevel.free]) {
    testWidgets('${level.name}: the AI tutor is locked and never called', (
      tester,
    ) async {
      Entitlements.instance.setForTest(level);
      final requests = fakeAi((_) => ok({'correct': true, 'feedback': 'x'}));
      // Even in a session that was started with the tutor on.
      await practise(tester, answer: 'Naloxone', aiTutor: true);
      await type(tester, 'something else entirely');

      expect(find.text('Not quite'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      await tester.tap(find.text('Ask the AI tutor why'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The AI tutor is part of Pro.'), findsOneWidget);
      expect(
        find.text(level == PlanLevel.guest ? 'Create account' : 'See plans'),
        findsOneWidget,
      );
      expect(requests, isEmpty);
    });
  }

  testWidgets('paid: the tutor marks what the phone could not match', (
    tester,
  ) async {
    Entitlements.instance.setForTest(PlanLevel.pro);
    final requests = fakeAi(
      (_) => ok({'correct': true, 'feedback': 'Yes, same drug.'}),
    );
    await practise(tester, answer: 'Naloxone', aiTutor: true);
    await type(tester, 'the opioid blocker narcan');

    expect(requests, hasLength(1));
    expect(find.text('Correct!'), findsOneWidget);
    expect(find.text('Yes, same drug.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsNothing);
  });

  testWidgets('paid, tutor off: the button asks the AI when tapped', (
    tester,
  ) async {
    Entitlements.instance.setForTest(PlanLevel.pro);
    final requests = fakeAi(
      (_) => ok({'correct': false, 'feedback': 'Think of opioids.'}),
    );
    await practise(tester, answer: 'Naloxone');
    await type(tester, 'flumazenil');
    expect(requests, isEmpty);
    expect(find.text('Not quite'), findsOneWidget);

    await tester.tap(find.text('Ask the AI tutor why'));
    await settle(tester);
    expect(requests, hasLength(1));
    expect(find.text('Think of opioids.'), findsOneWidget);
  });
}
