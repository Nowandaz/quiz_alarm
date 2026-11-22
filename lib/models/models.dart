/// Data classes shared across the app: study units, topics, questions
/// and alarms.
library;

import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

enum QuestionType { mcq, saq }

/// A course unit, e.g. "Pharmacology". Holds several [Topic]s.
class StudyUnit {
  final String id;
  final String name;
  final String description;

  const StudyUnit({
    required this.id,
    required this.name,
    this.description = '',
  });
}

/// A subtopic inside a unit, e.g. "Antimicrobials".
class Topic {
  final String id;
  final String unitId;
  final String name;
  final bool isCustom;

  /// For a topic the user made: what it should cover (learning
  /// objectives). Given to the AI when it writes questions.
  final String description;

  /// Who may open the topic: 'guest' (anyone), 'free' (anyone with an
  /// account) or 'paid' (see TopicAccess in services/entitlements.dart).
  /// A topic the user made counts as 'free' whatever is stored here.
  final String access;

  const Topic({
    required this.id,
    required this.unitId,
    required this.name,
    this.isCustom = false,
    this.description = '',
    this.access = 'paid',
  });
}

/// How the user is doing on one topic.
class TopicStats {
  /// Questions stored for the topic.
  final int total;

  /// Questions answered at least once.
  final int seen;

  /// Questions whose most recent answer was correct.
  final int mastered;

  const TopicStats({this.total = 0, this.seen = 0, this.mastered = 0});

  int get unseen => total - seen;
}

class Question {
  final String id;

  /// Id of the [Topic] this question belongs to.
  final String topicId;

  /// Topic name, kept on the question so screens can show it directly.
  final String topic;
  final QuestionType type;
  final String questionText;
  final List<String> options;
  final String correctAnswer;

  /// Other spellings / names that also count as correct for typed answers
  /// (e.g. "Epinephrine" for "Adrenaline").
  final List<String> altAnswers;

  /// Picture the question is about (spotter questions): an asset path or
  /// a web address. Empty for ordinary questions.
  final String image;

  /// Why the answer is right. Stored so explanations work offline.
  final String explanation;

  /// Where the question came from: 'seed' (bundled with the app),
  /// 'server' (downloaded bank), 'ai' or 'user'.
  final String source;

  const Question({
    required this.id,
    this.topicId = '',
    required this.topic,
    required this.type,
    required this.questionText,
    this.options = const [],
    required this.correctAnswer,
    this.altAnswers = const [],
    this.image = '',
    this.explanation = '',
    this.source = 'seed',
  });

  /// The same question with its options in a new random order, so the
  /// right answer is not always in the same place.
  Question shuffled([Random? rng]) =>
      copyWith(options: List<String>.of(options)..shuffle(rng ?? Random()));

  Question copyWith({String? explanation, List<String>? options}) => Question(
    id: id,
    topicId: topicId,
    topic: topic,
    type: type,
    questionText: questionText,
    options: options ?? this.options,
    correctAnswer: correctAnswer,
    altAnswers: altAnswers,
    image: image,
    explanation: explanation ?? this.explanation,
    source: source,
  );

  /// Reads a row of the `questions` table joined with its topic name.
  factory Question.fromRow(Map<String, Object?> row) {
    List<String> list(Object? raw) {
      try {
        return List<String>.from(jsonDecode(raw as String) as List);
      } catch (_) {
        return const [];
      }
    }

    return Question(
      id: row['id'] as String,
      topicId: row['topic_id'] as String,
      topic: (row['topic_name'] ?? '') as String,
      type: row['type'] == 'mcq' ? QuestionType.mcq : QuestionType.saq,
      questionText: row['text'] as String,
      options: list(row['options']),
      correctAnswer: row['answer'] as String,
      altAnswers: list(row['alt_answers']),
      image: (row['image'] ?? '') as String,
      explanation: (row['explanation'] ?? '') as String,
      source: (row['source'] ?? 'seed') as String,
    );
  }
}

/// One alarm ring or practice session, for the reports.
class StudySession {
  final int id;

  /// 'alarm', 'revision' or 'bank'.
  final String kind;
  final String title;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// 'dismissed', 'snoozed', 'finished', or null if it was cut short.
  final String? outcome;
  final int? requiredStreak;
  final int questions;
  final int correct;

  const StudySession({
    required this.id,
    required this.kind,
    required this.title,
    required this.startedAt,
    this.endedAt,
    this.outcome,
    this.requiredStreak,
    this.questions = 0,
    this.correct = 0,
  });

  Duration? get duration => endedAt?.difference(startedAt);
}

/// One answered question inside a session.
class AttemptDetail {
  final Question question;
  final String userAnswer;
  final bool correct;
  final Duration? timeTaken;
  final DateTime answeredAt;

  const AttemptDetail({
    required this.question,
    required this.userAnswer,
    required this.correct,
    required this.answeredAt,
    this.timeTaken,
  });
}

/// Answers given on one calendar day.
class DayStat {
  final DateTime day;
  final int answered;
  final int correct;
  const DayStat(this.day, this.answered, this.correct);
}

/// All-time accuracy on one topic.
class TopicAccuracy {
  /// Id of the topic, so a tap can open practice for it.
  final String id;
  final String topic;
  final int answered;
  final int correct;
  const TopicAccuracy(this.topic, this.answered, this.correct, {this.id = ''});
  double get accuracy => answered == 0 ? 0 : correct / answered;
}

/// How one topic did in the last 14 days and in the 14 days before.
class TopicTrend {
  final String id;
  final String topic;
  final int answered;
  final int correct;
  final int previousAnswered;
  final int previousCorrect;
  const TopicTrend({
    required this.id,
    required this.topic,
    this.answered = 0,
    this.correct = 0,
    this.previousAnswered = 0,
    this.previousCorrect = 0,
  });

  double get accuracy => answered == 0 ? 0 : correct / answered;
  double get previousAccuracy =>
      previousAnswered == 0 ? 0 : previousCorrect / previousAnswered;

  /// Percentage points gained (or lost, when negative) between the two
  /// periods.
  int get change => (accuracy * 100).round() - (previousAccuracy * 100).round();
}

/// The "Trends" card of the Reports tab: the last 14 days against the 14
/// days before, this week against last week, and the topics that moved.
class ReportTrends {
  /// A topic needs this many answers in a period before it is compared.
  /// Fewer would make one lucky answer look like progress.
  static const int minAnswers = 5;

  /// Answers in the last 14 days (today included).
  final int answered;
  final int correct;

  /// Answers in the 14 days before those.
  final int previousAnswered;
  final int previousCorrect;

  /// Questions answered since Monday, and in the week before.
  final int thisWeek;
  final int lastWeek;

  /// Monday to Sunday of this week: true on the days something was
  /// answered. Days still to come are false.
  final List<bool> weekDays;

  /// Topics whose accuracy rose most, biggest rise first (up to 3).
  final List<TopicTrend> improving;

  /// Topics with the lowest accuracy in the last 14 days (up to 3).
  final List<TopicTrend> needsRevision;

  const ReportTrends({
    this.answered = 0,
    this.correct = 0,
    this.previousAnswered = 0,
    this.previousCorrect = 0,
    this.thisWeek = 0,
    this.lastWeek = 0,
    this.weekDays = const [false, false, false, false, false, false, false],
    this.improving = const [],
    this.needsRevision = const [],
  });

  /// Accuracy in the last 14 days as a whole percentage, or null when
  /// nothing was answered.
  int? get accuracy =>
      answered == 0 ? null : (correct * 100 / answered).round();

  /// How the last 14 days compare with the 14 days before: "up 8 points
  /// from the 14 days before", "down 5 points from the 14 days before",
  /// "no change from the 14 days before" or, with nothing earlier to
  /// compare with, "first 14 days". Null when nothing was answered.
  String? get comparison {
    final now = accuracy;
    if (now == null) return null;
    if (previousAnswered == 0) return 'first 14 days';
    final diff = now - (previousCorrect * 100 / previousAnswered).round();
    if (diff == 0) return 'no change from the 14 days before';
    final points = '${diff.abs()} point${diff.abs() == 1 ? '' : 's'}';
    return '${diff > 0 ? 'up' : 'down'} $points from the 14 days before';
  }

  /// Days of this week with at least one answer.
  int get daysPractised => weekDays.where((d) => d).length;

  /// True when there is nothing recent to show at all.
  bool get isEmpty =>
      answered == 0 && previousAnswered == 0 && thisWeek == 0 && lastWeek == 0;
}

/// The numbers at the top of the Reports tab.
class ReportSummary {
  final int answered;
  final int correct;
  final int alarmsDismissed;

  /// Average time from the alarm ringing to it being dismissed.
  final Duration? avgWakeTime;

  /// Average number of questions it took to dismiss an alarm.
  final double? avgWakeQuestions;
  final List<DayStat> days;
  final List<TopicAccuracy> topics;
  final ReportTrends trends;

  const ReportSummary({
    this.answered = 0,
    this.correct = 0,
    this.alarmsDismissed = 0,
    this.avgWakeTime,
    this.avgWakeQuestions,
    this.days = const [],
    this.topics = const [],
    this.trends = const ReportTrends(),
  });
}

class AlarmItem {
  final int id; // 32-bit integer required by native Android AlarmManager
  TimeOfDay time;

  /// Topic or unit ids to draw questions from. Empty means "any topic".
  /// (Alarms saved by older versions hold topic names; those still resolve.)
  List<String> topics;
  bool isEnabled;
  List<int> activeDays; // 1 = Mon, 7 = Sun. Empty = ring once.
  String label;
  String audioPath; // Asset path or local storage file path
  bool vibrate;
  double fadeDuration; // Seconds for gradual volume fade-in
  double volume; // 0.0 to 1.0 enforced volume

  /// Correct answers in a row needed to dismiss the alarm
  /// (easy 2, medium 3, hard 5, custom 6 to 15).
  int requiredStreak;

  /// Length of the snooze, in minutes (3, 5 or 10).
  int snoozeMinutes;

  /// Set when the user skipped the next ring of a repeating alarm (from
  /// the heads-up notification): nothing rings up to and including this
  /// moment.
  DateTime? skipUntil;

  static const int minStreak = 1;
  static const int maxStreak = 15;
  static const List<int> snoozeChoices = [3, 5, 10];

  /// Wrong answers in a row before the snooze button appears while an
  /// alarm rings. One number for the ring screen and the editor's text.
  static const int wrongAnswersForSnooze = 5;

  /// Streaks of the named difficulties. Anything else is "Custom".
  static const int easyStreak = 2;
  static const int mediumStreak = 3;
  static const int hardStreak = 5;
  static const List<int> presetStreaks = [easyStreak, mediumStreak, hardStreak];

  /// The range the "Custom" slider offers.
  static const int customMinStreak = 6;
  static const int customMaxStreak = maxStreak;

  /// "Easy", "Medium", "Hard" or "Custom" for [streak].
  static String difficultyName(int streak) => switch (streak) {
    easyStreak => 'Easy',
    mediumStreak => 'Medium',
    hardStreak => 'Hard',
    _ => 'Custom',
  };

  /// What a difficulty asks for, said before the alarm is saved:
  /// "3 correct answers in a row to stop the alarm."
  static String difficultyMeaning(int streak) =>
      '$streak correct answers in a row to stop the alarm.';

  /// A rough idea of how long that takes, or '' where it is neither
  /// quick nor long.
  static String difficultyEffort(int streak) => streak <= easyStreak
      ? 'About a minute.'
      : streak >= hardStreak
      ? 'Expect a few minutes.'
      : '';

  /// The days an alarm rings on, in a few words: "Once", "Every day",
  /// "Weekdays", "Weekends" or "Mon, Wed, Fri".
  static String describeDays(List<int> activeDays) {
    final days = activeDays.toSet().toList()..sort();
    if (days.isEmpty) return 'Once';
    if (days.length == 7) return 'Every day';
    if (days.join() == '12345') return 'Weekdays';
    if (days.join() == '67') return 'Weekends';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days.map((d) => names[d - 1]).join(', ');
  }

  AlarmItem({
    required this.id,
    required this.time,
    required this.topics,
    this.isEnabled = true,
    this.activeDays = const [1, 2, 3, 4, 5, 6, 7],
    this.label = 'Quiz Alarm',
    this.audioPath = 'assets/sounds/alarm.mp3',
    this.vibrate = true,
    this.fadeDuration = 5.0,
    this.volume = 1.0,
    this.requiredStreak = 2,
    this.snoozeMinutes = 5,
    this.skipUntil,
  });

  /// A random id that is not in [taken].
  static int generateSafeId([Iterable<int> taken = const []]) {
    final used = taken.toSet();
    final rng = Random();
    while (true) {
      final id = rng.nextInt(900000) + 100000;
      if (!used.contains(id)) return id;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': time.hour,
    'minute': time.minute,
    'topics': topics,
    'isEnabled': isEnabled,
    'activeDays': activeDays,
    'label': label,
    'audioPath': audioPath,
    'vibrate': vibrate,
    'fadeDuration': fadeDuration,
    'volume': volume,
    'requiredStreak': requiredStreak,
    'snoozeMinutes': snoozeMinutes,
    'skipUntil': ?skipUntil?.millisecondsSinceEpoch,
  };

  factory AlarmItem.fromJson(Map<String, dynamic> json) => AlarmItem(
    id: json['id'] is int
        ? json['id']
        : int.tryParse(json['id'].toString()) ?? generateSafeId(),
    time: TimeOfDay(hour: json['hour'], minute: json['minute']),
    topics: List<String>.from(json['topics'] ?? []),
    isEnabled: json['isEnabled'] ?? true,
    activeDays: List<int>.from(json['activeDays'] ?? [1, 2, 3, 4, 5, 6, 7]),
    label: json['label'] ?? 'Quiz Alarm',
    audioPath: json['audioPath'] ?? 'assets/sounds/alarm.mp3',
    vibrate: json['vibrate'] ?? true,
    fadeDuration: (json['fadeDuration'] ?? 5.0).toDouble(),
    volume: (json['volume'] ?? 1.0).toDouble(),
    requiredStreak: ((json['requiredStreak'] ?? 2) as num).toInt().clamp(
      minStreak,
      maxStreak,
    ),
    snoozeMinutes: snoozeChoices.contains(json['snoozeMinutes'])
        ? json['snoozeMinutes'] as int
        : 5,
    skipUntil: json['skipUntil'] is int
        ? DateTime.fromMillisecondsSinceEpoch(json['skipUntil'] as int)
        : null,
  );
}
