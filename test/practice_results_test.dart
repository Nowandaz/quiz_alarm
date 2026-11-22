// The screen a practice session ends on.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/practice_results.dart';

import 'helpers.dart';

Question q(String id, String text, String answer) => Question(
  id: id,
  topic: 'Antibiotics',
  type: QuestionType.saq,
  questionText: text,
  correctAnswer: answer,
  explanation: 'Because $answer.',
);

void main() {
  // Each result carries a flag button, which reads the database.
  setUp(() => resetApp());

  Future<void> show(WidgetTester tester, List<PracticeResult> results) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PracticeResultsScreen(title: 'Practice', results: results),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('shows the score and the mistakes with the right answers', (
    tester,
  ) async {
    await show(tester, [
      PracticeResult(q('1', 'First?', 'Alpha'), 'Alpha', true),
      PracticeResult(q('2', 'Second?', 'Beta'), 'Gamma', false),
      PracticeResult(q('3', 'Third?', 'Delta'), '', false),
    ]);
    expect(find.text('1 of 3 right'), findsOneWidget);
    expect(find.text('1 answered "I don\'t know".'), findsOneWidget);
    expect(find.text('Review your mistakes'), findsOneWidget);
    // Only the two missed questions are listed at first.
    expect(find.text('First?'), findsNothing);
    expect(find.text('Second?'), findsOneWidget);
    expect(find.text('Third?'), findsOneWidget);
    expect(find.text('Because Beta.'), findsOneWidget);
    expect(find.text('Practise the 2 you missed'), findsOneWidget);

    await tester.tap(find.text('Show all 3'));
    await tester.pump();
    expect(find.text('First?'), findsOneWidget);
  });

  testWidgets('a perfect session has nothing to retry', (tester) async {
    await show(tester, [
      PracticeResult(q('1', 'First?', 'Alpha'), 'Alpha', true),
    ]);
    expect(find.text('All correct. Nicely done.'), findsOneWidget);
    expect(find.textContaining('you missed'), findsNothing);
    expect(
      find.text('First?'),
      findsOneWidget,
      reason: 'with no mistakes, all are shown',
    );
  });
}
