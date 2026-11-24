/// Entry point used only to film the app for the promo animation
/// (quizalarm_s/promo). It is the normal app in a browser, on a paid plan
/// without an account, with a question bank file loaded from the page's
/// own folder (promo_bank.json). The phone app never includes this file.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/main.dart' as app;
import 'package:quiz_alarm/screens/home_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/alarm_backend.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase.factoryOverride = databaseFactoryFfiWeb;
  HomeScreen.requireAccount = false;
  SimulatedAlarmBackend.showHints = false;
  // ignore: invalid_use_of_visible_for_testing_member
  Entitlements.instance.setForTest(PlanLevel.pro);
  try {
    // Only the film's own bank file: the starter banks built into the app
    // are left out (importing both at every start would replace the
    // questions and drop the answers given to them).
    final db = await AppDatabase.instance;
    await db.rawInsert('INSERT OR IGNORE INTO meta(key, value) VALUES(?, ?)', [
      QuestionRepository.bankSyncedKey,
      DateTime.now().toIso8601String(),
    ]);
    await QuestionRepository.ensureReady();
    final res = await http.get(Uri.base.resolve('promo_bank.json'));
    if (res.statusCode == 200) {
      await QuestionRepository.importUnit(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
      );
    }
  } catch (e) {
    // ignore: avoid_print
    print('Promo bank not loaded: $e');
  }
  await app.main();
  // As a signed-in Pro user sees it (the AI tutor button, not a sign-in
  // hint). The film blocks the network, so nothing is sent anywhere.
  // ignore: invalid_use_of_visible_for_testing_member
  Account.instance.signInForTest(email: 'student@example.com');
}
