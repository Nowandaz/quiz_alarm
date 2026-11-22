// What the plan opens on the phone: which questions of which topics, how
// many alarms, and an alarm's own volume.
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/app_database.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/alarm_backend.dart';
import 'package:quiz_alarm/services/alarm_provider.dart';
import 'package:quiz_alarm/services/entitlements.dart';

import 'alarm_provider_test.dart' show FakeBackend, alarm;
import 'helpers.dart';

/// Remembers the volume of every registration.
class VolumeBackend extends FakeBackend {
  final Map<int, double> volumes = {};
  @override
  Future<void> set(AlarmRequest request) {
    volumes[request.id] = request.volume;
    return super.set(request);
  }
}

void main() {
  final plan = Entitlements.instance;
  tearDown(openAllFeatures);

  group('topics and questions', () {
    /// One unit with a topic of each kind, 12 questions each, plus a
    /// topic of the user's own with 12.
    Future<void> bank() async {
      await resetApp();
      await QuestionRepository.ensureReady(); // brings the bundled banks
      await QuestionRepository.importUnit({
        'version': 1,
        'unit': {'id': 'u', 'name': 'Unit'},
        'topics': [
          for (final (id, access) in [
            ('tg', 'guest'),
            ('tf', 'free'),
            ('tp', 'paid'),
            ('tn', null), // nothing said: paid
          ])
            {
              'id': id,
              'name': 'Topic $id',
              'access': ?access,
              'questions': [
                for (var i = 10; i < 22; i++)
                  {
                    'id': '$id-$i',
                    'type': 'saq',
                    'text': 'Question $i of $id?',
                    'answer': 'Yes',
                  },
              ],
            },
        ],
      }, force: true);
      // The bundled banks are not part of this test.
      final db = await AppDatabase.instance;
      await db.delete('units', where: "id != 'u'");
      final own = await QuestionRepository.addCustomTopic('Mine');
      for (var i = 10; i < 22; i++) {
        await QuestionRepository.addQuestion(
          Question(
            id: 'own-$i',
            topicId: own.id,
            topic: own.name,
            type: QuestionType.saq,
            questionText: 'Own question $i?',
            correctAnswer: 'Yes',
            source: 'user',
          ),
        );
      }
    }

    Future<Map<String, int>> open() async {
      final topics = await QuestionRepository.getTopics();
      return {
        for (final t in topics)
          t.name: (await QuestionRepository.getQuestions(t.id)).length,
      };
    }

    test('the importer reads "access"; missing means paid', () async {
      await bank();
      expect(
        {for (final t in await QuestionRepository.getTopics()) t.id: t.access},
        {
          'tg': 'guest',
          'tf': 'free',
          'tp': 'paid',
          'tn': 'paid',
          'custom-mine': 'free',
        },
      );
    });

    test('guest: the first 10 questions of guest topics only', () async {
      await bank();
      plan.setForTest(PlanLevel.guest);
      expect(await open(), {
        'Topic tg': 10,
        'Topic tf': 0,
        'Topic tp': 0,
        'Topic tn': 0,
        'Mine': 0,
      });
      expect(
        (await QuestionRepository.getQuestions('tg')).map((q) => q.id).last,
        'tg-19',
        reason: 'the earliest ten',
      );
      final stats = await QuestionRepository.getStats();
      expect(stats.keys, ['tg']);
      expect(stats['tg']!.total, 10);
    });

    test('free: 10 each of guest and free topics, all of their own', () async {
      await bank();
      plan.setForTest(PlanLevel.free);
      expect(await open(), {
        'Topic tg': 10,
        'Topic tf': 10,
        'Topic tp': 0,
        'Topic tn': 0,
        'Mine': 12,
      });
      final topics = await QuestionRepository.getTopics();
      expect(
        {for (final t in topics) t.id: QuestionRepository.openLimit(t)},
        {'tg': 10, 'tf': 10, 'tp': 0, 'tn': 0, 'custom-mine': null},
      );
    });

    test('pro and ultra: everything', () async {
      await bank();
      for (final level in [PlanLevel.pro, PlanLevel.ultra]) {
        plan.setForTest(level);
        expect((await open()).values, everyElement(12));
      }
    });

    test('pickNext never hands out a locked or capped question', () async {
      await bank();
      plan.setForTest(PlanLevel.guest);
      final seen = <String>{};
      for (var i = 0; i < 40; i++) {
        final q = await QuestionRepository.pickNext(
          const ['tg', 'tp'],
          exclude: seen,
          repeat: false,
        );
        if (q == null) break;
        seen.add(q.id);
      }
      expect(seen, hasLength(10));
      expect(seen.every((id) => id.startsWith('tg-1')), isTrue);
    });

    test('an alarm on locked topics falls back to the open ones', () async {
      await bank();
      plan.setForTest(PlanLevel.guest);
      expect(await QuestionRepository.resolveTopicIds(const ['tp', 'tn']), [
        'tg',
      ]);
      expect(await QuestionRepository.resolveTopicIds(const ['u']), ['tg']);
      expect(await QuestionRepository.resolveTopicIds(const []), ['tg']);
      final q = await QuestionRepository.pickNext(
        await QuestionRepository.resolveTopicIds(const ['tp']),
      );
      expect(q!.topicId, 'tg');

      plan.setForTest(PlanLevel.free);
      expect((await QuestionRepository.resolveTopicIds(const ['u'])).toSet(), {
        'tg',
        'tf',
      });
    });

    test('with nothing open at all an alarm still gets a question; '
        'practice does not', () async {
      await bank();
      final db = await AppDatabase.instance;
      await db.update('topics', {'access': 'paid'});
      plan.setForTest(PlanLevel.guest);
      expect(await QuestionRepository.resolveTopicIds(const ['tp']), isEmpty);
      expect(await QuestionRepository.pickNext(const []), isNotNull);
      expect(
        await QuestionRepository.pickNext(const [], repeat: false),
        isNull,
      );
    });

    test('a plan that ran out locks questions already on the phone', () async {
      await bank();
      expect((await QuestionRepository.getQuestions('tp')), hasLength(12));
      plan.setForTest(PlanLevel.free);
      expect(await QuestionRepository.getQuestions('tp'), isEmpty);
    });
  });

  group('alarms', () {
    test('a guest can add three alarms; the fourth is refused', () async {
      await resetApp();
      plan.setForTest(PlanLevel.guest);
      final provider = AlarmProvider(backend: FakeBackend());
      await provider.loaded;
      for (var id = 1; id <= 3; id++) {
        expect(provider.canAddAlarm, isTrue);
        expect(await provider.addAlarm(alarm(id)), isTrue);
      }
      expect(provider.canAddAlarm, isFalse);
      expect(await provider.addAlarm(alarm(4)), isFalse);
      expect(provider.alarms.map((a) => a.id), [1, 2, 3]);

      // With an account there is no limit.
      plan.setForTest(PlanLevel.free);
      expect(await provider.addAlarm(alarm(4)), isTrue);
      provider.dispose();
    });

    test('alarms above the limit (after signing out) keep working, but no '
        'new one can be added', () async {
      await resetApp();
      final backend = FakeBackend();
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;
      for (var id = 1; id <= 5; id++) {
        await provider.addAlarm(alarm(id, days: const [1]));
      }
      plan.setForTest(PlanLevel.guest);
      expect(backend.registered.keys, hasLength(5));
      expect(await provider.addAlarm(alarm(6)), isFalse);

      // Still editable and deletable.
      final edited = alarm(5, days: const [2])..label = 'Edited';
      await provider.updateAlarm(edited);
      expect(provider.alarms.firstWhere((a) => a.id == 5).label, 'Edited');
      await provider.deleteAlarm(1);
      expect(provider.alarms, hasLength(4));
      expect(await provider.addAlarm(alarm(6)), isFalse);
      provider.dispose();
    });

    test('an alarm saved before volumes existed rings at full volume', () {
      final json = alarm(1).toJson()..remove('volume');
      expect(AlarmItem.fromJson(json).volume, 1.0);
      final quiet = alarm(2)..volume = 0.4;
      expect(AlarmItem.fromJson(quiet.toJson()).volume, 0.4);
    });

    test('an alarm\'s own volume is used on a paid plan only, and follows '
        'the plan', () async {
      await resetApp();
      final backend = VolumeBackend();
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;
      final quiet = alarm(7, days: const [1])..volume = 0.4;
      await provider.addAlarm(quiet);
      expect(backend.volumes[71], 0.4);

      // The plan runs out: back to maximum by itself.
      plan.setForTest(PlanLevel.free);
      await provider.updateAlarm(quiet); // waits for the re-registration
      expect(AlarmProvider.effectiveVolume(quiet), 1.0);
      expect(backend.volumes[71], 1.0);

      // And quiet again once it is back.
      plan.setForTest(PlanLevel.pro);
      await provider.updateAlarm(quiet);
      expect(backend.volumes[71], 0.4);

      // Never below the quietest setting.
      expect(
        AlarmProvider.effectiveVolume(alarm(8)..volume = 0),
        AlarmProvider.minVolume,
      );
      provider.dispose();
    });

    test('a change of plan alone re-registers quiet alarms', () async {
      await resetApp();
      final backend = VolumeBackend();
      final provider = AlarmProvider(backend: backend);
      await provider.loaded;
      await provider.addAlarm(alarm(7, days: const [1])..volume = 0.4);
      await provider.addAlarm(alarm(8, days: const [1]));
      backend.setCalls.clear();

      plan.setForTest(PlanLevel.free);
      await provider.deleteAlarm(999); // waits for the queue to empty
      expect(backend.volumes[71], 1.0);
      expect(backend.setCalls, [71], reason: 'the full-volume alarm is left');
      provider.dispose();
    });
  });
}
