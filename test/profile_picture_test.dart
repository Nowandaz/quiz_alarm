// The profile picture: kept on the phone and with the account (a private
// storage bucket on the server).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/profile_picture.dart';
import 'package:quiz_alarm/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  9,
]);
final _webp = Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
]);

const _object = '/storage/v1/object/avatars/test-user/avatar.jpg';
const _download =
    '/storage/v1/object/authenticated/avatars/test-user/avatar.jpg';

void main() {
  late List<http.Request> calls;

  /// Every call to the server is answered by [reply] and remembered.
  void server(http.Response Function(http.Request request) reply) {
    ProfilePicture.httpClient = MockClient((request) async {
      expect(request.url.toString(), startsWith(ServerConfig.supabaseUrl));
      expect(request.headers['apikey'], ServerConfig.supabaseKey);
      expect(request.headers['Authorization'], 'Bearer test-token');
      calls.add(request);
      return reply(request);
    });
  }

  Future<String?> pending() async => (await SharedPreferences.getInstance())
      .getString('profile_picture_pending:test-user');

  setUp(() async {
    await resetApp(signedIn: true);
    calls = [];
    ProfilePicture.pick = () async => _jpeg;
    server((_) => http.Response('{}', 200));
  });

  test('choosing a picture shows it and uploads it', () async {
    expect(await ProfilePicture.choose(), isNull);
    expect(ProfilePicture.current.value, _jpeg);

    final call = calls.single;
    expect(call.method, 'POST');
    expect(call.url.path, _object);
    expect(call.headers['Content-Type'], 'image/jpeg');
    expect(call.headers['x-upsert'], 'true');
    expect(call.bodyBytes, _jpeg);
    expect(await pending(), isNull);

    // Nothing left to do afterwards.
    await ProfilePicture.sync();
    expect(calls, hasLength(1));
  });

  test('the content type follows the kind of picture', () async {
    for (final (bytes, type) in [(_png, 'image/png'), (_webp, 'image/webp')]) {
      calls.clear();
      ProfilePicture.pick = () async => bytes;
      await ProfilePicture.choose();
      expect(calls.single.headers['Content-Type'], type);
      expect(calls.single.url.path, _object);
    }
    // A kind the server does not take stays on this phone only.
    calls.clear();
    ProfilePicture.pick = () async => Uint8List.fromList([1, 2, 3, 4]);
    expect(await ProfilePicture.choose(), isNull);
    expect(ProfilePicture.current.value, isNotNull);
    expect(calls, isEmpty);
    expect(await pending(), isNull);
  });

  test('a failed upload keeps the picture and is tried again', () async {
    server((_) => throw http.ClientException('offline'));
    expect(await ProfilePicture.choose(), isNull);
    expect(ProfilePicture.current.value, _jpeg);
    expect(await pending(), 'upload');

    server((_) => http.Response('busy', 503));
    await ProfilePicture.sync();
    expect(await pending(), 'upload');

    // A restart, then online again.
    ProfilePicture.resetForTest();
    await ProfilePicture.load();
    expect(ProfilePicture.current.value, _jpeg);
    calls.clear();
    server((_) => http.Response('{}', 200));
    await ProfilePicture.sync();
    expect(calls.single.method, 'POST');
    expect(calls.single.bodyBytes, _jpeg);
    expect(await pending(), isNull);
  });

  test('a new phone downloads the picture of the account', () async {
    server((request) => http.Response.bytes(_png, 200));
    await ProfilePicture.load();
    expect(ProfilePicture.current.value, isNull);
    await ProfilePicture.sync();
    expect(calls.single.method, 'GET');
    expect(calls.single.url.path, _download);
    expect(ProfilePicture.current.value, _png);

    // Cached: it is there after a restart without asking again.
    ProfilePicture.resetForTest();
    await ProfilePicture.load();
    expect(ProfilePicture.current.value, _png);
    await ProfilePicture.sync();
    expect(calls, hasLength(1));
  });

  test('no picture on the server is asked for once per app start', () async {
    server((_) => http.Response('{"error":"not_found"}', 400));
    await ProfilePicture.sync();
    await ProfilePicture.sync();
    expect(calls, hasLength(1));
    expect(ProfilePicture.current.value, isNull);

    // A server that could not answer is asked again.
    ProfilePicture.resetForTest();
    calls.clear();
    server((_) => http.Response('busy', 503));
    await ProfilePicture.sync();
    await ProfilePicture.sync();
    expect(calls, hasLength(2));
  });

  test('removing deletes it on the server too, now or later', () async {
    await ProfilePicture.choose();
    calls.clear();
    await ProfilePicture.remove();
    expect(ProfilePicture.current.value, isNull);
    expect(calls.single.method, 'DELETE');
    expect(calls.single.url.path, _object);
    expect(await pending(), isNull);

    // Offline: removed here, remembered for the server.
    await ProfilePicture.choose();
    server((_) => throw http.ClientException('offline'));
    await ProfilePicture.remove();
    expect(ProfilePicture.current.value, isNull);
    expect(await pending(), 'delete');

    calls.clear();
    server((_) => http.Response('{}', 200));
    await ProfilePicture.sync();
    // The delete only: the old picture is not fetched back.
    expect(calls.single.method, 'DELETE');
    expect(await pending(), isNull);
    expect(ProfilePicture.current.value, isNull);
  });

  test('signed out it does nothing and never throws', () async {
    Account.instance.resetForTest();
    await ProfilePicture.sync();
    await ProfilePicture.remove();
    expect(await ProfilePicture.choose(), contains('Sign in'));
    expect(calls, isEmpty);

    Account.instance.signInForTest();
    ProfilePicture.httpClient = MockClient((_) async => throw 'boom');
    await ProfilePicture.sync();
    await ProfilePicture.deleteFromServer();
  });

  test('pictures are kept per account', () async {
    await ProfilePicture.choose();
    Account.instance.signInForTest(userId: 'someone-else');
    await ProfilePicture.load();
    expect(ProfilePicture.current.value, isNull);
    Account.instance.signInForTest();
    await ProfilePicture.load();
    expect(ProfilePicture.current.value, base64Decode(base64Encode(_jpeg)));
  });
}
