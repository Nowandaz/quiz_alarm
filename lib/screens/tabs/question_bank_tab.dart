/// Question Banks tab: one card per unit (Pharmacology, Pathology...) with
/// its mastery. Tap a unit to see its topics. "Practise" opens the set-up
/// sheet where topics, number of questions and source are chosen.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/question_repository.dart';
import '../../models/models.dart';
import '../../services/bank_provider.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/coach_tour.dart';
import '../practice_setup.dart';
import '../unit_screen.dart';
import '../topic_screen.dart';

/// Asks for a name and unit, creates the topic and opens it.
Future<void> showAddTopicDialog(BuildContext context) async {
  final bank = context.read<BankProvider>();
  final nameCtrl = TextEditingController();
  String unitId = QuestionRepository.customUnitId;
  final created = await showDialog<Topic>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Add a topic'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Topic name',
                hintText: 'e.g. Antimalarial drugs',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: unitId,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: [
                for (final u in bank.units)
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
              '"Generate with AI" to fill it.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final t = await QuestionRepository.addCustomTopic(
                name,
                unitId: unitId,
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
  await bank.reload();
  if (context.mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TopicScreen(topic: created)),
    );
  }
}

class QuestionBankTab extends StatelessWidget {
  const QuestionBankTab({super.key});

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        6,
        16,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        PrimaryButton(
          key: TourKeys.practise,
          icon: Icons.play_arrow_rounded,
          label: 'Practise',
          onPressed: () => showPracticeSetup(
            context,
            initialTopics: bank.topics.map((t) => t.id).toSet(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Choose topics, how many questions, and bank or AI questions.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        for (final unit in bank.units)
          Builder(
            builder: (context) {
              final topics = bank.topicsOf(unit.id);
              final total = topics.fold<int>(
                0,
                (n, t) => n + bank.statsOf(t.id).total,
              );
              final mastered = topics.fold<int>(
                0,
                (n, t) => n + bank.statsOf(t.id).mastered,
              );
              final share = total == 0 ? 0.0 : mastered / total;

              return Padding(
                key: unit.id == bank.units.first.id ? TourKeys.firstUnit : null,
                padding: const EdgeInsets.only(bottom: 14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => UnitScreen(unit: unit)),
                  ),
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
                                  Text(
                                    unit.name,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${topics.length} topics · $total questions',
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
                ),
              );
            },
          ),
      ],
    );
  }
}
