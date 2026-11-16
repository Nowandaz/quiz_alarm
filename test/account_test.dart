// Signing in and out, and the calls to the AI server.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/ai_client.dart';

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
      expect(
        request.url.queryParameters['redirect_to'],
        endsWith('/confirmed'),
      );
      return http.Response('{"id":"user-1","email":"me@example.com"}', 200);
    });
    final result = await account.signUp('me@example.com', 'secret1');
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
