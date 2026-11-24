// "It's been a minute. Dare to answer this?": when it is offered, what it
// asks, and that answering is recorded.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/dare_sheet.dart';
import 'package:quiz_alarm/services/bank_provider.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

Question mcq(String id, Topic topic) => Question(
  id: id,
  topicId: topic.id,
  topic: topic.name,
  type: QuestionType.mcq,
  questionText: 'Which is right ($id)?',
  options: const ['Right', 'Wrong one', 'Wrong two', 'Wrong three'],
  correctAnswer: 'Right',
  explanation: 'Because it is.',
);

void main() {
  final start = DateTime(2026, 11, 20, 8);
  setUp(resetApp);

  group('when it is offered', () {
    test('never on the first day, then after 12 quiet hours', () async {
      expect(await Dare.due(anyAlarmOn: false, now: start), isFalse);
      expect(
        await Dare.due(
          anyAlarmOn: false,
          now: start.add(const Duration(hours: 11)),
        ),
        isFalse,
      );
      expect(
        await Dare.due(
          anyAlarmOn: false,
          now: start.add(const Duration(hours: 13)),
        ),
        isTrue,
      );
    });

    test('not while an alarm is switched on', () async {
      await Dare.due(anyAlarmOn: false, now: start);
      expect(
        await Dare.due(
          anyAlarmOn: true,
          now: start.add(const Duration(days: 2)),
        ),
        isFalse,
      );
    });

    test(
      'not within 12 hours of the last one, or of the last answer',
      () async {
        await Dare.due(anyAlarmOn: false, now: start);
        final later = start.add(const Duration(days: 1));
        await Dare.markShown(now: later);
        expect(
          await Dare.due(
            anyAlarmOn: false,
            now: later.add(const Duration(hours: 3)),
          ),
          isFalse,
        );
        expect(
          await Dare.due(
            anyAlarmOn: false,
            now: later.add(const Duration(hours: 13)),
          ),
          isTrue,
        );

        // A question answered just now: no dare (the real clock applies to
        // answers, so "now" is the real time here).
        await QuestionRepository.ensureReady();
        final topic = await QuestionRepository.addCustomTopic('Mine');
        await QuestionRepository.addQuestion(mcq('q1', topic));
        await QuestionRepository.recordAttempt(
          'q1',
          correct: true,
          mode: 'bank',
        );
        (await SharedPreferences.getInstance())
          ..setInt(Dare.firstOpenPref, 0)
          ..setInt(Dare.lastShownPref, 0);
        expect(await Dare.due(anyAlarmOn: false), isFalse);
      },
    );
  });

  group('what it asks', () {
    test('an ordinary question from a topic the plan opens', () async {
      await QuestionRepository.ensureReady();
      final db = await AppDatabase.instance;
      await db.delete('questions');
      final topic = await QuestionRepository.addCustomTopic('Mine');
      for (var i = 0; i < 4; i++) {
        await QuestionRepository.addQuestion(mcq('q$i', topic));
      }
      // A long answer question is never the dare.
      await db.update('questions', {'long_answer': 1}, where: "id = 'q0'");
      final seen = <String>{};
      for (var i = 0; i < 3; i++) {
        final q = await Dare.pick(exclude: seen, rng: Random(i));
        expect(q, isNotNull);
        expect(q!.longAnswer, isFalse);
        seen.add(q.id);
      }
      expect(seen, {'q1', 'q2', 'q3'});
      expect(await Dare.pick(exclude: seen), isNull);

      // A guest cannot open a topic of their own making: nothing to ask.
      Entitlements.instance.setForTest(PlanLevel.guest);
      expect(await Dare.pick(), isNull);
    });
  });

  testWidgets('answering shows the verdict and is recorded', (tester) async {
    late Topic topic;
    late BankProvider bank;
    await tester.runAsync(() async {
      await QuestionRepository.ensureReady();
      topic = await QuestionRepository.addCustomTopic('Mine');
      await QuestionRepository.addQuestion(mcq('q1', topic));
      bank = BankProvider();
      await bank.reload();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: bank,
        child: MaterialApp(home: DareDialog(first: mcq('q1', topic))),
      ),
    );
    expect(find.text("It's been a minute"), findsOneWidget);
    expect(find.text('Dare to answer this?'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Another question'), findsOneWidget);
    expect(find.text('Choose a topic'), findsOneWidget);

    await tester.tap(find.text('Wrong one'));
    for (var i = 0; i < 20 && find.text('Not quite').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
    }
    expect(find.text('Not quite'), findsOneWidget);
    expect(find.text('Answer: Right'), findsOneWidget);
    expect(find.text('Because it is.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    final progress = await tester.runAsync(
      () => QuestionRepository.getQuestionProgress(topic.id),
    );
    expect(progress, {'q1': false});
  });
}
