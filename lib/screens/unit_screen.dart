/// One unit (e.g. Pharmacology): its mastery, a "Practise" button and the
/// list of its topics. A unit can be archived here (hidden, never deleted).
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import '../services/bank_provider.dart';
import '../services/question_service.dart';
import '../widgets/app_widgets.dart';
import '../widgets/lock_prompt.dart';
import 'practice_setup.dart';
import 'tabs/question_bank_tab.dart' show showAddTopicDialog;
import 'topic_screen.dart';

/// Asks, then archives [unit]: it is hidden from Banks, the topic picker
/// and "all topics", but nothing is deleted. Returns true if archived.
Future<bool> confirmArchiveUnit(BuildContext context, StudyUnit unit) async {
  final bank = context.read<BankProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Archive ${unit.name}?'),
      content: const Text(
        'It is hidden from Banks, practice and alarms set to all topics. '
        'Nothing is deleted: your answers and reports stay. You can '
        'restore it at any time.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Archive'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await bank.setArchived(unit.id, true);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('${unit.name} archived. Restore it from Banks.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => bank.setArchived(unit.id, false),
        ),
      ),
    );
  return true;
}

class UnitScreen extends StatelessWidget {
  final StudyUnit unit;
  const UnitScreen({super.key, required this.unit});

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final topics = bank.topicsOf(unit.id);
    final total = topics.fold<int>(0, (n, t) => n + bank.statsOf(t.id).total);
    final mastered = topics.fold<int>(
      0,
      (n, t) => n + bank.statsOf(t.id).mastered,
    );
    final share = total == 0 ? 0.0 : mastered / total;
    final archived = bank.isArchived(unit.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(unit.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: FilledButton.icon(
              onPressed: () => showAddTopicDialog(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Topic'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) async {
              if (archived) {
                await bank.setArchived(unit.id, false);
              } else if (await confirmArchiveUnit(context, unit) &&
                  context.mounted) {
                // Back to Banks, where the unit has just left the list.
                Navigator.pop(context);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'archive',
                child: Text(archived ? 'Restore unit' : 'Archive unit'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          6,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (archived)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Archived. Hidden from Banks and from alarms set to '
                      'all topics. Nothing was deleted.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => bank.setArchived(unit.id, false),
                    child: const Text('Restore'),
                  ),
                ],
              ),
            ),
          GlossCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${plural(topics.length, 'topic')} \u00b7 '
                        '${plural(total, 'question')}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    FilledButton(
                      onPressed: total == 0
                          ? null
                          : () => showPracticeSetup(
                              context,
                              initialTopics: {
                                for (final t in topics)
                                  if (bank.isOpen(t)) t.id,
                              },
                              title: unit.name,
                            ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      child: const Text('Practise'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Overall subject mastery',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${(share * 100).round()}% mastered',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: share,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(6),
                ),
                if (unit.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(unit.description, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (topics.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No topics yet.', textAlign: TextAlign.center),
            ),
          for (final topic in topics)
            TopicCard(topic: topic, stats: bank.statsOf(topic.id)),
        ],
      ),
    );
  }
}

class TopicCard extends StatelessWidget {
  final Topic topic;
  final TopicStats stats;

  /// Shown above the topic name in search results.
  final String? unitName;
  const TopicCard({
    super.key,
    required this.topic,
    required this.stats,
    this.unitName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A topic the plan does not open: its title with a lock, nothing more.
    final locked = !context.watch<BankProvider>().isOpen(topic);
    final faded = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => locked
              ? showTopicLockedSheet(context, topic)
              : Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => TopicScreen(topic: topic)),
                ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            child: Row(
              children: [
                if (locked)
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: Icon(Icons.lock_rounded, color: faded),
                  )
                else
                  ProgressRing(
                    value: stats.total == 0 ? 0 : stats.mastered / stats.total,
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (unitName != null)
                        Text(unitName!, style: theme.textTheme.labelSmall),
                      Text(
                        topic.name,
                        style: locked
                            ? theme.textTheme.titleMedium?.copyWith(
                                color: faded,
                              )
                            : theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        locked
                            ? 'Locked'
                            : stats.total == 0
                            ? 'No questions yet'
                            : '${plural(stats.total, 'question')} \u00b7 '
                                  '${stats.seen} answered \u00b7 '
                                  '${stats.mastered} correct',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                // A topic the user made can be deleted right from the list.
                if (topic.isCustom)
                  IconButton(
                    tooltip: 'Delete topic',
                    icon: const Icon(Icons.delete_outline),
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: () => confirmDeleteTopic(context, topic),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks, then deletes a topic the user made together with its questions.
/// Returns true if it was deleted.
Future<bool> confirmDeleteTopic(BuildContext context, Topic topic) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete "${topic.name}"?'),
      content: const Text(
        'The topic, its questions and your answers to them will be removed. '
        'This cannot be undone.',
      ),
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
  if (ok != true) return false;
  await QuestionRepository.deleteCustomTopic(topic.id);
  QuestionService.changes.value++;
  return true;
}
