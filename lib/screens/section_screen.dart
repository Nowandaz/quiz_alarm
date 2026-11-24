/// A subunit or a section of a unit. A subunit ("Haematology") lists its
/// sections; a section ("Blood film") lists its topics. On top: what it
/// holds, its mastery and a "Practise" button for everything beneath it.
///
/// Also here: the card a unit or subunit shows for each of them, and
/// [openSection], which skips levels that hold only one thing.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/bank_provider.dart';
import '../widgets/app_widgets.dart';
import 'unit_screen.dart';

/// Opens what a section card stands for, without pointless stops: a
/// subunit with one section goes straight to that section, and a section
/// with one topic goes straight to the topic.
void openSection(BuildContext context, Section section) {
  final bank = context.read<BankProvider>();
  var target = section;
  if (target.isSubunit) {
    final children = bank.filledChildrenOf(target.id);
    if (children.length == 1) target = children.single;
  }
  if (!target.isSubunit) {
    final topics = bank.topicsIn(target.id);
    if (topics.length == 1) return openTopic(context, topics.single);
  }
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => SectionScreen(section: target)),
  );
}

class SectionScreen extends StatefulWidget {
  final Section section;
  const SectionScreen({super.key, required this.section});

  @override
  State<SectionScreen> createState() => _SectionScreenState();
}

class _SectionScreenState extends State<SectionScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    // The latest copy: a sync may have renamed it while this is open.
    final section = bank.sectionById(widget.section.id) ?? widget.section;
    final children = section.isSubunit
        ? bank.filledChildrenOf(section.id)
        : const <Section>[];
    final topics = bank.topicsUnder(section.id);
    // Where this is: "Pathology", or "Pathology · Haematology".
    final trail = [
      ...bank.units.where((u) => u.id == section.unitId).map((u) => u.name),
      ?bank.parentOf(section)?.name,
    ].join(' \u00b7 ');

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(section.name),
            if (trail.isNotEmpty) Text(trail, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          6,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          BankHeaderCard(
            topics: topics,
            title: section.name,
            lead: section.isSubunit ? plural(children.length, 'section') : null,
            description: section.description,
          ),
          const SizedBox(height: 14),
          if (topics.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No topics yet.', textAlign: TextAlign.center),
            ),
          if (topics.length > 6)
            BankSearchField(
              controller: _search,
              hint: section.isSubunit
                  ? 'Search sections and topics'
                  : 'Search topics',
              onChanged: (v) => setState(() => _query = v),
            ),
          if (_query.trim().isNotEmpty)
            ...bankSearchResults(
              context,
              query: _query,
              sections: children,
              topics: topics,
            )
          else if (section.isSubunit)
            for (final child in children) SectionCard(section: child)
          else
            for (final topic in topics)
              TopicCard(topic: topic, stats: bank.statsOf(topic.id)),
        ],
      ),
    );
  }
}

/// One subunit or section in a list: its name, what it holds and its
/// mastery. When the plan opens none of its topics it shows a lock.
class SectionCard extends StatelessWidget {
  final Section section;

  /// Shown above the name in search results: where the section is.
  final String? place;
  const SectionCard({super.key, required this.section, this.place});

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final topics = bank.topicsUnder(section.id);
    final stats = bank.statsFor(topics);
    final locked = bank.allLocked(topics);
    final faded = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final holds = [
      if (section.isSubunit)
        plural(bank.filledChildrenOf(section.id).length, 'section'),
      plural(topics.length, 'topic'),
    ].join(' \u00b7 ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openSection(context, section),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            child: Row(
              children: [
                if (locked)
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: Icon(
                      Icons.lock_rounded,
                      color: faded,
                      semanticLabel: 'Locked',
                    ),
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
                      if (place != null)
                        Text(place!, style: theme.textTheme.labelSmall),
                      Text(
                        section.name,
                        style: locked
                            ? theme.textTheme.titleMedium?.copyWith(
                                color: faded,
                              )
                            : theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        // All locked says so, instead of "0 questions".
                        locked
                            ? '$holds \u00b7 Locked'
                            : '$holds \u00b7 '
                                  '${plural(stats.total, 'question')}',
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
