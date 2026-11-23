// Long answer questions (several marks): how the phone marks them, that
// an alarm never asks one, and that an older database gains the columns.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/answer_grader.dart';
import 'package:quiz_alarm/services/long_answer_grader.dart';
import 'package:quiz_alarm/services/question_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

const aims = [
  ['sedation', 'anxiolysis'],
  ['amnesia'],
  ['antisialagogue', 'reduce secretions'],
  ['analgesia', 'pain relief'],
];

LongAnswerResult mark(
  String text, {
  List<List<String>> points = aims,
  int marks = 4,
}) => LongAnswerGrader.grade(text, keyPoints: points, marks: marks);

Question longQuestion(String id, Topic topic, {int marks = 4}) => Question(
  id: id,
  topicId: topic.id,
  topic: topic.name,
  type: QuestionType.saq,
  questionText: 'List 4 aims of pre-anaesthetic medication ($id).',
  correctAnswer: 'Sedation; amnesia; reduce secretions; analgesia',
  marks: marks,
  longAnswer: true,
  keyPoints: aims,
);

Question ordinary(String id, Topic topic) => Question(
  id: id,
  topicId: topic.id,
  topic: topic.name,
  type: QuestionType.saq,
  questionText: 'Ordinary question $id?',
  correctAnswer: 'Yes',
);

void main() {
  group('marking', () {
    tearDown(() => AnswerGrader.knownTerms = {});

    test('every point, one per line, earns full marks', () {
      final r = mark('Sedation\namnesia\nreduce secretions\npain relief');
      expect(r.score, 4);
      expect(r.correct, isTrue);
      expect(r.found, ['sedation', 'amnesia', 'antisialagogue', 'analgesia']);
      expect(r.missed, isEmpty);
    });

    test('points are found anywhere in a sentence, in any order', () {
      final r = mark(
        'It gives pain relief and amnesia, and it helps to reduce '
        'the secretions.',
      );
      expect(r.score, 3);
      expect(r.correct, isFalse);
      expect(r.found, ['amnesia', 'antisialagogue', 'analgesia']);
      expect(r.missed, ['sedation']);
    });

    test('two wordings of one point count once', () {
      final r = mark('sedation, anxiolysis, analgesia and pain relief');
      expect(r.score, 2);
      expect(r.found, ['sedation', 'analgesia']);
      expect(r.missed, ['amnesia', 'antisialagogue']);
    });

    test('typos are forgiven', () {
      final r = mark('sedaton; amnesai; antisialogogue; analgesa');
      expect(r.score, 4);
      expect(r.correct, isTrue);
    });

    test('"not X" does not count as X, and digits may not be mistyped', () {
      expect(mark('not sedation').score, 0);
      const points = [
        ['COX-2'],
        ['factor 8'],
      ];
      expect(mark('cox 1 and factor 9', points: points, marks: 2).score, 0);
      expect(mark('cox-2, factor VIII', points: points, marks: 2).score, 2);
    });

    test('any N of many: the score stops at the marks', () {
      const six = [
        ['pallor'],
        ['fatigue'],
        ['dyspnoea', 'breathlessness'],
        ['tachycardia'],
        ['koilonychia'],
        ['glossitis'],
      ];
      final four = mark(
        'pallor, fatigue, breathlessness, glossitis',
        points: six,
      );
      expect(four.score, 4);
      expect(four.correct, isTrue);
      expect(four.missed, ['tachycardia', 'koilonychia']);

      final all = mark(
        'pallor fatigue dyspnea tachycardia koilonychia glossitis',
        points: six,
      );
      expect(all.score, 4);
      expect(all.found, hasLength(6));

      final three = mark('pallor, fatigue, glossitis', points: six);
      expect(three.score, 3);
      expect(three.correct, isFalse);
    });

    test('nothing typed, or nothing relevant, scores 0', () {
      for (final text in ['', '   ', 'I have no idea']) {
        final r = mark(text);
        expect(r.score, 0, reason: text);
        expect(r.correct, isFalse);
        expect(r.missed, hasLength(4));
      }
    });

    test('no key points: self-marked, 0 from the phone', () {
      for (final points in [
        const <List<String>>[],
        const [
          <String>[],
          [' '],
        ],
      ]) {
        final r = mark('sedation and amnesia', points: points);
        expect(r.selfMarked, isTrue);
        expect(r.score, 0);
        expect(r.marks, 4);
        expect(r.correct, isFalse);
      }
    });

    test('key points from the server are made safe', () {
      expect(
        Question.cleanKeyPoints([
          ['a', ' ', 'b '],
          'c',
          <String>[],
          null,
          [1],
        ]),
        [
          ['a', 'b'],
          ['c'],
          ['1'],
        ],
      );
      expect(Question.cleanKeyPoints('nonsense'), isEmpty);
      expect(Question.cleanKeyPoints(null), isEmpty);
    });
  });

  group('in the question bank', () {
    setUp(() => resetApp());

    test('marks and key points are stored and read back', () async {
      await QuestionRepository.ensureReady();
      final topic = await QuestionRepository.addCustomTopic('Anaesthesia');
      await QuestionRepository.addQuestion(longQuestion('long-1', topic));
      await QuestionRepository.addQuestion(ordinary('short-1', topic));

      final stored = await QuestionRepository.getQuestions(topic.id);
      final long = stored.firstWhere((q) => q.id == 'long-1');
      expect(long.longAnswer, isTrue);
      expect(long.marks, 4);
      expect(long.keyPoints, aims);
      expect(long.marksLabel, '4 marks');
      expect(long.typeLabel, 'Long answer');
      final short = stored.firstWhere((q) => q.id == 'short-1');
      expect(short.longAnswer, isFalse);
      expect(short.marks, 1);
      expect(short.keyPoints, isEmpty);
      expect(short.typeLabel, 'Short answer');
      // A reshuffled copy keeps them.
      expect(long.shuffled().keyPoints, aims);

      // They are real questions: the topic counts them.
      expect((await QuestionRepository.getStats())[topic.id]!.total, 2);

      final r = await QuestionService.gradeLong(long, 'amnesia, sedation');
      expect(r.score, 2);
    });

    test('an alarm never picks a long answer, practice does', () async {
      await QuestionRepository.ensureReady();
      final topic = await QuestionRepository.addCustomTopic('Anaesthesia');
      for (var i = 0; i < 6; i++) {
        await QuestionRepository.addQuestion(longQuestion('long-$i', topic));
      }
      await QuestionRepository.addQuestion(ordinary('short-1', topic));

      // Alarm: the one ordinary question, again and again, also once it
      // was shown and answered.
      final shown = <String>{};
      for (var i = 0; i < 12; i++) {
        final q = (await QuestionRepository.pickNext([
          topic.id,
        ], exclude: shown))!;
        expect(q.id, 'short-1');
        shown.add(q.id);
        await QuestionRepository.recordAttempt(
          q.id,
          correct: i.isEven,
          mode: 'alarm',
        );
      }
      // The same through the call the ring screen makes.
      for (var i = 0; i < 5; i++) {
        final q = await QuestionService.nextQuestion([
          topic.id,
        ], longAnswers: false);
        expect(q!.id, 'short-1');
      }

      // Practice goes through all seven.
      final practised = <String>{};
      while (true) {
        final q = await QuestionRepository.pickNext(
          [topic.id],
          exclude: practised,
          repeat: false,
        );
        if (q == null) break;
        practised.add(q.id);
      }
      expect(practised, hasLength(7));
      expect(practised, contains('long-3'));
    });

    test('an alarm on nothing but long answers asks an ordinary question '
        'from elsewhere', () async {
      await QuestionRepository.ensureReady();
      final topic = await QuestionRepository.addCustomTopic('Only long');
      for (var i = 0; i < 3; i++) {
        await QuestionRepository.addQuestion(longQuestion('long-$i', topic));
      }
      for (var i = 0; i < 10; i++) {
        final q = await QuestionRepository.pickNext([topic.id]);
        expect(q, isNotNull);
        expect(q!.longAnswer, isFalse);
        expect(q.topicId, isNot(topic.id));
      }
      // Practice on that topic still gets them.
      final q = await QuestionRepository.pickNext([topic.id], repeat: false);
      expect(q!.longAnswer, isTrue);
    });

    test('a phone holding only long answers: the alarm gets nothing '
        '(its screen then offers to stop), never a long answer', () async {
      await QuestionRepository.ensureReady();
      final topic = await QuestionRepository.addCustomTopic('Only long');
      await QuestionRepository.addQuestion(longQuestion('long-1', topic));
      final db = await AppDatabase.instance;
      await db.delete('questions', where: 'long_answer = 0');
      expect(await QuestionRepository.pickNext([topic.id]), isNull);
      expect(await QuestionRepository.pickNext(const []), isNull);
    });

    test('marking it oneself changes the stored answer, adds none', () async {
      await QuestionRepository.ensureReady();
      final topic = await QuestionRepository.addCustomTopic('Anaesthesia');
      await QuestionRepository.addQuestion(longQuestion('long-1', topic));
      final session = await QuestionRepository.startSession('bank', 'P');
      final id = await QuestionRepository.recordAttempt(
        'long-1',
        correct: false,
        mode: 'bank',
        sessionId: session,
        userAnswer: 'sedation',
      );
      expect(id, isNotNull);
      final db = await AppDatabase.instance;
      await db.update('attempts', {'synced': 1});

      await QuestionRepository.setAttemptCorrect(id, true);
      final attempts = await QuestionRepository.getSessionAttempts(session!);
      expect(attempts, hasLength(1));
      expect(attempts.single.correct, isTrue);
      expect(attempts.single.userAnswer, 'sedation');
      // It is sent to the server again.
      expect((await db.query('attempts')).single['synced'], 0);
      expect(
        (await QuestionRepository.getQuestionProgress(topic.id))['long-1'],
        isTrue,
      );

      await QuestionRepository.setAttemptCorrect(id, false);
      expect(
        (await QuestionRepository.getSessionAttempts(session)).single.correct,
        isFalse,
      );
      await QuestionRepository.setAttemptCorrect(null, true); // no crash
    });
  });

  test('a database from the previous version gains the columns and keeps '
      'its data', () async {
    await resetApp();
    final dir = await Directory.systemTemp.createTemp('brainwake_marks');
    final path = '${dir.path}/v8.db';
    AppDatabase.pathOverride = path;
    await QuestionRepository.ensureReady();
    final topic = await QuestionRepository.addCustomTopic('Mine');
    await QuestionRepository.addQuestion(ordinary('mine-1', topic));
    await QuestionRepository.recordAttempt(
      'mine-1',
      correct: true,
      mode: 'bank',
    );
    final before = (await QuestionRepository.getStats()).length;
    await AppDatabase.close();

    // Make it the database version 8 left behind.
    final old = await databaseFactoryFfiNoIsolate.openDatabase(path);
    for (final column in ['marks', 'long_answer', 'key_points']) {
      await old.execute('ALTER TABLE questions DROP COLUMN $column');
    }
    await old.insert('meta', {
      'key': AppDatabase.bankFullKey,
      'value': DateTime.now().toIso8601String(),
    });
    await old.execute('PRAGMA user_version = 8');
    await old.close();

    QuestionRepository.resetForTest();
    final db = await AppDatabase.instance;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(AppDatabase.schemaVersion, 9);
    final mine = (await QuestionRepository.getQuestions(topic.id)).single;
    expect(mine.id, 'mine-1');
    expect(mine.marks, 1);
    expect(mine.longAnswer, isFalse);
    expect(mine.keyPoints, isEmpty);
    final stats = await QuestionRepository.getStats();
    expect(stats.length, before);
    expect(stats[topic.id]!.mastered, 1);
    // The next sync compares the whole bank, so long answers arrive.
    expect(
      await db.query(
        'meta',
        where: 'key = ?',
        whereArgs: [AppDatabase.bankFullKey],
      ),
      isEmpty,
    );
    // New rows can use the columns.
    await QuestionRepository.addQuestion(longQuestion('long-1', topic));
    expect(
      (await QuestionRepository.getQuestions(topic.id)).last.keyPoints,
      aims,
    );

    await AppDatabase.close();
    await dir.delete(recursive: true);
  });
}
