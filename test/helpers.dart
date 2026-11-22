/// Shared set-up for tests: an in-memory SQLite database, empty
/// preferences and a fake AI server.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/ai_client.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens every feature, as on a paid plan, whatever the sign-in state.
/// [resetApp] calls it, so tests see everything open unless they pick a
/// level themselves with `Entitlements.instance.setForTest(...)`
/// (null = work it out from the account and the saved plan).
void openAllFeatures() {
  Entitlements.instance
    ..resetForTest()
    ..setForTest(PlanLevel.pro);
}

/// Call from setUp(). Gives every test a fresh, empty world.
/// [signedIn] puts the app in a signed-in state (AI features need it).
/// Every feature is open ([openAllFeatures]).
Future<void> resetApp({
  Map<String, Object> prefs = const {},
  bool signedIn = false,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  await AppDatabase.close();
  AppDatabase.factoryOverride = databaseFactoryFfiNoIsolate;
  AppDatabase.pathOverride = inMemoryDatabasePath;
  QuestionRepository.resetForTest();
  SharedPreferences.setMockInitialValues(prefs);
  FlutterSecureStorage.setMockInitialValues({});
  Account.instance.resetForTest();
  if (signedIn) Account.instance.signInForTest();
  openAllFeatures();
}

/// Makes every call to the AI server answer with [reply] (given the
/// request body). Returns the list that collects the raw request bodies.
List<String> fakeAi(http.Response Function(Map<String, dynamic> body) reply) {
  final requests = <String>[];
  AiClient.httpClient = MockClient((request) async {
    expect(request.headers['Authorization'], 'Bearer test-token');
    requests.add(request.body);
    return reply(
      request.body.isEmpty
          ? const {}
          : jsonDecode(request.body) as Map<String, dynamic>,
    );
  });
  return requests;
}

/// A successful server reply carrying [json].
http.Response ok(Object json) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  200,
  headers: {'content-type': 'application/json'},
);
