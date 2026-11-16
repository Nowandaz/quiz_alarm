/// Keeps the phone and the server in step.
///
/// - The question bank comes DOWN from the server (for everyone, signed in
///   or not): new and edited questions arrive, deleted ones go away.
/// - The user's own progress goes UP when signed in: answers, sessions,
///   AI-written questions, and a backup of alarms and settings.
/// - On a phone that has never seen the account, that progress comes back
///   DOWN once (a new or reset phone).
///
/// Everything here is safe to repeat: rows carry ids made on the phone, so
/// sending or receiving one twice changes nothing. Nothing here may ever
/// get in the way of an alarm; every failure is swallowed and retried on
/// the next run.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';
import '../data/question_repository.dart';
import 'account.dart';
import 'question_service.dart';
import 'server_config.dart';

class SyncService {
  /// Tests replace this with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// Where downloaded pictures are kept. Tests and the browser leave it
  /// null, which keeps pictures as web addresses.
  @visibleForTesting
  static Future<Directory?> Function() pictureFolder = _defaultPictureFolder;

  /// Called after alarms were restored from the server's backup, so the
  /// alarm list can re-read them.
  static Future<void> Function()? onAlarmsRestored;

  /// One line for Settings: when the last sync happened, or why it failed.
  static final ValueNotifier<String?> status = ValueNotifier<String?>(null);
  static final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  static const String _statusPref = 'sync_status';
  static const String _backupPref = 'sync_backup_hash';
  static const String _bankPlanKey = 'bank_plan';
  static const String _bankFullKey = 'bank_full_at';
  static const String _ownerKey = 'data_owner';
  static const Duration _fullEvery = Duration(days: 3);
  static const int _page = 500;
  static const int _chunk = 200;

  /// Off in tests; main() switches it on. Only affects [schedule].
  static bool enabled = false;

  static Future<void>? _current;
  static Timer? _timer;

  // ------------------------------------------------------------- scheduling

  /// Runs a sync now (or joins the one already running). Never throws.
  static Future<void> run({bool fullBank = false}) {
    return _current ??= _run(fullBank: fullBank)
        .whenComplete(() => _current = null);
  }

  /// Runs a sync a little later; calls close together become one run.
  static void schedule([Duration delay = const Duration(seconds: 20)]) {
    if (!enabled) return;
    _timer?.cancel();
    _timer = Timer(delay, run);
  }

  static Future<void> loadStatus() async {
    final prefs = await SharedPreferences.getInstance();
    status.value = prefs.getString(_statusPref);
  }

  static Future<void> _run({required bool fullBank}) async {
    running.value = true;
    final problems = <String>[];
    try {
      await QuestionRepository.ensureReady();
      try {
        if (await _syncBank(full: fullBank)) QuestionService.changes.value++;
      } catch (e) {
        problems.add('question bank: ${_short(e)}');
      }
      if (Account.instance.isSignedIn) {
        try {
          if (await _restoreOnce()) QuestionService.changes.value++;
          await _upload();
        } catch (e) {
          problems.add('your progress: ${_short(e)}');
        }
      }
    } catch (e) {
      problems.add(_short(e));
    } finally {
      final now = DateTime.now();
      final stamp =
          '${now.day}/${now.month} ${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      final text = problems.isEmpty
          ? 'Up to date ($stamp)'
          : 'Could not sync ${problems.join('; ')} ($stamp)';
      status.value = text;
      try {
        (await SharedPreferences.getInstance()).setString(_statusPref, text);
      } catch (_) {}
      running.value = false;
    }
  }

  static String _short(Object e) {
    if (e is _SyncError) return e.message;
    if (e is TimeoutException ||
        e is SocketException ||
        e is http.ClientException) {
      return 'no connection';
    }
    debugPrint('Sync problem: $e');
    return 'unexpected error';
  }

  // ----------------------------------------------------------------- server

  static Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    String? prefer,
    String? token,
  }) async {
    final uri = Uri.parse('${ServerConfig.supabaseUrl}/rest/v1$path')
        .replace(queryParameters: query.isEmpty ? null : query);
    final headers = {
      'apikey': ServerConfig.supabaseKey,
      'Authorization': 'Bearer ${token ?? ServerConfig.supabaseKey}',
      'Content-Type': 'application/json',
      'Prefer': ?prefer,
    };
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final res = await http.Response.fromStream(
      await httpClient.send(request).timeout(const Duration(seconds: 30)),
    );
    if (res.statusCode >= 400) {
      debugPrint('Sync: $method $path -> ${res.statusCode} ${res.body}');
      throw _SyncError('the server answered ${res.statusCode}');
    }
    return res;
  }

  /// Every row of a table that matches [query], fetched page by page.
  static Future<List<Map<String, dynamic>>> _all(
    String table,
    Map<String, String> query, {
    required String order,
    String? token,
  }) async {
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += _page) {
      final res = await _send(
        'GET',
        '/$table',
        query: {
          ...query,
          'order': order,
          'limit': '$_page',
          'offset': '$offset',
        },
        token: token,
      );
      final page = (jsonDecode(utf8.decode(res.bodyBytes)) as List)
          .cast<Map<String, dynamic>>();
      rows.addAll(page);
      if (page.length < _page) return rows;
    }
  }

  static Future<void> _upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required String onConflict,
    required String token,
    bool keepExisting = false,
  }) async {
    for (var i = 0; i < rows.length; i += _chunk) {
      await _send(
        'POST',
        '/$table',
        query: {'on_conflict': onConflict},
        body: rows.sublist(i, min(i + _chunk, rows.length)),
        prefer:
            'resolution=${keepExisting ? 'ignore' : 'merge'}-duplicates,return=minimal',
        token: token,
      );
    }
  }

  // ------------------------------------------------------------------- meta

  static Future<String?> _meta(DatabaseExecutor db, String key) async {
    final rows = await db.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static Future<void> _setMeta(DatabaseExecutor db, String key, String value) =>
      db.insert('meta', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  static int _ms(Object? iso) =>
      DateTime.tryParse('${iso ?? ''}')?.millisecondsSinceEpoch ??
      DateTime.now().millisecondsSinceEpoch;

  static String _iso(Object? ms) => DateTime.fromMillisecondsSinceEpoch(
    (ms as int?) ?? 0,
    isUtc: true,
  ).toIso8601String();

  /// A random id in the standard 8-4-4-4-12 form.
  @visibleForTesting
  static String newUuid([Random? random]) {
    final rng = random ?? Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  // ---------------------------------------------------------- bank (down)

  /// Brings the local question bank in line with the server. Returns true
  /// if anything changed. Normally only asks for what changed since the
  /// last time; every few days, on the first run and when the user's plan
  /// changes, it compares everything.
  static Future<bool> _syncBank({required bool full}) async {
    final db = await AppDatabase.instance;
    final token = await Account.instance.accessToken();

    var premium = false;
    if (token != null) {
      final rows = await _all(
        'profiles',
        {
          'select': 'plan,plan_expires_at',
          'id': 'eq.${Account.instance.userId}',
        },
        order: 'id',
        token: token,
      );
      if (rows.isNotEmpty && rows.first['plan'] == 'premium') {
        final ends = DateTime.tryParse(
          '${rows.first['plan_expires_at'] ?? ''}',
        );
        premium = ends == null || ends.isAfter(DateTime.now());
      }
    }
    final plan = premium ? 'premium' : 'free';

    final since = await _meta(db, QuestionRepository.bankSyncedKey);
    final lastFull = DateTime.tryParse(await _meta(db, _bankFullKey) ?? '');
    full =
        full ||
        since == null ||
        await _meta(db, _bankPlanKey) != plan ||
        lastFull == null ||
        DateTime.now().difference(lastFull) > _fullEvery;

    final startedAt = DateTime.now().toUtc();
    final units = await _all(
      'units',
      {'select': '*'},
      order: 'id',
      token: token,
    );
    final topics = await _all(
      'topics',
      {'select': '*'},
      order: 'id',
      token: token,
    );
    final questions = await _all(
      'questions',
      {
        'select':
            'id,topic_id,type,text,options,answer,alt_answers,explanation,'
            'image_path,status,deleted_at,updated_at',
        if (!full) 'updated_at': 'gte.$since',
      },
      order: 'updated_at.asc,id.asc',
      token: token,
    );
    // Nothing sensible came back (an empty or broken project): keep what
    // the phone has rather than wiping the bank.
    if (units.isEmpty) return false;

    final folder = kIsWeb ? null : await pictureFolder();
    var changed = false;
    final pictures = <String, String>{}; // question id -> web address

    await db.transaction((txn) async {
      final liveUnits = <String>{};
      for (final u in units) {
        final id = u['id'] as String;
        if (id == QuestionRepository.customUnitId) continue;
        if (u['deleted_at'] != null || (u['premium'] == true && !premium)) {
          changed |=
              await txn.delete('units', where: 'id = ?', whereArgs: [id]) > 0;
          continue;
        }
        liveUnits.add(id);
        await txn.rawInsert(
          'INSERT INTO units(id, name, description, sort_order) VALUES(?,?,?,?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'description = excluded.description, sort_order = excluded.sort_order',
          [id, u['name'], u['description'] ?? '', u['sort_order'] ?? 0],
        );
      }

      final liveTopics = <String>{};
      for (final t in topics) {
        final id = t['id'] as String;
        if (t['deleted_at'] != null || !liveUnits.contains(t['unit_id'])) {
          changed |=
              await txn.delete(
                'topics',
                where: 'id = ? AND is_custom = 0',
                whereArgs: [id],
              ) >
              0;
          continue;
        }
        liveTopics.add(id);
        await txn.rawInsert(
          'INSERT INTO topics(id, unit_id, name, sort_order, is_custom) '
          'VALUES(?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET '
          'unit_id = excluded.unit_id, name = excluded.name, '
          'sort_order = excluded.sort_order',
          [id, t['unit_id'], t['name'], t['sort_order'] ?? 0],
        );
      }

      if (full) {
        // Everything curated is suspect until the server confirms it.
        await txn.rawUpdate(
          "UPDATE questions SET source = 'stale' WHERE source IN ('seed', 'server')",
        );
      }
      for (final q in questions) {
        final id = q['id'] as String;
        final gone =
            q['deleted_at'] != null ||
            q['status'] != 'published' ||
            !liveTopics.contains(q['topic_id']);
        if (gone) {
          changed |=
              await txn.delete('questions', where: 'id = ?', whereArgs: [id]) >
              0;
          continue;
        }
        final text = (q['text'] as String).trim();
        final key = QuestionRepository.textKey(text);
        final image = _localImage('${q['image_path'] ?? ''}', folder);
        if (image.startsWith('http') && folder != null) pictures[id] = image;
        // A generated copy of the same question gives way to the curated one.
        await txn.delete(
          'questions',
          where: 'topic_id = ? AND text_key = ? AND id != ?',
          whereArgs: [q['topic_id'], key, id],
        );
        await txn.rawInsert(
          'INSERT INTO questions(id, topic_id, type, text, text_key, options, '
          'answer, alt_answers, explanation, image, source, created_at) '
          "VALUES(?,?,?,?,?,?,?,?,?,?,'server',?) ON CONFLICT(id) DO UPDATE SET "
          'topic_id = excluded.topic_id, type = excluded.type, '
          'text = excluded.text, text_key = excluded.text_key, '
          'options = excluded.options, answer = excluded.answer, '
          'alt_answers = excluded.alt_answers, image = excluded.image, '
          "explanation = excluded.explanation, source = 'server'",
          [
            id,
            q['topic_id'],
            q['type'] == 'mcq' ? 'mcq' : 'saq',
            text,
            key,
            jsonEncode(q['options'] ?? const []),
            '${q['answer']}'.trim(),
            jsonEncode(q['alt_answers'] ?? const []),
            '${q['explanation'] ?? ''}',
            image,
            _ms(q['updated_at']),
          ],
        );
        changed = true;
      }

      if (full) {
        changed |= await txn.delete('questions', where: "source = 'stale'") > 0;
        // Curated topics and units the server no longer has, unless the
        // user's own questions still live in them.
        for (final row in await txn.query('topics', where: 'is_custom = 0')) {
          if (liveTopics.contains(row['id'])) continue;
          await txn.rawDelete(
            'DELETE FROM topics WHERE id = ? AND id NOT IN '
            '(SELECT DISTINCT topic_id FROM questions)',
            [row['id']],
          );
        }
        for (final row in await txn.query('units')) {
          final id = row['id'] as String;
          if (liveUnits.contains(id) || id == QuestionRepository.customUnitId) {
            continue;
          }
          await txn.rawDelete(
            'DELETE FROM units WHERE id = ? AND id NOT IN '
            '(SELECT DISTINCT unit_id FROM topics)',
            [id],
          );
        }
        await _setMeta(txn, _bankFullKey, startedAt.toIso8601String());
      }
      await _setMeta(txn, _bankPlanKey, plan);
      await _setMeta(
        txn,
        QuestionRepository.bankSyncedKey,
        // A minute of overlap covers clocks that disagree slightly.
        startedAt.subtract(const Duration(minutes: 1)).toIso8601String(),
      );
    });

    // Pictures are saved on the phone so spotter questions work offline.
    for (final entry in pictures.entries) {
      try {
        final file = File(_pictureFile(entry.value, folder!));
        if (!await file.exists()) {
          final res = await httpClient
              .get(Uri.parse(entry.value))
              .timeout(const Duration(seconds: 30));
          if (res.statusCode != 200) continue;
          await file.parent.create(recursive: true);
          await file.writeAsBytes(res.bodyBytes);
        }
        await db.update(
          'questions',
          {'image': file.path},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      } catch (e) {
        debugPrint('Could not save a question picture: $e');
      }
    }
    return changed;
  }

  static Future<Directory?> _defaultPictureFolder() async {
    try {
      return Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'question_images',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static String _pictureFile(String url, Directory folder) {
    final ext = p.extension(Uri.parse(url).path);
    return p.join(folder.path, '${sha1.convert(utf8.encode(url))}$ext');
  }

  /// What the app should show for a server picture path: the bundled copy
  /// for the pictures that ship with the app, the saved file if it was
  /// downloaded before, otherwise the web address.
  static String _localImage(String path, Directory? folder) {
    if (path.isEmpty) return '';
    if (path.startsWith('seed/')) {
      return 'assets/question_images/${path.substring(5)}';
    }
    final url = path.startsWith('http')
        ? path
        : '${ServerConfig.supabaseUrl}/storage/v1/object/public/question-images/$path';
    if (folder != null) {
      final file = File(_pictureFile(url, folder));
      if (file.existsSync()) return file.path;
    }
    return url;
  }

  // ------------------------------------------------------- progress (up)

  static Future<void> _upload() async {
    final token = await Account.instance.accessToken();
    final uid = Account.instance.userId;
    if (token == null || uid == null) throw const _SyncError('no connection');
    final db = await AppDatabase.instance;

    // Someone else's account on this phone: everything goes to theirs too.
    if (await _meta(db, _ownerKey) != uid) {
      await db.transaction((txn) async {
        await txn.rawUpdate('UPDATE sessions SET synced = 0');
        await txn.rawUpdate('UPDATE attempts SET synced = 0');
        await txn.rawUpdate('UPDATE questions SET synced = 0');
        await _setMeta(txn, _ownerKey, uid);
      });
    }
    for (final table in const ['sessions', 'attempts']) {
      for (final row in await db.query(
        table,
        columns: ['id'],
        where: 'uuid IS NULL',
      )) {
        await db.update(
          table,
          {'uuid': newUuid()},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    final bankSynced =
        await _meta(db, QuestionRepository.bankSyncedKey) != null;

    // 1. Questions the AI wrote for this user (or they added themselves).
    final ownQuestions = await db.rawQuery(
      'SELECT q.*, t.name AS topic_name, t.is_custom FROM questions q '
      'JOIN topics t ON t.id = q.topic_id '
      "WHERE q.synced = 0 AND q.source IN ('ai', 'user')",
    );
    await _upsert(
      'user_questions',
      [
        for (final q in ownQuestions)
          {
            'id': q['id'],
            'user_id': uid,
            'topic_id': bankSynced && q['is_custom'] == 0
                ? q['topic_id']
                : null,
            'topic_name': q['topic_name'],
            'type': q['type'],
            'text': q['text'],
            'options': jsonDecode(q['options'] as String),
            'answer': q['answer'],
            'alt_answers': jsonDecode(q['alt_answers'] as String),
            'explanation': q['explanation'],
            'created_at': _iso(q['created_at']),
          },
      ],
      onConflict: 'user_id,id',
      token: token,
    );
    for (final q in ownQuestions) {
      await db.update(
        'questions',
        {'synced': 1},
        where: 'id = ?',
        whereArgs: [q['id']],
      );
    }

    // 2. Sessions. One still in progress is sent again when it ends.
    final sessions = await db.query('sessions', where: 'synced = 0');
    await _upsert(
      'user_sessions',
      [
        for (final s in sessions)
          {
            'id': s['uuid'],
            'user_id': uid,
            'kind': const {'alarm', 'bank'}.contains(s['kind'])
                ? s['kind']
                : 'revision',
            'title': s['title'],
            'required_streak': s['required_streak'],
            'started_at': _iso(s['started_at']),
            'ended_at': s['ended_at'] == null ? null : _iso(s['ended_at']),
            'outcome':
                const {
                  'dismissed',
                  'snoozed',
                  'finished',
                }.contains(s['outcome'])
                ? s['outcome']
                : null,
          },
      ],
      onConflict: 'id',
      token: token,
    );
    for (final s in sessions) {
      if (s['ended_at'] == null) continue;
      await db.update(
        'sessions',
        {'synced': 1},
        where: 'id = ?',
        whereArgs: [s['id']],
      );
    }

    // 3. Answers.
    final attempts = await db.rawQuery(
      'SELECT a.*, s.uuid AS session_uuid FROM attempts a '
      'LEFT JOIN sessions s ON s.id = a.session_id WHERE a.synced = 0',
    );
    await _upsert(
      'user_attempts',
      [
        for (final a in attempts)
          {
            'user_id': uid,
            'client_id': a['uuid'],
            'question_id': a['question_id'],
            'session_id': a['session_uuid'],
            'mode': a['mode'],
            'correct': a['correct'] == 1,
            'user_answer': a['user_answer'],
            'duration_ms': a['duration_ms'],
            'answered_at': _iso(a['answered_at']),
          },
      ],
      onConflict: 'user_id,client_id',
      keepExisting: true,
      token: token,
    );
    for (final a in attempts) {
      await db.update(
        'attempts',
        {'synced': 1},
        where: 'id = ?',
        whereArgs: [a['id']],
      );
    }

    // 4. Alarms and settings, when they changed.
    final prefs = await SharedPreferences.getInstance();
    final backup = {
      'user_id': uid,
      'alarms': jsonDecode(prefs.getString('saved_alarms') ?? '[]'),
      'settings': {
        for (final key in const ['isDarkTheme', 'use24Hour', 'analogClock'])
          if (prefs.getBool(key) != null) key: prefs.getBool(key),
      },
    };
    final hash = '${sha1.convert(utf8.encode(jsonEncode(backup)))}';
    if (prefs.getString(_backupPref) != hash) {
      await _upsert(
        'user_backups',
        [backup],
        onConflict: 'user_id',
        token: token,
      );
      await prefs.setString(_backupPref, hash);
    }
  }

  // ----------------------------------------------------- progress (down)

  /// The first time an account is used on this phone, brings back what
  /// the server holds for it. Returns true if anything was added.
  static Future<bool> _restoreOnce() async {
    final token = await Account.instance.accessToken();
    final uid = Account.instance.userId;
    if (token == null || uid == null) throw const _SyncError('no connection');
    final db = await AppDatabase.instance;
    final doneKey = 'restored:$uid';
    if (await _meta(db, doneKey) != null) return false;

    final mine = {'select': '*', 'user_id': 'eq.$uid'};
    final questions = await _all(
      'user_questions',
      mine,
      order: 'id',
      token: token,
    );
    final sessions = await _all(
      'user_sessions',
      mine,
      order: 'id',
      token: token,
    );
    final attempts = await _all(
      'user_attempts',
      mine,
      order: 'id',
      token: token,
    );
    final backups = await _all(
      'user_backups',
      mine,
      order: 'user_id',
      token: token,
    );
    var added = false;

    // Questions first: answers can only be kept for questions that exist.
    for (final q in questions) {
      var topicId = q['topic_id'] as String?;
      if (topicId != null &&
          (await db.query(
            'topics',
            where: 'id = ?',
            whereArgs: [topicId],
          )).isEmpty) {
        topicId = null;
      }
      if (topicId == null) {
        final name = '${q['topic_name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        topicId =
            (await QuestionRepository.findTopicByName(name) ??
                    await QuestionRepository.addCustomTopic(name))
                .id;
      }
      final n = await db.insert('questions', {
        'id': q['id'],
        'topic_id': topicId,
        'type': q['type'] == 'mcq' ? 'mcq' : 'saq',
        'text': q['text'],
        'text_key': QuestionRepository.textKey('${q['text']}'),
        'options': jsonEncode(q['options'] ?? const []),
        'answer': q['answer'],
        'alt_answers': jsonEncode(q['alt_answers'] ?? const []),
        'explanation': q['explanation'] ?? '',
        'source': 'ai',
        'created_at': _ms(q['created_at']),
        'synced': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      added |= n > 0;
    }

    await db.transaction((txn) async {
      for (final s in sessions) {
        await txn.insert('sessions', {
          'uuid': s['id'],
          'kind': s['kind'],
          'title': s['title'] ?? '',
          'required_streak': s['required_streak'],
          'started_at': _ms(s['started_at']),
          'ended_at': s['ended_at'] == null ? null : _ms(s['ended_at']),
          'outcome': s['outcome'],
          'synced': 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final sessionIds = {
        for (final row in await txn.query('sessions', columns: ['id', 'uuid']))
          row['uuid']: row['id'],
      };
      final known = {
        for (final row in await txn.query('questions', columns: ['id']))
          row['id'],
      };
      for (final a in attempts) {
        if (!known.contains(a['question_id'])) continue;
        final n = await txn.insert('attempts', {
          'uuid': a['client_id'],
          'question_id': a['question_id'],
          'mode': a['mode'],
          'correct': a['correct'] == true ? 1 : 0,
          'answered_at': _ms(a['answered_at']),
          'session_id': sessionIds[a['session_id']],
          'user_answer': a['user_answer'] ?? '',
          'duration_ms': a['duration_ms'],
          'synced': 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        added |= n > 0;
      }
      // Sessions whose answers could not be kept would show as empty.
      await txn.rawDelete(
        'DELETE FROM sessions WHERE synced = 1 AND kind != ? AND id NOT IN '
        '(SELECT DISTINCT session_id FROM attempts WHERE session_id IS NOT NULL)',
        ['alarm'],
      );
      await _setMeta(txn, doneKey, DateTime.now().toIso8601String());
      await _setMeta(txn, _ownerKey, uid);
    });

    // Alarms come back only onto a phone that has none, and switched off:
    // the user turns on the ones they want here.
    final prefs = await SharedPreferences.getInstance();
    final local = jsonDecode(prefs.getString('saved_alarms') ?? '[]') as List;
    if (local.isEmpty &&
        backups.isNotEmpty &&
        backups.first['alarms'] is List) {
      final restored = [
        for (final a in (backups.first['alarms'] as List).whereType<Map>())
          {
            ...a,
            'isEnabled': false,
            // A ringtone picked from the old phone's files is not here.
            if (!'${a['audioPath'] ?? ''}'.startsWith('assets/'))
              'audioPath': 'assets/sounds/alarm.mp3',
          },
      ];
      if (restored.isNotEmpty) {
        await prefs.setString('saved_alarms', jsonEncode(restored));
        await onAlarmsRestored?.call();
        added = true;
      }
    }
    return added;
  }
}

class _SyncError implements Exception {
  final String message;
  const _SyncError(this.message);
  @override
  String toString() => message;
}
