/// History: every alarm and practice session, newest first, with a filter
/// for alarms or practice. Tap a session to see its questions. Opened
/// from the Reports tab.
library;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../data/question_repository.dart';
import '../models/models.dart';
import '../services/question_service.dart';
import '../services/theme_provider.dart';
import '../widgets/app_widgets.dart';
import 'session_screen.dart';
import 'tabs/reports_tab.dart' show formatDuration;

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  /// How many sessions are saved, for the "History" row on Reports.
  static Future<int> countSessions() async {
    await QuestionRepository.ensureReady();
    final rows = await (await AppDatabase.instance).rawQuery(
      'SELECT COUNT(*) AS n FROM sessions',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<StudySession>? _sessions;
  String? _kind; // null = all

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
      final sessions = await QuestionRepository.getSessions(
        kind: _kind,
        limit: 300,
      );
      if (mounted) setState(() => _sessions = sessions);
    } catch (e) {
      debugPrint('History could not be loaded: $e');
      if (mounted) setState(() => _sessions = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: sessions == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
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
                if (sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No sessions yet. Alarms and practice sessions '
                      'appear here.',
                    ),
                  ),
                for (final s in sessions) SessionCard(session: s),
              ],
            ),
    );
  }
}

/// One session in the list. Tapping it opens its questions.
class SessionCard extends StatelessWidget {
  final StudySession session;
  const SessionCard({super.key, required this.session});

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
      'timed_out' => 'Not answered',
      'finished' => null,
      _ => s.kind == 'alarm' ? 'Not finished' : null,
    };
    final parts = [
      plural(s.questions, 'question'),
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
          '${parts.join(' · ')}',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)),
        ),
      ),
    );
  }
}
