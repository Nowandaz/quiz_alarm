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

import '../data/alarm_log.dart';
import '../data/app_database.dart';
import '../data/flag_store.dart';
import '../data/question_repository.dart';
import '../models/models.dart';
import 'account.dart';
import 'entitlements.dart';
import 'profile_picture.dart';
import 'question_service.dart';
import 'server_config.dart';
import 'system_bridge.dart';

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
  static const String _bankLevelKey = 'bank_level';
  static const String _bankFullKey = 'bank_full_at';
  static const String _ownerKey = 'data_owner';
  static const String _deletedKey = QuestionRepository.deletedOwnQuestionsKey;

  /// Preference behind "Share alarm diagnostics" in Settings (on unless
  /// switched off). Off: the alarm diary stays on the phone.
  static const String shareDiagnosticsPref = 'shareDiagnostics';
  static const Duration _fullEvery = Duration(days: 3);
  static const int _page = 500;
  static const int _chunk = 200;

  /// Off in tests; main() switches it on. Only affects [schedule].
  static bool enabled = false;

  static Future<void>? _current;
  static Timer? _timer;

  // ------------------------------------------------------------- scheduling

  /// Runs a sync now (or joins the one already running). Never throws.
  ///
  /// [fullBank] compares the whole question bank instead of only asking
  /// for changes (needed after the user's plan changed). If a sync is
  /// already running, the full comparison is not forgotten: it runs right
  /// after that one.
  static Future<void> run({bool fullBank = false}) {
    if (fullBank) _fullWanted = true;
    return _current ??= _runAll().whenComplete(() => _current = null);
  }

  static bool _fullWanted = false;

  static Future<void> _runAll() async {
    do {
      final full = _fullWanted;
      _fullWanted = false;
      await _run(fullBank: full);
    } while (_fullWanted);
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
      final db = await AppDatabase.instance;
      final signedIn = Account.instance.isSignedIn;
      // Signed out on a phone that holds an account's data: the sign-in
      // person is a guest for now. Leave everything exactly as it is (a
      // download without the account would throw away the questions it
      // had; what a guest may open is decided on the phone meanwhile).
      if (!signedIn && await _meta(db, _ownerKey) != null) return;

      if (signedIn && await _adoptOwner()) QuestionService.changes.value++;
      var bankOk = false;
      try {
        if (await _syncBank(full: fullBank)) QuestionService.changes.value++;
        bankOk = true;
      } catch (e) {
        problems.add('question bank: ${_short(e)}');
      }
      if (signedIn) {
        try {
          // History is only brought back once the bank is in place:
          // answers can only be kept for questions the phone has.
          if (bankOk && await _restoreOnce()) QuestionService.changes.value++;
          await _upload();
          // Questions flagged for review (never throws).
          await FlagStore.upload();
          // The profile picture (never throws).
          await ProfilePicture.sync();
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
      throw _SyncError(
        'the server answered ${res.statusCode}',
        status: res.statusCode,
      );
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

  /// Every row of a table, fetched in id order, each page starting after
  /// the last id seen. Unlike [_all] this cannot skip a row when the
  /// table changes between pages, which matters when "not received" is
  /// taken to mean "deleted".
  static Future<List<Map<String, dynamic>>> _allById(
    String table,
    Map<String, String> query, {
    String? token,
  }) async {
    final rows = <Map<String, dynamic>>[];
    String? last;
    while (true) {
      final res = await _send(
        'GET',
        '/$table',
        query: {
          ...query,
          'order': 'id.asc',
          'limit': '$_page',
          'id': ?(last == null ? null : 'gt.$last'),
        },
        token: token,
      );
      final page = (jsonDecode(utf8.decode(res.bodyBytes)) as List)
          .cast<Map<String, dynamic>>();
      if (page.isEmpty) return rows;
      rows.addAll(page);
      last = '${page.last['id']}';
    }
  }

  /// Sends rows in batches. If the server refuses a batch because of one
  /// bad row, the rows are sent one by one and [rejected] is told the
  /// index of each row the server will not take, so that a single bad row
  /// cannot block everything behind it for ever.
  static Future<void> _upsert(
    String table,
    List<Map<String, Object?>> rows, {
    required String onConflict,
    required String token,
    bool keepExisting = false,
    Future<void> Function(int index)? rejected,
  }) async {
    Future<void> post(List<Map<String, Object?>> batch) => _send(
      'POST',
      '/$table',
      query: {'on_conflict': onConflict},
      body: batch,
      prefer:
          'resolution=${keepExisting ? 'ignore' : 'merge'}-duplicates,return=minimal',
      token: token,
    );
    bool refusedRow(Object e) =>
        e is _SyncError && const {400, 403, 409, 422}.contains(e.status);

    for (var i = 0; i < rows.length; i += _chunk) {
      final end = min(i + _chunk, rows.length);
      try {
        await post(rows.sublist(i, end));
      } catch (e) {
        if (rejected == null || !refusedRow(e)) rethrow;
        for (var j = i; j < end; j++) {
          try {
            await post([rows[j]]);
          } catch (e) {
            if (!refusedRow(e)) rethrow;
            await rejected(j);
          }
        }
      }
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
    return AlarmLog.newUuid(random);
  }

  // ---------------------------------------------------------- bank (down)

  /// Brings the local question bank in line with the server. Returns true
  /// if anything changed. Normally only asks for what changed since the
  /// last time; every few days, on the first run and when what the person
  /// may see changes (sign in, a new plan, a plan that ran out), it
  /// compares everything.
  ///
  /// The server sends every topic, each with who may open it ("access"),
  /// but only the questions this account may see. A topic that arrives
  /// without questions therefore stays on the phone as a locked title.
  static Future<bool> _syncBank({required bool full}) async {
    final db = await AppDatabase.instance;
    final token = await Account.instance.accessToken();
    // Signed in but the sign-in could not be confirmed right now: do not
    // download as a stranger, that would drop the account's questions.
    if (token == null && Account.instance.isSignedIn) {
      throw const _SyncError('no connection');
    }

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
    // What the server lets this phone see: 'guest', 'free' or 'paid'.
    final level = token == null
        ? TopicAccess.guest
        : premium
        ? TopicAccess.paid
        : TopicAccess.free;

    final since = await _meta(db, QuestionRepository.bankSyncedKey);
    final levelBefore = await _meta(db, _bankLevelKey);
    final levelChanged = levelBefore != level;
    final restoredKey = 'restored:${Account.instance.userId}';
    if (levelChanged && token != null && await _meta(db, restoredKey) != null) {
      // Questions may be about to leave the phone, and answers go with
      // them. Send what is not on the server yet first, and fetch the
      // history again afterwards (answers come back when their questions
      // do, e.g. after renewing a plan).
      try {
        await _upload();
        await db.delete('meta', where: 'key = ?', whereArgs: [restoredKey]);
      } catch (e) {
        debugPrint('Could not send progress before the bank changed: $e');
      }
    }
    final lastFull = DateTime.tryParse(await _meta(db, _bankFullKey) ?? '');
    full =
        full ||
        since == null ||
        levelChanged ||
        lastFull == null ||
        DateTime.now().difference(lastFull) > _fullEvery;

    final startedAt = DateTime.now().toUtc();
    final units = await _allById('units', {'select': '*'}, token: token);
    final topics = await _allById('topics', {'select': '*'}, token: token);
    // Subunits and sections. A server from before they existed has no such
    // table (404, or 400): the bank then arrives as before, without them.
    List<Map<String, dynamic>>? sections;
    try {
      sections = await _allById('sections', {'select': '*'}, token: token);
    } on _SyncError catch (e) {
      if (e.status != 404 && e.status != 400) rethrow;
      debugPrint('This server has no sections: $e');
    }
    const columns =
        'id,topic_id,type,text,options,answer,alt_answers,explanation,'
        'image_path,status,deleted_at,updated_at';
    final questions = full
        ? await _allById('questions', {'select': columns}, token: token)
        : await _all(
            'questions',
            {'select': columns, 'updated_at': 'gte.$since'},
            order: 'updated_at.asc,id.asc',
            token: token,
          );
    // Questions that were unpublished or deleted: a phone is not allowed to
    // read those rows any more, so the server lists their ids separately.
    var withdrawn = const <String>[];
    if (!full) {
      try {
        final res = await _send(
          'POST',
          '/rpc/question_tombstones',
          body: {'since': since},
          token: token,
        );
        withdrawn = [
          for (final r in jsonDecode(utf8.decode(res.bodyBytes)) as List)
            '${(r as Map)['id']}',
        ];
      } on _SyncError catch (e) {
        debugPrint('No list of withdrawn questions: $e');
      }
    }
    // The newest change received. The next download asks for changes
    // since then, by the server's clock rather than the phone's.
    DateTime? newest;
    for (final q in questions) {
      final t = DateTime.tryParse('${q['updated_at'] ?? ''}');
      if (t != null && (newest == null || t.isAfter(newest))) newest = t;
    }
    // Nothing sensible came back (an empty or broken project): keep what
    // the phone has rather than wiping the bank.
    if (units.isEmpty) return false;

    final folder = kIsWeb ? null : await pictureFolder();
    var changed = false;
    // A unit or topic that is live on the server but new to this phone
    // (restored by an admin): its questions did not change, so only a
    // full comparison brings them.
    var needFull = false;
    final pictures = <String, String>{}; // question id -> web address

    await db.transaction((txn) async {
      final liveUnits = <String>{};
      for (final u in units) {
        final id = u['id'] as String;
        if (id == QuestionRepository.customUnitId) continue;
        if (u['deleted_at'] != null) {
          changed |= await _retireUnit(txn, id);
          continue;
        }
        liveUnits.add(id);
        needFull |= (await txn.query(
          'units',
          where: 'id = ?',
          whereArgs: [id],
        )).isEmpty;
        await txn.rawInsert(
          'INSERT INTO units(id, name, description, sort_order) VALUES(?,?,?,?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'description = excluded.description, sort_order = excluded.sort_order',
          [id, u['name'], u['description'] ?? '', u['sort_order'] ?? 0],
        );
      }

      if (sections != null) {
        final liveSections = <String>{};
        for (final x in sections) {
          final id = x['id'] as String;
          if (x['deleted_at'] != null || !liveUnits.contains(x['unit_id'])) {
            continue;
          }
          liveSections.add(id);
          final row = <String, Object?>{
            'id': id,
            'unit_id': x['unit_id'],
            'parent_id': x['parent_id'],
            'kind': x['kind'] == Section.subunitKind
                ? Section.subunitKind
                : Section.sectionKind,
            'name': '${x['name'] ?? ''}',
            'description': '${x['description'] ?? ''}',
            'sort_order': x['sort_order'] ?? 0,
          };
          final had = await txn.query(
            'sections',
            where: 'id = ?',
            whereArgs: [id],
          );
          changed |= had.isEmpty || row.keys.any((k) => had.first[k] != row[k]);
          await txn.insert(
            'sections',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        // Sections the server deleted or no longer has. Their topics stay,
        // filed as the server says.
        for (final row in await txn.query('sections', columns: ['id'])) {
          if (liveSections.contains(row['id'])) continue;
          await txn.delete('sections', where: 'id = ?', whereArgs: [row['id']]);
          changed = true;
        }
      }

      final liveTopics = <String>{};
      for (final t in topics) {
        final id = t['id'] as String;
        if (t['deleted_at'] != null || !liveUnits.contains(t['unit_id'])) {
          changed |= await _retireTopic(txn, id);
          continue;
        }
        final access = QuestionRepository.cleanAccess(t['access']);
        final had = await txn.query(
          'topics',
          where: 'id = ? AND is_custom = 0',
          whereArgs: [id],
        );
        needFull |= had.isEmpty;
        // A topic that opened or locked shows differently straight away.
        changed |= had.isEmpty || had.first['access'] != access;
        liveTopics.add(id);
        // The section it is filed under. An older server does not send
        // one: what the phone has is then left alone.
        final filed = t.containsKey('section_id');
        final sectionId = t['section_id'] as String?;
        changed |=
            filed && had.isNotEmpty && had.first['section_id'] != sectionId;
        await txn.rawInsert(
          'INSERT INTO topics(id, unit_id, name, sort_order, is_custom, access, '
          'section_id) VALUES(?,?,?,?,0,?,?) ON CONFLICT(id) DO UPDATE SET '
          'unit_id = excluded.unit_id, name = excluded.name, '
          'sort_order = excluded.sort_order, is_custom = 0, '
          'access = excluded.access'
          '${filed ? ', section_id = excluded.section_id' : ''}',
          [
            id,
            t['unit_id'],
            t['name'],
            t['sort_order'] ?? 0,
            access,
            sectionId,
          ],
        );
        // How many published questions the topic has on the server (sent
        // by newer servers): a topic with none is hidden until it has some.
        if (t['question_count'] is int) {
          final known = had.isEmpty ? null : had.first['server_questions'];
          changed |= known != t['question_count'];
          await txn.rawUpdate(
            'UPDATE topics SET server_questions = ? WHERE id = ?',
            [t['question_count'], id],
          );
        }
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

      for (final id in withdrawn) {
        changed |=
            await txn.delete(
              'questions',
              where: "id = ? AND source IN ('seed', 'server')",
              whereArgs: [id],
            ) >
            0;
      }
      if (full) {
        changed |= await txn.delete('questions', where: "source = 'stale'") > 0;
        // Curated topics and units the server no longer has.
        for (final row in await txn.query('topics', where: 'is_custom = 0')) {
          if (liveTopics.contains(row['id'])) continue;
          changed |= await _retireTopic(txn, row['id'] as String);
        }
        for (final row in await txn.query('units')) {
          final id = row['id'] as String;
          if (liveUnits.contains(id) || id == QuestionRepository.customUnitId) {
            continue;
          }
          changed |= await _retireUnit(txn, id);
        }
        await _setMeta(txn, _bankFullKey, startedAt.toIso8601String());
      }
      await _setMeta(txn, _bankLevelKey, level);
      await _setMeta(
        txn,
        QuestionRepository.bankSyncedKey,
        // A minute of overlap, so nothing saved in the same moment is lost.
        (newest?.subtract(const Duration(minutes: 1)) ??
                DateTime.tryParse(since ?? '') ??
                startedAt.subtract(const Duration(days: 1)))
            .toUtc()
            .toIso8601String(),
      );
    });

    if (needFull && !full) return await _syncBank(full: true) || changed;

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

  /// Removes a curated topic the server no longer offers. Questions the
  /// user owns (written by the AI for them, or their own) are not thrown
  /// away with it: the topic then stays as one of the user's own topics,
  /// holding just those. Returns true if anything changed.
  static Future<bool> _retireTopic(Transaction txn, String id) async {
    final mine = Sqflite.firstIntValue(
      await txn.rawQuery(
        'SELECT COUNT(*) FROM questions q JOIN topics t ON t.id = q.topic_id '
        "WHERE t.id = ? AND t.is_custom = 0 AND q.source IN ('ai', 'user')",
        [id],
      ),
    );
    if ((mine ?? 0) == 0) {
      return await txn.delete(
            'topics',
            where: 'id = ? AND is_custom = 0',
            whereArgs: [id],
          ) >
          0;
    }
    await txn.delete(
      'questions',
      where: "topic_id = ? AND source NOT IN ('ai', 'user')",
      whereArgs: [id],
    );
    await txn.rawInsert(
      'INSERT OR IGNORE INTO units(id, name, description, sort_order) '
      "VALUES(?, 'My topics', 'Topics you added yourself', 1000)",
      [QuestionRepository.customUnitId],
    );
    await txn.update(
      'topics',
      // "My topics" has no sections.
      {
        'unit_id': QuestionRepository.customUnitId,
        'is_custom': 1,
        'section_id': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return true;
  }

  static Future<bool> _retireUnit(Transaction txn, String id) async {
    var changed = false;
    for (final row in await txn.query(
      'topics',
      columns: ['id'],
      where: 'unit_id = ?',
      whereArgs: [id],
    )) {
      changed |= await _retireTopic(txn, row['id'] as String);
    }
    // Topics the user made inside this unit move to "My topics" as well.
    final moved = await txn.update(
      'topics',
      {'unit_id': QuestionRepository.customUnitId},
      where: 'unit_id = ?',
      whereArgs: [id],
    );
    if (moved > 0) {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO units(id, name, description, sort_order) '
        "VALUES(?, 'My topics', 'Topics you added yourself', 1000)",
        [QuestionRepository.customUnitId],
      );
    }
    return await txn.delete('units', where: 'id = ?', whereArgs: [id]) > 0 ||
        changed;
  }

  /// Whose data this phone holds. The first account to sign in takes over
  /// whatever was recorded before. If a DIFFERENT account signs in later,
  /// the previous person's history is cleared from the phone (it stays
  /// safe on the server under their account) and the new account's own
  /// history is fetched. Alarms stay: they belong to the phone.
  /// Returns true if history was cleared.
  static Future<bool> _adoptOwner() async {
    final uid = Account.instance.userId;
    if (uid == null) return false;
    final db = await AppDatabase.instance;
    final owner = await _meta(db, _ownerKey);
    if (owner == uid) return false;
    if (owner == null) {
      await _setMeta(db, _ownerKey, uid);
      return false;
    }
    await db.transaction((txn) async {
      await _wipeHistory(txn, uid);
      await _setMeta(txn, _ownerKey, uid);
    });
    (await SharedPreferences.getInstance()).remove(_backupPref);
    return true;
  }

  /// Removes one person's history from the phone: answers, sessions, the
  /// alarm diary, their own questions and the topics left empty by that.
  /// Also forgets that [uid]'s history was ever fetched, so it would be
  /// fetched again. The question bank and the alarms stay.
  static Future<void> _wipeHistory(Transaction txn, String? uid) async {
    await txn.delete('attempts');
    await txn.delete('sessions');
    await txn.delete('alarm_events');
    await txn.delete('question_flags');
    await txn.delete('questions', where: "source IN ('ai', 'user')");
    await txn.rawDelete(
      'DELETE FROM topics WHERE is_custom = 1 AND id NOT IN '
      '(SELECT DISTINCT topic_id FROM questions)',
    );
    if (uid != null) {
      await txn.delete('meta', where: 'key = ?', whereArgs: ['restored:$uid']);
    }
    await txn.delete('meta', where: 'key = ?', whereArgs: [_deletedKey]);
  }

  /// Clears the signed-in person's history from this phone and forgets
  /// whose data the phone held, so the next account starts clean. Used
  /// when an account is deleted. Call it while still signed in.
  static Future<void> forgetLocalHistory() async {
    final uid = Account.instance.userId;
    final db = await AppDatabase.instance;
    await db.transaction((txn) async {
      await _wipeHistory(txn, uid);
      await txn.delete('meta', where: 'key = ?', whereArgs: [_ownerKey]);
    });
    (await SharedPreferences.getInstance()).remove(_backupPref);
    QuestionService.changes.value++;
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

  /// Marks a row the server refuses to take, so it is not sent again and
  /// again (2 = set aside).
  static Future<void> _setAside(Database db, String table, Object? id) async {
    debugPrint('Sync: the server refused a row of $table (id $id)');
    await db.update(table, {'synced': 2}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> _upload() async {
    final token = await Account.instance.accessToken();
    final uid = Account.instance.userId;
    if (token == null || uid == null) throw const _SyncError('no connection');
    final db = await AppDatabase.instance;

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
      rejected: (i) => _setAside(db, 'questions', ownQuestions[i]['id']),
      onConflict: 'user_id,id',
      token: token,
    );
    for (final q in ownQuestions) {
      await db.update(
        'questions',
        {'synced': 1},
        where: 'id = ? AND synced = 0',
        whereArgs: [q['id']],
      );
    }

    // Questions of their own that the user deleted on this phone.
    final gone = (jsonDecode(await _meta(db, _deletedKey) ?? '[]') as List)
        .map((e) => '$e')
        .where((id) => RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(id))
        .toList();
    for (var i = 0; i < gone.length; i += 50) {
      await _send(
        'DELETE',
        '/user_questions',
        query: {
          'user_id': 'eq.$uid',
          'id': 'in.(${gone.sublist(i, min(i + 50, gone.length)).join(',')})',
        },
        prefer: 'return=minimal',
        token: token,
      );
    }
    if (gone.isNotEmpty) {
      await db.delete('meta', where: 'key = ?', whereArgs: [_deletedKey]);
    }

    // 2. Sessions. One still in progress is sent again when it ends
    // (ending it marks it as changed).
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
                  'timed_out',
                }.contains(s['outcome'])
                ? s['outcome']
                : null,
          },
      ],
      rejected: (i) => _setAside(db, 'sessions', sessions[i]['id']),
      onConflict: 'id',
      token: token,
    );
    for (final s in sessions) {
      await db.update(
        'sessions',
        {'synced': 1},
        where: 'id = ? AND synced = 0',
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
      rejected: (i) => _setAside(db, 'attempts', attempts[i]['id']),
      token: token,
    );
    for (final a in attempts) {
      await db.update(
        'attempts',
        {'synced': 1},
        where: 'id = ? AND synced = 0',
        whereArgs: [a['id']],
      );
    }

    // 4. The alarm diary and problem reports.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(shareDiagnosticsPref) == false) {
      // Diagnostics are switched off: the diary stays on the phone. What
      // was written meanwhile is set aside for good, so switching the
      // setting back on does not send it after all. A problem report is
      // different: the user chose to send that one.
      await db.update('alarm_events', {
        'synced': 2,
      }, where: "synced = 0 AND type != 'report'");
    }
    final events = await db.query(
      'alarm_events',
      where: 'synced = 0',
      limit: 1000,
    );
    if (events.isNotEmpty) {
      final info = await SystemBridge.deviceInfo();
      final device = info['model'] == null
          ? '${info['platform'] ?? ''}'
          : '${info['manufacturer']} ${info['model']} (Android ${info['android']})';
      await _upsert(
        'alarm_events',
        [
          for (final e in events)
            {
              'user_id': uid,
              'client_id': e['uuid'],
              'at': _iso(e['at']),
              'alarm_id': e['alarm_id'],
              'type': e['type'],
              'detail': jsonDecode(e['detail'] as String),
              'device': device,
              'app_version': ServerConfig.appVersion,
            },
        ],
        onConflict: 'user_id,client_id',
        keepExisting: true,
        rejected: (i) => _setAside(db, 'alarm_events', events[i]['id']),
        token: token,
      );
      for (final e in events) {
        await db.update(
          'alarm_events',
          {'synced': 1},
          where: 'id = ? AND synced = 0',
          whereArgs: [e['id']],
        );
      }
    }

    // 5. Alarms and settings, when they changed.
    final saved = <String, Object>{};
    for (final key in const [
      'isDarkTheme',
      'use24Hour',
      'analogClock',
      'headsUp',
      'themeMode',
    ]) {
      // Only yes/no and text settings; anything else under these names
      // would be a mistake and is left out.
      final value = prefs.get(key);
      if (value is bool || value is String) saved[key] = value!;
    }
    final backup = {
      'user_id': uid,
      'alarms': jsonDecode(prefs.getString('saved_alarms') ?? '[]'),
      'settings': saved,
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
  final int? status;
  const _SyncError(this.message, {this.status});
  @override
  String toString() => message;
}
