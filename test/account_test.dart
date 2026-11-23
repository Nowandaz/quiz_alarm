// Signing in and out, and the calls to the AI server.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/alarm_log.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/ai_client.dart';
import 'package:quiz_alarm/services/profile_picture.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

http.Response session({int expiresIn = 3600, String token = 'access-1'}) =>
    http.Response(
      jsonEncode({
        'access_token': token,
        'refresh_token': 'refresh-1',
        'expires_in': expiresIn,
        'user': {'id': 'user-1', 'email': 'me@example.com'},
      }),
      200,
    );

void main() {
  setUp(() => resetApp());
  final account = Account.instance;

  test('signing in remembers the account across restarts', () async {
    Account.httpClient = MockClient((request) async {
      expect(request.url.path, '/auth/v1/token');
      expect(request.url.queryParameters['grant_type'], 'password');
      expect(request.headers['apikey'], isNotEmpty);
      expect(jsonDecode(request.body)['email'], 'me@example.com');
      return session();
    });
    expect(await account.signIn(' me@example.com ', 'secret1'), isNull);
    expect(account.isSignedIn, isTrue);
    expect(account.email, 'me@example.com');
    expect(await account.accessToken(), 'access-1');

    // A restart: memory is empty, the saved sign-in is read back.
    account.resetForTest();
    expect(account.isSignedIn, isFalse);
    await account.load();
    expect(account.isSignedIn, isTrue);
    expect(account.email, 'me@example.com');
  });

  group('deleting the account', () {
    /// Leaves an answer, a session, a diary entry and an own question on
    /// the phone, as a used account would have.
    Future<void> useTheApp() async {
      final db = await AppDatabase.instance;
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
      );
      await QuestionRepository.endSession(session, 'finished');
      await AlarmLog.add('rang', alarmId: 5);
      for (final key in ['data_owner', 'restored:test-user']) {
        await db.insert('meta', {'key': key, 'value': 'test-user'});
      }
    }

    test('removes it on the server, signs out and clears the history on '
        'this phone', () async {
      await resetApp(
        signedIn: true,
        prefs: {
          'saved_alarms': '[{"id":123456,"hour":6,"minute":30}]',
          'sync_backup_hash': 'abc',
          'profile_picture:test-user': base64Encode([0xFF, 0xD8, 1, 2]),
        },
      );
      await useTheApp();
      final bankQuestions = (await QuestionRepository.getQuestions('pharm-cns'))
          .length;
      var notified = 0;
      void listener() => notified++;
      account.addListener(listener);
      // A profile picture, here and on the server.
      await ProfilePicture.load();
      expect(ProfilePicture.current.value, isNotNull);
      final pictureCalls = <String>[];
      ProfilePicture.httpClient = MockClient((request) async {
        pictureCalls.add('${request.method} ${request.url.path}');
        return http.Response('{}', 200);
      });

      final calls = <http.Request>[];
      Account.httpClient = MockClient((request) async {
        calls.add(request);
        return http.Response('', 204);
      });
      expect(await account.deleteAccount(), isNull);
      account.removeListener(listener);

      final call = calls.single;
      expect(call.method, 'POST');
      expect(call.url.path, '/rest/v1/rpc/delete_my_account');
      expect(call.headers['apikey'], isNotEmpty);
      expect(call.headers['Authorization'], 'Bearer test-token');
      expect(call.body, '{}');

      // The picture went from the server and from this phone.
      expect(pictureCalls, [
        'DELETE /storage/v1/object/avatars/test-user/avatar.jpg',
      ]);
      expect(ProfilePicture.current.value, isNull);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'profile_picture:test-user',
        ),
        isNull,
      );

      // Signed out (which is what brings up the sign-in screen), without
      // a sign-out call for an account that no longer exists.
      expect(account.isSignedIn, isFalse);
      expect(account.email, isNull);
      expect(notified, greaterThan(0));

      // The person's history is gone from the phone...
      final db = await AppDatabase.instance;
      for (final table in ['attempts', 'sessions', 'alarm_events']) {
        expect(await db.query(table), isEmpty, reason: table);
      }
      expect(
        await db.query('questions', where: "source IN ('ai', 'user')"),
        isEmpty,
      );
      expect(await QuestionRepository.findTopicByName('My notes'), isNull);
      expect(
        await db.query(
          'meta',
          where: "key = 'data_owner' OR key LIKE 'restored:%'",
        ),
        isEmpty,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_backup_hash'), isNull);
      // ...the question bank and the alarms are not.
      expect(
        (await QuestionRepository.getQuestions('pharm-cns')).length,
        bankQuestions,
      );
      expect(prefs.getString('saved_alarms'), contains('123456'));
    });

    test('a refusal from the server changes nothing', () async {
      await resetApp(
        signedIn: true,
        prefs: {
          'profile_picture:test-user': base64Encode([0xFF, 0xD8, 1, 2]),
        },
      );
      await ProfilePicture.load();
      await useTheApp();
      Account.httpClient = MockClient(
        (_) async => http.Response('{"message":"Not allowed"}', 403),
      );
      expect(await account.deleteAccount(), 'Not allowed');
      expect(account.isSignedIn, isTrue);
      // The account stays, so its picture is sent to the server again.
      final sent = <String>[];
      ProfilePicture.httpClient = MockClient((request) async {
        sent.add(request.method);
        return http.Response('{}', 200);
      });
      await ProfilePicture.sync();
      expect(sent, ['POST']);
      expect(ProfilePicture.current.value, isNotNull);
      expect((await QuestionRepository.getReport()).answered, 1);
    });

    test('with no connection it says so and changes nothing', () async {
      await resetApp(signedIn: true);
      await useTheApp();
      Account.httpClient = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      expect(await account.deleteAccount(), contains('Could not reach'));
      expect(account.isSignedIn, isTrue);
      expect((await QuestionRepository.getReport()).answered, 1);
    });
  });

  test('a wrong password gives a plain reason', () async {
    Account.httpClient = MockClient(
      (_) async => http.Response(
        '{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}',
        400,
      ),
    );
    expect(
      await account.signIn('me@example.com', 'nope'),
      'Wrong email or password.',
    );
    expect(account.isSignedIn, isFalse);
  });

  test('forgot password asks the server to email a reset link', () async {
    Account.httpClient = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/auth/v1/recover');
      expect(request.url.queryParameters['redirect_to'], 'brainwake://auth');
      expect(jsonDecode(request.body), {'email': 'me@example.com'});
      return http.Response('{}', 200);
    });
    expect(await account.resetPassword(' me@example.com '), isNull);
    expect(account.isSignedIn, isFalse);

    // A refusal and a dead connection both come back as a sentence.
    Account.httpClient = MockClient(
      (_) async => http.Response(
        '{"code":429,"error_code":"over_email_send_rate_limit","msg":"wait"}',
        429,
      ),
    );
    expect(await account.resetPassword('me@example.com'), isNotEmpty);
    Account.httpClient = MockClient((_) async => throw Exception('offline'));
    expect(
      await account.resetPassword('me@example.com'),
      contains('connection'),
    );
  });

  test('no connection is reported, not thrown', () async {
    Account.httpClient = MockClient((_) async => throw Exception('offline'));
    expect(
      await account.signIn('me@example.com', 'secret1'),
      contains('connection'),
    );
  });

  test('a new account may need the emailed link first', () async {
    Account.httpClient = MockClient((request) async {
      expect(request.url.path, '/auth/v1/signup');
      expect(request.url.queryParameters['redirect_to'], 'brainwake://auth');
      // Agreeing to the terms is recorded with the account.
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['email'], 'me@example.com');
      expect(body['password'], 'secret1');
      expect(body['data'], {
        'terms_accepted_at': '2026-11-22T09:30:00.000Z',
        'terms_version': '2026-11-22',
      });
      return http.Response('{"id":"user-1","email":"me@example.com"}', 200);
    });
    final result = await account.signUp(
      'me@example.com',
      'secret1',
      now: DateTime.utc(2026, 11, 22, 9, 30),
    );
    expect(result.error, isNull);
    expect(result.needsConfirmation, isTrue);
    expect(account.isSignedIn, isFalse);
  });

  test('an expiring token is refreshed once, even if asked twice', () async {
    var refreshes = 0;
    Account.httpClient = MockClient((request) async {
      if (request.url.queryParameters['grant_type'] == 'refresh_token') {
        refreshes++;
        expect(jsonDecode(request.body)['refresh_token'], 'refresh-1');
        return session(token: 'access-2');
      }
      return session(expiresIn: 10); // about to run out
    });
    await account.signIn('me@example.com', 'secret1');
    final tokens = await Future.wait([
      account.accessToken(),
      account.accessToken(),
    ]);
    expect(tokens, ['access-2', 'access-2']);
    expect(refreshes, 1);
  });

  test('a sign-in ended on the server signs the phone out', () async {
    Account.httpClient = MockClient((request) async {
      if (request.url.queryParameters['grant_type'] == 'refresh_token') {
        return http.Response('{"error_code":"refresh_token_not_found"}', 400);
      }
      return session(expiresIn: 10);
    });
    await account.signIn('me@example.com', 'secret1');
    expect(await account.accessToken(), isNull);
    expect(account.isSignedIn, isFalse);
  });

  test('being offline keeps the sign-in', () async {
    var offline = false;
    Account.httpClient = MockClient((request) async {
      if (offline) throw Exception('offline');
      return session(expiresIn: 10);
    });
    await account.signIn('me@example.com', 'secret1');
    offline = true;
    expect(await account.accessToken(), isNull);
    expect(account.isSignedIn, isTrue);
  });

  test('signing out forgets the account', () async {
    final paths = <String>[];
    Account.httpClient = MockClient((request) async {
      paths.add(request.url.path);
      return request.url.path.endsWith('/logout')
          ? http.Response('', 204)
          : session();
    });
    await account.signIn('me@example.com', 'secret1');
    await account.signOut();
    expect(account.isSignedIn, isFalse);
    expect(paths.last, '/auth/v1/logout');
    account.resetForTest();
    await account.load();
    expect(account.isSignedIn, isFalse);
  });

  test(
    'Google sign-in: the reply is exchanged with the secret kept here',
    () async {
      final url = Uri.parse(await account.googleSignInUrl());
      expect(url.path, '/auth/v1/authorize');
      expect(url.queryParameters['provider'], 'google');
      expect(url.queryParameters['redirect_to'], 'brainwake://auth');
      final challenge = url.queryParameters['code_challenge']!;

      Account.httpClient = MockClient((request) async {
        expect(request.url.queryParameters['grant_type'], 'pkce');
        final body = jsonDecode(request.body) as Map;
        expect(body['auth_code'], 'the-code');
        // The secret must hash to the challenge that was sent to Google.
        final hashed = base64Url
            .encode(sha256.convert(ascii.encode(body['code_verifier'])).bytes)
            .replaceAll('=', '');
        expect(hashed, challenge);
        return session();
      });
      expect(
        await account.completeOAuth(
          Uri.parse('brainwake://auth?code=the-code'),
        ),
        isNull,
      );
      expect(account.isSignedIn, isTrue);
    },
  );

  test('Google sign-in: a refusal is explained', () async {
    expect(
      await account.completeOAuth(
        Uri.parse(
          'brainwake://auth?error=access_denied&error_description=User+said+no',
        ),
      ),
      contains('User said no'),
    );
    expect(
      await account.completeOAuth(Uri.parse('brainwake://auth')),
      contains('cancelled'),
    );
    expect(account.isSignedIn, isFalse);
  });

  test(
    'creating an account with an email that already has one says so',
    () async {
      // The server pretends a new account was made; the empty "identities"
      // list is the only sign that it was not.
      Account.httpClient = MockClient(
        (_) async => http.Response(
          '{"id":"fake","email":"me@example.com","identities":[]}',
          200,
        ),
      );
      final result = await account.signUp('me@example.com', 'secret1');
      expect(result.needsConfirmation, isFalse);
      expect(result.error, contains('already an account'));
    },
  );

  test('the emailed password link opens the app, which asks for the new '
      'password and then signs in', () async {
    final requests = <http.Request>[];
    Account.httpClient = MockClient((request) async {
      requests.add(request);
      expect(request.method, 'PUT');
      expect(request.url.path, '/auth/v1/user');
      expect(request.headers['Authorization'], 'Bearer link-access');
      expect(jsonDecode(request.body), {'password': 'brand-new'});
      return http.Response('{"id":"user-1","email":"me@example.com"}', 200);
    });
    expect(
      await account.completeOAuth(
        Uri.parse(
          'brainwake://auth#access_token=link-access&refresh_token=link-refresh'
          '&expires_in=3600&type=recovery',
        ),
      ),
      isNull,
    );
    expect(account.recovering.value, isTrue);
    expect(
      account.isSignedIn,
      isFalse,
      reason: 'not until the password is set',
    );

    expect(await account.setNewPassword('brand-new'), isNull);
    expect(account.recovering.value, isFalse);
    expect(account.isSignedIn, isTrue);
    expect(account.email, 'me@example.com');
    expect(await account.accessToken(), 'link-access');
    expect(requests.length, 1);
  });

  test('the emailed confirmation link signs the new account in', () async {
    Account.httpClient = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/auth/v1/user');
      return http.Response('{"id":"user-9","email":"new@example.com"}', 200);
    });
    expect(
      await account.completeOAuth(
        Uri.parse(
          'brainwake://auth#access_token=a&refresh_token=r&expires_in=3600&type=signup',
        ),
      ),
      isNull,
    );
    expect(account.isSignedIn, isTrue);
    expect(account.userId, 'user-9');
  });

  test('a link from our own email page is exchanged for the sign-in', () async {
    final paths = <String>[];
    Account.httpClient = MockClient((request) async {
      paths.add('${request.method} ${request.url.path}');
      if (request.url.path == '/auth/v1/verify') {
        expect(jsonDecode(request.body), {
          'type': 'signup',
          'token_hash': 'abc123',
        });
        return http.Response(
          '{"access_token":"a","refresh_token":"r","expires_in":3600}',
          200,
        );
      }
      return http.Response('{"id":"user-9","email":"new@example.com"}', 200);
    });
    expect(
      await account.completeOAuth(
        Uri.parse('brainwake://auth?token_hash=abc123&type=signup'),
      ),
      isNull,
    );
    expect(account.isSignedIn, isTrue);
    expect(paths.first, 'POST /auth/v1/verify');
  });

  test('a new-password link from our own email page asks for the password '
      'first, and a used one is explained', () async {
    var used = false;
    Account.httpClient = MockClient((request) async {
      if (request.url.path == '/auth/v1/verify') {
        if (used) return http.Response('{"msg":"expired"}', 403);
        used = true;
        return http.Response(
          '{"access_token":"link-access","refresh_token":"r","expires_in":3600}',
          200,
        );
      }
      return http.Response('{"id":"user-1","email":"me@example.com"}', 200);
    });
    final link = Uri.parse('brainwake://auth?token_hash=h1&type=recovery');
    expect(await account.completeOAuth(link), isNull);
    expect(account.recovering.value, isTrue);
    expect(account.isSignedIn, isFalse);
    expect(await account.completeOAuth(link), contains('expired'));
  });

  test('an expired email link is explained', () async {
    expect(
      await account.completeOAuth(
        Uri.parse(
          'brainwake://auth#error=access_denied&error_code=otp_expired'
          '&error_description=Email+link+is+invalid+or+has+expired',
        ),
      ),
      contains('expired'),
    );
  });

  group('AI server', () {
    test('needs an account', () async {
      expect(AiClient.available, isFalse);
      expect(
        () => AiClient.allowance(),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('Sign in'),
          ),
        ),
      );
    });

    test('reads the allowance', () async {
      await resetApp(signedIn: true);
      fakeAi(
        (_) => ok({
          'enabled': true,
          'plan': 'free',
          'limit': 10,
          'used': 4,
          'remaining': 6,
        }),
      );
      final a = await AiClient.allowance();
      expect(a.remaining, 6);
      expect(a.plan, 'free');
    });

    test('marks a typed answer', () async {
      await resetApp(signedIn: true);
      final sent = fakeAi((_) => ok({'correct': true}));
      expect(
        await AiClient.grade(
          question: 'Q?',
          correctAnswer: 'Adrenaline',
          userAnswer: 'epinephrine',
        ),
        isTrue,
      );
      expect(jsonDecode(sent.single)['user_answer'], 'epinephrine');
    });

    test('an unreadable failure still gives a sentence', () async {
      await resetApp(signedIn: true);
      fakeAi((_) => http.Response('<html>Bad gateway</html>', 502));
      expect(
        () => AiClient.allowance(),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('502'),
          ),
        ),
      );
    });
  });
}
