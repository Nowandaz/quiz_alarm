// How an answer is marked end to end: the phone first, the AI only for
// paid plans, and the "mute right and wrong sounds" setting.
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/ai_client.dart';
import 'package:quiz_alarm/services/answer_grader.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/question_service.dart';
import 'package:quiz_alarm/services/sound_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

const saq = Question(
  id: 'q',
  topic: 'ANS',
  type: QuestionType.saq,
  questionText: 'First-line drug for anaphylaxis?',
  correctAnswer: 'Adrenaline',
  altAnswers: ['Epinephrine'],
);

void main() {
  setUp(() => resetApp(signedIn: true));
  tearDown(() {
    Entitlements.instance.setForTest(null);
    AnswerGrader.knownTerms = {};
  });

  group('marking a typed answer', () {
    test('a match on the phone never asks the AI', () async {
      final requests = fakeAi((_) => ok({'correct': false}));
      final r = await QuestionService.grade(saq, 'adrenalin');
      expect(r.correct, isTrue);
      expect(r.corrected, 'Adrenaline');
      expect(requests, isEmpty);
    });

    test('paid plans: the AI is asked when the phone says wrong', () async {
      Entitlements.instance.setForTest(PlanLevel.pro);
      final requests = fakeAi((_) => ok({'correct': true}));
      expect(await QuestionService.gradeAnswer(saq, 'epi pen drug'), isTrue);
      expect(requests, hasLength(1));
    });

    test('paid plans: an AI failure keeps the phone\'s verdict', () async {
      Entitlements.instance.setForTest(PlanLevel.ultra);
      fakeAi((_) => ok({'nonsense': 1}));
      expect(await QuestionService.gradeAnswer(saq, 'epi pen drug'), isFalse);
    });

    for (final level in [PlanLevel.guest, PlanLevel.free]) {
      test('${level.name}: the phone\'s verdict is final', () async {
        Entitlements.instance.setForTest(level);
        final requests = fakeAi((_) => ok({'correct': true}));
        expect(await QuestionService.gradeAnswer(saq, 'epi pen drug'), isFalse);
        expect(await QuestionService.gradeAnswer(saq, 'epinephrine'), isTrue);
        expect(requests, isEmpty, reason: 'the AI server is never called');
      });
    }

    test('MCQs are never sent to the AI', () async {
      const mcq = Question(
        id: 'm',
        topic: 'ANS',
        type: QuestionType.mcq,
        questionText: 'Pick',
        options: ['Liver', 'Kidney'],
        correctAnswer: 'Liver',
      );
      final requests = fakeAi((_) => ok({'correct': true}));
      expect(await QuestionService.gradeAnswer(mcq, 'Kidney'), isFalse);
      expect(await QuestionService.gradeAnswer(mcq, 'liver'), isTrue);
      expect(requests, isEmpty);
    });

    test('a typo that spells another answer in the bank is refused', () async {
      Entitlements.instance.setForTest(PlanLevel.free);
      final topic = (await QuestionRepository.getTopics()).first;
      Question drug(String id, String name) => Question(
        id: id,
        topicId: topic.id,
        topic: topic.name,
        type: QuestionType.saq,
        questionText: 'Which drug is $id?',
        correctAnswer: name,
      );
      const target = 'Cefalotin';
      await QuestionRepository.addQuestion(drug('one', target));
      expect(
        await QuestionService.gradeAnswer(drug('one', target), 'cefalexin'),
        isTrue,
        reason: 'one typo, and no other answer is spelled that way',
      );
      await QuestionRepository.addQuestion(drug('two', 'Cefalexin'));
      expect(
        await QuestionService.gradeAnswer(drug('one', target), 'cefalexin'),
        isFalse,
      );
      expect(
        await QuestionService.gradeAnswer(drug('one', target), 'cefalotn'),
        isTrue,
      );
    });
  });

  group('the AI client refuses plans without the AI', () {
    for (final level in [PlanLevel.guest, PlanLevel.free]) {
      test(level.name, () async {
        Entitlements.instance.setForTest(level);
        final requests = fakeAi((_) => ok({'correct': true}));
        final isPro = isA<AiException>().having(
          (e) => e.message,
          'message',
          'AI is part of Pro.',
        );
        await expectLater(
          AiClient.grade(question: 'q', correctAnswer: 'a', userAnswer: 'b'),
          throwsA(isPro),
        );
        await expectLater(AiClient.generate('x', count: 1), throwsA(isPro));
        await expectLater(
          AiClient.feedback(
            question: 'q',
            options: const [],
            correctAnswer: 'a',
            explanation: '',
            userAnswer: 'b',
          ),
          throwsA(isPro),
        );
        expect(requests, isEmpty);
      });
    }
  });

  test('"mute right and wrong sounds" is saved and read back', () async {
    expect(await SoundPrefs.load(), isFalse);
    await SoundPrefs.setMuteAnswerSounds(true);
    expect(SoundPrefs.muteAnswerSounds, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('muteAnswerSounds'), isTrue);
    await resetApp(prefs: {'muteAnswerSounds': true});
    expect(await SoundPrefs.load(), isTrue);
    await resetApp();
    expect(await SoundPrefs.load(), isFalse);
  });
}
