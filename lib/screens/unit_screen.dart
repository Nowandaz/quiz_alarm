/// One unit (e.g. Pharmacology): its mastery, a "Practise" button and what
/// it holds: its sections (or subunits) as cards, then "Other topics" for
/// topics in no section. A unit without sections lists its topics.
/// A unit can be archived here (hidden, never deleted).
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
import 'section_screen.dart';
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

/// The search box inside a unit, subunit or section.
class BankSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  const BankSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search sections and topics',
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    ),
  );
}

/// What a search inside a unit, subunit or section found: the sections
/// (from [sections]) and topics (from [topics]) called something that
/// contains [query]. A topic also matches by the section it is in.
List<Widget> bankSearchResults(
  BuildContext context, {
  required String query,
  required Iterable<Section> sections,
  required Iterable<Topic> topics,
}) {
  final bank = context.read<BankProvider>();
  final q = query.trim().toLowerCase();
  final foundTopics = [
    for (final t in topics)
      if (t.name.toLowerCase().contains(q) || bank.sectionMatches(t, q)) t,
  ];
  final foundSections = [
    for (final x in sections)
      if (x.name.toLowerCase().contains(q) && bank.topicsUnder(x.id).length > 1)
        x,
  ];
  return [
    for (final x in foundSections)
      SectionCard(section: x, place: bank.parentOf(x)?.name),
    for (final t in foundTopics)
      TopicCard(
        topic: t,
        stats: bank.statsOf(t.id),
        unitName: bank.sectionOf(t)?.name,
      ),
    if (foundSections.isEmpty && foundTopics.isEmpty)
      Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nothing matches "${query.trim()}".',
          textAlign: TextAlign.center,
        ),
      ),
  ];
}

class UnitScreen extends StatefulWidget {
  final StudyUnit unit;
  const UnitScreen({super.key, required this.unit});

  @override
  State<UnitScreen> createState() => _UnitScreenState();
}

class _UnitScreenState extends State<UnitScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  StudyUnit get unit => widget.unit;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final searching = _query.trim().isNotEmpty;
    final theme = Theme.of(context);
    final topics = bank.topicsOf(unit.id);
    final sections = bank.filledSectionsOf(unit.id);
    // With no sections every topic is listed, as before sections existed.
    final loose = sections.isEmpty ? topics : bank.unfiledTopics(unit.id);
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
          BankHeaderCard(
            topics: topics,
            title: unit.name,
            description: unit.description,
          ),
          const SizedBox(height: 14),
          if (topics.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No topics yet.', textAlign: TextAlign.center),
            ),
          // Worth a search box once there is more than a screenful.
          if (topics.length > 6)
            BankSearchField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
            ),
          if (searching)
            ...bankSearchResults(
              context,
              query: _query,
              sections: bank.sections.where((x) => x.unitId == unit.id),
              topics: topics,
            )
          else ...[
            for (final section in sections) SectionCard(section: section),
            if (sections.isNotEmpty && loose.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                child: Text('Other topics', style: theme.textTheme.titleSmall),
              ),
            for (final topic in loose)
              TopicCard(topic: topic, stats: bank.statsOf(topic.id)),
          ],
        ],
      ),
    );
  }
}

/// The card at the top of a unit, subunit or section: how much it holds,
/// "Practise" for everything beneath it, and the mastery bar.
class BankHeaderCard extends StatelessWidget {
  /// Every topic beneath.
  final List<Topic> topics;

  /// Names the practice session in the reports.
  final String title;

  /// Goes before the topic count, e.g. "3 sections".
  final String? lead;
  final String description;
  const BankHeaderCard({
    super.key,
    required this.topics,
    required this.title,
    this.lead,
    this.description = '',
  });

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final stats = bank.statsFor(topics);
    final total = stats.total;
    final share = total == 0 ? 0.0 : stats.mastered / total;
    return GlossCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${lead == null ? '' : '$lead \u00b7 '}'
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
                        title: title,
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
          if (description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(description, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Opens [topic], or says why it is locked.
void openTopic(BuildContext context, Topic topic) {
  if (!context.read<BankProvider>().isOpen(topic)) {
    showTopicLockedSheet(context, topic);
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => TopicScreen(topic: topic)),
  );
}

class TopicCard extends StatelessWidget {
  final Topic topic;
  final TopicStats stats;

  /// Shown above the topic name in search results: where the topic is.
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
          onTap: () => openTopic(context, topic),
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
