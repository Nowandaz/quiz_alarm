// Syncing with the server, against a pretend Supabase.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/account.dart';
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
  String acceptUser = 'test-user';

  /// Ids the server says were unpublished or deleted.
  List<String> withdrawn = [];

  /// A question id the server refuses to store (as a broken row would be).
  String? refuse;

  void unit(String id, {bool premium = false, String? deletedAt}) =>
      tables['units']!.add({
        'id': id,
        'name': id.toUpperCase(),
        'description': '',
        'sort_order': 0,
        'premium': premium,
        'deleted_at': deletedAt,
      });

  /// [access] null: a server that does not send the column yet.
  void topic(String id, String unit, {String? access}) =>
      tables['topics']!.add({
        'id': id,
        'unit_id': unit,
        'name': 'Topic $id',
        'sort_order': 0,
        'deleted_at': null,
        'access': ?access,
      });

  /// Set to make the server hand out questions as the real one does: only
  /// those of topics open to the caller ('guest' without a sign-in,
  /// otherwise by the profile's plan), ten per topic unless paid.
  bool byAccess = false;

  bool _mayRead(Map<String, dynamic> question, http.Request request) {
    final signedIn = request.headers['Authorization'] == 'Bearer test-token';
    final paid =
        signedIn && tables['profiles']!.any((p) => p['plan'] == 'premium');
    if (paid) return true;
    final topic = tables['topics']!.firstWhere(
      (t) => t['id'] == question['topic_id'],
    );
    final open = signedIn ? const ['guest', 'free'] : const ['guest'];
    if (!open.contains(topic['access'])) return false;
    final firstTen =
        (tables['questions']!
                .where((q) => q['topic_id'] == topic['id'])
                .map((q) => '${q['id']}')
                .toList()
              ..sort())
            .take(10);
    return firstTen.contains(question['id']);
  }

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
    if (table == 'question_tombstones') {
      return http.Response(
        jsonEncode([
          for (final id in withdrawn) {'id': id},
        ]),
        200,
      );
    }
    final rows = tables[table]!;
    final q = request.url.queryParameters;

    if (request.method == 'DELETE') {
      expect(q['user_id'], 'eq.test-user');
      final ids = q['id']!.substring(4, q['id']!.length - 1).split(',');
      rows.removeWhere((r) => ids.contains(r['id']));
      return http.Response('', 204);
    }

    if (request.method == 'GET') {
      var out = rows.where((r) {
        if (byAccess && table == 'questions' && !_mayRead(r, request)) {
          return false;
        }
        if (q['user_id'] != null && 'eq.${r['user_id']}' != q['user_id']) {
          return false;
        }
        if (q['updated_at'] != null) {
          final since = DateTime.parse(q['updated_at']!.substring(4));
          if (DateTime.parse(r['updated_at'] as String).isBefore(since)) {
            return false;
          }
        }
        if ((q['id'] ?? '').startsWith('gt.') &&
            '${r['id']}'.compareTo(q['id']!.substring(3)) <= 0) {
          return false;
        }
        return true;
      }).toList();
      if (q['order'] == 'id.asc') {
        out.sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
      }
      final offset = int.parse(q['offset'] ?? '0');
      out = out.skip(offset).take(int.parse(q['limit'] ?? '1000')).toList();
      return http.Response.bytes(utf8.encode(jsonEncode(out)), 200);
    }

    // POST = upsert on the columns named in on_conflict.
    expect(request.headers['Authorization'], 'Bearer test-token');
    final keys = q['on_conflict']!.split(',');
    final keep = request.headers['Prefer']!.contains('ignore-duplicates');
    final incoming = jsonDecode(request.body) as List;
    if (refuse != null && incoming.any((r) => (r as Map)['id'] == refuse)) {
      return http.Response('{"code":"23503"}', 409);
    }
    for (final row
        in (jsonDecode(request.body) as List).cast<Map<String, dynamic>>()) {
      expect(row['user_id'], acceptUser);
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

    /// A bank with one topic of each kind; the paid one has 12 questions.
    void bankByAccess() {
      server.byAccess = true;
      server.unit('u');
      server.topic('tg', 'u', access: 'guest');
      server.topic('tf', 'u', access: 'free');
      server.topic('tp', 'u', access: 'paid');
      server.topic('told', 'u'); // no access sent: counts as paid
      server.question('g1', 'tg');
      server.question('f1', 'tf');
      for (var i = 10; i < 22; i++) {
        server.question('p$i', 'tp');
      }
      server.tables['profiles']!.add({
        'id': 'test-user',
        'plan': 'free',
        'plan_expires_at': null,
      });
    }

    Future<Map<String, String>> localAccess() async => {
      for (final t in await QuestionRepository.getTopics()) t.id: t.access,
    };

    test('each topic keeps who may open it; a topic that arrives without '
        'questions stays as a locked title', () async {
      await start(signedIn: true);
      bankByAccess();
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));
      expect(await localAccess(), {
        'tg': 'guest',
        'tf': 'free',
        'tp': 'paid',
        'told': 'paid',
      });
      expect((await localQuestionIds('server')).toSet(), {'g1', 'f1'});

      // Still there after a later run and after comparing everything.
      await SyncService.run();
      await SyncService.run(fullBank: true);
      expect((await localAccess()).keys, containsAll(['tp', 'told']));

      // The admin opens a topic to everyone: it follows.
      server.tables['topics']!.firstWhere((t) => t['id'] == 'tp')['access'] =
          'guest';
      await SyncService.run();
      expect((await localAccess())['tp'], 'guest');
    });

    test('a change of plan compares the whole bank: paid questions arrive, '
        'and leave again when the plan ends', () async {
      await start(signedIn: true);
      bankByAccess();
      await SyncService.run();
      expect((await localQuestionIds('server')).toSet(), {'g1', 'f1'});

      // Paid. The questions are old, so only a full comparison brings them.
      server.tables['profiles']!.first['plan'] = 'premium';
      await SyncService.run();
      expect(await localQuestionIds('server'), hasLength(14));

      // The same level again: only changes are asked for.
      server.requests.clear();
      await SyncService.run();
      expect(
        server.requests.where(
          (r) =>
              r.url.path.endsWith('/questions') &&
              r.url.queryParameters['updated_at'] == null,
        ),
        isEmpty,
      );

      // The plan ran out: what the server no longer hands out goes, the
      // topic stays.
      server.tables['profiles']!.first['plan'] = 'free';
      await SyncService.run();
      expect((await localQuestionIds('server')).toSet(), {'g1', 'f1'});
      expect((await localAccess())['tp'], 'paid');
    });

    test('a guest gets the starter topics only, and more after signing '
        'in', () async {
      await start();
      bankByAccess();
      await SyncService.run();
      expect(await localQuestionIds('server'), ['g1']);
      expect((await localAccess()).keys.toSet(), {'tg', 'tf', 'tp', 'told'});

      Account.instance.signInForTest();
      await SyncService.run();
      expect((await localQuestionIds('server')).toSet(), {'g1', 'f1'});
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

    test('with diagnostics switched off the alarm diary stays on the '
        'phone; a problem report still goes', () async {
      await start(signedIn: true);
      SharedPreferences.setMockInitialValues({
        SyncService.shareDiagnosticsPref: false,
      });
      await AlarmLog.add('scheduled', alarmId: 5);
      await AlarmLog.add('rang', alarmId: 5, detail: {'late_seconds': 2});
      await AlarmLog.add('report', alarmId: 5, detail: {'problem': 'late'});
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));
      expect(server.tables['alarm_events']!.map((r) => r['type']), ['report']);
      // Still on the phone for the user's own report screen.
      expect((await AlarmLog.recent()).length, 3);

      // Switching it back on sends what happens from then on, not what
      // was recorded while it was off.
      (await SharedPreferences.getInstance()).setBool(
        SyncService.shareDiagnosticsPref,
        true,
      );
      await AlarmLog.add('dismissed', alarmId: 5);
      await SyncService.run();
      expect(server.tables['alarm_events']!.map((r) => r['type']), [
        'report',
        'dismissed',
      ]);
    });

    test('the settings backup carries the theme and the heads-up '
        'choice', () async {
      await start(signedIn: true);
      SharedPreferences.setMockInitialValues({
        'themeMode': 'system',
        'use24Hour': true,
        'headsUp': false,
      });
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));
      expect(server.tables['user_backups']!.single['settings'], {
        'themeMode': 'system',
        'use24Hour': true,
        'headsUp': false,
      });
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

  group('review fixes', () {
    Future<void> ownQuestion(String id, String topicId, String topicName) =>
        QuestionRepository.addQuestion(
          Question(
            id: id,
            topicId: topicId,
            topic: topicName,
            type: QuestionType.saq,
            questionText: 'Mine $id?',
            correctAnswer: 'Yes',
            source: 'ai',
          ),
        );

    test('a different account on the phone starts clean; the first '
        'account\'s history is not handed to it', () async {
      await start(signedIn: true);
      final topic = await QuestionRepository.addCustomTopic('Notes');
      await ownQuestion('ai_a', topic.id, topic.name);
      await QuestionRepository.recordAttempt(
        'ai_a',
        correct: true,
        mode: 'bank',
      );
      await SyncService.run();
      expect(server.tables['user_attempts']!.length, 1);

      // Someone else signs in on the same phone.
      Account.instance.signInForTest(
        email: 'other@example.com',
        userId: 'user-b',
      );
      server.tables.forEach((_, rows) => rows.clear());
      server.acceptUser = 'user-b';
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));
      expect(server.tables['user_attempts'], isEmpty);
      expect(server.tables['user_questions'], isEmpty);
      expect(await QuestionRepository.findTopicByName('Notes'), isNull);
    });

    test(
      'nothing is touched while signed out on a phone that has an account',
      () async {
        await start(signedIn: true);
        server.unit('u1');
        server.topic('t1', 'u1');
        server.question('a', 't1');
        await SyncService.run();
        Account.instance.resetForTest(); // signed out
        server.requests.clear();
        await SyncService.run();
        expect(server.requests, isEmpty);
        expect(await localQuestionIds('server'), ['a']);
      },
    );

    test(
      'a topic removed on the server keeps the user\'s own questions',
      () async {
        await start(signedIn: true);
        server.unit('u1');
        server.topic('t1', 'u1');
        server.question('a', 't1');
        await SyncService.run();
        await ownQuestion('ai_1', 't1', 'Topic t1');

        server.tables['topics']!.single['deleted_at'] = '2026-02-01T00:00:00Z';
        await SyncService.run();
        expect(await localQuestionIds('server'), isEmpty);
        final kept = await QuestionRepository.findTopicByName('Topic t1');
        expect(kept!.isCustom, isTrue);
        expect(
          (await QuestionRepository.getQuestions(kept.id)).single.id,
          'ai_1',
        );

        // The admin restores it: its questions return at once, not days later.
        server.tables['topics']!.single['deleted_at'] = null;
        await SyncService.run();
        expect(await localQuestionIds('server'), ['a']);
      },
    );

    test('an unpublished question disappears at the next sync', () async {
      await start();
      server.unit('u1');
      server.topic('t1', 'u1');
      server.question('a', 't1');
      server.question('b', 't1');
      await SyncService.run();
      // Drafts are hidden from phones, so the row itself no longer arrives.
      server.tables['questions']!.removeWhere((q) => q['id'] == 'a');
      server.withdrawn = ['a'];
      await SyncService.run();
      expect(await localQuestionIds('server'), ['b']);
    });

    test(
      'deleting a question of your own removes the server copy too',
      () async {
        await start(signedIn: true);
        final topic = await QuestionRepository.addCustomTopic('Notes');
        await ownQuestion('ai_x', topic.id, topic.name);
        await ownQuestion('ai_y', topic.id, topic.name);
        await SyncService.run();
        expect(server.tables['user_questions']!.length, 2);

        await QuestionRepository.deleteQuestion('ai_x');
        await SyncService.run();
        expect(server.tables['user_questions']!.single['id'], 'ai_y');
        await QuestionRepository.deleteCustomTopic(topic.id);
        await SyncService.run();
        expect(server.tables['user_questions'], isEmpty);
      },
    );

    test('one row the server refuses does not hold up the rest', () async {
      await start(signedIn: true);
      final topic = await QuestionRepository.addCustomTopic('Notes');
      await ownQuestion('ai_bad', topic.id, topic.name);
      await ownQuestion('ai_good', topic.id, topic.name);
      await QuestionRepository.recordAttempt(
        'ai_good',
        correct: true,
        mode: 'bank',
      );
      server.refuse = 'ai_bad';
      await SyncService.run();
      expect(SyncService.status.value, startsWith('Up to date'));
      expect(server.tables['user_questions']!.single['id'], 'ai_good');
      expect(server.tables['user_attempts']!.length, 1);
      // The refused row is set aside, not sent again every time.
      server.requests.clear();
      await SyncService.run();
      expect(
        server.requests.where(
          (r) => r.method == 'POST' && !r.url.path.contains('rpc'),
        ),
        isEmpty,
      );
    });

    test(
      'the next download starts from the server\'s clock, not the phone\'s',
      () async {
        await start();
        server.unit('u1');
        server.topic('t1', 'u1');
        server.question('a', 't1', updatedAt: '2020-05-05T10:00:00Z');
        await SyncService.run();
        server.requests.clear();
        await SyncService.run();
        final asked = server.requests.firstWhere(
          (r) => r.url.path.endsWith('/questions'),
        );
        expect(
          asked.url.queryParameters['updated_at'],
          'gte.2020-05-05T09:59:00.000Z',
        );
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
