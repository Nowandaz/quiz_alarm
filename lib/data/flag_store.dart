/// Questions the user flagged for review ("the answer is wrong", "the
/// question is unclear"...). A flag is saved on the phone first (table
/// `question_flags`, one per question) and sent to the reviewers when the
/// user is signed in and online. Guests' flags stay on the phone until
/// they sign in.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../services/account.dart';
import '../services/server_config.dart';
import 'alarm_log.dart';
import 'app_database.dart';

/// One flag as stored.
class QuestionFlag {
  final String uuid;
  final String questionId;
  final String questionText;

  /// One of the codes in [FlagStore.reasons].
  final String reason;
  final String note;
  final DateTime createdAt;

  /// 0 = waiting to be sent, 1 = sent, 2 = the server refused it (it is
  /// not tried again).
  final int synced;

  const QuestionFlag({
    required this.uuid,
    required this.questionId,
    required this.questionText,
    required this.reason,
    required this.note,
    required this.createdAt,
    this.synced = 0,
  });

  /// False once it has left the phone: it can no longer be taken back.
  bool get canRemove => synced == 0;

  static QuestionFlag fromRow(Map<String, Object?> r) => QuestionFlag(
    uuid: r['uuid'] as String,
    questionId: r['question_id'] as String,
    questionText: (r['question_text'] ?? '') as String,
    reason: (r['reason'] ?? '') as String,
    note: (r['note'] ?? '') as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    synced: (r['synced'] ?? 0) as int,
  );
}

class FlagStore {
  /// The reasons offered, as (code stored and sent, text shown).
  static const List<(String, String)> reasons = [
    ('wrong_answer', 'The answer is wrong'),
    ('unclear', 'The question is unclear'),
    ('typo', 'Spelling or typo'),
    ('picture', 'Picture is wrong or missing'),
    ('other', 'Something else'),
  ];

  /// The longest note that is kept.
  static const int maxNote = 300;

  static const String _table = 'question_flags';

  /// Tests replace this with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// Bumped whenever a flag is saved, removed or sent, so open screens
  /// can redraw their flag icons.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// The flag on one question, or null.
  static Future<QuestionFlag?> get(String questionId) async {
    final rows = await (await AppDatabase.instance).query(
      _table,
      where: 'question_id = ?',
      whereArgs: [questionId],
      limit: 1,
    );
    return rows.isEmpty ? null : QuestionFlag.fromRow(rows.first);
  }

  /// Every flag, newest first.
  static Future<List<QuestionFlag>> all() async {
    final rows = await (await AppDatabase.instance).query(
      _table,
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(QuestionFlag.fromRow).toList();
  }

  /// Flags a question (or changes a flag that has not been sent yet) and
  /// starts sending it. A flag that was already sent is left as it is.
  static Future<QuestionFlag> save({
    required String questionId,
    required String questionText,
    required String reason,
    String note = '',
    DateTime? now,
    bool send = true,
  }) async {
    final db = await AppDatabase.instance;
    final old = await get(questionId);
    if (old != null && !old.canRemove) return old;
    var cut = note.trim();
    if (cut.length > maxNote) cut = cut.substring(0, maxNote);
    final values = {
      'uuid': old?.uuid ?? AlarmLog.newUuid(),
      'question_id': questionId,
      'question_text': questionText,
      'reason': reason,
      'note': cut,
      'created_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'synced': 0,
    };
    if (old == null) {
      await db.insert(
        _table,
        values,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await db.update(
        _table,
        values,
        where: 'question_id = ?',
        whereArgs: [questionId],
      );
    }
    changes.value++;
    if (send) unawaited(upload());
    return (await get(questionId))!;
  }

  /// Takes a flag back. Only possible while it has not been sent; false
  /// when it had already gone (or there was none).
  static Future<bool> remove(String questionId) async {
    final n = await (await AppDatabase.instance).delete(
      _table,
      where: 'question_id = ? AND synced = 0',
      whereArgs: [questionId],
    );
    if (n > 0) changes.value++;
    return n > 0;
  }

  static Future<int>? _uploading;

  /// Sends the flags that are waiting. Returns how many were sent. Does
  /// nothing when signed out or offline (they wait for the next call).
  /// Never throws.
  static Future<int> upload() =>
      _uploading ??= _upload().whenComplete(() => _uploading = null);

  static Future<int> _upload() async {
    try {
      if (!Account.instance.isSignedIn) return 0;
      final db = await AppDatabase.instance;
      final rows = await db.query(_table, where: 'synced = 0', orderBy: 'id');
      if (rows.isEmpty) return 0;
      final token = await Account.instance.accessToken();
      if (token == null) return 0;

      var sent = 0;
      Future<void> mark(Iterable<Map<String, Object?>> done, int state) async {
        for (final r in done) {
          await db.update(
            _table,
            {'synced': state},
            where: 'id = ?',
            whereArgs: [r['id']],
          );
        }
      }

      final status = await _post(rows, token);
      if (_ok(status)) {
        await mark(rows, 1);
        sent = rows.length;
      } else if (_refused(status)) {
        // One bad row must not hold the others back: send them singly.
        for (final row in rows) {
          final one = rows.length == 1 ? status : await _post([row], token);
          if (_ok(one)) {
            await mark([row], 1);
            sent++;
          } else if (_refused(one)) {
            await mark([row], 2);
          }
        }
      }
      changes.value++;
      return sent;
    } catch (e) {
      debugPrint('Sending flags failed (will try again): $e');
      return 0;
    }
  }

  static bool _ok(int status) => status >= 200 && status < 300;

  /// A "no" that trying again will not change. Being signed out (401),
  /// too many requests (429) and a slow server (408) are worth another
  /// try later.
  static bool _refused(int status) =>
      status >= 400 && status < 500 && !const {401, 408, 429}.contains(status);

  static Future<int> _post(
    List<Map<String, Object?>> rows,
    String token,
  ) async {
    final res = await httpClient
        .post(
          Uri.parse('${ServerConfig.supabaseUrl}/rest/v1/$_table'),
          headers: {
            'apikey': ServerConfig.supabaseKey,
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Prefer': 'resolution=ignore-duplicates',
          },
          body: jsonEncode([
            for (final r in rows)
              {
                'id': r['uuid'],
                'question_id': r['question_id'],
                'question_text': r['question_text'],
                'reason': r['reason'],
                'note': r['note'],
                'created_at': DateTime.fromMillisecondsSinceEpoch(
                  r['created_at'] as int,
                ).toUtc().toIso8601String(),
              },
          ]),
        )
        .timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) {
      debugPrint('Flags: the server answered ${res.statusCode} ${res.body}');
    }
    return res.statusCode;
  }
}
