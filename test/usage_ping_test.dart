// The anonymous usage ping: what it carries and how often it goes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/server_config.dart';
import 'package:quiz_alarm/services/sync_service.dart';
import 'package:quiz_alarm/services/usage_ping.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  late List<http.Request> calls;
  var clock = DateTime(2026, 11, 22, 9);
  final plan = Entitlements.instance;

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Future<void> start({
    bool signedIn = false,
    Map<String, Object> prefs = const {},
  }) async {
    await resetApp(signedIn: signedIn, prefs: prefs);
    plan.setForTest(null); // the level is worked out
    clock = DateTime(2026, 11, 22, 9);
    UsagePing.now = () => clock;
    calls = [];
    UsagePing.httpClient = MockClient((request) async {
      calls.add(request);
      return http.Response('', 204);
    });
  }

  tearDown(() {
    UsagePing.now = DateTime.now;
    openAllFeatures();
  });

  /// Two answers (one right), and a diary with one alarm dismissed and
  /// two not answered.
  Future<void> useTheApp() async {
    await QuestionRepository.ensureReady();
    plan.setForTest(PlanLevel.pro); // so the bank can be read
    final q = (await QuestionRepository.getQuestions('pharm-cns')).first;
    await QuestionRepository.recordAttempt(q.id, correct: true, mode: 'bank');
    await QuestionRepository.recordAttempt(q.id, correct: false, mode: 'bank');
    plan.setForTest(null);
    for (final type in ['rang', 'dismissed', 'missed', 'timed_out']) {
      await AlarmLog.add(type, alarmId: 1);
    }
  }

  test('a guest: the public key, the level and this phone\'s totals', () async {
    await start(prefs: {'saved_alarms': '[{"id":1},{"id":2}]'});
    await useTheApp();
    expect(await UsagePing.send(), isTrue);

    final call = calls.single;
    expect(call.method, 'POST');
    expect(
      call.url.toString(),
      '${ServerConfig.supabaseUrl}/rest/v1/rpc/app_ping',
    );
    expect(call.headers['apikey'], ServerConfig.supabaseKey);
    expect(call.headers['Authorization'], 'Bearer ${ServerConfig.supabaseKey}');
    expect(call.headers['Content-Type'], startsWith('application/json'));

    final sent = body(call);
    final install = sent.remove('install') as String;
    expect(
      install,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-'
          r'[0-9a-f]{12}$',
        ),
      ),
    );
    expect(sent, {
      'level': 'guest',
      'version': ServerConfig.appVersion,
      'platform': 'android',
      'answered': 2,
      'correct': 1,
      'alarms_ok': 1,
      'alarms_missed': 2,
      'alarms': 2,
      'device': '',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('install_id'), install);
    expect(prefs.getString('usage_ping_day'), '2026-11-22');
  });

  test('signed in: the account\'s token and its level', () async {
    await start(signedIn: true);
    expect(await UsagePing.send(), isTrue);
    expect(calls.single.headers['Authorization'], 'Bearer test-token');
    expect(calls.single.headers['apikey'], ServerConfig.supabaseKey);
    final sent = body(calls.single);
    expect(sent['level'], 'free');
    expect(sent['answered'], 0);
    expect(sent['alarms'], 0);
  });

  test('once per day, with the same install id', () async {
    await start();
    expect(await UsagePing.send(), isTrue);
    expect(await UsagePing.send(), isFalse);
    clock = DateTime(2026, 11, 22, 23, 59);
    expect(await UsagePing.send(), isFalse);
    expect(calls, hasLength(1));

    clock = DateTime(2026, 11, 23, 0, 1);
    expect(await UsagePing.send(), isTrue);
    expect(calls, hasLength(2));
    expect(body(calls[1])['install'], body(calls[0])['install']);
  });

  test('the totals are left out when diagnostics are switched off', () async {
    await start(
      prefs: {
        SyncService.shareDiagnosticsPref: false,
        'saved_alarms': '[{"id":1}]',
      },
    );
    await useTheApp();
    await UsagePing.send();
    final sent = body(calls.single);
    for (final key in ['answered', 'correct', 'alarms_ok', 'alarms_missed']) {
      expect(sent.containsKey(key), isTrue, reason: key);
      expect(sent[key], isNull, reason: key);
    }
    expect(sent['level'], 'guest');
    expect(sent['alarms'], 1);
  });

  test('a change of plan level sends it again the same day', () async {
    await start(signedIn: true);
    plan.now = () => clock;
    await UsagePing.send();
    await plan.apply(
      premium: true,
      tier: 'ultra',
      tierName: 'Ultra',
      expires: null,
    );
    expect(await UsagePing.send(), isTrue);
    expect(await UsagePing.send(), isFalse);
    expect(calls.map((c) => body(c)['level']), ['free', 'ultra']);
  });

  test('a failure is not counted: it goes with the next try', () async {
    await start();
    UsagePing.httpClient = MockClient((_) async => http.Response('no', 500));
    expect(await UsagePing.send(), isFalse);
    UsagePing.httpClient = MockClient((_) async => throw Exception('offline'));
    expect(await UsagePing.send(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('usage_ping_day'), isNull);

    UsagePing.httpClient = MockClient((request) async {
      calls.add(request);
      return http.Response('', 200);
    });
    expect(await UsagePing.send(), isTrue);
    expect(calls, hasLength(1));
  });
}
