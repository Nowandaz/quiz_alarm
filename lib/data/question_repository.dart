/// All reads and writes of units, topics, questions and attempts.
///
/// Question banks ship as JSON files in `assets/question_banks/`. Each file
/// is one unit with its topics and questions; it is copied into the database
/// the first time the app runs and again whenever its `version` goes up.
/// A topic in a file may name the section it belongs to (`"section"`) and
/// the subunit that section is in (`"subunit"`).
/// Questions keep their ids across re-imports, so progress is never lost.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../services/entitlements.dart';
import 'app_database.dart';

class QuestionRepository {
  static const String seedFolder = 'assets/question_banks/';
  static const String customUnitId = 'custom';
  static const String _legacyBankPref = 'offline_question_bank';

  static Future<void>? _ready;

  /// Opens the database and imports bundled / legacy data once.
  static Future<void> ensureReady() => _ready ??= _init().then((_) async {
    try {
      await revealBaseline();
    } catch (e) {
      debugPrint('Could not set the topics out: $e');
    }
  });

  @visibleForTesting
  static void resetForTest() => _ready = null;

  static Future<Database> get _db => AppDatabase.instance;

  /// Called when the user's own data changed (an answer, a finished
  /// session, a new question of theirs), so it can be sent to the server.
  static void Function()? onLocalChange;

  /// Set (in the meta table) once the bank was downloaded from the
  /// server. From then on the server is the source and the files bundled
  /// with the app are no longer imported.
  static const String bankSyncedKey = 'bank_synced_at';

  static Future<void> _init() async {
    final db = await _db;
    final synced = await db.query(
      'meta',
      where: 'key = ?',
      whereArgs: [bankSyncedKey],
    );
    if (synced.isNotEmpty) return;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final files =
          manifest
              .listAssets()
              .where((a) => a.startsWith(seedFolder) && a.endsWith('.json'))
              .toList()
            ..sort();
      for (var i = 0; i < files.length; i++) {
        try {
          final data = jsonDecode(await rootBundle.loadString(files[i]));
          await importUnit(data as Map<String, dynamic>, sortOrder: i);
        } catch (e) {
          debugPrint('Could not import ${files[i]}: $e');
        }
      }
    } catch (e) {
      debugPrint('No bundled question banks found: $e');
    }
    await _importLegacyBank();
  }

  // ------------------------------------------------------------- importing

  static String textKey(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String slug(String text) {
    final s = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'topic' : s;
  }

  /// Copies one unit file into the database. Does nothing when this
  /// version of the file was already imported (unless [force]).
  static Future<void> importUnit(
    Map<String, dynamic> data, {
    int sortOrder = 0,
    bool force = false,
  }) async {
    final db = await _db;
    final unit = data['unit'] as Map<String, dynamic>;
    final unitId = unit['id'] as String;
    final version = '${data['version'] ?? 1}';
    final metaKey = 'seed:$unitId';

    final seen = await db.query('meta', where: 'key = ?', whereArgs: [metaKey]);
    if (!force && seen.isNotEmpty && seen.first['value'] == version) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT INTO units(id, name, description, sort_order) VALUES(?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
        'description = excluded.description, sort_order = excluded.sort_order',
        // "order" in the file wins over the file's position.
        [
          unitId,
          unit['name'],
          unit['description'] ?? '',
          (unit['order'] as int?) ?? sortOrder,
        ],
      );

      // Subunits and sections named by the topics, in file order:
      // id -> the id of its subunit (null when it has none).
      final placed = <String, String?>{};
      Future<String> place(String kind, String name, {String? parentId}) async {
        final prefix = kind == Section.subunitKind ? 'sub' : 'sec';
        var id = '$unitId-$prefix-${slug(name)}';
        // The same section name under two subunits is two sections.
        if (placed.containsKey(id) && placed[id] != parentId) {
          id = '$parentId-$prefix-${slug(name)}';
        }
        if (placed.containsKey(id)) return id;
        await txn.rawInsert(
          'INSERT INTO sections(id, unit_id, parent_id, kind, name, sort_order) '
          'VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
          'unit_id = excluded.unit_id, parent_id = excluded.parent_id, '
          'kind = excluded.kind, name = excluded.name, '
          'sort_order = excluded.sort_order',
          [id, unitId, parentId, kind, name, placed.length],
        );
        placed[id] = parentId;
        return id;
      }

      final keepTopics = <String>[];
      final keepQuestions = <String>[];
      final topics = (data['topics'] as List).cast<Map<String, dynamic>>();
      for (var t = 0; t < topics.length; t++) {
        final topicId = topics[t]['id'] as String;
        keepTopics.add(topicId);
        final sectionName = '${topics[t]['section'] ?? ''}'.trim();
        final subunitName = '${topics[t]['subunit'] ?? ''}'.trim();
        String? sectionId;
        if (sectionName.isNotEmpty) {
          final subunitId = subunitName.isEmpty
              ? null
              : await place(Section.subunitKind, subunitName);
          sectionId = await place(
            Section.sectionKind,
            sectionName,
            parentId: subunitId,
          );
        }
        await txn.rawInsert(
          'INSERT INTO topics(id, unit_id, name, sort_order, is_custom, access, '
          'section_id) VALUES(?,?,?,?,0,?,?) ON CONFLICT(id) DO UPDATE SET '
          'unit_id = excluded.unit_id, name = excluded.name, '
          'sort_order = excluded.sort_order, access = excluded.access, '
          'section_id = excluded.section_id',
          [
            topicId,
            unitId,
            topics[t]['name'],
            t,
            cleanAccess(topics[t]['access']),
            sectionId,
          ],
        );

        final questions = ((topics[t]['questions'] ?? const []) as List)
            .cast<Map<String, dynamic>>();
        for (final q in questions) {
          final id = q['id'] as String;
          final text = (q['text'] as String).trim();
          final key = textKey(text);
          keepQuestions.add(id);
          // A generated copy of the same question gives way to the curated one.
          await txn.delete(
            'questions',
            where: 'topic_id = ? AND text_key = ? AND id != ?',
            whereArgs: [topicId, key, id],
          );
          await txn.rawInsert(
            'INSERT INTO questions(id, topic_id, type, text, text_key, options, '
            'answer, alt_answers, explanation, image, source, created_at) '
            "VALUES(?,?,?,?,?,?,?,?,?,?,'seed',?) ON CONFLICT(id) DO UPDATE SET "
            'topic_id = excluded.topic_id, type = excluded.type, '
            'text = excluded.text, text_key = excluded.text_key, '
            'options = excluded.options, answer = excluded.answer, '
            'alt_answers = excluded.alt_answers, image = excluded.image, explanation = excluded.explanation',
            [
              id,
              topicId,
              q['type'] == 'mcq' ? 'mcq' : 'saq',
              text,
              key,
              jsonEncode(q['options'] ?? const []),
              (q['answer'] as String).trim(),
              jsonEncode(q['alt_answers'] ?? const []),
              (q['explanation'] ?? '') as String,
              (q['image'] ?? '') as String,
              now,
            ],
          );
        }
      }

      // Drop curated questions/topics that were removed from the file.
      // Generated questions and topics that still hold some are kept.
      final qMarks = List.filled(keepQuestions.length, '?').join(',');
      await txn.rawDelete(
        "DELETE FROM questions WHERE source = 'seed' "
        'AND topic_id IN (SELECT id FROM topics WHERE unit_id = ?) '
        '${keepQuestions.isEmpty ? '' : 'AND id NOT IN ($qMarks)'}',
        [unitId, ...keepQuestions],
      );
      final tMarks = List.filled(keepTopics.length, '?').join(',');
      await txn.rawDelete(
        'DELETE FROM topics WHERE unit_id = ? AND is_custom = 0 '
        '${keepTopics.isEmpty ? '' : 'AND id NOT IN ($tMarks) '}'
        'AND id NOT IN (SELECT DISTINCT topic_id FROM questions)',
        [unitId, ...keepTopics],
      );
      // Sections the file no longer names.
      final sMarks = List.filled(placed.length, '?').join(',');
      await txn.rawDelete(
        'DELETE FROM sections WHERE unit_id = ? '
        '${placed.isEmpty ? '' : 'AND id NOT IN ($sMarks)'}',
        [unitId, ...placed.keys],
      );

      await txn.insert('meta', {
        'key': metaKey,
        'value': version,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Moves AI questions saved by app versions that kept the bank in
  /// SharedPreferences into the database, then removes the old copy.
  static Future<void> _importLegacyBank() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_legacyBankPref);
      if (raw == null) return;
      for (final e in jsonDecode(raw) as List) {
        try {
          final m = e as Map<String, dynamic>;
          final id = '${m['id'] ?? ''}';
          if (!id.startsWith('ai_')) continue; // old built-in demo questions
          final topicName = '${m['topic'] ?? 'General'}';
          final topic =
              await findTopicByName(topicName) ??
              await addCustomTopic(topicName);
          await addQuestion(
            Question(
              id: id,
              topicId: topic.id,
              topic: topic.name,
              type: m['type'] == 'mcq' ? QuestionType.mcq : QuestionType.saq,
              questionText: '${m['questionText']}',
              options: List<String>.from(m['options'] ?? const []),
              correctAnswer: '${m['correctAnswer']}',
              source: 'ai',
            ),
          );
        } catch (err) {
          debugPrint('Skipping unreadable saved question: $err');
        }
      }
      await prefs.remove(_legacyBankPref);
      await prefs.remove('asked_question_ids');
    } catch (e) {
      debugPrint('Old question bank could not be imported: $e');
    }
  }

  // ---------------------------------------------------------------- topics

  static Future<List<StudyUnit>> getUnits() async {
    await ensureReady();
    final rows = await (await _db).query('units', orderBy: 'sort_order, name');
    return rows
        .map(
          (r) => StudyUnit(
            id: r['id'] as String,
            name: r['name'] as String,
            description: (r['description'] ?? '') as String,
          ),
        )
        .toList();
  }

  static Topic _topicFromRow(Map<String, Object?> r) => Topic(
    id: r['id'] as String,
    unitId: r['unit_id'] as String,
    name: r['name'] as String,
    isCustom: r['is_custom'] == 1,
    description: (r['description'] ?? '') as String,
    access: cleanAccess(r['access']),
    sectionId: r['section_id'] as String?,
  );

  /// Every subunit and section, in the order they are shown.
  static Future<List<Section>> getSections() async {
    await ensureReady();
    final rows = await (await _db).query(
      'sections',
      orderBy: 'sort_order, name',
    );
    return [
      for (final r in rows)
        Section(
          id: r['id'] as String,
          unitId: r['unit_id'] as String,
          parentId: r['parent_id'] as String?,
          kind: r['kind'] == Section.subunitKind
              ? Section.subunitKind
              : Section.sectionKind,
          name: r['name'] as String,
          description: (r['description'] ?? '') as String,
          sortOrder: (r['sort_order'] as int?) ?? 0,
        ),
    ];
  }

  static Future<List<Topic>> getTopics() async {
    await ensureReady();
    final rows = await (await _db).rawQuery(
      // A bank topic the server says has no published question yet is
      // part of the outline still being written: it is not shown (it
      // would otherwise look like a locked topic with nothing behind it).
      'SELECT t.* FROM topics t JOIN units u ON u.id = t.unit_id '
      'WHERE t.is_custom = 1 OR t.server_questions IS NULL '
      'OR t.server_questions > 0 '
      'OR EXISTS (SELECT 1 FROM questions q WHERE q.topic_id = t.id) '
      'ORDER BY u.sort_order, u.name, t.sort_order, t.name',
    );
    return rows.map(_topicFromRow).toList();
  }

  static Future<Topic?> findTopicByName(String name) async {
    final rows = await (await _db).query(
      'topics',
      where: 'LOWER(name) = ?',
      whereArgs: [name.trim().toLowerCase()],
      limit: 1,
    );
    return rows.isEmpty ? null : _topicFromRow(rows.first);
  }

  /// Creates a topic of the user's own (under [unitId], or under
  /// "My topics"). Returns the existing topic if the name is already used.
  static Future<Topic> addCustomTopic(
    String name, {
    String? unitId,
    String description = '',
  }) async {
    final db = await _db;
    final clean = name.trim();
    final unit = unitId ?? customUnitId;
    final existing = await db.query(
      'topics',
      where: 'unit_id = ? AND LOWER(name) = ?',
      whereArgs: [unit, clean.toLowerCase()],
      limit: 1,
    );
    if (existing.isNotEmpty) return _topicFromRow(existing.first);

    if (unit == customUnitId) {
      await db.rawInsert(
        'INSERT OR IGNORE INTO units(id, name, description, sort_order) '
        "VALUES(?, 'My topics', 'Topics you added yourself', 1000)",
        [customUnitId],
      );
    }
    var id = '$unit-${slug(clean)}';
    var n = 2;
    while ((await db.query(
      'topics',
      where: 'id = ?',
      whereArgs: [id],
    )).isNotEmpty) {
      id = '$unit-${slug(clean)}-${n++}';
    }
    await db.insert('topics', {
      'id': id,
      'unit_id': unit,
      'name': clean,
      'sort_order': 1000,
      'is_custom': 1,
      'description': description.trim(),
      'access': TopicAccess.free,
    });
    return Topic(
      id: id,
      unitId: unit,
      name: clean,
      isCustom: true,
      description: description.trim(),
      access: TopicAccess.free,
    );
  }

  /// Deletes a user-made topic with its questions.
  /// Meta key: ids of the user's own questions deleted on this phone and
  /// not yet removed from the server (a JSON list).
  static const String deletedOwnQuestionsKey = 'deleted_own_questions';

  /// Remembers that questions of the user's own were deleted, so the copy
  /// kept on the server for their other phones goes too.
  static Future<void> _noteDeleted(Database db, Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final rows = await db.query(
      'meta',
      where: 'key = ?',
      whereArgs: [deletedOwnQuestionsKey],
    );
    final list = rows.isEmpty
        ? <dynamic>[]
        : jsonDecode(rows.first['value'] as String) as List;
    await db.insert('meta', {
      'key': deletedOwnQuestionsKey,
      'value': jsonEncode({...list, ...ids}.toList()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    onLocalChange?.call();
  }

  static Future<void> deleteCustomTopic(String topicId) async {
    final db = await _db;
    await _noteDeleted(db, [
      for (final r in await db.query(
        'questions',
        columns: ['id'],
        where:
            "topic_id = ? AND source IN ('ai', 'user') AND topic_id IN "
            '(SELECT id FROM topics WHERE is_custom = 1)',
        whereArgs: [topicId],
      ))
        r['id'] as String,
    ]);
    await db.delete(
      'topics',
      where: 'id = ? AND is_custom = 1',
      whereArgs: [topicId],
    );
  }

  // ------------------------------------------------- what the plan opens

  /// Questions of a bank topic that are open without a paid plan.
  static const int freeQuestionCap = 10;

  /// 'guest', 'free' or 'paid'. Anything else (also nothing) is 'paid'.
  static String cleanAccess(Object? raw) =>
      raw == TopicAccess.guest || raw == TopicAccess.free
      ? raw as String
      : TopicAccess.paid;

  /// Whether the person may open [topic] right now. A topic they made
  /// themselves needs an account and nothing more.
  static bool isOpen(Topic topic) => Entitlements.instance.canOpenTopic(
    topic.isCustom ? TopicAccess.free : topic.access,
  );

  /// How many of [topic]'s questions are open right now: none when the
  /// topic is locked, the first [freeQuestionCap] of a bank topic without
  /// a paid plan, otherwise all of them (null = no limit).
  static int? openLimit(Topic topic) => !isOpen(topic)
      ? 0
      : Entitlements.instance.isPaid || topic.isCustom
      ? null
      : freeQuestionCap;

  /// The one rule for "which questions are open right now", as an SQL
  /// condition on a question [q] and its topic [t]. It says the same as
  /// [isOpen] and [openLimit], and every read of questions for use goes
  /// through it. It works from what is on the phone, so it also holds
  /// offline and after a plan has run out.
  static String _openSql({String q = 'q', String t = 't'}) {
    final e = Entitlements.instance;
    // Only questions brought out of the bank so far (see [revealBaseline]).
    if (e.isPaid) return '$q.revealed = 1';
    final firstFew =
        '$q.id IN (SELECT o.id FROM questions o WHERE o.topic_id = $q.topic_id '
        'AND o.revealed = 1 '
        'ORDER BY o.created_at, o.id LIMIT $freeQuestionCap)';
    if (e.isGuest) {
      return "($t.is_custom = 0 AND $t.access = '${TopicAccess.guest}' "
          'AND $firstFew)';
    }
    return '($q.revealed = 1 AND ($t.is_custom = 1 OR ($t.access IN '
        "('${TopicAccess.guest}', '${TopicAccess.free}') AND $firstFew)))";
  }

  // ------------------------------------------- how much of the bank is out

  /// How many bank questions a topic starts with, and how many more come
  /// out each time more are asked for. The whole bank is on the phone
  /// (so this works offline); the rest of a topic waits until the user
  /// loads more, or an alarm on the topic is half way through what is out.
  static const int topicBatch = 20;

  static const String _bank = "source IN ('seed', 'server')";

  /// A topic on an alarm should have at least this many questions the
  /// alarm can ask that were never answered.
  static const int alarmReserve = 5;

  /// Per topic: how many open questions an alarm can ask (not long
  /// answers) have never been answered. Topics with none are not in the
  /// map.
  static Future<Map<String, int>> unseenForAlarms() async {
    await ensureReady();
    final rows = await (await _db).rawQuery(
      'SELECT q.topic_id AS topic_id, COUNT(*) AS n FROM questions q '
      'JOIN topics t ON t.id = q.topic_id '
      'WHERE ${_openSql()} AND q.long_answer = 0 AND NOT EXISTS '
      '(SELECT 1 FROM attempts a WHERE a.question_id = q.id) '
      'GROUP BY q.topic_id',
    );
    return {
      for (final r in rows) r['topic_id'] as String: (r['n'] as int?) ?? 0,
    };
  }

  /// Sets every topic out: questions already answered are out, and each
  /// topic has at least [topicBatch] bank questions out (or all it has).
  /// Called after the bank or the history changed. True if anything
  /// came out.
  static Future<bool> revealBaseline() async {
    final db = await _db;
    var changed =
        await db.rawUpdate(
          'UPDATE questions SET revealed = 1 WHERE revealed = 0 AND id IN '
          '(SELECT question_id FROM attempts WHERE question_id IS NOT NULL)',
        ) >
        0;
    final rows = await db.rawQuery(
      'SELECT topic_id, SUM(revealed) AS shown FROM questions '
      'WHERE $_bank GROUP BY topic_id '
      'HAVING SUM(revealed) < $topicBatch AND SUM(revealed) < COUNT(*)',
    );
    for (final r in rows) {
      final shown = (r['shown'] as int?) ?? 0;
      changed |=
          await revealMore(r['topic_id'] as String, topicBatch - shown) > 0;
    }
    return changed;
  }

  /// Brings up to [count] more bank questions of a topic out. Returns how
  /// many came out (0 when the topic has no more).
  static Future<int> revealMore(
    String topicId, [
    int count = topicBatch,
    bool ordinaryFirst = false,
  ]) async {
    if (count <= 0) return 0;
    return (await _db).rawUpdate(
      'UPDATE questions SET revealed = 1 WHERE id IN '
      '(SELECT id FROM questions WHERE topic_id = ? AND revealed = 0 '
      'AND $_bank ORDER BY ${ordinaryFirst ? 'long_answer, ' : ''}'
      'created_at, id LIMIT ?)',
      [topicId, count],
    );
  }

  /// How many bank questions of a topic have not come out yet.
  static Future<int> waitingCount(String topicId) async =>
      Sqflite.firstIntValue(
        await (await _db).rawQuery(
          'SELECT COUNT(*) FROM questions WHERE topic_id = ? AND revealed = 0 '
          'AND $_bank',
          [topicId],
        ),
      ) ??
      0;

  /// For the topics alarms ask about ([selectors], as on an alarm): a
  /// topic where at least half of the questions an alarm can ask have
  /// been answered gets [topicBatch] more from the bank, so alarms do not
  /// run out of new questions. Only on a paid plan (the others see a
  /// fixed first few). Returns how many questions came out.
  static Future<int> revealForAlarms(Iterable<String> selectors) async {
    if (!Entitlements.instance.isPaid) return 0;
    await ensureReady();
    final ids = await resolveTopicIds(selectors);
    if (ids.isEmpty) return 0;
    final db = await _db;
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT q.topic_id AS topic_id, '
      'SUM(CASE WHEN q.revealed = 1 AND q.long_answer = 0 THEN 1 ELSE 0 END) '
      'AS shown, '
      'SUM(CASE WHEN q.revealed = 1 AND q.long_answer = 0 AND EXISTS '
      '(SELECT 1 FROM attempts a WHERE a.question_id = q.id) THEN 1 ELSE 0 END) '
      'AS done, '
      'SUM(CASE WHEN q.revealed = 0 THEN 1 ELSE 0 END) AS waiting '
      'FROM questions q WHERE q.topic_id IN ($marks) GROUP BY q.topic_id',
      ids,
    );
    var out = 0;
    for (final r in rows) {
      final shown = (r['shown'] as int?) ?? 0;
      final done = (r['done'] as int?) ?? 0;
      if (((r['waiting'] as int?) ?? 0) == 0) continue;
      // Half way through, or nearly out of new ones (a topic whose first
      // questions are mostly long answers has few an alarm can ask).
      if (done * 2 < shown && shown - done >= alarmReserve) continue;
      // Ones an alarm can ask come out first.
      out += await revealMore(r['topic_id'] as String, topicBatch, true);
    }
    return out;
  }

  // -------------------------------------------------------- archived units

  /// Preference holding the ids of archived units. It lives outside the
  /// database because a bank sync rewrites the units table.
  static const String archivedUnitsPref = 'archived_units';

  /// Ids of the units the user archived. An archived unit is only hidden:
  /// its questions, answers and sessions all stay.
  static Future<Set<String>> getArchivedUnits() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(archivedUnitsPref) ?? const []).toSet();
  }

  /// Hides a unit ([archived] true) or brings it back. Nothing is deleted
  /// either way.
  static Future<void> setUnitArchived(String unitId, bool archived) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(archivedUnitsPref) ?? const []).toSet();
    if (!(archived ? ids.add(unitId) : ids.remove(unitId))) return;
    await prefs.setStringList(archivedUnitsPref, ids.toList()..sort());
  }

  /// Turns what an alarm or a session stores (topic ids, section or
  /// subunit ids, unit ids, or names from older versions) into topic ids.
  /// A section, subunit or unit stands for every topic inside it, so a
  /// topic added to it later is included. Empty or unknown input means
  /// every topic, leaving out the units in [archived]. A unit or topic
  /// that is named still counts when archived: an alarm set on it keeps
  /// working. If every unit is archived, "every topic" really is every
  /// topic, because an alarm must always have questions to ask.
  ///
  /// Topics the plan does not open ([isOpen]) are left out. A selection
  /// made only of locked topics falls back to every open topic, again so
  /// that an alarm always has something to ask.
  static List<String> resolveIn(
    Iterable<String> selectors,
    List<StudyUnit> units,
    List<Topic> topics, {
    List<Section> sections = const [],
    Set<String> archived = const {},
  }) {
    final ids = <String>{};
    for (final raw in selectors) {
      final s = raw.trim().toLowerCase();
      if (s.isEmpty) continue;
      final unitIds = units
          .where((u) => u.id.toLowerCase() == s || u.name.toLowerCase() == s)
          .map((u) => u.id)
          .toSet();
      // A section named by its id, or a subunit and the sections in it.
      final sectionIds = {
        for (final x in sections)
          if (x.id.toLowerCase() == s || x.parentId?.toLowerCase() == s) x.id,
      };
      for (final t in topics) {
        if (t.id.toLowerCase() == s ||
            t.name.toLowerCase() == s ||
            unitIds.contains(t.unitId) ||
            sectionIds.contains(t.sectionId)) {
          if (isOpen(t)) ids.add(t.id);
        }
      }
    }
    if (ids.isNotEmpty) return ids.toList();
    final open = topics.where(isOpen).toList();
    final active = [
      for (final t in open)
        if (!archived.contains(t.unitId)) t.id,
    ];
    return active.isEmpty ? open.map((t) => t.id).toList() : active;
  }

  static Future<List<String>> resolveTopicIds(
    Iterable<String> selectors,
  ) async => resolveIn(
    selectors,
    await getUnits(),
    await getTopics(),
    sections: await getSections(),
    archived: await getArchivedUnits(),
  );

  /// The open topics beneath each unit, subunit and section, keyed by its
  /// id. A subunit or section with no open topic is not in the map.
  static Map<String, Set<String>> _openGroups(
    List<StudyUnit> units,
    List<Section> sections,
    List<Topic> topics,
  ) {
    final parentOf = {for (final x in sections) x.id: x.parentId};
    final groups = {for (final u in units) u.id: <String>{}};
    for (final t in topics.where(isOpen)) {
      groups[t.unitId]?.add(t.id);
      final section = t.sectionId;
      if (section == null || !parentOf.containsKey(section)) continue;
      groups.putIfAbsent(section, () => {}).add(t.id);
      final subunit = parentOf[section];
      if (subunit != null && parentOf.containsKey(subunit)) {
        groups.putIfAbsent(subunit, () => {}).add(t.id);
      }
    }
    return groups;
  }

  /// What to store for the ticked [topicIds]: the topic ids themselves,
  /// plus the id of every unit, subunit and section whose open topics are
  /// all ticked (only the highest one: a ticked unit covers its sections).
  /// That id is what brings in a topic added there later; the topic ids
  /// keep the selection working should the section itself go away.
  static List<String> selectorsFor(
    Set<String> topicIds,
    List<StudyUnit> units,
    List<Section> sections,
    List<Topic> topics,
  ) {
    final groups = _openGroups(units, sections, topics);
    bool whole(String? id) {
      final inside = groups[id];
      return inside != null &&
          inside.isNotEmpty &&
          topicIds.containsAll(inside);
    }

    return [
      for (final u in units)
        if (whole(u.id)) u.id,
      for (final x in sections)
        if (whole(x.id) && !whole(x.unitId) && !whole(x.parentId)) x.id,
      ...topicIds,
    ];
  }

  /// A short human label for what [selectors] cover, e.g.
  /// "Pharmacology" or "Antimicrobials, CNS drugs".
  static String describeIn(
    Iterable<String> selectors,
    List<StudyUnit> units,
    List<Topic> topics, {
    List<Section> sections = const [],
    Set<String> archived = const {},
  }) {
    final wanted = selectors.where((s) => s.trim().isNotEmpty).toList();
    if (wanted.isEmpty || topics.isEmpty) return 'All topics';
    final ids = resolveIn(
      wanted,
      units,
      topics,
      sections: sections,
      archived: archived,
    ).toSet();
    // The same set an empty selection stands for.
    final all = resolveIn(const [], units, topics, archived: archived);
    if (ids.length == all.length && ids.containsAll(all)) return 'All topics';

    final groups = _openGroups(units, sections, topics);
    final parts = <String>[];
    for (final u in units) {
      // A unit is named when all of its open topics are picked.
      final inUnit = groups[u.id] ?? const <String>{};
      final picked = inUnit.where(ids.contains).toSet();
      if (picked.isEmpty) continue;
      if (picked.length == inUnit.length) {
        parts.add(u.name);
        continue;
      }
      // So is a subunit or a section, when it holds several topics (one
      // topic is better called by its own name).
      final named = <String>{};
      final inside = sections.where((x) => x.unitId == u.id);
      for (final x in [
        ...inside.where((x) => x.isSubunit),
        ...inside.where((x) => !x.isSubunit),
      ]) {
        final held = groups[x.id] ?? const <String>{};
        if (held.length < 2 || !ids.containsAll(held)) continue;
        if (named.containsAll(held)) continue; // its subunit was named
        parts.add(x.name);
        named.addAll(held);
      }
      parts.addAll(
        topics
            .where((t) => picked.contains(t.id) && !named.contains(t.id))
            .map((t) => t.name),
      );
    }
    if (parts.length > 3) {
      return '${parts.take(2).join(', ')} +${parts.length - 2} more';
    }
    return parts.join(', ');
  }

  static Future<String> describeSelection(Iterable<String> selectors) async =>
      describeIn(
        selectors,
        await getUnits(),
        await getTopics(),
        sections: await getSections(),
        archived: await getArchivedUnits(),
      );

  // ------------------------------------------------------------- questions

  static const String _questionSelect =
      'SELECT q.*, t.name AS topic_name FROM questions q '
      'JOIN topics t ON t.id = q.topic_id';

  /// The questions of a topic that are open right now (see [_openSql]):
  /// none for a locked topic, the first few without a paid plan.
  static Future<List<Question>> getQuestions(String topicId) async {
    await ensureReady();
    final rows = await (await _db).rawQuery(
      '$_questionSelect WHERE q.topic_id = ? AND ${_openSql()} '
      'ORDER BY q.created_at, q.id',
      [topicId],
    );
    return rows.map(Question.fromRow).toList();
  }

  /// Stores [q] unless its topic already has a question with the same text.
  /// Returns true if it was added.
  static Future<bool> addQuestion(Question q) async {
    final db = await _db;
    await db.insert('questions', {
      'id': q.id,
      'topic_id': q.topicId,
      'type': q.type == QuestionType.mcq ? 'mcq' : 'saq',
      'text': q.questionText.trim(),
      'text_key': textKey(q.questionText),
      'options': jsonEncode(q.options),
      'answer': q.correctAnswer.trim(),
      'alt_answers': jsonEncode(q.altAnswers),
      'explanation': q.explanation.trim(),
      'image': q.image,
      'source': q.source,
      'marks': q.marks,
      'long_answer': q.longAnswer ? 1 : 0,
      'key_points': jsonEncode(q.keyPoints),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final stored = await db.query(
      'questions',
      where: 'id = ?',
      whereArgs: [q.id],
    );
    if (stored.isNotEmpty && q.source != 'seed') onLocalChange?.call();
    return stored.isNotEmpty;
  }

  static Future<void> setExplanation(String questionId, String text) async {
    await (await _db).update(
      'questions',
      {'explanation': text.trim(), 'synced': 0},
      where: 'id = ?',
      whereArgs: [questionId],
    );
  }

  static Future<void> deleteQuestion(String questionId) async {
    final db = await _db;
    await _noteDeleted(db, [
      for (final r in await db.query(
        'questions',
        columns: ['id'],
        where: "id = ? AND source IN ('ai', 'user')",
        whereArgs: [questionId],
      ))
        r['id'] as String,
    ]);
    await db.delete('questions', where: 'id = ?', whereArgs: [questionId]);
  }

  /// Stores one answer. Returns the attempt's id (for
  /// [setAttemptCorrect]), or null if it could not be saved.
  static Future<int?> recordAttempt(
    String questionId, {
    required bool correct,
    required String mode,
    int? sessionId,
    String userAnswer = '',
    Duration? timeTaken,
  }) async {
    try {
      final id = await (await _db).insert('attempts', {
        'question_id': questionId,
        'mode': mode,
        'correct': correct ? 1 : 0,
        'answered_at': DateTime.now().millisecondsSinceEpoch,
        'session_id': sessionId,
        'user_answer': userAnswer.trim(),
        'duration_ms': timeTaken?.inMilliseconds,
      });
      onLocalChange?.call();
      return id;
    } catch (e) {
      debugPrint('Could not record the answer: $e');
      return null;
    }
  }

  /// Changes the verdict of an answer already stored (the user marked a
  /// long answer themselves). No second attempt is added.
  static Future<void> setAttemptCorrect(int? attemptId, bool correct) async {
    if (attemptId == null) return;
    try {
      await (await _db).update(
        'attempts',
        {'correct': correct ? 1 : 0, 'synced': 0},
        where: 'id = ?',
        whereArgs: [attemptId],
      );
      onLocalChange?.call();
    } catch (e) {
      debugPrint('Could not change the answer: $e');
    }
  }

  /// When a question was last answered (in an alarm or in practice), or
  /// null if none ever was.
  static Future<DateTime?> lastAnswerAt() async {
    try {
      final at = Sqflite.firstIntValue(
        await (await _db).rawQuery('SELECT MAX(answered_at) FROM attempts'),
      );
      return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
    } catch (e) {
      debugPrint('Could not read the last answer: $e');
      return null;
    }
  }

  /// For one topic: question id -> whether the latest answer was correct.
  /// Questions never answered are not in the map.
  static Future<Map<String, bool>> getQuestionProgress(String topicId) async {
    final rows = await (await _db).rawQuery(
      'SELECT q.id AS id, la.correct AS correct FROM questions q '
      'JOIN attempts la ON la.id = '
      '(SELECT MAX(a.id) FROM attempts a WHERE a.question_id = q.id) '
      'WHERE q.topic_id = ?',
      [topicId],
    );
    return {for (final r in rows) r['id'] as String: r['correct'] == 1};
  }

  /// Per-topic totals, keyed by topic id. Only open questions count, so
  /// a locked topic is not in the map.
  static Future<Map<String, TopicStats>> getStats() async {
    await ensureReady();
    final rows = await (await _db).rawQuery('''
      SELECT q.topic_id AS topic_id,
             COUNT(*) AS total,
             SUM(CASE WHEN la.correct IS NOT NULL THEN 1 ELSE 0 END) AS seen,
             SUM(CASE WHEN la.correct = 1 THEN 1 ELSE 0 END) AS mastered
      FROM questions q
      JOIN topics t ON t.id = q.topic_id
      LEFT JOIN attempts la ON la.id =
        (SELECT MAX(a.id) FROM attempts a WHERE a.question_id = q.id)
      WHERE ${_openSql()}
      GROUP BY q.topic_id''');
    return {
      for (final r in rows)
        r['topic_id'] as String: TopicStats(
          total: (r['total'] as int?) ?? 0,
          seen: (r['seen'] as int?) ?? 0,
          mastered: (r['mastered'] as int?) ?? 0,
        ),
    };
  }

  /// Picks the next question from [topicIds]. Order of preference:
  /// never answered, then last answered wrong, then answered longest ago.
  /// Questions in [exclude] (already shown this session) are avoided
  /// while anything else is left; after that they come round again, or
  /// with [repeat] false the result is null. Returns null only if there are no
  /// questions at all.
  ///
  /// Only open questions are picked (see [_openSql]). The one exception:
  /// an alarm ([repeat]) on a phone with no open question at all still
  /// gets one, because a ringing alarm must always have something to ask.
  ///
  /// Long answer questions ([Question.longAnswer]) are for practice only.
  /// With [longAnswers] false (the default for an alarm, [repeat]) they
  /// are never picked: a selection made only of them falls back to the
  /// ordinary questions of every topic, like a selection with nothing in
  /// it. Null if the phone holds nothing but long answer questions.
  static Future<Question?> pickNext(
    List<String> topicIds, {
    Set<String> exclude = const {},
    bool repeat = true,
    bool? longAnswers,
    Random? rng,
  }) async {
    final ordinaryOnly = !(longAnswers ?? !repeat);
    await ensureReady();
    final db = await _db;
    Future<List<Map<String, Object?>>> load(
      List<String> ids, {
      bool openOnly = true,
    }) {
      final marks = List.filled(ids.length, '?').join(',');
      return db.rawQuery(
        'SELECT q.*, t.name AS topic_name, la.correct AS last_correct, '
        'la.answered_at AS last_at FROM questions q '
        'JOIN topics t ON t.id = q.topic_id '
        'LEFT JOIN attempts la ON la.id = '
        '(SELECT MAX(a.id) FROM attempts a WHERE a.question_id = q.id) '
        'WHERE ${openOnly ? _openSql() : '1 = 1'} '
        '${ordinaryOnly ? 'AND q.long_answer = 0 ' : ''}'
        '${ids.isEmpty ? '' : 'AND q.topic_id IN ($marks)'}',
        ids,
      );
    }

    var rows = await load(topicIds);
    if (rows.isEmpty && topicIds.isNotEmpty) rows = await load(const []);
    if (rows.isEmpty && repeat) rows = await load(const [], openOnly: false);
    if (rows.isEmpty) return null;

    var pool = rows.where((r) => !exclude.contains(r['id'])).toList();
    // (query results are read-only, hence the copy before sorting below)
    if (pool.isEmpty) {
      // Everything was shown already. A practice session ends here; an
      // alarm ([repeat]) starts over.
      if (!repeat) return null;
      pool = List.of(rows);
    }

    final random = rng ?? Random();
    final unseen = pool.where((r) => r['last_at'] == null).toList();
    if (unseen.isNotEmpty) {
      return Question.fromRow(unseen[random.nextInt(unseen.length)])
          .shuffled(random);
    }
    int at(Map<String, Object?> r) => (r['last_at'] as int?) ?? 0;
    final wrong = pool.where((r) => r['last_correct'] == 0).toList()
      ..sort((a, b) => at(a).compareTo(at(b)));
    final tier = wrong.isNotEmpty
        ? wrong
        : (pool..sort((a, b) => at(a).compareTo(at(b))));
    final oldest = tier.take(min(5, tier.length)).toList();
    return Question.fromRow(oldest[random.nextInt(oldest.length)])
        .shuffled(random);
  }

  // -------------------------------------------------- sessions and reports

  /// Starts a session ('alarm', 'revision' or 'bank') and returns its id,
  /// or null if it could not be saved (the quiz must go on regardless).
  static Future<int?> startSession(
    String kind,
    String title, {
    int? alarmId,
    int? requiredStreak,
  }) async {
    try {
      await ensureReady();
      return await (await _db).insert('sessions', {
        'kind': kind,
        'title': title,
        'alarm_id': alarmId,
        'required_streak': requiredStreak,
        'started_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Could not start a session: $e');
      return null;
    }
  }

  /// Closes a session. One in which nothing was answered is removed.
  static Future<void> endSession(int? id, String outcome) async {
    if (id == null) return;
    try {
      final db = await _db;
      final n = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM attempts WHERE session_id = ?',
          [id],
        ),
      );
      if ((n ?? 0) == 0 && outcome != 'dismissed' && outcome != 'snoozed') {
        await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
        return;
      }
      await db.update(
        'sessions',
        {
          'ended_at': DateTime.now().millisecondsSinceEpoch,
          'outcome': outcome,
          'synced': 0,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      onLocalChange?.call();
    } catch (e) {
      debugPrint('Could not close the session: $e');
    }
  }

  static DateTime _time(Object? ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms as int);

  /// Past sessions, newest first. [kind] filters to one kind.
  static Future<List<StudySession>> getSessions({
    String? kind,
    int limit = 100,
  }) async {
    await ensureReady();
    final rows = await (await _db).rawQuery(
      'SELECT s.*, COUNT(a.id) AS questions, '
      'COALESCE(SUM(a.correct), 0) AS correct_count '
      'FROM sessions s LEFT JOIN attempts a ON a.session_id = s.id '
      // 'practice' covers both kinds of practice session.
      '${kind == null ? '' : (kind == 'practice' ? "WHERE s.kind IN ('bank', 'revision') " : 'WHERE s.kind = ? ')}'
      'GROUP BY s.id ORDER BY s.started_at DESC LIMIT ?',
      [if (kind != null && kind != 'practice') kind, limit],
    );
    return rows
        .map(
          (r) => StudySession(
            id: r['id'] as int,
            kind: r['kind'] as String,
            title: r['title'] as String,
            startedAt: _time(r['started_at']),
            endedAt: r['ended_at'] == null ? null : _time(r['ended_at']),
            outcome: r['outcome'] as String?,
            requiredStreak: r['required_streak'] as int?,
            questions: (r['questions'] as int?) ?? 0,
            correct: (r['correct_count'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  /// Every question answered in a session, in order, with what the user
  /// answered. The question (and so its explanation) comes from the
  /// database, so this works offline.
  static Future<List<AttemptDetail>> getSessionAttempts(int sessionId) async {
    final rows = await (await _db).rawQuery(
      'SELECT q.*, t.name AS topic_name, a.user_answer AS a_user_answer, '
      'a.correct AS a_correct, a.duration_ms AS a_duration_ms, '
      'a.answered_at AS a_answered_at FROM attempts a '
      'JOIN questions q ON q.id = a.question_id '
      'JOIN topics t ON t.id = q.topic_id '
      'WHERE a.session_id = ? ORDER BY a.id',
      [sessionId],
    );
    return rows
        .map(
          (r) => AttemptDetail(
            question: Question.fromRow(r),
            userAnswer: (r['a_user_answer'] ?? '') as String,
            correct: r['a_correct'] == 1,
            answeredAt: _time(r['a_answered_at']),
            timeTaken: r['a_duration_ms'] == null
                ? null
                : Duration(milliseconds: r['a_duration_ms'] as int),
          ),
        )
        .toList();
  }

  /// Totals, the last [days] days, trends and per-topic accuracy for the
  /// Reports tab. Archived units are included: archiving hides a unit, it
  /// does not rewrite history. [now] is only passed by tests.
  static Future<ReportSummary> getReport({int days = 14, DateTime? now}) async {
    await ensureReady();
    final db = await _db;
    final today = now ?? DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day - (days - 1));

    final totals = (await db.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(correct), 0) AS c FROM attempts',
    )).first;

    final recent = await db.rawQuery(
      'SELECT answered_at, correct FROM attempts WHERE answered_at >= ?',
      [firstDay.millisecondsSinceEpoch],
    );
    final answered = List<int>.filled(days, 0);
    final correct = List<int>.filled(days, 0);
    for (final r in recent) {
      final t = _time(r['answered_at']);
      final i = DateTime(t.year, t.month, t.day).difference(firstDay).inHours;
      final index = (i / 24).round();
      if (index < 0 || index >= days) continue;
      answered[index]++;
      if (r['correct'] == 1) correct[index]++;
    }

    final topicRows = await db.rawQuery(
      'SELECT t.id AS id, t.name AS name, COUNT(*) AS n, SUM(a.correct) AS c '
      'FROM attempts a JOIN questions q ON q.id = a.question_id '
      'JOIN topics t ON t.id = q.topic_id GROUP BY t.id',
    );
    final topics =
        topicRows
            .map(
              (r) => TopicAccuracy(
                r['name'] as String,
                (r['n'] as int?) ?? 0,
                (r['c'] as int?) ?? 0,
                id: r['id'] as String,
              ),
            )
            .toList()
          ..sort((a, b) => a.accuracy.compareTo(b.accuracy));

    final wake = (await db.rawQuery(
      "SELECT COUNT(*) AS n, AVG(ended_at - started_at) AS ms, "
      "AVG((SELECT COUNT(*) FROM attempts a WHERE a.session_id = s.id)) AS q "
      "FROM sessions s WHERE kind = 'alarm' AND outcome = 'dismissed'",
    )).first;
    final dismissed = (wake['n'] as int?) ?? 0;

    final dayStats = [
      for (var i = 0; i < days; i++)
        DayStat(
          DateTime(firstDay.year, firstDay.month, firstDay.day + i),
          answered[i],
          correct[i],
        ),
    ];
    return ReportSummary(
      answered: (totals['n'] as int?) ?? 0,
      correct: (totals['c'] as int?) ?? 0,
      alarmsDismissed: dismissed,
      avgWakeTime: dismissed == 0
          ? null
          : Duration(milliseconds: (wake['ms'] as num).round()),
      avgWakeQuestions: dismissed == 0 ? null : (wake['q'] as num).toDouble(),
      days: dayStats,
      topics: topics,
      trends: await _trends(db, today, dayStats),
    );
  }

  /// The last 14 days against the 14 days before, and this week against
  /// last week. Two grouped queries; [days] (the per-day counts already
  /// worked out for the chart) says which days of this week had answers.
  static Future<ReportTrends> _trends(
    Database db,
    DateTime today,
    List<DayStat> days,
  ) async {
    const span = 14;
    int ms(DateTime t) => t.millisecondsSinceEpoch;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    // Midnights: periods are whole calendar days, today included.
    final recentStart = DateTime(
      today.year,
      today.month,
      today.day - (span - 1),
    );
    final previousStart = DateTime(
      today.year,
      today.month,
      today.day - (2 * span - 1),
    );
    final end = DateTime(today.year, today.month, today.day + 1);
    final monday = DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - 1),
    );
    final lastMonday = DateTime(monday.year, monday.month, monday.day - 7);

    // (Plain "?" placeholders, repeated: numbered ones are not handled the
    // same way by every platform's SQLite binding.)
    final r0 = ms(recentStart);
    final t = (await db.rawQuery(
      'SELECT '
      'SUM(CASE WHEN answered_at >= ? THEN 1 ELSE 0 END) AS n, '
      'SUM(CASE WHEN answered_at >= ? THEN correct ELSE 0 END) AS c, '
      'SUM(CASE WHEN answered_at < ? THEN 1 ELSE 0 END) AS pn, '
      'SUM(CASE WHEN answered_at < ? THEN correct ELSE 0 END) AS pc, '
      'SUM(CASE WHEN answered_at >= ? THEN 1 ELSE 0 END) AS week, '
      'SUM(CASE WHEN answered_at >= ? AND answered_at < ? '
      'THEN 1 ELSE 0 END) AS last_week '
      'FROM attempts WHERE answered_at >= ? AND answered_at < ?',
      [
        r0,
        r0,
        r0,
        r0,
        ms(monday),
        ms(lastMonday),
        ms(monday),
        ms(previousStart),
        ms(end),
      ],
    )).first;

    final rows = await db.rawQuery(
      'SELECT t.id AS id, t.name AS name, '
      'SUM(CASE WHEN a.answered_at >= ? THEN 1 ELSE 0 END) AS n, '
      'SUM(CASE WHEN a.answered_at >= ? THEN a.correct ELSE 0 END) AS c, '
      'SUM(CASE WHEN a.answered_at < ? THEN 1 ELSE 0 END) AS pn, '
      'SUM(CASE WHEN a.answered_at < ? THEN a.correct ELSE 0 END) AS pc '
      'FROM attempts a JOIN questions q ON q.id = a.question_id '
      'JOIN topics t ON t.id = q.topic_id '
      'WHERE a.answered_at >= ? AND a.answered_at < ? GROUP BY t.id',
      [r0, r0, r0, r0, ms(previousStart), ms(end)],
    );
    final perTopic = [
      for (final r in rows)
        TopicTrend(
          id: r['id'] as String,
          topic: r['name'] as String,
          answered: n(r['n']),
          correct: n(r['c']),
          previousAnswered: n(r['pn']),
          previousCorrect: n(r['pc']),
        ),
    ];
    const enough = ReportTrends.minAnswers;
    final improving =
        perTopic
            .where(
              (t) =>
                  t.answered >= enough &&
                  t.previousAnswered >= enough &&
                  t.change > 0,
            )
            .toList()
          ..sort((a, b) {
            final byChange = b.change.compareTo(a.change);
            return byChange != 0 ? byChange : a.topic.compareTo(b.topic);
          });
    // A topic answered perfectly has nothing to revise.
    final weak =
        perTopic
            .where((t) => t.answered >= enough && t.correct < t.answered)
            .toList()
          ..sort((a, b) {
            final byAccuracy = a.accuracy.compareTo(b.accuracy);
            return byAccuracy != 0 ? byAccuracy : a.topic.compareTo(b.topic);
          });

    return ReportTrends(
      answered: n(t['n']),
      correct: n(t['c']),
      previousAnswered: n(t['pn']),
      previousCorrect: n(t['pc']),
      thisWeek: n(t['week']),
      lastWeek: n(t['last_week']),
      weekDays: [
        for (var i = 0; i < 7; i++)
          days.any(
            (d) =>
                d.answered > 0 &&
                d.day == DateTime(monday.year, monday.month, monday.day + i),
          ),
      ],
      improving: improving.take(3).toList(),
      needsRevision: weak.take(3).toList(),
    );
  }
}
