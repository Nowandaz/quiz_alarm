import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/alarm_provider.dart';
import 'package:quiz_alarm/services/question_service.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:quiz_alarm/widgets/app_widgets.dart';

void main() {
  group('calculateNextTrigger', () {
    // Friday 13 Nov 2026, 10:00
    final now = DateTime(2026, 11, 13, 10, 0);

    test('ring-once, time already passed today -> tomorrow', () {
      expect(
        calculateNextTrigger(
          const TimeOfDay(hour: 9, minute: 0),
          const [],
          now,
        ),
        DateTime(2026, 11, 14, 9, 0),
      );
    });

    test('ring-once, time later today -> today', () {
      expect(
        calculateNextTrigger(
          const TimeOfDay(hour: 11, minute: 0),
          const [],
          now,
        ),
        DateTime(2026, 11, 13, 11, 0),
      );
    });

    test('repeating on Mondays -> next Monday', () {
      expect(
        calculateNextTrigger(const TimeOfDay(hour: 11, minute: 0), const [
          1,
        ], now),
        DateTime(2026, 11, 16, 11, 0),
      );
    });

    test('exactly now counts as passed -> next matching day', () {
      expect(
        calculateNextTrigger(const TimeOfDay(hour: 10, minute: 0), const [
          5,
        ], now),
        DateTime(2026, 11, 20, 10, 0),
      );
    });
  });

  test('formatClock follows the 12 / 24 hour setting', () {
    final evening = DateTime(2026, 11, 13, 18, 5);
    expect(formatClock(evening, use24Hour: true), '18:05');
    expect(formatClock(evening, use24Hour: false), '6:05 PM');
    expect(
      formatTimeOfDay(const TimeOfDay(hour: 0, minute: 30), use24Hour: true),
      '00:30',
    );
    expect(
      formatTimeOfDay(const TimeOfDay(hour: 0, minute: 30), use24Hour: false),
      '12:30 AM',
    );
  });

  test('greetings follow the time of day', () {
    expect(greetingFor(2), 'Hello, night owl');
    expect(greetingFor(2, waking: true), 'Hello, early bird');
    expect(greetingFor(7), 'Good morning');
    expect(greetingFor(13), 'Good afternoon');
    expect(greetingFor(18), 'Good evening');
    expect(greetingFor(22), 'Good night');
  });

  test('plural adds an s except for one', () {
    expect(plural(1, 'topic'), '1 topic');
    expect(plural(0, 'question'), '0 questions');
    expect(plural(12, 'question'), '12 questions');
  });

  test('describeDay and describeAlarmSet say when an alarm rings', () {
    // Friday 13 Nov 2026, 23:30
    final now = DateTime(2026, 11, 13, 23, 30);
    expect(describeDay(DateTime(2026, 11, 13, 23, 45), now), 'today');
    // Half an hour away, but on the next calendar day.
    expect(describeDay(DateTime(2026, 11, 14, 0, 0), now), 'tomorrow');
    expect(describeDay(DateTime(2026, 11, 14, 23, 59), now), 'tomorrow');
    expect(describeDay(DateTime(2026, 11, 15, 7, 0), now), 'Sunday');
    expect(describeDay(DateTime(2026, 11, 16, 7, 0), now), 'Monday');

    expect(
      describeAlarmSet(DateTime(2026, 11, 14, 8, 13), now, use24Hour: false),
      'Alarm set for tomorrow 8:13 AM, in 8 hours 43 minutes',
    );
    expect(
      describeAlarmSet(DateTime(2026, 11, 15, 20, 5), now, use24Hour: true),
      'Alarm set for Sunday 20:05, in 1 day 20 hours',
    );
  });

  group('describeTimeUntil', () {
    final now = DateTime(2026, 11, 13, 10, 0);
    test('minutes, hours and days', () {
      expect(
        describeTimeUntil(now.add(const Duration(seconds: 20)), now),
        'in less than a minute',
      );
      expect(
        describeTimeUntil(now.add(const Duration(minutes: 5)), now),
        'in 5 minutes',
      );
      expect(
        describeTimeUntil(now.add(const Duration(hours: 1, minutes: 1)), now),
        'in 1 hour 1 minute',
      );
      expect(
        describeTimeUntil(now.add(const Duration(days: 3, hours: 1)), now),
        'in 3 days 1 hour',
      );
    });
  });

  group('answersMatch (local marking)', () {
    test('a single letter never passes', () {
      expect(answersMatch('n', 'Naloxone'), isFalse);
      expect(answersMatch('a', 'Aspirin'), isFalse);
      expect(answersMatch('', 'Naloxone'), isFalse);
    });

    test('a fragment of the answer does not pass', () {
      expect(answersMatch('nal', 'Naloxone'), isFalse);
      expect(answersMatch('beta', 'Beta blocker'), isFalse);
    });

    test('exact, case and punctuation differences pass', () {
      expect(answersMatch('naloxone', 'Naloxone'), isTrue);
      expect(answersMatch('  NALOXONE. ', 'Naloxone'), isTrue);
      expect(answersMatch('beta lactams', 'Beta-lactams'), isTrue);
    });

    test('extra words around the answer pass', () {
      expect(answersMatch('it is naloxone', 'Naloxone'), isTrue);
    });

    test('small typos on longer words pass', () {
      expect(answersMatch('naloxon', 'Naloxone'), isTrue);
      expect(answersMatch('mitocondria', 'Mitochondria'), isTrue);
    });

    test('wrong answers fail', () {
      expect(answersMatch('naltrexone', 'Naloxone'), isFalse);
      expect(answersMatch('flumazenil', 'Naloxone'), isFalse);
    });

    test('the examples from the marking rules', () {
      expect(answersMatch('paracetemol', 'Paracetamol'), isTrue);
      expect(answersMatch('adrenalin', 'Adrenaline'), isTrue);
      expect(answersMatch('warfrin', 'Warfarin'), isTrue);
      expect(answersMatch('asprin', 'Aspirin'), isTrue);
      expect(answersMatch('mitochondrion', 'Mitochondria'), isTrue);
      expect(answersMatch('n acetyl cysteine', 'N-acetylcysteine'), isTrue);
      expect(answersMatch('cox1', 'COX-1'), isTrue);
      expect(answersMatch('COX-2', 'COX-1'), isFalse);
      expect(answersMatch('IL-2', 'IL-1'), isFalse);
      expect(answersMatch('ACh', 'ACE'), isFalse);
      expect(answersMatch('hyperkalaemia', 'Hypokalaemia'), isFalse);
      expect(normalizeAnswer('  N-Acetyl  CYSTEINE! '), 'n acetyl cysteine');
    });
  });

  group('isLocallyCorrect', () {
    const saq = Question(
      id: 'q',
      topic: 'ANS',
      type: QuestionType.saq,
      questionText: 'First-line drug for anaphylaxis?',
      correctAnswer: 'Adrenaline',
      altAnswers: ['Epinephrine', 'B6'],
    );
    const mcq = Question(
      id: 'm',
      topic: 'ANS',
      type: QuestionType.mcq,
      questionText: 'Pick',
      options: ['Liver', 'Kidney', 'Lungs', 'Spleen'],
      correctAnswer: 'Liver',
    );

    test('accepted alternatives count for typed answers', () {
      expect(isLocallyCorrect(saq, 'epinephrine'), isTrue);
      expect(isLocallyCorrect(saq, 'IM adrenaline'), isTrue);
      expect(isLocallyCorrect(saq, 'b6'), isTrue); // short but exact
      expect(isLocallyCorrect(saq, 'atropine'), isFalse);
      expect(isLocallyCorrect(saq, ''), isFalse);
    });

    test('MCQ needs the exact option', () {
      expect(isLocallyCorrect(mcq, 'liver'), isTrue);
      expect(isLocallyCorrect(mcq, 'Kidney'), isFalse);
    });

    test('certainVerdict: the phone marks first, the rest is left open', () {
      expect(QuestionService.certainVerdict(mcq, 'Kidney'), isFalse);
      expect(QuestionService.certainVerdict(saq, 'Adrenaline'), isTrue);
      // A small typo is now marked right on the phone (it used to be
      // left to the AI).
      expect(
        QuestionService.certainVerdict(saq, 'adrenalin injection'),
        isTrue,
      );
      // Only an answer the phone cannot match is left for the AI.
      expect(QuestionService.certainVerdict(saq, 'atropine'), isNull);
      expect(QuestionService.certainVerdict(saq, ''), isFalse);
    });

    test('gradeLocally says which spelling was meant', () {
      final typo = gradeLocally(saq, 'epinefrine');
      expect(typo.correct, isTrue);
      expect(typo.hint, 'Spelling: Epinephrine');
      expect(gradeLocally(saq, 'Adrenaline').hint, isNull);
      expect(gradeLocally(mcq, 'liver').exact, isTrue);
      expect(gradeLocally(mcq, 'livr').correct, isFalse);
    });
  });

  group('validateGenerated (AI question checks)', () {
    const topic = Topic(id: 't1', unitId: 'u1', name: 'Antimicrobials');
    Map<String, dynamic> mcq(List<String> options, String answer) => {
      'type': 'mcq',
      'questionText': 'Pick one',
      'options': options,
      'correctAnswer': answer,
      'explanation': 'Because.',
    };

    test('accepts a valid MCQ and keeps the right answer after shuffling', () {
      final q = QuestionService.validateGenerated(
        mcq(['A1', 'B2', 'C3', 'D4', 'E5'], 'c3'),
        topic,
        rng: Random(1),
      );
      expect(q, isNotNull);
      expect(q!.options.toSet(), {'A1', 'B2', 'C3', 'D4', 'E5'});
      expect(q.correctAnswer, 'C3');
      expect(q.topicId, 't1');
      expect(q.explanation, 'Because.');
      expect(q.source, 'ai');
    });

    test('rejects an answer that is not among the options', () {
      expect(
        QuestionService.validateGenerated(
          mcq(['A', 'B', 'C', 'D', 'E'], 'F'),
          topic,
        ),
        isNull,
      );
    });

    test('rejects the wrong number of options or duplicates', () {
      expect(
        QuestionService.validateGenerated(
          mcq(['A', 'B', 'C', 'D'], 'A'),
          topic,
        ),
        isNull,
      );
      expect(
        QuestionService.validateGenerated(
          mcq(['A', 'a', 'C', 'D', 'E'], 'A'),
          topic,
        ),
        isNull,
      );
    });

    test('rejects empty text or non-map data', () {
      expect(QuestionService.validateGenerated('nope', topic), isNull);
      expect(
        QuestionService.validateGenerated({
          'questionText': ' ',
          'correctAnswer': 'x',
        }, topic),
        isNull,
      );
    });

    test('accepts a valid SAQ with accepted answers', () {
      final q = QuestionService.validateGenerated({
        'type': 'saq',
        'questionText': 'Antidote for opioids?',
        'options': [],
        'correctAnswer': 'Naloxone',
        'acceptedAnswers': ['Narcan', 'Naloxone'],
      }, topic);
      expect(q!.type, QuestionType.saq);
      expect(q.altAnswers, ['Narcan']);
    });

    test('questionItems copes with every reply shape', () {
      expect(QuestionService.questionItems([1, 2]), [1, 2]);
      expect(
        QuestionService.questionItems({
          'questions': [1],
        }),
        [1],
      );
      expect(QuestionService.questionItems({'questionText': 'x'}).length, 1);
      expect(QuestionService.questionItems('text'), isEmpty);
    });
  });
}
