/// Reports tab: how you are doing over time (trends against the weeks
/// before), which topics are weak (tap one to practise it), how long
/// alarms take to dismiss, and the history of every alarm and practice
/// session (tap one to see its questions and explanations).
library;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/question_repository.dart';
import '../../models/models.dart';
import '../../services/question_service.dart';
import '../../services/theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/coach_tour.dart';
import '../practice_setup.dart';
import '../session_screen.dart';

/// "1m 20s", "45s" or "2h 5m".
String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

class ReportsTab extends StatefulWidget {
  const ReportsTab({super.key});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  ReportSummary? _report;
  List<StudySession> _sessions = [];
  String? _kind; // null = all
  String? _error;

  @override
  void initState() {
    super.initState();
    QuestionService.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    QuestionService.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final report = await QuestionRepository.getReport();
      final sessions = await QuestionRepository.getSessions(kind: _kind);
      if (!mounted) return;
      setState(() {
        _report = report;
        _sessions = sessions;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Reports could not be loaded: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (report == null) return const Center(child: CircularProgressIndicator());

    final accuracy = report.answered == 0
        ? null
        : (report.correct * 100 / report.answered).round();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          6,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // Headline: overall accuracy.
          GlossCard(
            key: TourKeys.reportsHero,
            child: Row(
              children: [
                ProgressRing(
                  value: report.answered == 0
                      ? 0
                      : report.correct / report.answered,
                  size: 96,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        accuracy == null
                            ? 'No answers yet'
                            : 'Overall accuracy',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        accuracy == null
                            ? 'Answer a few questions and your progress '
                                  'shows up here.'
                            : '${report.correct} correct out of '
                                  '${report.answered} answered',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Hidden until there is something to compare.
          if (report.answered > 0) ...[
            const SizedBox(height: 12),
            _TrendsCard(trends: report.trends),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _StatTile(
                label: 'Average time to wake',
                icon: Icons.timer_rounded,
                value: report.avgWakeTime == null
                    ? '-'
                    : formatDuration(report.avgWakeTime!),
              ),
              const SizedBox(width: 12),
              _StatTile(
                label: 'Questions per alarm',
                icon: Icons.bolt_rounded,
                value: report.avgWakeQuestions == null
                    ? '-'
                    : report.avgWakeQuestions!.toStringAsFixed(1),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              report.alarmsDismissed == 0
                  ? 'The alarm figures fill in after your first alarm.'
                  : 'Averages over ${report.alarmsDismissed} dismissed '
                        'alarm${report.alarmsDismissed == 1 ? '' : 's'}.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Last 14 days', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _DayChart(days: report.days),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('By topic', style: theme.textTheme.titleMedium),
                  Text(
                    report.topics.isEmpty
                        ? 'Weakest first.'
                        : 'Weakest first. Tap a topic to practise it.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (report.topics.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Nothing answered yet.'),
                    ),
                  for (final (i, t) in report.topics.indexed)
                    // The weakest topic carries the "Practise" label; the
                    // chevrons say the rest work the same way.
                    _TopicRow(topic: t, weakest: i == 0),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text('History', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (key, label) in const [
                ('all', 'All'),
                ('alarm', 'Alarms'),
                ('practice', 'Practice'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: (_kind ?? 'all') == key,
                  showCheckmark: false,
                  onSelected: (_) {
                    _kind = key == 'all' ? null : key;
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No sessions yet. Alarms and practice sessions appear here.',
              ),
            ),
          for (final s in _sessions) _SessionCard(session: s),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bar per day: full height = answers that day, green part = correct.
class _DayChart extends StatelessWidget {
  final List<DayStat> days;
  const _DayChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final peak = days.fold<int>(0, (m, d) => d.answered > m ? d.answered : m);
    const height = 110.0;

    return SizedBox(
      child: Column(
        children: [
          SizedBox(
            height: height,
            child: peak == 0
                ? const Center(child: Text('No answers in this period yet.'))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final d in days)
                        Expanded(
                          child: Tooltip(
                            message:
                                '${DateFormat('d MMM').format(d.day)}: '
                                '${d.correct} of ${d.answered} correct',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Container(
                                      height:
                                          height *
                                          (d.answered - d.correct) /
                                          peak,
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.18,
                                      ),
                                    ),
                                    Container(
                                      height: height * d.correct / peak,
                                      color: scheme.primary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final d in days)
                Expanded(
                  child: Text(
                    '${d.day.day}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 10, height: 10, color: scheme.primary),
              const SizedBox(width: 4),
              Text('Correct', style: theme.textTheme.labelSmall),
              const SizedBox(width: 14),
              Container(
                width: 10,
                height: 10,
                color: scheme.onSurface.withValues(alpha: 0.18),
              ),
              const SizedBox(width: 4),
              Text('Wrong', style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens the practice set-up with one topic ticked.
void _practise(BuildContext context, String topicId, String name) =>
    showPracticeSetup(context, initialTopics: {topicId}, title: name);

/// "Practise" and a chevron: marks a row as something to tap.
class _PractiseHint extends StatelessWidget {
  final bool label;
  const _PractiseHint({this.label = true});

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

/// All-time accuracy on one topic. Tapping it opens practice for it.
class _TopicRow extends StatelessWidget {
  final TopicAccuracy topic;
  final bool weakest;
  const _TopicRow({required this.topic, this.weakest = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _practise(context, topic.id, topic.topic),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(topic.topic)),
                Text(
                  '${(topic.accuracy * 100).round()}%  '
                  '(${topic.correct}/${topic.answered})',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 6),
                _PractiseHint(label: weakest),
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

/// How the last 14 days compare with the 14 before, this week with last
/// week, and which topics moved. A row with nothing to say is left out.
class _TrendsCard extends StatelessWidget {
  final ReportTrends trends;
  const _TrendsCard({required this.trends});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = trends;
    final accuracy = t.accuracy;
    final small = theme.textTheme.bodySmall;

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Text(text, style: theme.textTheme.titleSmall),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Trends', style: theme.textTheme.titleMedium),
            if (t.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Nothing answered in the last four weeks. Practise a few '
                  'questions and your trends show up here.',
                  style: small,
                ),
              ),
            if (accuracy != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '$accuracy%',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Accuracy, last 14 days',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(_sentence(t.comparison!), style: small),
                      ],
                    ),
                  ),
                  if (t.previousAnswered > 0)
                    Icon(
                      t.comparison!.startsWith('up')
                          ? Icons.trending_up_rounded
                          : t.comparison!.startsWith('down')
                          ? Icons.trending_down_rounded
                          : Icons.trending_flat_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                ],
              ),
            ],
            if (t.thisWeek > 0 || t.lastWeek > 0) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _WeekCount(label: 'This week', count: t.thisWeek),
                  ),
                  Expanded(
                    child: _WeekCount(label: 'Last week', count: t.lastWeek),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    _DayDot(letter: 'MTWTFSS'[i], practised: t.weekDays[i]),
                ],
              ),
              const SizedBox(height: 6),
              // Under the dots, not beside them: a narrow phone has no
              // room for both on one line.
              Text(
                'You practised on ${t.daysPractised} of 7 days this week.',
                style: small,
              ),
            ],
            if (t.improving.isNotEmpty) ...[
              heading('Improving most'),
              for (final topic in t.improving)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(child: Text(topic.topic)),
                      Text(
                        '${(topic.previousAccuracy * 100).round()}% to '
                        '${(topic.accuracy * 100).round()}%',
                        style: small,
                      ),
                      const SizedBox(width: 8),
                      Pill(
                        'Up ${topic.change}',
                        icon: Icons.trending_up_rounded,
                        color: AppColors.success,
                      ),
                    ],
                  ),
                ),
            ],
            if (t.needsRevision.isNotEmpty) ...[
              heading('Needs revision'),
              for (final topic in t.needsRevision)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _practise(context, topic.id, topic.topic),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Expanded(child: Text(topic.topic)),
                        Text(
                          '${(topic.accuracy * 100).round()}%  '
                          '(${topic.correct}/${topic.answered})',
                          style: small,
                        ),
                        const SizedBox(width: 6),
                        const _PractiseHint(),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// "up 8 points..." with a capital and a full stop.
  static String _sentence(String text) =>
      '${text[0].toUpperCase()}${text.substring(1)}.';
}

/// "This week" over a count of questions.
class _WeekCount extends StatelessWidget {
  final String label;
  final int count;
  const _WeekCount({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(
          plural(count, 'question'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// One day of the week: filled when something was answered that day.
class _DayDot extends StatelessWidget {
  final String letter;
  final bool practised;
  const _DayDot({required this.letter, required this.practised});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 24,
      height: 24,
      margin: const EdgeInsets.only(right: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: practised ? scheme.primary : Colors.transparent,
        border: Border.all(
          color: practised ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: practised ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final StudySession session;
  const _SessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session;
    final icon = switch (s.kind) {
      'alarm' => Icons.alarm_rounded,
      _ => Icons.auto_stories_rounded,
    };
    final outcome = switch (s.outcome) {
      'dismissed' => 'Dismissed',
      'snoozed' => 'Snoozed',
      'finished' => null,
      _ => s.kind == 'alarm' ? 'Not finished' : null,
    };
    final parts = [
      '${s.questions} question${s.questions == 1 ? '' : 's'}',
      '${s.correct} correct',
      if (s.duration != null) formatDuration(s.duration!),
      ?outcome,
    ];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: theme.colorScheme.onSurface, size: 22),
        ),
        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${DateFormat('EEE d MMM').format(s.startedAt)}, '
          '${formatClock(s.startedAt, use24Hour: context.watch<ThemeProvider>().use24Hour)}\n'
          '${parts.join(' \u00b7 ')}',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SessionScreen(session: s)),
        ),
      ),
    );
  }
}
