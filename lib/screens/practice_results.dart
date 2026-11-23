/// What a practice session ends on: the score, every mistake with the
/// right answer and why, and a way to practise the missed questions again
/// straight away.
library;

import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/question_image.dart';
import 'flag_sheet.dart';
import 'practice_screen.dart';

/// One answered question of a session. An empty [userAnswer] means the
/// user chose "I don't know".
class PracticeResult {
  final Question question;
  final String userAnswer;
  final bool correct;
  const PracticeResult(this.question, this.userAnswer, this.correct);
}

class PracticeResultsScreen extends StatefulWidget {
  final String title;
  final String mode;
  final bool aiTutor;
  final List<PracticeResult> results;

  const PracticeResultsScreen({
    super.key,
    required this.title,
    required this.results,
    this.mode = 'bank',
    this.aiTutor = false,
  });

  @override
  State<PracticeResultsScreen> createState() => _PracticeResultsScreenState();
}

class _PracticeResultsScreenState extends State<PracticeResultsScreen> {
  // Mistakes are what the user came to see; "All" is one tap away.
  late bool _mistakesOnly = _missed.isNotEmpty;

  List<PracticeResult> get _missed =>
      widget.results.where((r) => !r.correct).toList();

  /// A fresh session made of just the questions that were missed.
  void _retry() {
    final title = widget.title.startsWith('Retry: ')
        ? widget.title
        : 'Retry: ${widget.title}';
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PracticeScreen(
          title: title,
          selectors: const [],
          mode: widget.mode,
          aiTutor: widget.aiTutor,
          questions: [for (final r in _missed) r.question],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = widget.results.length;
    final missed = _missed;
    final right = total - missed.length;
    final unknown = missed.where((r) => r.userAnswer.isEmpty).length;
    final percent = total == 0 ? 0 : (right * 100 / total).round();
    final shown = _mistakesOnly ? missed : widget.results;

    final verdict = missed.isEmpty
        ? 'All correct. Nicely done.'
        : percent >= 80
        ? 'Strong session.'
        : percent >= 50
        ? 'Good work. A few to look at again.'
        : 'Worth another go. The answers are below.';

    return Scaffold(
      appBar: AppBar(title: const Text('Results')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (missed.isNotEmpty) ...[
                PrimaryButton(
                  icon: Icons.replay_rounded,
                  label:
                      'Practise the ${missed.length == 1 ? 'one' : missed.length} '
                      'you missed',
                  onPressed: _retry,
                ),
                const SizedBox(height: 4),
              ],
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          GlossCard(
            child: Row(
              children: [
                // The ring writes the percentage in its middle itself.
                ProgressRing(value: percent / 100, size: 92),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$right of $total right',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(verdict, style: theme.textTheme.bodyMedium),
                      if (unknown > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$unknown answered "I don\'t know".',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  _mistakesOnly ? 'Review your mistakes' : 'All questions',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (missed.isNotEmpty && missed.length < total)
                TextButton(
                  onPressed: () =>
                      setState(() => _mistakesOnly = !_mistakesOnly),
                  child: Text(
                    _mistakesOnly ? 'Show all $total' : 'Mistakes only',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final r in shown) _ResultCard(r, scheme: scheme),
        ],
      ),
    );
  }
}

/// One question in the review: what was asked, what was answered, the
/// right answer and why.
class _ResultCard extends StatelessWidget {
  final PracticeResult result;
  final ColorScheme scheme;
  const _ResultCard(this.result, {required this.scheme});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = result.question;
    final color = result.correct ? AppColors.success : AppColors.danger;

    Widget line(String label, String text, Color c, IconData icon) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$label  ',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: c,
                    ),
                  ),
                  TextSpan(text: text),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              q.topic,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              q.questionText,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.3),
            ),
            if (q.longAnswer) ...[
              const SizedBox(height: 6),
              Pill(q.marksLabel),
            ],
            if (q.image.isNotEmpty) ...[
              const SizedBox(height: 10),
              QuestionImage(q.image, maxHeight: 160),
            ],
            if (result.correct)
              line(
                'YOUR ANSWER',
                result.userAnswer,
                AppColors.success,
                Icons.check_rounded,
              )
            else ...[
              line(
                'YOUR ANSWER',
                result.userAnswer.isEmpty ? "I don't know" : result.userAnswer,
                AppColors.danger,
                Icons.close_rounded,
              ),
              line(
                q.longAnswer ? 'MODEL ANSWER' : 'CORRECT',
                q.correctAnswer,
                AppColors.success,
                Icons.check_rounded,
              ),
            ],
            if (q.explanation.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                q.explanation,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ],
            // Report a wrong or unclear question to the reviewers.
            Align(alignment: Alignment.centerRight, child: FlagButton(q)),
          ],
        ),
      ),
    );
  }
}
