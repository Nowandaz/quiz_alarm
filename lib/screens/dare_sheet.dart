/// "It's been a minute. Dare to answer this?"
///
/// Someone who has not answered a question for half a day, and has no
/// alarm switched on to ask them one, is offered a single question when
/// they open the app: from a random topic their plan opens. They can
/// answer it, ask for another, choose a topic themselves, or wave it
/// away. It never shows while an alarm rings, on the very first day, or
/// more than once in twelve hours.
library;

import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import '../services/bank_provider.dart';
import '../services/question_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/question_image.dart';
import 'practice_setup.dart';

class Dare {
  /// How long without a question before the dare, and between two dares.
  static const Duration quiet = Duration(hours: 12);

  static const String firstOpenPref = 'first_open_at';
  static const String lastShownPref = 'dare_last_shown';

  /// Whether to offer a question now. [anyAlarmOn]: an alarm is switched
  /// on (it will ask its own questions, so there is no dare).
  static Future<bool> due({required bool anyAlarmOn, DateTime? now}) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    final firstOpen = prefs.getInt(firstOpenPref);
    if (firstOpen == null) {
      // The first day belongs to the welcome and the tour.
      await prefs.setInt(firstOpenPref, t);
      return false;
    }
    if (anyAlarmOn) return false;
    if (t - firstOpen < quiet.inMilliseconds) return false;
    if (t - (prefs.getInt(lastShownPref) ?? 0) < quiet.inMilliseconds) {
      return false;
    }
    final last = await QuestionRepository.lastAnswerAt();
    if (last != null &&
        t - last.millisecondsSinceEpoch < quiet.inMilliseconds) {
      return false;
    }
    return true;
  }

  static Future<void> markShown({DateTime? now}) async {
    (await SharedPreferences.getInstance()).setInt(
      lastShownPref,
      (now ?? DateTime.now()).millisecondsSinceEpoch,
    );
  }

  /// A question from a random topic the plan opens (never a long answer
  /// question), avoiding [exclude]. Null when there is nothing to ask.
  static Future<Question?> pick({
    Set<String> exclude = const {},
    Random? rng,
  }) async {
    final random = rng ?? Random();
    final topics = [
      for (final t in await QuestionRepository.getTopics())
        if (QuestionRepository.isOpen(t)) t.id,
    ]..shuffle(random);
    for (final id in topics.take(12)) {
      final q = await QuestionRepository.pickNext(
        [id],
        exclude: exclude,
        repeat: false,
        longAnswers: false,
        rng: random,
      );
      if (q != null && q.topicId == id) return q;
    }
    return null;
  }
}

/// Shows the dare if it is due. Returns true if it was shown.
Future<bool> maybeShowDare(
  BuildContext context, {
  required bool anyAlarmOn,
}) async {
  if (!await Dare.due(anyAlarmOn: anyAlarmOn)) return false;
  final first = await Dare.pick();
  if (first == null || !context.mounted) return false;
  await Dare.markShown();
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (_) => DareDialog(first: first),
  );
  return true;
}

class DareDialog extends StatefulWidget {
  final Question first;
  const DareDialog({super.key, required this.first});

  @override
  State<DareDialog> createState() => _DareDialogState();
}

class _DareDialogState extends State<DareDialog> {
  late Question _q = widget.first;
  final Set<String> _asked = {};
  final TextEditingController _typed = TextEditingController();

  // Null while the question is still open.
  bool? _correct;
  String _given = '';
  bool _busy = false;
  Future<int?>? _session;

  @override
  void initState() {
    super.initState();
    _asked.add(_q.id);
  }

  @override
  void dispose() {
    _typed.dispose();
    final session = _session;
    if (session != null) {
      session.then((id) => QuestionRepository.endSession(id, 'finished'));
      QuestionService.changes.value++;
    }
    super.dispose();
  }

  Future<void> _answer(String answer) async {
    if (_correct != null || _busy || answer.trim().isEmpty) return;
    setState(() => _busy = true);
    final result = await QuestionService.gradeLocal(_q, answer);
    _session ??= QuestionRepository.startSession('bank', 'Quick question');
    await QuestionRepository.recordAttempt(
      _q.id,
      correct: result.correct,
      mode: 'bank',
      sessionId: await _session,
      userAnswer: answer.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _correct = result.correct;
      _given = answer;
    });
  }

  Future<void> _another() async {
    if (_busy) return;
    setState(() => _busy = true);
    var next = await Dare.pick(exclude: _asked);
    // Everything open has been asked: start over.
    next ??= await Dare.pick();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (next != null) {
        _q = next;
        _asked.add(next.id);
        _correct = null;
        _given = '';
        _typed.clear();
      }
    });
  }

  Future<void> _chooseTopic() async {
    final bank = context.read<BankProvider>();
    final navigator = Navigator.of(context);
    final rootContext = navigator.context;
    navigator.pop();
    await showPracticeSetup(
      rootContext,
      initialTopics: bank.openTopics.map((t) => t.id).toSet(),
    );
  }

  Widget _option(String option, ColorScheme scheme) {
    final answered = _correct != null;
    final isRight =
        option.toLowerCase() == _q.correctAnswer.trim().toLowerCase();
    final isPicked = option == _given;
    Color? background;
    Color border = scheme.outlineVariant;
    if (answered && isRight) {
      background = AppColors.success.withValues(alpha: 0.16);
      border = AppColors.success;
    } else if (answered && isPicked) {
      background = scheme.error.withValues(alpha: 0.16);
      border = scheme.error;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: background ?? scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: answered ? null : () => _answer(option),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                LetterBadge(index: _q.options.indexOf(option)),
                const SizedBox(width: 12),
                Expanded(child: Text(option)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final answered = _correct != null;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("It's been a minute", style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                'Dare to answer this?',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _q.topic.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_q.image.isNotEmpty) ...[
                        QuestionImage(_q.image, maxHeight: 170),
                        const SizedBox(height: 8),
                      ],
                      Text(_q.questionText, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      if (_q.type == QuestionType.mcq)
                        for (final o in _q.options) _option(o, scheme)
                      else if (!answered)
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _typed,
                                textInputAction: TextInputAction.done,
                                onSubmitted: _answer,
                                decoration: const InputDecoration(
                                  hintText: 'Type your answer',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () => _answer(_typed.text),
                              child: const Text('Check'),
                            ),
                          ],
                        ),
                      if (answered) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              _correct! ? Icons.check_circle : Icons.cancel,
                              color: _correct!
                                  ? AppColors.success
                                  : scheme.error,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _correct! ? 'Correct!' : 'Not quite',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                        if (_q.type != QuestionType.mcq || !_correct!)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Answer: ${_q.correctAnswer}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        if (_q.explanation.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _q.explanation,
                              style: const TextStyle(height: 1.4),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: _busy ? null : _another,
                  child: const Text('Another question'),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(answered ? 'Done' : 'Not now'),
                  ),
                  TextButton(
                    onPressed: _chooseTopic,
                    child: const Text('Choose a topic'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
