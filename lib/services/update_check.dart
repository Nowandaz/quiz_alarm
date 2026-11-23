/// "A new version is out."
///
/// The app is shared as an install file, not through a store, so nothing
/// updates it by itself. The owner lists each new version on the admin
/// site; the app reads the newest one (every few hours, when it is
/// open or an alarm wakes it), and if it is newer than the one installed
/// it shows a notification and a banner that lead to the download page.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'server_config.dart';
import 'system_bridge.dart';

class AppRelease {
  final String version;
  final String notes;
  const AppRelease(this.version, this.notes);
}

class UpdateCheck {
  /// The newer version on offer, if any (null: up to date, or not known).
  static final ValueNotifier<AppRelease?> available = ValueNotifier(null);

  /// Tests replace these.
  @visibleForTesting
  static http.Client httpClient = http.Client();
  @visibleForTesting
  static DateTime Function() now = DateTime.now;
  @visibleForTesting
  static Future<bool> Function({
    required int id,
    required String title,
    required String body,
  })
  showNotice = SystemBridge.showNotice;

  /// The installed version; tests replace it.
  @visibleForTesting
  static Future<String> Function() installedVersion = _installed;

  static const String checkedPref = 'update_checked_at';
  static const String noticedPref = 'update_noticed_version';
  static const String dismissedPref = 'update_dismissed_version';
  static const String knownVersionPref = 'update_known_version';
  static const String knownNotesPref = 'update_known_notes';
  static const Duration every = Duration(hours: 3);

  static Future<String> _installed() async {
    // What Android says is installed; the constant is the fallback.
    final fromPhone =
        '${(await SystemBridge.deviceInfo())['app_version'] ?? ''}';
    final version = fromPhone.isNotEmpty ? fromPhone : ServerConfig.appVersion;
    return version.split('+').first.trim();
  }

  /// True when version [a] is newer than [b] ("1.0.10" is newer than
  /// "1.0.9"). Anything that is not numbers counts as zero.
  static bool isNewer(String a, String b) {
    List<int> parts(String v) => v
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      final m = i < x.length ? x[i] : 0, n = i < y.length ? y[i] : 0;
      if (m != n) return m > n;
    }
    return false;
  }

  static Future<void>? _running;

  /// Looks for a newer version, at most every [every] unless [force].
  /// Never throws.
  static Future<void> run({bool force = false}) =>
      _running ??= _run(force).whenComplete(() => _running = null);

  static Future<void> _run(bool force) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(checkedPref) ?? 0;
      final t = now().millisecondsSinceEpoch;
      if (!force && t - last < every.inMilliseconds && t >= last) {
        // Not asking the server this time: the banner still shows for
        // the version it told us about before.
        final known = prefs.getString(knownVersionPref) ?? '';
        available.value =
            known.isNotEmpty &&
                prefs.getString(dismissedPref) != known &&
                isNewer(known, await installedVersion())
            ? AppRelease(known, prefs.getString(knownNotesPref) ?? '')
            : null;
        return;
      }
      final res = await httpClient
          .get(
            Uri.parse(
              '${ServerConfig.supabaseUrl}/rest/v1/app_releases'
              '?select=version,notes&order=published_at.desc&limit=1',
            ),
            headers: {
              'apikey': ServerConfig.supabaseKey,
              'Authorization': 'Bearer ${ServerConfig.supabaseKey}',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      await prefs.setInt(checkedPref, t);
      final rows = jsonDecode(utf8.decode(res.bodyBytes));
      if (rows is! List || rows.isEmpty) {
        available.value = null;
        return;
      }
      final version = '${rows.first['version'] ?? ''}'.trim();
      final notes = '${rows.first['notes'] ?? ''}'.trim();
      await prefs.setString(knownVersionPref, version);
      await prefs.setString(knownNotesPref, notes);
      if (version.isEmpty || !isNewer(version, await installedVersion())) {
        available.value = null;
        return;
      }
      // The banner, unless this version was already waved away.
      available.value = prefs.getString(dismissedPref) == version
          ? null
          : AppRelease(version, notes);
      // The notification, once per version.
      if (prefs.getString(noticedPref) != version) {
        await prefs.setString(noticedPref, version);
        await showNotice(
          id: 880001,
          title: 'Update available',
          body:
              'Brain O\' Clock $version is out. Open the app and tap '
              '"Get it" to download it.',
        );
      }
    } catch (e) {
      debugPrint('Looking for an update failed: $e');
    }
  }

  /// "Later": hides the banner until an even newer version is listed.
  static Future<void> dismiss() async {
    final release = available.value;
    available.value = null;
    if (release == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(dismissedPref, release.version);
  }

  /// Opens the download page in the browser.
  static Future<bool> open() => SystemBridge.openUrl(ServerConfig.downloadUrl);
}
