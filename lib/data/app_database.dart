/// Opens the app's SQLite database and owns its schema.
///
/// Tables:
/// - `units`      course units (Pharmacology, ...)
/// - `sections`   the subunits and sections of a unit: a unit holds
///                sections directly, or subunits that hold sections
/// - `topics`     topics of a unit, each filed under a section (or not)
/// - `questions`  questions with their answer AND explanation, so the
///                bank works fully offline
/// - `attempts`   every answer the user gave, with what they answered and
///                how long it took (drives "not asked yet", progress,
///                weak-question selection and the reports)
/// - `sessions`   one row per alarm ring or practice session, so the
///                reports can show history and time-to-wake
/// - `alarm_events` the alarm diary: what happened to each alarm and when
/// - `question_flags` questions the user reported as wrong or unclear
/// - `meta`       small key/value store (seed versions)
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static const int schemaVersion = 9;
  static const String fileName = 'brainwake.db';

  /// Meta key: when the whole bank was last compared with the server
  /// (see lib/services/sync_service.dart).
  static const String bankFullKey = 'bank_full_at';

  static Database? _db;
  static Future<Database>? _opening;

  /// Replaces the phone's SQLite. Tests set it to an in-memory database;
  /// the browser emulator (tool/emulator/main.dart) sets it to SQLite
  /// compiled for the web.
  static DatabaseFactory? factoryOverride;
  static String? pathOverride;

  static Future<Database> get instance {
    final db = _db;
    if (db != null) return Future.value(db);
    return _opening ??= _open();
  }

  static Future<Database> _open() async {
    final factory = factoryOverride ?? databaseFactory;
    final path =
        pathOverride ??
        (kIsWeb
            ? fileName
            : p.join(await factory.getDatabasesPath(), fileName));
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => _create(db),
        onUpgrade: _upgrade,
      ),
    );
    _db = db;
    return db;
  }

  static Future<void> _create(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE units(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0
      )''');
    batch.execute('''
      CREATE TABLE topics(
        id TEXT PRIMARY KEY,
        unit_id TEXT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_custom INTEGER NOT NULL DEFAULT 0,
        description TEXT NOT NULL DEFAULT '',
        access TEXT NOT NULL DEFAULT 'paid',
        section_id TEXT,
        server_questions INTEGER
      )''');
    batch.execute(_createSections);
    batch.execute('''
      CREATE TABLE questions(
        id TEXT PRIMARY KEY,
        topic_id TEXT NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        text TEXT NOT NULL,
        text_key TEXT NOT NULL,
        options TEXT NOT NULL DEFAULT '[]',
        answer TEXT NOT NULL,
        alt_answers TEXT NOT NULL DEFAULT '[]',
        explanation TEXT NOT NULL DEFAULT '',
        image TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'seed',
        created_at INTEGER NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        marks INTEGER NOT NULL DEFAULT 1,
        long_answer INTEGER NOT NULL DEFAULT 0,
        key_points TEXT NOT NULL DEFAULT '[]'
      )''');
    batch.execute(
      'CREATE UNIQUE INDEX idx_questions_unique ON questions(topic_id, text_key)',
    );
    batch.execute('''
      CREATE TABLE attempts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
        mode TEXT NOT NULL,
        correct INTEGER NOT NULL,
        answered_at INTEGER NOT NULL,
        session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL,
        user_answer TEXT NOT NULL DEFAULT '',
        duration_ms INTEGER,
        uuid TEXT,
        synced INTEGER NOT NULL DEFAULT 0
      )''');
    batch.execute(_createSessions);
    batch.execute(
      'CREATE INDEX idx_attempts_question ON attempts(question_id)',
    );
    batch.execute(
      'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    for (final sql in _syncIndexes) {
      batch.execute(sql);
    }
    batch.execute(_createAlarmEvents);
    for (final sql in _createQuestionFlags) {
      batch.execute(sql);
    }
    await batch.commit(noResult: true);
  }

  /// Subunits (kind 'subunit', no parent) and sections (kind 'section',
  /// parent = a subunit of the same unit, or none: straight under the
  /// unit). A topic points at its section with `topics.section_id`.
  static const String _createSections = '''
    CREATE TABLE sections(
      id TEXT PRIMARY KEY,
      unit_id TEXT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
      parent_id TEXT,
      kind TEXT NOT NULL DEFAULT 'section',
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      sort_order INTEGER NOT NULL DEFAULT 0
    )''';

  static const String _createSessions = '''
    CREATE TABLE sessions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      alarm_id INTEGER,
      required_streak INTEGER,
      started_at INTEGER NOT NULL,
      ended_at INTEGER,
      outcome TEXT,
      uuid TEXT,
      synced INTEGER NOT NULL DEFAULT 0
    )''';

  // "uuid" is the row's name on the server, so uploading or restoring the
  // same row twice changes nothing. "synced" = already uploaded.
  static const List<String> _syncIndexes = [
    'CREATE UNIQUE INDEX idx_sessions_uuid ON sessions(uuid)',
    'CREATE UNIQUE INDEX idx_attempts_uuid ON attempts(uuid)',
  ];

  /// The alarm diary (see lib/data/alarm_log.dart).
  static const String _createAlarmEvents = '''
    CREATE TABLE alarm_events(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      at INTEGER NOT NULL,
      alarm_id INTEGER,
      type TEXT NOT NULL,
      detail TEXT NOT NULL DEFAULT '{}',
      synced INTEGER NOT NULL DEFAULT 0
    )''';

  /// Questions the user flagged (see lib/data/flag_store.dart). No link
  /// to the questions table on purpose: a flag must survive the question
  /// being replaced. One flag per question.
  static const List<String> _createQuestionFlags = [
    '''
    CREATE TABLE question_flags(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      question_id TEXT NOT NULL,
      question_text TEXT NOT NULL DEFAULT '',
      reason TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      synced INTEGER NOT NULL DEFAULT 0
    )''',
    'CREATE UNIQUE INDEX idx_question_flags_question '
        'ON question_flags(question_id)',
  ];

  /// Brings an older database up to date without losing anything.
  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute(_createSessions);
      await db.execute(
        'ALTER TABLE attempts ADD COLUMN session_id INTEGER '
        'REFERENCES sessions(id) ON DELETE SET NULL',
      );
      await db.execute(
        "ALTER TABLE attempts ADD COLUMN user_answer TEXT NOT NULL DEFAULT ''",
      );
      await db.execute('ALTER TABLE attempts ADD COLUMN duration_ms INTEGER');
    }
    if (from < 3) {
      // Picture for spotter questions (asset path or web address).
      await db.execute(
        "ALTER TABLE questions ADD COLUMN image TEXT NOT NULL DEFAULT ''",
      );
    }
    if (from < 4) {
      // Syncing with the server (see lib/services/sync_service.dart).
      // A version-2 database was created with the newer sessions table.
      final sessionColumns = await db.rawQuery('PRAGMA table_info(sessions)');
      if (!sessionColumns.any((c) => c['name'] == 'uuid')) {
        await db.execute('ALTER TABLE sessions ADD COLUMN uuid TEXT');
        await db.execute(
          'ALTER TABLE sessions ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.execute('ALTER TABLE attempts ADD COLUMN uuid TEXT');
      await db.execute(
        'ALTER TABLE attempts ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE questions ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      for (final sql in _syncIndexes) {
        await db.execute(sql);
      }
    }
    if (from < 5) {
      await db.execute(_createAlarmEvents);
      // What a topic the user made should cover (given to the AI).
      await db.execute(
        "ALTER TABLE topics ADD COLUMN description TEXT NOT NULL DEFAULT ''",
      );
    }
    if (from < 6) {
      // Who may open a topic: 'guest', 'free' or 'paid'
      // (see lib/services/entitlements.dart).
      await db.execute(
        "ALTER TABLE topics ADD COLUMN access TEXT NOT NULL DEFAULT 'paid'",
      );
      for (final sql in _createQuestionFlags) {
        await db.execute(sql);
      }
    }
    if (from < 7) {
      // Unit -> (subunit) -> section -> topic. Topics not filed under a
      // section yet keep section_id NULL.
      await db.execute(_createSections);
      await db.execute('ALTER TABLE topics ADD COLUMN section_id TEXT');
    }
    if (from < 8) {
      // How many published questions the server has for the topic (NULL =
      // not known). A topic with none is still being written: it is hidden.
      await db.execute(
        'ALTER TABLE topics ADD COLUMN server_questions INTEGER',
      );
    }
    if (from < 9) {
      // Marks, and "long answer" questions with the points that earn them
      // (asked in practice only, never while an alarm rings).
      await db.execute(
        'ALTER TABLE questions ADD COLUMN marks INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'ALTER TABLE questions ADD COLUMN long_answer INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE questions ADD COLUMN key_points TEXT NOT NULL DEFAULT '[]'",
      );
      // Long answer questions already on the server did not change, so
      // only a whole comparison brings them: make the next sync one.
      await db.delete('meta', where: 'key = ?', whereArgs: [bankFullKey]);
    }
  }

  /// Closes the database (tests use this between cases).
  @visibleForTesting
  static Future<void> close() async {
    final db = _db ?? await _opening;
    _db = null;
    _opening = null;
    await db?.close();
  }
}
