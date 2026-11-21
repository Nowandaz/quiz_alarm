import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

void main() {
  setUp(() => resetApp());

  test(
    'pickNext still works when every question was shown and answered right',
    () async {
      // This used to crash (and the alarm said "the question bank is empty")
      // on long streaks over a small topic.
      const topic = 'pharm-cns';
      final all = await QuestionRepository.getQuestions(topic);
      for (final q in all) {
        await QuestionRepository.recordAttempt(
          q.id,
          correct: true,
          mode: 'alarm',
        );
      }
      final q = await QuestionRepository.pickNext([
        topic,
      ], exclude: all.map((q) => q.id).toSet());
      expect(q, isNotNull);
    },
  );

  test('a practice session ends rather than repeating questions', () async {
    const topic = 'pharm-cns';
    final all = await QuestionRepository.getQuestions(topic);
    final shown = all.map((q) => q.id).toSet();
    expect(
      await QuestionRepository.pickNext([topic], exclude: shown, repeat: false),
      isNull,
    );
    // An alarm keeps asking.
    expect(
      await QuestionRepository.pickNext([topic], exclude: shown),
      isNotNull,
    );
  });

  test('units come in the order their files ask for', () async {
    final units = await QuestionRepository.getUnits();
    expect(units.map((u) => u.id).toList(), ['pharmacology', 'pathology']);
  });

  test('sessions keep the answers, timings and outcome', () async {
    final qs = await QuestionRepository.getQuestions('pharm-cns');
    final id = await QuestionRepository.startSession(
      'alarm',
      'Morning',
      alarmId: 7,
      requiredStreak: 3,
    );
    await QuestionRepository.recordAttempt(
      qs[0].id,
      correct: false,
      mode: 'alarm',
      sessionId: id,
      userAnswer: ' Diazepam ',
      timeTaken: const Duration(seconds: 12),
    );
    await QuestionRepository.recordAttempt(
      qs[1].id,
      correct: true,
      mode: 'alarm',
      sessionId: id,
      userAnswer: qs[1].correctAnswer,
      timeTaken: const Duration(seconds: 4),
    );
    await QuestionRepository.endSession(id, 'dismissed');

    final s = (await QuestionRepository.getSessions(kind: 'alarm')).single;
    expect(s.title, 'Morning');
    expect(s.outcome, 'dismissed');
    expect(s.requiredStreak, 3);
    expect(s.questions, 2);
    expect(s.correct, 1);
    expect(s.duration, isNotNull);
    expect(await QuestionRepository.getSessions(kind: 'practice'), isEmpty);

    final attempts = await QuestionRepository.getSessionAttempts(id!);
    expect(attempts.map((a) => a.question.id), [qs[0].id, qs[1].id]);
    expect(attempts[0].userAnswer, 'Diazepam');
    expect(attempts[0].correct, isFalse);
    expect(attempts[0].timeTaken, const Duration(seconds: 12));
    expect(attempts[0].question.explanation, isNotEmpty);
    expect(attempts[1].correct, isTrue);
  });

  test('a practice session with no answers leaves nothing behind', () async {
    final id = await QuestionRepository.startSession('bank', 'Empty');
    await QuestionRepository.endSession(id, 'finished');
    expect(await QuestionRepository.getSessions(), isEmpty);
  });

  test('report totals, days, topics and alarm averages', () async {
    final empty = await QuestionRepository.getReport();
    expect(empty.answered, 0);
    expect(empty.avgWakeTime, isNull);
    expect(empty.days.length, 14);

    final cns = await QuestionRepository.getQuestions('pharm-cns');
    final abx = await QuestionRepository.getQuestions('pharm-antimicrobials');
    final id = await QuestionRepository.startSession('alarm', 'A');
    for (var i = 0; i < 3; i++) {
      await QuestionRepository.recordAttempt(
        cns[i].id,
        correct: i > 0,
        mode: 'alarm',
        sessionId: id,
      );
    }
    await QuestionRepository.endSession(id, 'dismissed');
    await QuestionRepository.recordAttempt(
      abx[0].id,
      correct: false,
      mode: 'bank',
    );

    final r = await QuestionRepository.getReport();
    expect(r.answered, 4);
    expect(r.correct, 2);
    expect(r.alarmsDismissed, 1);
    expect(r.avgWakeQuestions, 3);
    expect(r.avgWakeTime, isNotNull);
    expect(r.days.last.answered, 4); // today is the last bar
    expect(r.days.last.correct, 2);
    // Weakest topic first.
    expect(r.topics.first.topic, 'Antimicrobials');
    expect(r.topics.first.accuracy, 0);
    expect(r.topics.last.answered, 3);
  });

  group('trends', () {
    // Wednesday. This week began on Monday 16 March; the last 14 days
    // run from 5 March, the 14 before that from 19 February.
    final now = DateTime(2026, 3, 18, 12);

    /// Records [correct] right and [wrong] wrong answers on [topic], all
    /// at noon on [day].
    Future<void> answers(
      String topic,
      DateTime day, {
      int correct = 0,
      int wrong = 0,
    }) async {
      final db = await AppDatabase.instance;
      final qs = await QuestionRepository.getQuestions(topic);
      for (var i = 0; i < correct + wrong; i++) {
        await db.insert('attempts', {
          'question_id': qs[i % qs.length].id,
          'mode': 'bank',
          'correct': i < correct ? 1 : 0,
          'answered_at': DateTime(
            day.year,
            day.month,
            day.day,
            12,
          ).millisecondsSinceEpoch,
        });
      }
    }

    test('with no answers there is nothing to say', () async {
      final t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.isEmpty, isTrue);
      expect(t.accuracy, isNull);
      expect(t.comparison, isNull);
      expect(t.daysPractised, 0);
      expect(t.improving, isEmpty);
      expect(t.needsRevision, isEmpty);
    });

    test('the first 14 days have nothing to be compared with', () async {
      await answers('pharm-cns', DateTime(2026, 3, 17), correct: 3, wrong: 1);
      final t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.accuracy, 75);
      expect(t.comparison, 'first 14 days');
      expect(t.isEmpty, isFalse);
    });

    test('accuracy is compared with the 14 days before', () async {
      // Before: 5 of 10. Now: 8 of 10.
      await answers('pharm-cns', DateTime(2026, 2, 25), correct: 5, wrong: 5);
      await answers('pharm-cns', DateTime(2026, 3, 10), correct: 8, wrong: 2);
      // Too old to count in either period.
      await answers('pharm-cns', DateTime(2026, 2, 18), wrong: 6);
      var t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.answered, 10);
      expect(t.previousAnswered, 10);
      expect(t.accuracy, 80);
      expect(t.comparison, 'up 30 points from the 14 days before');

      // The edges: 5 March is the first of the last 14 days, 4 March the
      // last of the 14 before, 19 February the first of those.
      await answers('pharm-cns', DateTime(2026, 3, 5), wrong: 10);
      await answers('pharm-cns', DateTime(2026, 3, 4), correct: 5);
      await answers('pharm-cns', DateTime(2026, 2, 19), correct: 5);
      t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.answered, 20);
      expect(t.correct, 8);
      expect(t.previousAnswered, 20);
      expect(t.previousCorrect, 15);
      expect(t.comparison, 'down 35 points from the 14 days before');
    });

    test('"no change" and a single point read properly', () {
      expect(
        const ReportTrends(
          answered: 10,
          correct: 5,
          previousAnswered: 4,
          previousCorrect: 2,
        ).comparison,
        'no change from the 14 days before',
      );
      expect(
        const ReportTrends(
          answered: 100,
          correct: 51,
          previousAnswered: 100,
          previousCorrect: 50,
        ).comparison,
        'up 1 point from the 14 days before',
      );
    });

    test('this week, last week and the days practised', () async {
      await answers('pharm-cns', DateTime(2026, 3, 16), correct: 2); // Mon
      await answers('pharm-cns', DateTime(2026, 3, 18), correct: 1, wrong: 2);
      await answers('pharm-cns', DateTime(2026, 3, 15), correct: 4); // Sun
      await answers('pharm-cns', DateTime(2026, 3, 9), wrong: 1); // Mon
      await answers('pharm-cns', DateTime(2026, 3, 8), correct: 9); // older
      final t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.thisWeek, 5);
      expect(t.lastWeek, 5);
      expect(t.weekDays, [true, false, true, false, false, false, false]);
      expect(t.daysPractised, 2);
    });

    test('topics improving most and topics needing revision', () async {
      final before = DateTime(2026, 2, 26);
      final recent = DateTime(2026, 3, 12);
      // Up 40 points.
      await answers('pharm-cns', before, correct: 2, wrong: 3);
      await answers('pharm-cns', recent, correct: 4, wrong: 1);
      // Up 30 points.
      await answers('pharm-autonomic', before, correct: 3, wrong: 2);
      await answers('pharm-autonomic', recent, correct: 9, wrong: 1);
      // Went down: the weakest now.
      await answers('pharm-antimicrobials', before, correct: 5);
      await answers('pharm-antimicrobials', recent, correct: 1, wrong: 4);
      // A big rise, but too few answers before to be believed.
      await answers('pharm-analgesics', before, wrong: 4);
      await answers('pharm-analgesics', recent, correct: 5);
      // Too few answers now to be judged at all.
      await answers('pharm-cardiovascular', recent, wrong: 4);

      final t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.improving.map((x) => x.id), ['pharm-cns', 'pharm-autonomic']);
      expect(t.improving.first.change, 40);
      expect(t.improving.first.topic, 'Central nervous system drugs');
      // Lowest accuracy first; a topic answered perfectly is left out.
      expect(t.needsRevision.map((x) => x.id), [
        'pharm-antimicrobials',
        'pharm-cns',
        'pharm-autonomic',
      ]);
      expect(t.needsRevision.first.answered, 5);
      expect(t.needsRevision.first.correct, 1);
    });

    test('at most three topics are listed each way', () async {
      final before = DateTime(2026, 2, 26);
      final recent = DateTime(2026, 3, 12);
      const topics = [
        'pharm-general-principles',
        'pharm-autonomic',
        'pharm-cardiovascular',
        'pharm-cns',
      ];
      for (var i = 0; i < topics.length; i++) {
        await answers(topics[i], before, correct: 1, wrong: 9);
        await answers(topics[i], recent, correct: 2 + i, wrong: 8 - i);
      }
      final t = (await QuestionRepository.getReport(now: now)).trends;
      expect(t.improving.map((x) => x.id), [
        'pharm-cns',
        'pharm-cardiovascular',
        'pharm-autonomic',
      ]);
      expect(t.needsRevision.map((x) => x.id), [
        'pharm-general-principles',
        'pharm-autonomic',
        'pharm-cardiovascular',
      ]);
    });
  });

  test('a database from the previous app version is upgraded, not wiped', () async {
    final dir = await Directory.systemTemp.createTemp('brainwake_test');
    final path = '${dir.path}/old.db';
    final old = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE units(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
            "description TEXT NOT NULL DEFAULT '', "
            'sort_order INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE topics(id TEXT PRIMARY KEY, unit_id TEXT NOT NULL, '
            'name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, '
            'is_custom INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute(
            'CREATE TABLE questions(id TEXT PRIMARY KEY, topic_id TEXT NOT NULL, '
            'type TEXT NOT NULL, text TEXT NOT NULL, text_key TEXT NOT NULL, '
            "options TEXT NOT NULL DEFAULT '[]', answer TEXT NOT NULL, "
            "alt_answers TEXT NOT NULL DEFAULT '[]', "
            "explanation TEXT NOT NULL DEFAULT '', "
            "source TEXT NOT NULL DEFAULT 'seed', created_at INTEGER NOT NULL)",
          );
          await db.execute(
            'CREATE UNIQUE INDEX idx_questions_unique '
            'ON questions(topic_id, text_key)',
          );
          await db.execute(
            'CREATE TABLE attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'question_id TEXT NOT NULL REFERENCES questions(id) '
            'ON DELETE CASCADE, mode TEXT NOT NULL, correct INTEGER NOT NULL, '
            'answered_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.insert('units', {
            'id': 'pharmacology',
            'name': 'Pharmacology',
          });
          await db.insert('topics', {
            'id': 'pharm-cns',
            'unit_id': 'pharmacology',
            'name': 'CNS',
          });
          await db.insert('questions', {
            'id': 'pharm-cns-002',
            'topic_id': 'pharm-cns',
            'type': 'saq',
            'text': 'Old text',
            'text_key': 'old text',
            'answer': 'Flumazenil',
            'created_at': 1,
          });
          await db.insert('questions', {
            'id': 'ai_1',
            'topic_id': 'pharm-cns',
            'type': 'saq',
            'text': 'My AI question?',
            'text_key': 'my ai question?',
            'answer': 'Yes',
            'source': 'ai',
            'created_at': 2,
          });
          await db.insert('attempts', {
            'question_id': 'pharm-cns-002',
            'mode': 'bank',
            'correct': 1,
            'answered_at': DateTime.now().millisecondsSinceEpoch,
          });
          await db.insert('meta', {'key': 'seed:pharmacology', 'value': '1'});
        },
      ),
    );
    await old.close();

    await AppDatabase.close();
    AppDatabase.pathOverride = path;
    QuestionRepository.resetForTest();

    // Old progress and the user's AI question survive; the new bank and
    // the new session features work.
    final stats = await QuestionRepository.getStats();
    expect(stats['pharm-cns']!.mastered, 1);
    final cns = await QuestionRepository.getQuestions('pharm-cns');
    expect(cns.map((q) => q.id), contains('ai_1'));
    expect(cns.length, 11);
    expect((await QuestionRepository.getReport()).answered, 1);
    final id = await QuestionRepository.startSession('bank', 'After upgrade');
    await QuestionRepository.recordAttempt(
      'ai_1',
      correct: true,
      mode: 'bank',
      sessionId: id,
      userAnswer: 'Yes',
    );
    await QuestionRepository.endSession(id, 'finished');
    expect((await QuestionRepository.getSessions()).single.questions, 1);

    await AppDatabase.close();
    await dir.delete(recursive: true);
  });
}
