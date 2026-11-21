/// A diary of what happened to each alarm on this phone: scheduled, rang,
/// snoozed, dismissed, edited, missed... It is what makes "my alarm did
/// not ring" something that can be investigated: the entries are sent to
/// the server with the next sync, and a problem report points at them.
///
/// Writing an entry must never get in the way of an alarm, so nothing
/// here throws.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'app_database.dart';

/// One entry of the diary.
class AlarmEvent {
  final DateTime at;
  final int? alarmId;
  final String type;
  final Map<String, dynamic> detail;
  const AlarmEvent({
    required this.at,
    required this.type,
    this.alarmId,
    this.detail = const {},
  });
}

class AlarmLog {
  /// Entries kept on the phone once they have been uploaded.
  static const int _keep = 400;

  /// Called after an entry that should reach the server soon (a missed
  /// alarm, a problem report).
  static void Function()? onUrgent;

  /// A random id in the standard 8-4-4-4-12 form.
  static String newUuid([Random? random]) {
    final rng = random ?? Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  static Future<void> add(
    String type, {
    int? alarmId,
    Map<String, Object?> detail = const {},
    bool urgent = false,
  }) async {
    try {
      final db = await AppDatabase.instance;
      await db.insert('alarm_events', {
        'uuid': newUuid(),
        'at': DateTime.now().millisecondsSinceEpoch,
        'alarm_id': alarmId,
        'type': type,
        'detail': jsonEncode(detail),
      });
      await db.rawDelete(
        // Uploaded entries, and ones set aside because diagnostics are
        // switched off. Entries still waiting to go up are never trimmed.
        'DELETE FROM alarm_events WHERE synced != 0 AND id NOT IN '
        '(SELECT id FROM alarm_events ORDER BY id DESC LIMIT ?)',
        [_keep],
      );
      if (urgent) onUrgent?.call();
    } catch (e) {
      debugPrint('Could not write the alarm diary: $e');
    }
  }

  /// The latest entries, newest first, optionally for one alarm.
  static Future<List<AlarmEvent>> recent({int? alarmId, int limit = 30}) async {
    try {
      final db = await AppDatabase.instance;
      final rows = await db.query(
        'alarm_events',
        where: alarmId == null ? null : 'alarm_id = ?',
        whereArgs: alarmId == null ? null : [alarmId],
        orderBy: 'id DESC',
        limit: limit,
      );
      return [
        for (final r in rows)
          AlarmEvent(
            at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
            alarmId: r['alarm_id'] as int?,
            type: r['type'] as String,
            detail: (jsonDecode(r['detail'] as String) as Map)
                .cast<String, dynamic>(),
          ),
      ];
    } catch (e) {
      debugPrint('Could not read the alarm diary: $e');
      return const [];
    }
  }
}
