// Syncing with the server, against a pretend Supabase.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Tables held in memory, answering the calls the app makes.
class FakeServer {
  final tables = <String, List<Map<String, dynamic>>>{
    'units': [],
    'topics': [],
    'questions': [],
    'profiles': [],
    'user_questions': [],
    'user_sessions': [],
    'user_attempts': [],
    'user_backups': [],
    'alarm_events': [],
  };
  final requests = <http.Request>[];
  bool down = false;

  void unit(String id, {bool premium = false, String? deletedAt}) =>
      tables['units']!.add({
        'id': id,
        'name': id.toUpperCase(),
        'description': '',
        'sort_order': 0,
        'premium': premium,
        'deleted_at': deletedAt,
      });

  void topic(String id, String unit) => tables['topics']!.add({
    'id': id,
    'unit_id': unit,
    'name': 'Topic $id',
    'sort_order': 0,
    'deleted_at': null,
  });

  Map<String, dynamic> question(
    String id,
    String topic, {
    String text = '',
    String status = 'published',
    String image = '',
    String updatedAt = '2026-01-01T00:00:00Z',
  }) {
    final row = {
      'id': id,
      'topic_id': topic,
      'type': 'saq',
      'text': text.isEmpty ? 'Question $id?' : text,
      'options': <String>[],
      'answer': 'Answer',
      'alt_answers': <String>[],
      'explanation': 'Because.',
      'image_path': image,
      'status': status,
      'deleted_at': null,
      'updated_at': updatedAt,
    };
    tables['questions']!.add(row);
    return row;
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (down) throw http.ClientException('offline');
    expect(request.headers['apikey'], isNotEmpty);
    final table = request.url.pathSegments.last;
    final rows = tables[table]!;
    final q = request.url.queryParameters;

    if (request.method == 'GET') {
      var out = rows.where((r) {
        if (q['user_id'] != null && 'eq.${r['user_id']}' != q['user_id']) {
          return false;
        }
        if (q['updated_at'] != null) {
          final since = DateTime.parse(q['updated_at']!.substring(4));
          if (DateTime.parse(r['updated_at'] as String).isBefore(since)) {
            return false;
          }
        }
        return true;
      }).toList();
      final offset = int.parse(q['offset'] ?? '0');
      out = out.skip(offset).take(int.parse(q['limit'] ?? '1000')).toList();
      return http.Response.bytes(utf8.encode(jsonEncode(out)), 200);
    }

    // POST = upsert on the columns named in on_conflict.
    expect(request.headers['Authorization'], 'Bearer test-token');
    final keys = q['on_conflict']!.split(',');
    final keep = request.headers['Prefer']!.contains('ignore-duplicates');
    for (final row
        in (jsonDecode(request.body) as List).cast<Map<String, dynamic>>()) {
      expect(row['user_id'], 'test-user');
      final i = rows.indexWhere((r) => keys.every((k) => r[k] == row[k]));
      if (i == -1) {
        rows.add(row);
      } else if (!keep) {
        rows[i] = row;
      }
    }
    return http.Response('', 201);
  }
}

Future<List<String>> localQuestionIds(String source) async {
  final db = await AppDatabase.instance;
  return [
    for (final r in await db.query(
      'questions',
      where: 'source = ?',
      whereArgs: [source],
    ))
      r['id'] as String,
  ];
}

void main() {
  late FakeServer server;

  Future<void> start({bool signedIn = false}) async {
    await resetApp(signedIn: signedIn);
    server = FakeServer();
    SyncService.httpClient = MockClient(server.handle);
    SyncService.pictureFolder = () async => null;
  }

  group('question bank', () {
    test(
      'the server replaces the bundled bank: adds, edits and removes',
      () async {
        await start();
        await QuestionRepository.ensureReady();
        final bundled = await localQuestionIds('seed');
        expect(bundled, isNotEmpty);
        final kept = bundled.first;
        final db = await AppDatabase.instance;
        final topicId =
            (await db.query(
                  'questions',
                  where: 'id = ?',
                  whereArgs: [kept],
                )).first['topic_id']
                as String;
        final unitId =
            (await db.query(
                  'topics',
                  where: 'id = ?',
                  whereArgs: [topicId],
                )).first['unit_id']
                as String;

        server.unit(unitId);
        server.topic(topicId, unitId);
        server.question(kept, topicId, text: 'Edited on the admin site?');
        server.question('new-1', topicId, image: 'q/x/pic.png');
        server.question('spot-1', topicId, image: 'seed/sickle_cells.png');
        server.question('draft-1', topicId, status: 'draft');

        await SyncService.run();
        expect(SyncService.status.value, startsWith('Up to date'));
        expect((await localQuestionIds('server')).toSet(), {
          kept,
          'new-1',
          'spot-1',
        });
        expect(
          await localQuestionIds('seed'),
          isEmpty,
          reason: 'not on the server any more',
        );
        final questions = await QuestionRepository.getQuestions(topicId);
        expect(
          questions.firstWhere((q) => q.id == kept).questionText,
          'Edited on the admin site?',
        );
        expect(
          questions.firstWhere((q) => q.id == 'new-1').image,
          endsWith('/storage/v1/object/public/question-images/q/x/pic.png'),
        );
        expect(
          questions.firstWhere((q) => q.id == 'spot-1').image,
          'assets/question_images/sickle_cells.png',
        );
        // Other bundled units are gone too: the server is the bank now.
        expect((await QuestionRepository.getUnits()).map((u) => u.id), [
          unitId,
        ]);
      },
    );

    test('later runs only ask for changes, and deletions arrive', () async {
      await start();
      server.unit('u1');
      server.topic('t1', 'u1');
      final a = server.question('a', 't1');
      server.question('b', 't1');
      await SyncService.run();
      expect((await localQuestionIds('server')).toSet(), {'a', 'b'});

      a['deleted_at'] = DateTime.now().toUtc().toIso8601String();
      a['updated_at'] = a['deleted_at'];
      server.requests.clear();
      await SyncService.run();
      final asked = server.requests.firstWhere(
        (r) => r.url.path.endsWith('/questions'),
      );
      expect(asked.url.queryParameters['updated_at'], startsWith('gte.'));
      expect(await localQuestionIds('server'), ['b']);
    });

    test('a failed or empty download never wipes the bank', () async {
      await start();
      await QuestionRepository.ensureReady();
      final before = (await localQuestionIds('seed')).length;
      await SyncService.run(); // the server has nothing
      expect((await localQuestionIds('seed')).length, before);

      server.down = true;
      await SyncService.run();
      expect(SyncService.status.value, contains('no connection'));
      expect((await localQuestionIds('seed')).length, before);
    });

    test('premium units arrive only with a premium plan', () async {
      await start(signedIn: true);
      server.unit('free');
      server.unit('gold', premium: true);
      server.topic('tf', 'free');
      server.topic('tg', 'gold');
      server.question('f1', 'tf');
      server.question('g1', 'tg');
      server.tables['profiles']!.add({
        'id': 'test-user',
        'plan': 'free',
        'plan_expires_at': null,
      });
      await SyncService.run();
      expect(await localQuestionIds('server'), ['f1']);

      server.tables['profiles']!.first['plan'] = 'premium';
      await SyncService.run(); // the plan change makes it compare everything
      expect((await localQuestionIds('server')).toSet(), {'f1', 'g1'});
    });
  });

  group('progress', () {
    Future<void> answerOne() async {
      final topic = await QuestionRepository.addCustomTopic('My notes');
      await QuestionRepository.addQuestion(
        Question(
          id: 'ai_1',
          topicId: topic.id,
          topic: topic.name,
          type: QuestionType.saq,
          questionText: 'Longest bone?',
          correctAnswer: 'Femur',
          source: 'ai',
        ),
      );
      final session = await QuestionRepository.startSession('bank', 'Practice');
      await QuestionRepository.recordAttempt(
        'ai_1',
        correct: true,
        mode: 'bank',
        sessionId: session,
        userAnswer: 'femur',
        timeTaken: const Duration(seconds: 4),
      );
      await QuestionRepository.endSession(session, 'finished');
    }

    test('answers, sessions, own questions and alarms go up once', () async {
      await start(signedIn: true);
      SharedPreferences.setMockInitialValues({
        'saved_alarms': jsonEncode([
          {'id': 123456, 'hour': 6, 'minute': 30, 'isEnabled': true},
        ]),
      });
      await answerOne();
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));

      final attempt = server.tables['user_attempts']!.single;
      final session = server.tables['user_sessions']!.single;
      expect(attempt['question_id'], 'ai_1');
      expect(attempt['correct'], isTrue);
      expect(attempt['session_id'], session['id']);
      expect(session['outcome'], 'finished');
      final question = server.tables['user_questions']!.single;
      expect(
        question['topic_id'],
        isNull,
        reason: 'a topic the user made is not on the server',
      );
      expect(question['topic_name'], 'My notes');
      expect(server.tables['user_backups']!.single['alarms'], hasLength(1));

      server.requests.clear();
      await SyncService.run();
      expect(server.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    test('the alarm diary and problem reports go up once', () async {
      await start(signedIn: true);
      await AlarmLog.add('rang', alarmId: 5, detail: {'late_seconds': 2});
      await AlarmLog.add(
        'report',
        alarmId: 5,
        detail: {'rang': false, 'problem': 'no_sound'},
      );
      await SyncService.run();
      final rows = server.tables['alarm_events']!;
      expect(rows.map((r) => r['type']), ['rang', 'report']);
      expect(rows.last['detail'], {'rang': false, 'problem': 'no_sound'});
      expect(rows.last['app_version'], isNotEmpty);

      await SyncService.run();
      expect(server.tables['alarm_events']!.length, 2);
    });

    test('nothing personal is sent when signed out', () async {
      await start();
      await answerOne();
      await SyncService.run();
      expect(server.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    test(
      'a new phone gets the account\'s history back, alarms switched off',
      () async {
        await start(signedIn: true);
        await answerOne();
        SharedPreferences.setMockInitialValues({
          'saved_alarms': jsonEncode([
            {
              'id': 123456,
              'hour': 6,
              'minute': 30,
              'isEnabled': true,
              'audioPath': '/sdcard/song.mp3',
            },
          ]),
        });
        await SyncService.run();
        final saved = server.tables;

        // The new phone: empty database and preferences, same account.
        await resetApp(signedIn: true);
        var reloaded = 0;
        SyncService.onAlarmsRestored = () async => reloaded++;
        await SyncService.run();

        final topic = await QuestionRepository.findTopicByName('My notes');
        expect(topic, isNotNull);
        expect(
          (await QuestionRepository.getQuestions(topic!.id)).single.id,
          'ai_1',
        );
        final sessions = await QuestionRepository.getSessions();
        expect(sessions.single.title, 'Practice');
        expect(
          (await QuestionRepository.getSessionAttempts(sessions.single.id))
              .single
              .userAnswer,
          'femur',
        );

        final prefs = await SharedPreferences.getInstance();
        final alarm =
            (jsonDecode(prefs.getString('saved_alarms')!) as List).single
                as Map;
        expect(alarm['isEnabled'], isFalse);
        expect(alarm['audioPath'], startsWith('assets/'));
        expect(reloaded, 1);

        // Restoring is not repeated, and nothing is uploaded twice.
        final attempts = saved['user_attempts']!.length;
        await SyncService.run();
        expect(saved['user_attempts']!.length, attempts);
        expect((await QuestionRepository.getSessions()).length, 1);
      },
    );
  });

  test('ids look like UUIDs', () {
    expect(
      SyncService.newUuid(),
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}
