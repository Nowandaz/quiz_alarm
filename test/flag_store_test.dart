// Flagging a question for review: kept on the phone, sent when signed in.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/flag_store.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/server_config.dart';

import 'helpers.dart';

/// Answers every upload with what [reply] says for the rows it was sent.
List<http.Request> fakeFlags(int Function(List<dynamic> rows) reply) {
  final requests = <http.Request>[];
  FlagStore.httpClient = MockClient((request) async {
    requests.add(request);
    return http.Response('', reply(jsonDecode(request.body) as List));
  });
  return requests;
}

Future<QuestionFlag> flag(
  String id, {
  String reason = 'typo',
  String note = '',
}) => FlagStore.save(
  questionId: id,
  questionText: 'What is $id?',
  reason: reason,
  note: note,
  now: DateTime.utc(2026, 11, 22, 8, 30),
  send: false,
);

void main() {
  setUp(() => resetApp(signedIn: true));

  test('a flag is saved, changed and taken back while unsent', () async {
    expect(await FlagStore.get('q1'), isNull);
    final first = await flag('q1', note: '  x' * 200);
    expect(first.reason, 'typo');
    expect(first.note.length, FlagStore.maxNote);
    expect(first.canRemove, isTrue);

    // One flag per question: a second save changes it.
    final second = await flag('q1', reason: 'unclear', note: 'Which drug?');
    expect(second.uuid, first.uuid);
    expect(second.reason, 'unclear');
    expect(await FlagStore.all(), hasLength(1));

    expect(await FlagStore.remove('q1'), isTrue);
    expect(await FlagStore.get('q1'), isNull);
    expect(await FlagStore.remove('q1'), isFalse);
  });

  test('the reasons offered', () {
    expect(FlagStore.reasons.map((r) => r.$1), [
      'wrong_answer',
      'unclear',
      'typo',
      'picture',
      'other',
    ]);
  });

  test('unsent flags are posted to the server and marked sent', () async {
    final saved = await flag('q1', reason: 'wrong_answer', note: 'It is B.');
    await flag('q2');
    final requests = fakeFlags((_) => 201);

    expect(await FlagStore.upload(), 2);
    final request = requests.single;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      '${ServerConfig.supabaseUrl}/rest/v1/question_flags',
    );
    expect(request.headers['apikey'], ServerConfig.supabaseKey);
    expect(request.headers['Authorization'], 'Bearer test-token');
    expect(request.headers['Prefer'], 'resolution=ignore-duplicates');
    final rows = jsonDecode(request.body) as List;
    expect(rows.first, {
      'id': saved.uuid,
      'question_id': 'q1',
      'question_text': 'What is q1?',
      'reason': 'wrong_answer',
      'note': 'It is B.',
      'created_at': '2026-11-22T08:30:00.000Z',
    });

    final after = (await FlagStore.get('q1'))!;
    expect(after.synced, 1);
    expect(after.canRemove, isFalse);
    // Sent flags stay as they are, and are not sent twice.
    expect(await FlagStore.remove('q1'), isFalse);
    expect((await flag('q1', reason: 'other')).reason, 'wrong_answer');
    expect(await FlagStore.upload(), 0);
    expect(requests, hasLength(1));
  });

  test('guests keep their flags on the phone', () async {
    Account.instance.resetForTest(); // signed out
    await flag('q1');
    final requests = fakeFlags((_) => 201);
    expect(await FlagStore.upload(), 0);
    expect(requests, isEmpty);
    expect((await FlagStore.get('q1'))!.synced, 0);

    // After signing in they go out.
    Account.instance.signInForTest();
    expect(await FlagStore.upload(), 1);
  });

  test('a network problem leaves the flag for the next try', () async {
    await flag('q1');
    FlagStore.httpClient = MockClient((_) async => throw Exception('offline'));
    expect(await FlagStore.upload(), 0);
    expect((await FlagStore.get('q1'))!.synced, 0);

    fakeFlags((_) => 503);
    expect(await FlagStore.upload(), 0);
    expect((await FlagStore.get('q1'))!.synced, 0);

    fakeFlags((_) => 401);
    expect(await FlagStore.upload(), 0);
    expect((await FlagStore.get('q1'))!.synced, 0);
  });

  test('a flag the server refuses is not tried for ever', () async {
    await flag('bad');
    await flag('good');
    // The batch is refused because of one row; alone, the good one passes.
    final requests = fakeFlags(
      (rows) => rows.any((r) => r['question_id'] == 'bad') ? 400 : 201,
    );
    expect(await FlagStore.upload(), 1);
    expect(requests, hasLength(3));
    expect((await FlagStore.get('bad'))!.synced, 2);
    expect((await FlagStore.get('good'))!.synced, 1);

    expect(await FlagStore.upload(), 0);
    expect(requests, hasLength(3));
  });

  test('saving a flag sends it straight away', () async {
    final requests = fakeFlags((_) => 201);
    await FlagStore.save(
      questionId: 'q9',
      questionText: 'Q?',
      reason: 'picture',
    );
    await FlagStore.upload(); // joins the upload already running
    expect(requests, hasLength(1));
    expect((await FlagStore.get('q9'))!.synced, 1);
  });
}
