// Practising a long answer question: the bigger text field, the marks,
// the points found and missed, and marking it oneself.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/practice_screen.dart';
import 'package:quiz_alarm/screens/session_screen.dart';
import 'package:quiz_alarm/screens/topic_screen.dart';
import 'package:quiz_alarm/services/bank_provider.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:quiz_alarm/widgets/app_widgets.dart';

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

const modelAnswer = 'Sedation; amnesia; reduce secretions; analgesia';

late Topic topic;

/// Stores one long answer question (and, with [second], an ordinary one
/// after it) and opens a practice session on them.
Future<void> practise(
  WidgetTester tester, {
  List<List<String>> keyPoints = const [
    ['sedation', 'anxiolysis'],
    ['amnesia'],
    ['antisialagogue', 'reduce secretions'],
    ['analgesia', 'pain relief'],
  ],
  bool second = false,
  bool aiTutor = false,
}) async {
  final questions = await tester.runAsync(() async {
    await QuestionRepository.ensureReady();
    topic = await QuestionRepository.addCustomTopic('Anaesthesia');
    final list = [
      Question(
        id: 'long-1',
        topicId: topic.id,
        topic: topic.name,
        type: QuestionType.saq,
        questionText: 'List 4 aims of pre-anaesthetic medication.',
        correctAnswer: modelAnswer,
        explanation: 'It makes induction smoother.',
        marks: 4,
        longAnswer: true,
        keyPoints: keyPoints,
      ),
      if (second)
        Question(
          id: 'short-1',
          topicId: topic.id,
          topic: topic.name,
          type: QuestionType.saq,
          questionText: 'Antidote for paracetamol overdose?',
          correctAnswer: 'N-acetylcysteine',
        ),
    ];
    for (final q in list) {
      await QuestionRepository.addQuestion(q);
    }
    return list;
  });
  tester.view.physicalSize = const Size(420, 2800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: PracticeScreen(
        title: 'Practice',
        selectors: const [],
        questions: questions!,
        aiTutor: aiTutor,
      ),
    ),
  );
  await settle(tester);
}

Future<void> submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('Submit'));
  await settle(tester);
}

/// The answers stored for the long question, oldest first.
Future<List<AttemptDetail>> stored(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final sessions = await QuestionRepository.getSessions();
      return QuestionRepository.getSessionAttempts(sessions.single.id);
    }))!;

void main() {
  setUp(() => resetApp(signedIn: true));
  tearDown(() => Entitlements.instance.setForTest(null));

  testWidgets('asks with a marks chip and a big text field', (tester) async {
    await practise(tester);
    expect(find.widgetWithText(Pill, '4 marks'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 4);
    expect(field.maxLines, isNull);
    expect(
      field.decoration!.hintText,
      'Type your answer. One point per line works well.',
    );
    expect(find.text('Submit'), findsOneWidget);
    expect(find.text('Check'), findsNothing);
  });

  testWidgets('shows the marks, the points and the model answer; the AI '
      'is not asked', (tester) async {
    final requests = fakeAi((_) => ok({'correct': true, 'feedback': 'x'}));
    await practise(tester, aiTutor: true);
    await submit(tester, 'Sedation\nstops pain (analgesa)');

    expect(find.text('You got 2 of 4 marks'), findsOneWidget);
    expect(find.text('Points found'), findsOneWidget);
    expect(find.text('sedation'), findsOneWidget);
    expect(find.text('analgesia'), findsOneWidget);
    expect(find.text('Points missed'), findsOneWidget);
    expect(find.text('amnesia'), findsOneWidget);
    expect(find.text('antisialagogue'), findsOneWidget);
    expect(find.text('Model answer'), findsOneWidget);
    expect(find.text(modelAnswer), findsOneWidget);
    expect(find.text('Explanation'), findsOneWidget);
    expect(find.text('It makes induction smoother.'), findsOneWidget);
    expect(
      find.text('Marked too harshly? Count it as correct'),
      findsOneWidget,
    );
    expect(requests, isEmpty);
    expect(find.textContaining('AI tutor'), findsNothing);

    final attempts = await stored(tester);
    expect(attempts.single.correct, isFalse);
    expect(attempts.single.userAnswer, 'Sedation\nstops pain (analgesa)');
  });

  testWidgets('full marks count as correct, and can be taken back', (
    tester,
  ) async {
    await practise(tester);
    await submit(
      tester,
      'sedation, amnesia, '
      'reduce secretions, pain relief',
    );
    expect(find.text('You got 4 of 4 marks'), findsOneWidget);
    expect(find.text('Points missed'), findsNothing);
    expect((await stored(tester)).single.correct, isTrue);

    await tester.tap(find.text('Not really? Count it as wrong'));
    await settle(tester);
    expect(find.text('You counted it as wrong.'), findsOneWidget);
    expect(
      find.text('Marked too harshly? Count it as correct'),
      findsOneWidget,
    );
    final attempts = await stored(tester);
    expect(attempts, hasLength(1));
    expect(attempts.single.correct, isFalse);
  });

  testWidgets('"Count it as correct" changes the answer just stored and '
      'the results', (tester) async {
    await practise(tester, second: true);
    await submit(tester, 'it calms the patient');
    expect(find.text('You got 0 of 4 marks'), findsOneWidget);

    await tester.tap(find.text('Marked too harshly? Count it as correct'));
    await settle(tester);
    expect(find.text('You counted it as correct.'), findsOneWidget);
    expect(find.text('Not really? Count it as wrong'), findsOneWidget);
    var attempts = await stored(tester);
    expect(attempts, hasLength(1), reason: 'changed, not added');
    expect(attempts.single.correct, isTrue);
    expect(
      (await tester.runAsync(
        () => QuestionRepository.getQuestionProgress(topic.id),
      ))!['long-1'],
      isTrue,
    );

    // The ordinary question after it is asked the ordinary way.
    await tester.tap(find.text('Next question'));
    await settle(tester);
    expect(find.byType(Pill), findsNothing);
    expect(find.text('Check'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 1);
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Check'));
    await settle(tester);
    expect(find.text('Not quite'), findsOneWidget);
    expect(find.textContaining('Count it as'), findsNothing);

    await tester.tap(find.text('Finish').last);
    await settle(tester);
    expect(find.text('1 of 2 right'), findsOneWidget);
    // The results show the mistake; "all" shows the long answer with its
    // marks.
    await tester.tap(find.text('Show all 2'));
    await settle(tester);
    expect(find.widgetWithText(Pill, '4 marks'), findsOneWidget);
    attempts = await stored(tester);
    expect(attempts.map((a) => a.correct), [true, false]);
  });

  testWidgets('no key points: the user compares and marks it themselves', (
    tester,
  ) async {
    await practise(tester, keyPoints: const []);
    await submit(tester, 'sedation and amnesia');
    expect(find.text('Compare with the model answer'), findsOneWidget);
    expect(find.textContaining('You got'), findsNothing);
    expect(find.text(modelAnswer), findsOneWidget);
    expect((await stored(tester)).single.correct, isFalse);

    await tester.tap(find.text('Marked too harshly? Count it as correct'));
    await settle(tester);
    expect((await stored(tester)).single.correct, isTrue);
  });

  testWidgets('"I don\'t know" shows the model answer', (tester) async {
    await practise(tester);
    await tester.tap(find.text("I don't know"));
    await settle(tester);
    expect(find.text('You got 0 of 4 marks'), findsOneWidget);
    expect(find.text(modelAnswer), findsOneWidget);
    expect((await stored(tester)).single.userAnswer, '');
  });

  testWidgets('the topic list and the session history show the marks', (
    tester,
  ) async {
    await practise(tester, second: true);
    await submit(tester, 'sedation');
    await tester.tap(find.text('Next question'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'n-acetylcysteine');
    await tester.tap(find.text('Check'));
    await settle(tester);

    final bank = BankProvider();
    await tester.runAsync(bank.reload);
    Future<void> show(Widget screen) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider.value(value: bank),
          ],
          child: MaterialApp(home: screen),
        ),
      );
      await settle(tester);
    }

    await show(TopicScreen(topic: topic));
    expect(find.textContaining('2 questions'), findsOneWidget);
    expect(find.widgetWithText(Pill, '4 marks'), findsOneWidget);
    expect(find.textContaining('Long answer'), findsOneWidget);
    expect(find.textContaining('Short answer'), findsOneWidget);

    final session = (await tester.runAsync(
      () => QuestionRepository.getSessions(),
    ))!.single;
    await show(SessionScreen(session: session));
    expect(find.widgetWithText(Pill, '4 marks'), findsOneWidget);
  });
}
