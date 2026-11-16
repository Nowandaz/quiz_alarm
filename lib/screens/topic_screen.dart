/// One topic of the question bank: practise it, add questions with AI,
/// and browse every question with its answer and explanation.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import '../services/bank_provider.dart';
import '../services/ai_client.dart';
import '../services/question_service.dart';
import '../theme/app_theme.dart';
import '../widgets/question_image.dart';
import 'practice_setup.dart';

class TopicScreen extends StatefulWidget {
  final Topic topic;
  const TopicScreen({super.key, required this.topic});

  @override
  State<TopicScreen> createState() => _TopicScreenState();
}

class _TopicScreenState extends State<TopicScreen> {
  List<Question>? _questions;

  // Question id -> was the latest answer correct. Absent = not done yet.
  Map<String, bool> _progress = {};
  String _filter = 'all'; // all | todo | done
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await QuestionRepository.getQuestions(widget.topic.id);
    final progress = await QuestionRepository.getQuestionProgress(
      widget.topic.id,
    );
    if (!mounted) return;
    setState(() {
      _questions = list;
      _progress = progress;
    });
  }

  void _message(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    if (!AiClient.available) {
      if (mounted) {
        _message(
          'Sign in needed',
          'Sign in from Settings (the gear icon on the home screen) to '
              'have the AI write new questions.',
        );
      }
      return;
    }
    setState(() => _generating = true);
    final result = await QuestionService.generateForTopic(widget.topic);
    if (!mounted) return;
    setState(() => _generating = false);
    await _load();
    if (!mounted) return;
    if (result.error != null) {
      _message('Could not generate questions', result.error!);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${result.added} new question(s).')),
      );
    }
  }

  Future<void> _deleteQuestion(Question q) async {
    await QuestionRepository.deleteQuestion(q.id);
    QuestionService.changes.value++;
    await _load();
  }

  Future<void> _deleteTopic() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${widget.topic.name}"?'),
        content: const Text('The topic and all its questions will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await QuestionRepository.deleteCustomTopic(widget.topic.id);
    QuestionService.changes.value++;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<BankProvider>().statsOf(widget.topic.id);
    final theme = Theme.of(context);
    final questions = _questions;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic.name),
        actions: [
          if (widget.topic.isCustom)
            IconButton(
              tooltip: 'Delete topic',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteTopic,
            ),
        ],
      ),
      body: questions == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                Text(
                  '${stats.total} questions - ${stats.seen} answered - '
                  '${stats.mastered} correct on the last try',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: questions.isEmpty
                      ? null
                      : () async {
                          await showPracticeSetup(
                            context,
                            initialTopics: {widget.topic.id},
                            title: widget.topic.name,
                          );
                          _load();
                        },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Practise this topic'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _generating ? null : _generate,
                  icon: _generating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(
                    _generating
                        ? 'Writing questions (up to a minute)...'
                        : 'Generate 5 more with AI',
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Questions', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                // Which ones have been done, and which are still to do.
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (key, label) in [
                      ('all', 'All (${questions.length})'),
                      (
                        'todo',
                        'Not done (${questions.where((q) => !_progress.containsKey(q.id)).length})',
                      ),
                      (
                        'done',
                        'Done (${questions.where((q) => _progress.containsKey(q.id)).length})',
                      ),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _filter == key,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _filter = key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (questions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No questions in this topic yet.'),
                  ),
                for (final q in questions.where(
                  (q) => switch (_filter) {
                    'todo' => !_progress.containsKey(q.id),
                    'done' => _progress.containsKey(q.id),
                    _ => true,
                  },
                ))
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    clipBehavior: Clip.antiAlias,
                    child: ExpansionTile(
                      shape: const Border(),
                      leading: switch (_progress[q.id]) {
                        true => const Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                        ),
                        false => const Icon(
                          Icons.cancel,
                          color: AppColors.danger,
                        ),
                        null => Icon(
                          Icons.radio_button_unchecked,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      },
                      title: Text(q.questionText),
                      subtitle: Text(
                        '${switch (_progress[q.id]) {
                          true => 'Done, correct',
                          false => 'Done, wrong last time',
                          null => 'Not done',
                        }}'
                        ' \u00b7 ${q.type == QuestionType.mcq ? 'Multiple choice' : 'Short answer'}'
                        '${q.image.isNotEmpty ? ' \u00b7 Picture' : ''}'
                        '${q.source == 'ai' ? ' \u00b7 AI generated' : ''}',
                        style: theme.textTheme.bodySmall,
                      ),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        if (q.image.isNotEmpty) ...[
                          QuestionImage(q.image, maxHeight: 160),
                          const SizedBox(height: 8),
                        ],
                        for (final o in q.options)
                          Text(
                            '${o == q.correctAnswer ? '✓' : '•'} $o',
                            style: TextStyle(
                              fontWeight: o == q.correctAnswer
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        if (q.options.isEmpty)
                          Text(
                            'Answer: ${q.correctAnswer}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          q.explanation.isEmpty
                              ? 'No explanation saved yet.'
                              : q.explanation,
                          style: const TextStyle(height: 1.4),
                        ),
                        if (q.source != 'seed')
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => _deleteQuestion(q),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const Text('Remove'),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
