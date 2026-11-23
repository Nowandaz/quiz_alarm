/// Marks a "long answer" (a question that wants several things, such as
/// "List 4 aims of pre-anaesthetic medication") on the phone. Pure Dart.
///
/// The question carries key points, each with the wordings that count
/// for it. A point is had when any of its wordings is somewhere in the
/// typed text, matched the tolerant way [AnswerGrader] matches short
/// answers. Each point counts once, and the score never passes the
/// question's marks, so "any 4 of these 6" works by listing 6 points on
/// a 4-mark question.
library;

import 'dart:math';

import 'answer_grader.dart';

/// The outcome of marking one long answer.
class LongAnswerResult {
  /// Marks earned: points had, at most [marks].
  final int score;

  /// What the question is worth.
  final int marks;

  /// The points the answer had and those it did not, each shown by its
  /// first wording.
  final List<String> found;
  final List<String> missed;

  /// True when the question has no key points, so the phone cannot mark
  /// it: the user compares with the model answer and marks it themselves.
  final bool selfMarked;

  const LongAnswerResult({
    required this.score,
    required this.marks,
    this.found = const [],
    this.missed = const [],
    this.selfMarked = false,
  });

  /// Full marks. This is what streaks, statistics and history count.
  bool get correct => !selfMarked && score >= marks;
}

class LongAnswerGrader {
  /// Marks [user] against [keyPoints] for a question worth [marks].
  static LongAnswerResult grade(
    String user, {
    required List<List<String>> keyPoints,
    required int marks,
  }) {
    final worth = max(1, marks);
    final points = [
      for (final p in keyPoints)
        if (p.any((w) => w.trim().isNotEmpty)) p,
    ];
    if (points.isEmpty) {
      return LongAnswerResult(score: 0, marks: worth, selfMarked: true);
    }
    final had = AnswerGrader.pointsIn(user, points);
    final found = <String>[];
    final missed = <String>[];
    for (final (i, p) in points.indexed) {
      (had[i] ? found : missed).add(p.firstWhere((w) => w.trim().isNotEmpty));
    }
    return LongAnswerResult(
      score: min(found.length, worth),
      marks: worth,
      found: found,
      missed: missed,
    );
  }
}
