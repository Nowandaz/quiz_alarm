/// A small anonymous "this phone uses the app" note for the owner: how
/// many phones are in use, on which plan and app version.
///
/// It carries a random id made once for this install (not the account,
/// not the phone's own ids), the plan level, the app version and the
/// platform. A few totals (answers given, alarms dismissed or missed) are
/// added only while "Share alarm diagnostics" is on in Settings.
///
/// Sent at most once per calendar day, and again when the plan level
/// changes. A failed send is simply tried again at the next app start.
/// Nothing here ever throws or gets in the app's way.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/alarm_log.dart';
import '../data/app_database.dart';
import 'account.dart';
import 'entitlements.dart';
import 'server_config.dart';
import 'sync_service.dart';

class UsagePing {
  /// Talks to the server; tests replace it with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// The clock; tests replace it.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static const String installPref = 'install_id';
  static const String dayPref = 'usage_ping_day';

  /// The plan level the last ping carried.
  static const String levelPref = 'usage_ping_level';

  static Future<bool>? _sending;

  /// Sends the ping if today's has not gone yet, or the plan level is
  /// not the one last sent. True when one was sent. Never throws.
  static Future<bool> send() =>
      _sending ??= _send().whenComplete(() => _sending = null);

  static Future<bool> _send() async {
    // Browser builds are previews and tests, not phones: never counted.
    if (kIsWeb) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = now();
      final day =
          '${t.year}-${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}';
      final level = Entitlements.instance.level.name;
      if (prefs.getString(dayPref) == day &&
          prefs.getString(levelPref) == level) {
        return false;
      }

      var install = prefs.getString(installPref);
      if (install == null) {
        install = AlarmLog.newUuid();
        await prefs.setString(installPref, install);
      }
      // On unless switched off, as in Settings.
      final share = prefs.getBool(SyncService.shareDiagnosticsPref) ?? true;
      final counts = share ? await _counts() : null;
      final token = Account.instance.isSignedIn
          ? await Account.instance.accessToken()
          : null;

      final res = await httpClient
          .post(
            Uri.parse('${ServerConfig.supabaseUrl}/rest/v1/rpc/app_ping'),
            headers: {
              'apikey': ServerConfig.supabaseKey,
              'Authorization': 'Bearer ${token ?? ServerConfig.supabaseKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'install': install,
              'level': level,
              'version': ServerConfig.appVersion,
              'platform': kIsWeb
                  ? 'web'
                  : defaultTargetPlatform.name.toLowerCase(),
              'answered': counts?.answered,
              'correct': counts?.correct,
              'alarms_ok': counts?.alarmsOk,
              'alarms_missed': counts?.alarmsMissed,
              'alarms': _alarms(prefs),
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      await prefs.setString(dayPref, day);
      await prefs.setString(levelPref, level);
      return true;
    } catch (e) {
      debugPrint('Usage ping failed (will try again): $e');
      return false;
    }
  }

  /// Totals from this phone's own records (null if they cannot be read).
  static Future<({int answered, int correct, int alarmsOk, int alarmsMissed})?>
  _counts() async {
    try {
      final db = await AppDatabase.instance;
      final a = (await db.rawQuery(
        'SELECT COUNT(*) AS n, COALESCE(SUM(correct != 0), 0) AS ok '
        'FROM attempts',
      )).first;
      final e = (await db.rawQuery(
        "SELECT COALESCE(SUM(type = 'dismissed'), 0) AS ok, "
        "COALESCE(SUM(type IN ('missed', 'timed_out')), 0) AS missed "
        'FROM alarm_events',
      )).first;
      return (
        answered: (a['n'] as num).toInt(),
        correct: (a['ok'] as num).toInt(),
        alarmsOk: (e['ok'] as num).toInt(),
        alarmsMissed: (e['missed'] as num).toInt(),
      );
    } catch (e) {
      debugPrint('Usage ping: could not read the totals: $e');
      return null;
    }
  }

  /// How many alarms are set up now (null if unknown).
  static int? _alarms(SharedPreferences prefs) {
    try {
      final raw = prefs.getString('saved_alarms');
      if (raw == null) return 0;
      return (jsonDecode(raw) as List).length;
    } catch (_) {
      return null;
    }
  }
}
