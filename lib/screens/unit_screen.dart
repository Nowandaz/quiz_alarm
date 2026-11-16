/// One unit (e.g. Pharmacology): its mastery, a "Practise" button and the
/// list of its topics.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/bank_provider.dart';
import '../widgets/app_widgets.dart';
import 'practice_setup.dart';
import 'tabs/question_bank_tab.dart' show showAddTopicDialog;
import 'topic_screen.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: Text(unit.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
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
          GlossCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${topics.length} topics \u00b7 $total questions',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    FilledButton(
                      onPressed: total == 0
                          ? null
                          : () => showPracticeSetup(
                              context,
                              initialTopics: topics.map((t) => t.id).toSet(),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TopicScreen(topic: topic)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            child: Row(
              children: [
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
                      Text(topic.name, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 3),
                      Text(
                        stats.total == 0
                            ? 'No questions yet'
                            : '${stats.total} questions \u00b7 ${stats.seen} answered \u00b7 '
                                  '${stats.mastered} correct',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
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
