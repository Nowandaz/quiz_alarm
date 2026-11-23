/// Question logic on top of the database: choosing the next question,
/// marking answers (locally, or with the AI for typed answers), AI tutor
/// feedback, and generating new questions with explanations.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_database.dart';
import '../data/question_repository.dart';
import '../models/models.dart';
import 'ai_client.dart';
import 'answer_grader.dart';
import 'entitlements.dart';
import 'long_answer_grader.dart';

export 'long_answer_grader.dart' show LongAnswerResult;
export 'answer_grader.dart' show GradeResult;

// ---------------------------------------------------------------------------
// Answer matching (works offline; the rules are in answer_grader.dart)
// ---------------------------------------------------------------------------

/// Lowercase, no accents, punctuation as spaces, single spaces.
String normalizeAnswer(String s) => AnswerGrader.normalizeText(s);

/// True if the typed [user] answer says [correct] (small typos allowed).
bool answersMatch(String user, String correct) =>
    AnswerGrader.grade(user, correct).correct;

/// Marks [userAnswer] without the network, with the details (which part
/// is missing, the right spelling). MCQs need the exact option; typed
/// answers go through [AnswerGrader].
GradeResult gradeLocally(Question q, String userAnswer) {
  final user = userAnswer.trim();
  if (user.isEmpty) return GradeResult.wrong;
  if (q.type == QuestionType.mcq) {
    final right = user.toLowerCase() == q.correctAnswer.trim().toLowerCase();
    return GradeResult(correct: right, exact: right);
  }
  return AnswerGrader.grade(user, q.correctAnswer, alts: q.altAnswers);
}

/// [gradeLocally], as a plain yes or no.
bool isLocallyCorrect(Question q, String userAnswer) =>
    gradeLocally(q, userAnswer).correct;

/// What the AI tutor said about one answer.
class AiFeedback {
  final bool correct;
  final String feedback;
  const AiFeedback({required this.correct, required this.feedback});
}

/// Outcome of asking the AI for new questions.
class GenerationResult {
  final int added;
  final String? error;

  /// The new questions that were stored.
  final List<Question> questions;
  const GenerationResult({
    this.added = 0,
    this.error,
    this.questions = const [],
  });
}

class QuestionService {
  static const String _statusPref = 'ai_last_status';

  /// Bumped whenever questions are added or removed, so open screens can
  /// refresh their counts.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  // ------------------------------------------------------------- selection

  /// Next question for [selectors] (topic/unit ids; empty = any topic),
  /// from the local database only. Null when the bank is empty.
  /// [longAnswers] false leaves out long answer questions (an alarm never
  /// asks one); by default only an alarm ([repeat]) leaves them out.
  static Future<Question?> nextQuestion(
    List<String> selectors, {
    Set<String> exclude = const {},
    bool repeat = true,
    bool? longAnswers,
  }) async {
    final ids = await QuestionRepository.resolveTopicIds(selectors);
    return QuestionRepository.pickNext(
      ids,
      exclude: exclude,
      repeat: repeat,
      longAnswers: longAnswers,
    );
  }

  // --------------------------------------------------------------- grading

  /// Whether the AI may be asked at all: signed in and on a paid plan.
  static bool get canUseAi =>
      AiClient.available && Entitlements.instance.canUseAi;

  /// Marks an answer when an alarm is ringing: fast and never blocked by
  /// the network for long. The phone marks it first. Only when that says
  /// "wrong" for a typed answer, and the plan includes the AI, is the AI
  /// asked (5 s limit); for everyone else the phone's verdict stands.
  static Future<GradeResult> grade(Question q, String userAnswer) async {
    final local = await gradeLocal(q, userAnswer);
    if (local.correct ||
        q.type == QuestionType.mcq ||
        !canUseAi ||
        normalizeAnswer(userAnswer).length < 3) {
      return local;
    }
    try {
      final right = await AiClient.grade(
        question: q.questionText,
        correctAnswer: q.correctAnswer,
        userAnswer: userAnswer.trim(),
        timeout: const Duration(seconds: 5),
      );
      if (right) return const GradeResult(correct: true);
    } catch (e) {
      debugPrint('AI grading failed, keeping the local verdict: $e');
    }
    return local;
  }

  /// [grade], as a plain yes or no.
  static Future<bool> gradeAnswer(Question q, String userAnswer) async =>
      (await grade(q, userAnswer)).correct;

  /// Marks an answer on the phone only. Like [gradeLocally], but first
  /// makes sure the other answers in the bank are known, so a typo that
  /// spells a different answer is not forgiven.
  static Future<GradeResult> gradeLocal(Question q, String userAnswer) async {
    if (q.type != QuestionType.mcq && userAnswer.trim().isNotEmpty) {
      await _loadKnownTerms();
    }
    return gradeLocally(q, userAnswer);
  }

  /// Marks a long answer on the phone: how many of the question's key
  /// points the typed text has.
  static Future<LongAnswerResult> gradeLong(
    Question q,
    String userAnswer,
  ) async {
    if (userAnswer.trim().isNotEmpty) await _loadKnownTerms();
    return LongAnswerGrader.grade(
      userAnswer,
      keyPoints: q.keyPoints,
      marks: q.marks,
    );
  }

  static int _knownFor = -1;

  /// Fills [AnswerGrader.knownTerms] with every answer, alternative and
  /// option in the bank. Read again only when the bank has changed size.
  static Future<void> _loadKnownTerms() async {
    try {
      final db = await AppDatabase.instance;
      final count =
          (await db.rawQuery('SELECT COUNT(*) AS n FROM questions')).first['n']
              as int;
      if (count == _knownFor) return;
      final terms = <String>{};
      void add(String key) {
        // Shorter words get no typo allowance, so they cannot collide.
        if (key.length >= 5) terms.add(key);
      }

      List<String> list(Object? json) {
        try {
          return [for (final e in jsonDecode('$json') as List) '$e'];
        } catch (_) {
          return const [];
        }
      }

      for (final row in await db.rawQuery(
        'SELECT answer, alt_answers, options FROM questions',
      )) {
        final forms = AnswerGrader.buildForms(
          '${row['answer']}',
          list(row['alt_answers']),
        );
        for (final form in forms) {
          for (final concept in form.concepts) {
            concept.keys.forEach(add);
          }
        }
        for (final option in list(row['options'])) {
          add(AnswerGrader.termKey(option));
        }
      }
      AnswerGrader.knownTerms = terms;
      _knownFor = count;
    } catch (e) {
      debugPrint('Could not read the bank\'s answers: $e');
    }
  }

  /// Whether the app can mark [userAnswer] by itself without any doubt.
  /// Null means "a typed answer the phone could not match": the AI may
  /// judge it when the plan includes it, otherwise it is wrong.
  static bool? certainVerdict(Question q, String userAnswer) {
    if (userAnswer.trim().isEmpty) return false;
    final local = isLocallyCorrect(q, userAnswer);
    if (q.type == QuestionType.mcq || local) return local;
    return null;
  }

  /// Asks the AI tutor to explain an answer: where the student went wrong
  /// and why the right answer is right. An empty [userAnswer] means the
  /// student chose "I don't know".
  ///
  /// [knownVerdict] is passed when the app already knows whether the answer
  /// is right (MCQs, exact matches); otherwise the AI decides.
  /// If the question had no stored explanation, the AI writes one and it
  /// is saved for offline use. Throws [AiException] on failure.
  static Future<AiFeedback> aiFeedback(
    Question q,
    String userAnswer, {
    bool? knownVerdict,
  }) async {
    final user = userAnswer.trim();
    final needExplanation = q.explanation.trim().isEmpty;
    final data = await AiClient.feedback(
      question: q.questionText,
      options: q.options,
      correctAnswer: q.correctAnswer,
      explanation: q.explanation,
      userAnswer: user,
      knownVerdict: knownVerdict,
    );
    if ('${data['feedback'] ?? ''}'.trim().isEmpty) {
      throw const AiException('The AI reply had no feedback in it.');
    }

    final explanation = '${data['explanation'] ?? ''}'.trim();
    if (needExplanation && explanation.isNotEmpty) {
      await QuestionRepository.setExplanation(q.id, explanation);
    }
    final verdict = user.isEmpty
        ? false
        : knownVerdict ??
              (data['correct'] is bool
                  ? data['correct'] as bool
                  : isLocallyCorrect(q, user));
    return AiFeedback(correct: verdict, feedback: '${data['feedback']}'.trim());
  }

  // ------------------------------------------------------------ generation

  static int _idCounter = 0;

  /// Options every multiple-choice question has.
  static const int optionCount = 5;

  /// Checks one AI-written question. Returns null if it is unusable.
  /// For MCQs: exactly 5 distinct non-empty options and the correct answer
  /// must be one of them. Options are shuffled so the answer is not
  /// always in the same slot.
  static Question? validateGenerated(dynamic data, Topic topic, {Random? rng}) {
    if (data is! Map) return null;
    final text = '${data['questionText'] ?? data['text'] ?? ''}'.trim();
    final answer = '${data['correctAnswer'] ?? data['answer'] ?? ''}'.trim();
    if (text.isEmpty || answer.isEmpty) return null;
    final explanation = '${data['explanation'] ?? ''}'.trim();
    final id = 'ai_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

    final raw = data['options'];
    final options = raw is List
        ? raw.map((e) => e.toString().trim()).toList()
        : <String>[];
    final type = '${data['type'] ?? ''}'.toLowerCase();
    final isMcq = type == 'mcq' || (type != 'saq' && options.isNotEmpty);

    if (!isMcq) {
      final rawAlts = data['alt_answers'] ?? data['acceptedAnswers'];
      final alts = rawAlts is List
          ? rawAlts
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty && e != answer)
                .toList()
          : <String>[];
      return Question(
        id: id,
        topicId: topic.id,
        topic: topic.name,
        type: QuestionType.saq,
        questionText: text,
        correctAnswer: answer,
        altAnswers: alts,
        explanation: explanation,
        source: 'ai',
      );
    }

    if (options.length != optionCount || options.any((o) => o.isEmpty)) {
      return null;
    }
    if (options.map((o) => o.toLowerCase()).toSet().length != optionCount) {
      return null;
    }
    final idx = options.indexWhere(
      (o) => o.toLowerCase() == answer.toLowerCase(),
    );
    if (idx == -1) return null;

    final canonical = options[idx];
    options.shuffle(rng ?? Random());
    return Question(
      id: id,
      topicId: topic.id,
      topic: topic.name,
      type: QuestionType.mcq,
      questionText: text,
      options: options,
      correctAnswer: canonical,
      explanation: explanation,
      source: 'ai',
    );
  }

  /// Pulls the list of question objects out of whatever shape the model
  /// used: {"questions": [...]}, a bare list, or a single object.
  @visibleForTesting
  static List<dynamic> questionItems(dynamic data) {
    if (data is List) return data;
    if (data is Map) {
      for (final key in const ['questions', 'items', 'data']) {
        if (data[key] is List) return data[key] as List;
      }
      return [data];
    }
    return const [];
  }

  /// Asks the AI for [count] new questions (with explanations) on [topic]
  /// and stores the valid, non-duplicate ones.
  static Future<GenerationResult> generateForTopic(
    Topic topic, {
    int count = 5,
  }) async {
    await QuestionRepository.ensureReady();
    final units = await QuestionRepository.getUnits();
    final unitName = units
        .where((u) => u.id == topic.unitId)
        .map((u) => u.name)
        .firstWhere((_) => true, orElse: () => '');
    final subject =
        (unitName.isEmpty || topic.unitId == QuestionRepository.customUnitId)
        ? topic.name
        : '$unitName - ${topic.name}';
    final existing = (await QuestionRepository.getQuestions(topic.id))
        .map((q) => q.questionText)
        .toList();
    final avoid = existing.length > 40
        ? existing.sublist(existing.length - 40)
        : existing;

    try {
      final items = questionItems(
        await AiClient.generate(
          subject,
          count: count,
          avoid: avoid,
          objectives: topic.description,
        ),
      );
      final stored = <Question>[];
      for (final item in items) {
        final q = validateGenerated(item, topic);
        if (q != null && await QuestionRepository.addQuestion(q)) stored.add(q);
      }
      final added = stored.length;
      if (added > 0) changes.value++;
      if (added == 0) {
        return GenerationResult(
          error: items.isEmpty
              ? 'The AI reply contained no questions.'
              : 'The AI wrote ${items.length} question(s) but none were usable '
                    '(invalid or already in the bank).',
        );
      }
      return GenerationResult(added: added, questions: stored);
    } catch (e) {
      return GenerationResult(error: e.toString());
    }
  }

  /// Writes about [count] brand-new questions for a practice session,
  /// spread over [topicIds] (at most three topics per call, to keep the
  /// number of AI requests small). The questions are saved to the bank
  /// too. [error] is set if nothing could be written.
  static Future<GenerationResult> generateFresh(
    List<String> topicIds, {
    required int count,
    Random? rng,
  }) async {
    if (!canUseAi) {
      return GenerationResult(
        error: AiClient.available ? AiClient.proHint : AiClient.signInHint,
      );
    }
    final wanted = topicIds.toSet();
    final topics =
        (await QuestionRepository.getTopics())
            .where((t) => wanted.isEmpty || wanted.contains(t.id))
            .toList()
          ..shuffle(rng ?? Random());
    if (topics.isEmpty) {
      return const GenerationResult(error: 'No topics were selected.');
    }
    final chosen = topics.take(3).toList();
    final per = (count / chosen.length).ceil();

    final all = <Question>[];
    String? error;
    for (final topic in chosen) {
      if (all.length >= count) break;
      final r = await generateForTopic(
        topic,
        count: min(per, count - all.length),
      );
      all.addAll(r.questions);
      if (r.error != null) {
        error = r.error;
        break; // limit / network errors would just repeat
      }
    }
    return GenerationResult(
      added: all.length,
      questions: all,
      error: all.isEmpty ? (error ?? 'No questions were written.') : null,
    );
  }

  static bool _toppingUp = false;

  /// Keeps fresh questions ready: for the topics behind [selectors], any
  /// topic with fewer than [targetUnseen] never-answered questions gets
  /// new ones from the AI (emptiest topics first, at most [maxTopics] per
  /// run to stay inside the daily allowance). Does nothing when signed out
  /// or on a plan without the AI.
  static Future<GenerationResult> topUp(
    Iterable<String> selectors, {
    int targetUnseen = 5,
    int maxTopics = 2,
  }) async {
    if (_toppingUp || !canUseAi) {
      return const GenerationResult();
    }
    _toppingUp = true;
    try {
      final ids = (await QuestionRepository.resolveTopicIds(selectors)).toSet();
      final stats = await QuestionRepository.getStats();
      final low =
          (await QuestionRepository.getTopics())
              .where((t) => ids.contains(t.id))
              .where((t) => (stats[t.id]?.unseen ?? 0) < targetUnseen)
              .toList()
            ..sort(
              (a, b) => (stats[a.id]?.unseen ?? 0).compareTo(
                stats[b.id]?.unseen ?? 0,
              ),
            );

      var added = 0;
      String? error;
      final done = <String>[];
      for (final topic in low.take(maxTopics)) {
        final r = await generateForTopic(topic);
        added += r.added;
        if (r.added > 0) done.add(topic.name);
        if (r.error != null) {
          error = '${topic.name}: ${r.error}';
          break; // most failures (limit, network) would just repeat
        }
      }
      if (added > 0 || error != null) {
        await _saveStatus(
          error != null
              ? 'Failed - $error'
              : 'Added $added question(s) to ${done.join(', ')}',
        );
      }
      return GenerationResult(added: added, error: error);
    } finally {
      _toppingUp = false;
    }
  }

  static Future<void> _saveStatus(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final stamp = DateFormat('d MMM HH:mm').format(DateTime.now());
    await prefs.setString(_statusPref, '$stamp: $text');
  }

  /// One line describing the last automatic top-up, or null if none ran.
  static Future<String?> lastStatus() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_statusPref);
  }
}
