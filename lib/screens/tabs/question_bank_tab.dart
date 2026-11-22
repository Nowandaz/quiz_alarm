/// Question Banks tab: one card per unit (Pharmacology, Pathology...) with
/// its mastery. Tap a unit to see its topics. "Practise" opens the set-up
/// sheet where topics, number of questions and source are chosen. Units
/// the user archived sit in a closed "Archived" list at the bottom.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/question_repository.dart';
import '../../models/models.dart';
import '../../services/bank_provider.dart';
import '../../services/entitlements.dart';
import '../../services/sync_service.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/coach_tour.dart';
import '../../widgets/lock_prompt.dart';
import '../practice_setup.dart';
import '../unit_screen.dart';
import '../topic_screen.dart';

/// Asks for a name and unit, creates the topic and opens it. Topics of
/// your own need an account: a guest is asked to create one.
Future<void> showAddTopicDialog(BuildContext context) async {
  if (Entitlements.instance.isGuest) {
    return showLockedSheet(
      context,
      title: 'Your own topics',
      guestMessage: 'Create a free account to add topics of your own.',
      accountIsEnough: true,
    );
  }
  final bank = context.read<BankProvider>();
  final nameCtrl = TextEditingController();
  final aboutCtrl = TextEditingController();
  String unitId = QuestionRepository.customUnitId;
  String? nameError; // shown under the name field after an empty Add
  final created = await showDialog<Topic>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Add a topic'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                // Typing again clears the "enter a name" error.
                onChanged: (_) {
                  if (nameError != null) {
                    setDialogState(() => nameError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Topic name',
                  hintText: 'e.g. Antimalarial drugs',
                  errorText: nameError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: aboutCtrl,
                textCapitalization: TextCapitalization.sentences,
                minLines: 2,
                maxLines: 4,
                maxLength: 600,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'e.g. mechanisms, side effects and resistance',
                  helperText:
                      'What should it cover? The AI uses this when '
                      'writing questions.',
                  helperMaxLines: 3,
                  alignLabelWithHint: true,
                ),
              ),
              // Clear of the helper text above, which can wrap to 3 lines.
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                initialValue: unitId,
                decoration: const InputDecoration(labelText: 'Unit'),
                items: [
                  for (final u in bank.activeUnits)
                    if (u.id != QuestionRepository.customUnitId)
                      DropdownMenuItem(value: u.id, child: Text(u.name)),
                  const DropdownMenuItem(
                    value: QuestionRepository.customUnitId,
                    child: Text('My topics'),
                  ),
                ],
                onChanged: (v) => setDialogState(() => unitId = v ?? unitId),
              ),
              const SizedBox(height: 12),
              Text(
                'New topics start empty. Open the topic and tap '
                '"Generate 5 with AI" to fill it.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                setDialogState(() => nameError = 'Enter a topic name');
                return;
              }
              final t = await QuestionRepository.addCustomTopic(
                name,
                unitId: unitId,
                description: aboutCtrl.text,
              );
              if (ctx.mounted) Navigator.pop(ctx, t);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
  if (created == null) return;
  // A new topic in the archived "My topics" would be invisible.
  if (bank.isArchived(created.unitId)) {
    await QuestionRepository.setUnitArchived(created.unitId, false);
  }
  await bank.reload();
  if (context.mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TopicScreen(topic: created)),
    );
  }
}

class QuestionBankTab extends StatefulWidget {
  const QuestionBankTab({super.key});

  @override
  State<QuestionBankTab> createState() => _QuestionBankTabState();
}

class _QuestionBankTabState extends State<QuestionBankTab> {
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

    if (bank.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (bank.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(bank.error!, textAlign: TextAlign.center),
        ),
      );
    }

    final units = bank.activeUnits;
    final topics = bank.activeTopics;
    final archived = bank.archivedUnits;
    final padding = EdgeInsets.fromLTRB(
      16,
      6,
      16,
      24 + MediaQuery.paddingOf(context).bottom,
    );

    // Nothing at all: the first download has not finished and no bank
    // came with the app.
    if (bank.units.isEmpty) {
      return ListView(padding: padding, children: const [_EmptyBank()]);
    }

    final q = _query.trim().toLowerCase();
    bool matches(Topic t) =>
        t.name.toLowerCase().contains(q) ||
        units.any((u) => u.id == t.unitId && u.name.toLowerCase().contains(q));

    return ListView(
      padding: padding,
      children: [
        PrimaryButton(
          key: TourKeys.practise,
          icon: Icons.play_arrow_rounded,
          label: 'Practise',
          onPressed: () => showPracticeSetup(
            context,
            initialTopics: bank.openTopics.map((t) => t.id).toSet(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Choose topics, how many questions, and bank or AI questions.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search units and topics',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
        const SizedBox(height: 14),
        // While searching: the matching topics, straight to the topic.
        if (q.isNotEmpty) ...[
          for (final topic in topics.where(matches))
            TopicCard(
              topic: topic,
              stats: bank.statsOf(topic.id),
              unitName: units
                  .where((u) => u.id == topic.unitId)
                  .map((u) => u.name)
                  .firstOrNull,
            ),
          if (!topics.any(matches))
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Nothing matches "${_query.trim()}".',
                textAlign: TextAlign.center,
              ),
            ),
        ] else ...[
          if (units.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Every unit is archived. Restore one below to practise it.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final unit in units)
            Padding(
              key: unit.id == units.first.id ? TourKeys.firstUnit : null,
              padding: const EdgeInsets.only(bottom: 14),
              child: _UnitCard(unit: unit),
            ),
          if (archived.isNotEmpty) _ArchivedUnits(units: archived),
        ],
      ],
    );
  }
}

/// One unit on the Banks tab: name, size and mastery. Tap opens it;
/// a long press offers to archive it.
class _UnitCard extends StatelessWidget {
  final StudyUnit unit;
  const _UnitCard({required this.unit});

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final topics = bank.topicsOf(unit.id);
    final total = topics.fold<int>(0, (n, t) => n + bank.statsOf(t.id).total);
    final mastered = topics.fold<int>(
      0,
      (n, t) => n + bank.statsOf(t.id).mastered,
    );
    final share = total == 0 ? 0.0 : mastered / total;

    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UnitScreen(unit: unit)),
      ),
      onLongPress: () => confirmArchiveUnit(context, unit),
      child: GlossCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(unit.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        '${plural(topics.length, 'topic')} \u00b7 '
                        '${plural(total, 'question')}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 16),
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
                    color: scheme.primary,
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
          ],
        ),
      ),
    );
  }
}

/// "Archived (n)": closed until tapped, then the archived units, each
/// with "Restore". Their answers and reports were never touched.
class _ArchivedUnits extends StatelessWidget {
  final List<StudyUnit> units;
  const _ArchivedUnits({required this.units});

  @override
  Widget build(BuildContext context) {
    final bank = context.read<BankProvider>();
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text('Archived (${units.length})'),
        subtitle: Text(
          'Hidden, not deleted. Your history stays.',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          for (final unit in units)
            ListTile(
              title: Text(unit.name),
              subtitle: Text(plural(bank.topicsOf(unit.id).length, 'topic')),
              trailing: TextButton(
                onPressed: () => bank.setArchived(unit.id, false),
                child: const Text('Restore'),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => UnitScreen(unit: unit)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown when there are no units at all: says the bank arrives by itself
/// and what can be done meanwhile.
class _EmptyBank extends StatelessWidget {
  const _EmptyBank();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.cloud_download_outlined, size: 28),
              ),
            ),
            const SizedBox(height: 14),
            Text('No questions yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'The question bank downloads by itself when you are online.',
            ),
            const SizedBox(height: 6),
            const Text(
              'You can also add a topic of your own with "Add topic" and '
              'have the AI write questions for it.',
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              icon: Icons.add_rounded,
              label: 'Add topic',
              onPressed: () => showAddTopicDialog(context),
            ),
            const SizedBox(height: 8),
            // The download again, now. Its result shows underneath.
            ValueListenableBuilder<bool>(
              valueListenable: SyncService.running,
              builder: (context, running, _) => OutlinedButton.icon(
                onPressed: running ? null : () => SyncService.run(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: Text(running ? 'Downloading...' : 'Try again'),
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: SyncService.status,
              builder: (context, status, _) =>
                  status == null || !status.startsWith('Could not')
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        status,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
