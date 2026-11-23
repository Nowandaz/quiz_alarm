/// Messages from the team ("Pharmacology topics uploaded").
///
/// An admin writes them on the admin site. The app fetches the recent
/// ones when it is opened or an alarm wakes it (at most every few hours;
/// there is no push), shows a notification for each new one, a banner on
/// the first screen for the newest unread one, and keeps them in a list.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlements.dart';
import 'server_config.dart';
import 'system_bridge.dart';

class Announcement {
  final int id;
  final String title;
  final String body;
  final String link;
  final DateTime publishedAt;
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.link,
    required this.publishedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'link': link,
    'published_at': publishedAt.toUtc().toIso8601String(),
  };

  static Announcement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = '${raw['title'] ?? ''}'.trim();
    if (id is! int || title.isEmpty) return null;
    return Announcement(
      id: id,
      title: title,
      body: '${raw['body'] ?? ''}'.trim(),
      link: '${raw['link'] ?? ''}'.trim(),
      publishedAt:
          DateTime.tryParse('${raw['published_at'] ?? ''}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class Announcements {
  /// The recent messages for this person, newest first.
  static final ValueNotifier<List<Announcement>> all = ValueNotifier(const []);

  /// The newest one not yet read (null: nothing new). The banner shows it.
  static final ValueNotifier<Announcement?> unread = ValueNotifier(null);

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

  static const String checkedPref = 'announcements_checked_at';
  static const String cachePref = 'announcements_cache';
  static const String readPref = 'announcements_read_up_to';
  static const String noticedPref = 'announcements_noticed_up_to';
  static const Duration every = Duration(hours: 3);
  static const int keep = 20;

  /// What is saved on the phone, for showing before (or without) internet.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cachePref);
      if (raw != null) {
        final list = (jsonDecode(raw) as List)
            .map(Announcement.fromJson)
            .whereType<Announcement>()
            .toList();
        _show(list, prefs.getInt(readPref) ?? 0);
      }
    } catch (e) {
      debugPrint('Reading saved messages failed: $e');
    }
  }

  static void _show(List<Announcement> list, int readUpTo) {
    all.value = list;
    final fresh = list.where((a) => a.id > readUpTo);
    unread.value = fresh.isEmpty ? null : fresh.first;
  }

  static Future<void>? _running;

  /// Fetches the recent messages, at most every [every] unless [force].
  /// Never throws.
  static Future<void> run({bool force = false}) =>
      _running ??= _run(force).whenComplete(() => _running = null);

  static Future<void> _run(bool force) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = now();
      final last = prefs.getInt(checkedPref) ?? 0;
      final since = t.millisecondsSinceEpoch - last;
      if (!force && since >= 0 && since < every.inMilliseconds) return;

      // Who the person is, for messages meant for one level only.
      final level = Entitlements.instance.level;
      final mine = level == PlanLevel.guest
          ? 'guest'
          : level == PlanLevel.free
          ? 'free'
          : 'paid';
      final res = await httpClient
          .get(
            Uri.parse(
              '${ServerConfig.supabaseUrl}/rest/v1/announcements'
              '?select=id,title,body,link,published_at,expires_at'
              '&audience=in.(all,$mine)'
              '&order=published_at.desc&limit=$keep',
            ),
            headers: {
              'apikey': ServerConfig.supabaseKey,
              'Authorization': 'Bearer ${ServerConfig.supabaseKey}',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      await prefs.setInt(checkedPref, t.millisecondsSinceEpoch);
      final rows = jsonDecode(utf8.decode(res.bodyBytes));
      if (rows is! List) return;
      final list = <Announcement>[];
      for (final row in rows) {
        final a = Announcement.fromJson(row);
        if (a == null) continue;
        final ends = DateTime.tryParse('${(row as Map)['expires_at'] ?? ''}');
        if (ends != null && ends.isBefore(t)) continue;
        list.add(a);
      }
      await prefs.setString(
        cachePref,
        jsonEncode(list.map((a) => a.toJson()).toList()),
      );

      // A notification for each new one, oldest first (three at most, so
      // a phone that was away for long is not flooded).
      final noticed = prefs.getInt(noticedPref);
      final newest = list.isEmpty ? 0 : list.map((a) => a.id).reduce(_max);
      if (noticed == null) {
        // First time on this phone: old messages are not news.
        await prefs.setInt(noticedPref, newest);
        await prefs.setInt(readPref, newest);
      } else if (newest > noticed) {
        final fresh = list.where((a) => a.id > noticed).toList().reversed;
        for (final a in fresh.skip(fresh.length > 3 ? fresh.length - 3 : 0)) {
          await showNotice(
            id: 700000 + a.id % 100000,
            title: a.title,
            body: a.body.isEmpty ? 'Open Brain O\' Clock to read it.' : a.body,
          );
        }
        await prefs.setInt(noticedPref, newest);
      }
      _show(list, prefs.getInt(readPref) ?? 0);
    } catch (e) {
      debugPrint('Fetching messages failed: $e');
    }
  }

  static int _max(int a, int b) => a > b ? a : b;

  /// Marks everything up to now as read (the banner goes away).
  static Future<void> markRead() async {
    final list = all.value;
    unread.value = null;
    if (list.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(readPref, list.map((a) => a.id).reduce(_max));
  }

  /// Opens a message's web address, if it has one.
  static Future<bool> open(Announcement a) =>
      a.link.isEmpty ? Future.value(false) : SystemBridge.openUrl(a.link);

  @visibleForTesting
  static void resetForTest() {
    all.value = const [];
    unread.value = null;
    now = DateTime.now;
  }
}
