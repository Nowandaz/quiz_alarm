/// By topic: how you are doing on every topic you have answered, weakest
/// first, with a search box. Tap a topic to practise it. Opened from the
/// Reports tab; the figures are part of the paid plans.
library;

import 'package:material_ui/material_ui.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import '../services/entitlements.dart';
import 'practice_setup.dart';
import 'upgrade_screen.dart';

class TopicStatsScreen extends StatefulWidget {
  /// The topics with their figures, weakest first (as Reports has them).
  final List<TopicAccuracy> topics;
  const TopicStatsScreen({super.key, required this.topics});

  @override
  State<TopicStatsScreen> createState() => _TopicStatsScreenState();
}

class _TopicStatsScreenState extends State<TopicStatsScreen> {
  final _search = TextEditingController();

  /// Topic id -> where it is, shown under its name: "Pharmacology", or
  /// "Pathology · Blood film" for a topic in a section.
  Map<String, String> _unitOf = const {};

  /// Topic id -> the names a search also looks in: its unit, section and
  /// subunit.
  Map<String, String> _findBy = const {};

  @override
  void initState() {
    super.initState();
    _loadUnits();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadUnits() async {
    try {
      final units = {
        for (final u in await QuestionRepository.getUnits()) u.id: u.name,
      };
      final sections = {
        for (final x in await QuestionRepository.getSections()) x.id: x,
      };
      final place = <String, String>{};
      final findBy = <String, String>{};
      for (final t in await QuestionRepository.getTopics()) {
        final unit = units[t.unitId] ?? '';
        final section = sections[t.sectionId];
        final subunit = sections[section?.parentId];
        place[t.id] = [
          if (unit.isNotEmpty) unit,
          if (section != null &&
              section.name.toLowerCase() != t.name.toLowerCase())
            section.name,
        ].join(' \u00b7 ');
        findBy[t.id] = [
          unit,
          ?section?.name,
          ?subunit?.name,
        ].join('\n').toLowerCase();
      }
      if (mounted) {
        setState(() {
          _unitOf = place;
          _findBy = findBy;
        });
      }
    } catch (e) {
      debugPrint('Unit names could not be loaded: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('By topic')),
      body: ListenableBuilder(
        listenable: Entitlements.instance,
        builder: (context, _) => Entitlements.instance.canSeeTrends
            ? _list(context)
            : const Padding(
                padding: EdgeInsets.all(16),
                child: TrendsLockedCard(),
              ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final t in widget.topics)
        if (query.isEmpty ||
            t.topic.toLowerCase().contains(query) ||
            (_findBy[t.id] ?? '').contains(query))
          t,
    ];
    final weakest = widget.topics.isEmpty ? null : widget.topics.first;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search topics',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              if (widget.topics.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Nothing answered yet.'),
                )
              else if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No topic matches'),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Weakest first. Tap a topic to practise it.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final t in shown)
                TopicStatRow(
                  topic: t,
                  unit: _unitOf[t.id] ?? '',
                  weakest: identical(t, weakest),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// All-time accuracy on one topic. Tapping it opens practice for it.
class TopicStatRow extends StatelessWidget {
  final TopicAccuracy topic;
  final String unit;

  /// The weakest topic carries the word "Practise"; the others only the
  /// chevron.
  final bool weakest;
  const TopicStatRow({
    super.key,
    required this.topic,
    this.unit = '',
    this.weakest = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => showPracticeSetup(
        context,
        initialTopics: {topic.id},
        title: topic.topic,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(topic.topic),
                      if (unit.isNotEmpty)
                        Text(unit, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Text(
                  '${(topic.accuracy * 100).round()}%  '
                  '(${topic.correct}/${topic.answered})',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 6),
                PractiseHint(label: weakest),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: topic.accuracy,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Practise" and a chevron: marks a row as something to tap.
class PractiseHint extends StatelessWidget {
  final bool label;
  const PractiseHint({super.key, this.label = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label)
          Text(
            'Practise',
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

/// Shown in place of the trends and the topic figures on plans without
/// them: what is locked, and a way to the plans.
class TrendsLockedCard extends StatelessWidget {
  const TrendsLockedCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guest = Entitlements.instance.isGuest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.lock_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    guest
                        ? 'Create a free account and go Pro to see trends.'
                        : 'Trends and topic figures are part of Pro.',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: () => showUpgrade(context),
              child: const Text('See plans'),
            ),
          ],
        ),
      ),
    );
  }
}
