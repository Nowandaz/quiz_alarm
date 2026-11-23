// A topic keeps its first 20 bank questions out; the rest wait until
// the user loads more, or an alarm on the topic is half way through.
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/entitlements.dart';

import 'helpers.dart';

Future<Topic> bankTopic(int questions) async {
  await QuestionRepository.ensureReady();
  final topic = await QuestionRepository.addCustomTopic('Batch topic');
  final db = await AppDatabase.instance;
  for (var i = 0; i < questions; i++) {
    final n = i.toString().padLeft(3, '0');
    await db.insert('questions', {
      'id': 'srv-$n',
      'topic_id': topic.id,
      'type': 'saq',
      'text': 'Question $n?',
      'text_key': 'question $n?',
      'answer': 'Yes',
      'source': 'server',
      'created_at': 1000 + i,
      'revealed': 0, // as the sync stores a new bank question
    });
  }
  return topic;
}

Future<void> answer(String id) async {
  await QuestionRepository.recordAttempt(id, correct: true, mode: 'bank');
}

void main() {
  setUp(resetApp);

  test('a topic starts with 20; the rest wait and load 20 at a time', () async {
    final topic = await bankTopic(50);
    expect(await QuestionRepository.getQuestions(topic.id), isEmpty);
    expect(await QuestionRepository.revealBaseline(), isTrue);
    expect(await QuestionRepository.getQuestions(topic.id), hasLength(20));
    expect(await QuestionRepository.waitingCount(topic.id), 30);
    expect((await QuestionRepository.getStats())[topic.id]!.total, 20);
    // Setting out again changes nothing.
    expect(await QuestionRepository.revealBaseline(), isFalse);

    expect(await QuestionRepository.revealMore(topic.id), 20);
    expect(await QuestionRepository.getQuestions(topic.id), hasLength(40));
    expect(await QuestionRepository.revealMore(topic.id), 10);
    expect(await QuestionRepository.revealMore(topic.id), 0);
    expect(await QuestionRepository.waitingCount(topic.id), 0);
  });

  test(
    'a small topic is all out, and waiting questions are never asked',
    () async {
      final topic = await bankTopic(25);
      await QuestionRepository.revealBaseline();
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        final q = await QuestionRepository.pickNext(
          [topic.id],
          exclude: seen,
          repeat: false,
        );
        seen.add(q!.id);
      }
      expect(seen, hasLength(20));
      expect(
        await QuestionRepository.pickNext(
          [topic.id],
          exclude: seen,
          repeat: false,
        ),
        isNull,
      );
    },
  );

  test(
    'an alarm topic half done gets 20 more; before that it does not',
    () async {
      final topic = await bankTopic(50);
      await QuestionRepository.revealBaseline();
      for (var i = 0; i < 9; i++) {
        await answer('srv-${i.toString().padLeft(3, '0')}');
      }
      expect(await QuestionRepository.revealForAlarms([topic.id]), 0);
      await answer('srv-009');
      expect(await QuestionRepository.revealForAlarms([topic.id]), 20);
      expect(await QuestionRepository.getQuestions(topic.id), hasLength(40));
      // 10 of 40 done: not again until half of those are done too.
      expect(await QuestionRepository.revealForAlarms([topic.id]), 0);
    },
  );

  test('without a paid plan alarms bring nothing more out', () async {
    final topic = await bankTopic(50);
    await QuestionRepository.revealBaseline();
    for (var i = 0; i < 12; i++) {
      await answer('srv-${i.toString().padLeft(3, '0')}');
    }
    Entitlements.instance.setForTest(PlanLevel.free);
    expect(await QuestionRepository.revealForAlarms([topic.id]), 0);
  });

  test('an answered question that was waiting comes out', () async {
    final topic = await bankTopic(30);
    await QuestionRepository.revealBaseline();
    await answer('srv-029'); // e.g. history restored from the account
    await QuestionRepository.revealBaseline();
    final ids = (await QuestionRepository.getQuestions(topic.id))
        .map((q) => q.id);
    expect(ids, contains('srv-029'));
    expect(ids, hasLength(21));
  });
}
