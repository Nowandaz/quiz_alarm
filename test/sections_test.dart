// Unit -> (subunit) -> section -> topic: the database upgrade, the
// importer, the tree the screens read, selecting a whole section for an
// alarm, and the screens that show sections.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/section_screen.dart';
import 'package:quiz_alarm/screens/tabs/question_bank_tab.dart';
import 'package:quiz_alarm/screens/topic_screen.dart';
import 'package:quiz_alarm/screens/unit_screen.dart';
import 'package:quiz_alarm/services/bank_provider.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/widgets/topic_picker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';

/// One topic of a seed file, with two questions.
Map<String, dynamic> seedTopic(
  String id, {
  String? section,
  String? subunit,
  String access = 'free',
}) => {
  'id': id,
  'name': 'Topic $id',
  'access': access,
  'section': ?section,
  'subunit': ?subunit,
  'questions': [
    for (var i = 1; i <= 2; i++)
      {'id': '$id-$i', 'type': 'saq', 'text': 'Q$i of $id?', 'answer': 'Yes'},
  ],
};

/// A unit using every shape:
/// - subunit Haematology: sections Blood film (t1, t2) and Clotting (t3)
/// - subunit Immunology: one section, Basics (t4, t5)
/// - section General, straight under the unit (t6, t7: paid)
/// - section Solo with one topic (t8)
/// - t9 in no section
Map<String, dynamic> seedUnit({List<Map<String, dynamic>> more = const []}) => {
  'version': 1,
  'unit': {'id': 'u', 'name': 'Pathology'},
  'topics': [
    seedTopic('t1', subunit: 'Haematology', section: 'Blood film'),
    seedTopic('t2', subunit: 'Haematology', section: 'Blood film'),
    seedTopic('t3', subunit: 'Haematology', section: 'Clotting'),
    seedTopic('t4', subunit: 'Immunology', section: 'Basics'),
    seedTopic('t5', subunit: 'Immunology', section: 'Basics'),
    seedTopic('t6', section: 'General', access: 'paid'),
    seedTopic('t7', section: 'General', access: 'paid'),
    seedTopic('t8', section: 'Solo'),
    seedTopic('t9'),
    ...more,
  ],
};

/// A fresh app holding only [seedUnit].
Future<void> startWithUnit() async {
  await resetApp();
  await QuestionRepository.ensureReady();
  await QuestionRepository.importUnit(seedUnit(), force: true);
  final db = await AppDatabase.instance;
  await db.delete('units', where: "id != 'u'");
}

void main() {
  tearDown(openAllFeatures);

  test('a version 6 database is upgraded and keeps its data', () async {
    await resetApp();
    final dir = await Directory.systemTemp.createTemp('brainwake_v6');
    final path = '${dir.path}/v6.db';
    final old = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          for (final sql in [
            'CREATE TABLE units(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
                "description TEXT NOT NULL DEFAULT '', "
                'sort_order INTEGER NOT NULL DEFAULT 0)',
            'CREATE TABLE topics(id TEXT PRIMARY KEY, unit_id TEXT NOT NULL '
                'REFERENCES units(id) ON DELETE CASCADE, name TEXT NOT NULL, '
                'sort_order INTEGER NOT NULL DEFAULT 0, '
                'is_custom INTEGER NOT NULL DEFAULT 0, '
                "description TEXT NOT NULL DEFAULT '', "
                "access TEXT NOT NULL DEFAULT 'paid')",
            'CREATE TABLE questions(id TEXT PRIMARY KEY, topic_id TEXT NOT NULL '
                'REFERENCES topics(id) ON DELETE CASCADE, type TEXT NOT NULL, '
                'text TEXT NOT NULL, text_key TEXT NOT NULL, '
                "options TEXT NOT NULL DEFAULT '[]', answer TEXT NOT NULL, "
                "alt_answers TEXT NOT NULL DEFAULT '[]', "
                "explanation TEXT NOT NULL DEFAULT '', "
                "image TEXT NOT NULL DEFAULT '', "
                "source TEXT NOT NULL DEFAULT 'seed', "
                'created_at INTEGER NOT NULL, '
                'synced INTEGER NOT NULL DEFAULT 0)',
            'CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'kind TEXT NOT NULL, title TEXT NOT NULL, alarm_id INTEGER, '
                'required_streak INTEGER, started_at INTEGER NOT NULL, '
                'ended_at INTEGER, outcome TEXT, uuid TEXT, '
                'synced INTEGER NOT NULL DEFAULT 0)',
            'CREATE TABLE attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, '
                'question_id TEXT NOT NULL REFERENCES questions(id) '
                'ON DELETE CASCADE, mode TEXT NOT NULL, '
                'correct INTEGER NOT NULL, answered_at INTEGER NOT NULL, '
                'session_id INTEGER, user_answer TEXT NOT NULL DEFAULT \'\', '
                'duration_ms INTEGER, uuid TEXT, '
                'synced INTEGER NOT NULL DEFAULT 0)',
            'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          ]) {
            await db.execute(sql);
          }
          await db.insert('units', {'id': 'u', 'name': 'Old unit'});
          await db.insert('topics', {
            'id': 'old-topic',
            'unit_id': 'u',
            'name': 'Old topic',
            'access': 'guest',
          });
          await db.insert('questions', {
            'id': 'old-q',
            'topic_id': 'old-topic',
            'type': 'saq',
            'text': 'Old?',
            'text_key': 'old?',
            'answer': 'Yes',
            'created_at': 1,
          });
          await db.insert('attempts', {
            'question_id': 'old-q',
            'mode': 'bank',
            'correct': 1,
            'answered_at': 5,
          });
          // The bank came from the server: no bundled files on top.
          await db.insert('meta', {
            'key': QuestionRepository.bankSyncedKey,
            'value': '2026-01-01T00:00:00Z',
          });
        },
      ),
    );
    await old.close();

    await AppDatabase.close();
    AppDatabase.pathOverride = path;
    QuestionRepository.resetForTest();

    final topics = await QuestionRepository.getTopics();
    expect(topics.single.id, 'old-topic');
    expect(topics.single.access, 'guest');
    expect(topics.single.sectionId, isNull);
    expect(await QuestionRepository.getSections(), isEmpty);
    expect((await QuestionRepository.getStats())['old-topic']!.mastered, 1);
    // The unit has no sections, so it is one flat list, as before.
    final bank = BankProvider();
    await bank.reload();
    expect(bank.filledSectionsOf('u'), isEmpty);
    expect(bank.unfiledTopics('u').single.id, 'old-topic');
    bank.dispose();
    // The new table works.
    final db = await AppDatabase.instance;
    await db.insert('sections', {'id': 's', 'unit_id': 'u', 'name': 'New'});
    expect((await QuestionRepository.getSections()).single.kind, 'section');

    await AppDatabase.close();
    await dir.delete(recursive: true);
  });

  group('the importer', () {
    test('creates subunits and sections from "subunit" and "section", in '
        'file order, and files the topics', () async {
      await startWithUnit();
      final sections = await QuestionRepository.getSections();
      expect(
        [for (final x in sections) '${x.kind} ${x.id} <${x.parentId}'],
        [
          'subunit u-sub-haematology <null',
          'section u-sec-blood-film <u-sub-haematology',
          'section u-sec-clotting <u-sub-haematology',
          'subunit u-sub-immunology <null',
          'section u-sec-basics <u-sub-immunology',
          'section u-sec-general <null',
          'section u-sec-solo <null',
        ],
      );
      expect(sections.first.name, 'Haematology');
      expect(sections.first.isSubunit, isTrue);
      expect(
        {
          for (final t in await QuestionRepository.getTopics())
            t.id: t.sectionId,
        },
        {
          't1': 'u-sec-blood-film',
          't2': 'u-sec-blood-film',
          't3': 'u-sec-clotting',
          't4': 'u-sec-basics',
          't5': 'u-sec-basics',
          't6': 'u-sec-general',
          't7': 'u-sec-general',
          't8': 'u-sec-solo',
          't9': null,
        },
      );
    });

    test('a later version of the file moves topics and drops sections that '
        'are no longer named; answers stay', () async {
      await startWithUnit();
      await QuestionRepository.recordAttempt(
        't8-1',
        correct: true,
        mode: 'bank',
      );
      final next = seedUnit()..['version'] = 2;
      (next['topics'] as List)
        ..removeWhere((t) => (t as Map)['id'] == 't8')
        ..add(seedTopic('t8', section: 'General'));
      await QuestionRepository.importUnit(next);
      final ids = (await QuestionRepository.getSections()).map((x) => x.id);
      expect(ids, isNot(contains('u-sec-solo')));
      final t8 = (await QuestionRepository.getTopics()).firstWhere(
        (t) => t.id == 't8',
      );
      expect(t8.sectionId, 'u-sec-general');
      expect((await QuestionRepository.getStats())['t8']!.mastered, 1);
    });

    test('the same section name under two subunits is two sections', () async {
      await resetApp();
      await QuestionRepository.importUnit({
        'version': 1,
        'unit': {'id': 'x', 'name': 'X'},
        'topics': [
          seedTopic('a', subunit: 'One', section: 'General'),
          seedTopic('b', subunit: 'Two', section: 'General'),
        ],
      }, force: true);
      final topics = {
        for (final t in await QuestionRepository.getTopics())
          if (t.unitId == 'x') t.id: t.sectionId,
      };
      expect(topics, {'a': 'x-sec-general', 'b': 'x-sub-two-sec-general'});
    });

    test('the bundled banks come with sections', () async {
      await resetApp();
      final bank = BankProvider();
      await bank.reload();
      // Pharmacology: sections straight under the unit.
      final pharm = bank.sectionsOf('pharmacology');
      expect(pharm, hasLength(bank.topicsOf('pharmacology').length));
      expect(pharm.any((x) => x.isSubunit), isFalse);
      expect(bank.unfiledTopics('pharmacology'), isEmpty);
      // Pathology: subunits, then sections.
      final path = bank.sectionsOf('pathology');
      expect(path.map((x) => x.name), ['Haematology', 'Anatomical pathology']);
      expect(path.every((x) => x.isSubunit), isTrue);
      expect(bank.childrenOf(path.first.id).single.name, 'Blood film');
      expect(
        bank.topicsUnder(path.first.id).single.id,
        'path-haematology-spotters',
      );
      expect(
        bank
            .sectionOf(bank.topics.firstWhere((t) => t.id.contains('histo')))!
            .name,
        'Histopathology',
      );
      bank.dispose();
    });
  });

  group('the bank provider', () {
    late BankProvider bank;
    Future<void> load({PlanLevel level = PlanLevel.pro}) async {
      await startWithUnit();
      Entitlements.instance.setForTest(level);
      bank = BankProvider();
      await bank.reload();
      addTearDown(bank.dispose);
    }

    List<String> ids(Iterable<Topic> topics) => [for (final t in topics) t.id];

    test('walks the tree', () async {
      await load();
      expect(bank.sectionsOf('u').map((x) => x.name), [
        'Haematology',
        'Immunology',
        'General',
        'Solo',
      ]);
      expect(bank.childrenOf('u-sub-haematology').map((x) => x.name), [
        'Blood film',
        'Clotting',
      ]);
      expect(bank.childrenOf('u-sec-general'), isEmpty);
      expect(ids(bank.topicsIn('u-sec-blood-film')), ['t1', 't2']);
      expect(bank.topicsIn('u-sub-haematology'), isEmpty);
      expect(ids(bank.topicsUnder('u-sub-haematology')), ['t1', 't2', 't3']);
      expect(ids(bank.topicsUnder('u-sec-general')), ['t6', 't7']);
      expect(ids(bank.unfiledTopics('u')), ['t9']);
      expect(
        bank.parentOf(bank.sectionById('u-sec-clotting')!)!.name,
        'Haematology',
      );
      final t1 = bank.topics.firstWhere((t) => t.id == 't1');
      expect(bank.placeOf(t1), 'Pathology · Blood film');
      expect(
        bank.placeOf(bank.topics.firstWhere((t) => t.id == 't9')),
        'Pathology',
      );
      expect(bank.sectionMatches(t1, 'haemat'), isTrue);
      expect(bank.sectionMatches(t1, 'clot'), isFalse);
    });

    test('adds up questions and mastery beneath a section', () async {
      await load();
      await QuestionRepository.recordAttempt(
        't1-1',
        correct: true,
        mode: 'bank',
      );
      await QuestionRepository.recordAttempt(
        't3-1',
        correct: false,
        mode: 'bank',
      );
      await bank.reload();
      final film = bank.sectionStats('u-sec-blood-film');
      expect([film.total, film.seen, film.mastered], [4, 1, 1]);
      final haem = bank.sectionStats('u-sub-haematology');
      expect([haem.total, haem.seen, haem.mastered], [6, 2, 1]);
    });

    test('a section whose topics are all locked is locked, and counts '
        'nothing', () async {
      await load(level: PlanLevel.free);
      expect(bank.isSectionLocked('u-sec-general'), isTrue);
      expect(bank.sectionStats('u-sec-general').total, 0);
      expect(bank.isSectionLocked('u-sub-haematology'), isFalse);
      expect(bank.sectionStats('u-sub-haematology').total, 6);
    });

    test(
      'a topic whose section is not on the phone counts as unfiled',
      () async {
        await load();
        final db = await AppDatabase.instance;
        await db.delete('sections', where: "id = 'u-sec-solo'");
        await bank.reload();
        expect(ids(bank.unfiledTopics('u')), ['t8', 't9']);
      },
    );
  });

  group('choosing a section for an alarm', () {
    late BankProvider bank;
    Future<void> load() async {
      await startWithUnit();
      bank = BankProvider();
      await bank.reload();
      addTearDown(bank.dispose);
    }

    test('a ticked section is stored by its id, and a topic added to it '
        'later is asked too', () async {
      await load();
      final stored = bank.selectorsFor({'t1', 't2'});
      expect(stored, containsAll(['u-sec-blood-film', 't1', 't2']));
      expect(stored, isNot(contains('u-sub-haematology')));
      expect(bank.describe(stored), 'Blood film');
      expect((await QuestionRepository.resolveTopicIds(stored)).toSet(), {
        't1',
        't2',
      });

      // The bank grows: a new topic in that section.
      await QuestionRepository.importUnit(
        seedUnit(
          more: [
            seedTopic('t10', subunit: 'Haematology', section: 'Blood film'),
          ],
        )..['version'] = 2,
      );
      expect((await QuestionRepository.resolveTopicIds(stored)).toSet(), {
        't1',
        't2',
        't10',
      });
      // An alarm on the section id alone works the same.
      expect(
        (await QuestionRepository.resolveTopicIds(['u-sec-blood-film']))
            .toSet(),
        {'t1', 't2', 't10'},
      );
      await bank.reload();
      expect(bank.selectedIds(stored), {'t1', 't2', 't10'});
    });

    test('a ticked subunit covers its sections; a ticked unit covers '
        'everything in it', () async {
      await load();
      final haem = bank.selectorsFor({'t1', 't2', 't3'});
      expect(haem, contains('u-sub-haematology'));
      expect(haem, isNot(contains('u-sec-blood-film')));
      expect(bank.describe(haem), 'Haematology');
      expect(
        (await QuestionRepository.resolveTopicIds(['u-sub-haematology']))
            .toSet(),
        {'t1', 't2', 't3'},
      );

      await QuestionRepository.addCustomTopic('Mine');
      await bank.reload();
      final all = {for (final t in bank.topicsOf('u')) t.id};
      final unit = bank.selectorsFor(all);
      expect(unit.where((s) => !s.startsWith('t')), ['u']);
      expect(bank.describe(unit), 'Pathology');
    });

    test('part of a section is stored as its topics only', () async {
      await load();
      expect(bank.selectorsFor({'t1', 't9'}), ['t1', 't9']);
      expect(bank.describe(['t1', 't9']), 'Topic t1, Topic t9');
    });

    test(
      'selections saved before sections existed resolve as before',
      () async {
        await load();
        expect(await QuestionRepository.resolveTopicIds(['t3']), ['t3']);
        expect(await QuestionRepository.resolveTopicIds(['Topic t3']), ['t3']);
        expect((await QuestionRepository.resolveTopicIds(['u'])).length, 9);
        expect(
          (await QuestionRepository.resolveTopicIds(['pathology'])).length,
          9,
        );
        expect(await QuestionRepository.describeSelection(['t3']), 'Topic t3');
        expect(
          await QuestionRepository.describeSelection(const []),
          'All topics',
        );
      },
    );

    test('a locked section adds nothing; the alarm falls back to the open '
        'topics', () async {
      await load();
      Entitlements.instance.setForTest(PlanLevel.free);
      expect(
        (await QuestionRepository.resolveTopicIds([
          'u-sec-general',
          'u-sec-solo',
        ])),
        ['t8'],
      );
      expect(
        (await QuestionRepository.resolveTopicIds(['u-sec-general'])).toSet(),
        {'t1', 't2', 't3', 't4', 't5', 't8', 't9'},
      );
    });
  });

  group('screens', () {
    late BankProvider bank;

    Future<void> show(
      WidgetTester tester,
      Widget screen, {
      PlanLevel level = PlanLevel.pro,
    }) async {
      tester.view.physicalSize = const Size(1600, 3200);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await startWithUnit();
        Entitlements.instance.setForTest(level);
        bank = BankProvider();
        await bank.reload();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: bank,
          child: MaterialApp(home: screen),
        ),
      );
      await tester.pump();
    }

    /// Taps and lets the next screen slide in (its database reads need
    /// real time, hence runAsync).
    Future<void> tap(WidgetTester tester, Finder what) async {
      await tester.tap(what);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    const unit = StudyUnit(id: 'u', name: 'Pathology');

    testWidgets('a unit lists its subunits and sections, then "Other '
        'topics"', (tester) async {
      await show(tester, const UnitScreen(unit: unit));
      expect(find.byType(SectionCard), findsNWidgets(4));
      expect(find.text('2 sections · 3 topics · 6 questions'), findsOneWidget);
      expect(find.text('2 topics · 4 questions'), findsOneWidget);
      expect(find.text('Other topics'), findsOneWidget);
      expect(find.byType(TopicCard), findsOneWidget);
      expect(find.text('Topic t9'), findsOneWidget);
      // The unit's own line counts everything.
      expect(find.text('9 topics · 18 questions'), findsOneWidget);
    });

    testWidgets('a unit without sections lists its topics as before', (
      tester,
    ) async {
      await show(tester, const SizedBox());
      await tester.runAsync(() async {
        final db = await AppDatabase.instance;
        await db.delete('sections');
        await bank.reload();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: bank,
          child: const MaterialApp(home: UnitScreen(unit: unit)),
        ),
      );
      await tester.pump();
      expect(find.byType(SectionCard), findsNothing);
      expect(find.text('Other topics'), findsNothing);
      expect(find.byType(TopicCard), findsNWidgets(9));
    });

    testWidgets('a subunit opens its sections, a section its topics', (
      tester,
    ) async {
      await show(tester, const UnitScreen(unit: unit));
      await tap(tester, find.text('Haematology'));
      expect(find.byType(SectionScreen), findsOneWidget);
      expect(find.text('Pathology'), findsWidgets); // where it is
      expect(find.text('Blood film'), findsOneWidget);
      expect(find.text('Clotting'), findsOneWidget);

      await tap(tester, find.text('Blood film'));
      expect(find.text('Pathology · Haematology'), findsOneWidget);
      expect(find.text('Topic t1'), findsOneWidget);
      expect(find.text('Topic t2'), findsOneWidget);
      expect(find.byType(TopicScreen), findsNothing);
    });

    testWidgets('a section with one topic opens the topic', (tester) async {
      await show(tester, const UnitScreen(unit: unit));
      await tap(tester, find.text('Solo'));
      expect(find.byType(SectionScreen), findsNothing);
      expect(find.byType(TopicScreen), findsOneWidget);
      expect(
        tester.widget<TopicScreen>(find.byType(TopicScreen)).topic.id,
        't8',
      );
    });

    testWidgets('so does a section with one topic inside a subunit', (
      tester,
    ) async {
      await show(tester, const UnitScreen(unit: unit));
      await tap(tester, find.text('Haematology'));
      await tap(tester, find.text('Clotting'));
      expect(
        tester.widget<TopicScreen>(find.byType(TopicScreen)).topic.id,
        't3',
      );
    });

    testWidgets('a subunit with one section opens that section\'s topics', (
      tester,
    ) async {
      await show(tester, const UnitScreen(unit: unit));
      await tap(tester, find.text('Immunology'));
      final screen = tester.widget<SectionScreen>(find.byType(SectionScreen));
      expect(screen.section.id, 'u-sec-basics');
      expect(find.text('Pathology · Immunology'), findsOneWidget);
      expect(find.text('Topic t4'), findsOneWidget);
      expect(find.text('Topic t5'), findsOneWidget);
    });

    testWidgets('a section whose topics are all locked shows the lock', (
      tester,
    ) async {
      await show(tester, const UnitScreen(unit: unit), level: PlanLevel.free);
      final general = find.ancestor(
        of: find.text('General'),
        matching: find.byType(SectionCard),
      );
      expect(
        find.descendant(of: general, matching: find.text('2 topics · Locked')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: general, matching: find.byIcon(Icons.lock_rounded)),
        findsOneWidget,
      );
      // The others are open.
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      // It still opens, onto its locked topics.
      await tap(tester, find.text('General'));
      expect(find.byType(SectionScreen), findsOneWidget);
      expect(find.text('Locked'), findsNWidgets(2));
    });

    testWidgets('the Banks search finds sections and subunits by name', (
      tester,
    ) async {
      await show(tester, const Scaffold(body: QuestionBankTab()));
      await tester.enterText(find.byType(TextField), 'haemat');
      await tester.pump();
      expect(find.byType(SectionCard), findsOneWidget);
      expect(find.text('Haematology'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'blood');
      await tester.pump();
      expect(find.text('Blood film'), findsOneWidget);
      expect(find.text('Pathology · Haematology'), findsOneWidget);

      // A topic says where it is.
      await tester.enterText(find.byType(TextField), 'topic t1');
      await tester.pump();
      expect(find.byType(SectionCard), findsNothing);
      expect(find.text('Pathology · Blood film'), findsOneWidget);
    });

    testWidgets('the picker is a tree: ticking a section ticks its topics', (
      tester,
    ) async {
      var picked = <String>{};
      await show(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TopicPicker(
                selected: picked,
                onChanged: (s) => setState(() => picked = s),
              ),
            ),
          ),
        ),
        level: PlanLevel.free,
      );
      Finder tickOf(String name) => find.descendant(
        of: find
            .ancestor(of: find.text(name), matching: find.byType(Row))
            .first,
        matching: find.byType(Checkbox),
      );

      // Closed below the unit until tapped.
      expect(find.text('Haematology'), findsNothing);
      await tester.tap(find.text('Pathology'));
      await tester.pumpAndSettle();
      expect(find.text('Haematology'), findsOneWidget);
      expect(find.text('Blood film'), findsNothing);
      // A section with one topic is simply that topic.
      expect(find.text('Solo'), findsNothing);
      expect(find.text('Topic t8'), findsOneWidget);
      expect(find.text('Topic t9'), findsOneWidget);

      await tester.tap(find.text('Haematology'));
      await tester.pumpAndSettle();
      expect(find.text('Blood film'), findsOneWidget);
      expect(find.text('Topic t1'), findsNothing);
      await tester.tap(tickOf('Blood film'));
      await tester.pumpAndSettle();
      expect(picked, {'t1', 't2'});
      await tester.tap(find.text('Blood film'));
      await tester.pumpAndSettle();
      expect(find.text('Topic t1'), findsOneWidget);

      // The subunit's tick takes everything beneath it.
      await tester.tap(tickOf('Haematology'));
      await tester.pumpAndSettle();
      expect(picked, {'t1', 't2', 't3'});

      // A subunit with one section goes straight to the topics.
      await tester.tap(find.text('Immunology'));
      await tester.pumpAndSettle();
      expect(find.text('Basics'), findsNothing);
      expect(find.text('Topic t4'), findsOneWidget);

      // A locked section cannot be ticked.
      expect(tester.widget<Checkbox>(tickOf('General')).onChanged, isNull);
      await tester.tap(tickOf('Pathology'));
      await tester.pumpAndSettle();
      expect(picked, {'t1', 't2', 't3', 't4', 't5', 't8', 't9'});

      // Searching by a section's name lists its topics.
      await tester.enterText(find.byType(TextField), 'clott');
      await tester.pumpAndSettle();
      expect(find.text('Topic t3'), findsOneWidget);
      expect(find.text('Topic t1'), findsNothing);
    });
  });
}
