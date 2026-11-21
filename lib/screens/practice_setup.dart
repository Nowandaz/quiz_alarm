/// The sheet that opens before a practice session: how many questions,
/// which topics, where the questions come from (saved bank, written now by
/// the AI, or both) and whether the AI tutor explains each answer.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/bank_provider.dart';
import '../services/ai_client.dart';
import '../widgets/app_widgets.dart';
import '../widgets/topic_picker.dart';
import 'practice_screen.dart';

/// Opens the set-up sheet with [initialTopics] ticked, then starts the
/// session. [title] names the session in the reports.
Future<void> showPracticeSetup(
  BuildContext context, {
  required Set<String> initialTopics,
  String title = 'Practice',
}) async {
  final hasKey = AiClient.available;
  final bank = context.read<BankProvider>();

  var topics = {...initialTopics};
  var count = 10;
  var customCount = false; // true once "Custom" is picked
  var source = PracticeSource.bank;
  var tutor = hasKey;
  const counts = [5, 10, 20, 30];

  final start = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final theme = Theme.of(ctx);
        final available = bank.topics
            .where((t) => topics.contains(t.id))
            .fold<int>(0, (n, t) => n + bank.statsOf(t.id).total);
        final canStart =
            topics.isNotEmpty &&
            (source != PracticeSource.bank || available > 0);

        Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(text, style: theme.textTheme.titleSmall),
        );

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.88,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Set up practice', style: theme.textTheme.titleLarge),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          label('How many questions'),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final n in counts)
                                ChoiceChip(
                                  label: Text('$n'),
                                  selected: !customCount && count == n,
                                  showCheckmark: false,
                                  onSelected: (_) => refresh(() {
                                    count = n;
                                    customCount = false;
                                  }),
                                ),
                              ChoiceChip(
                                label: Text(
                                  customCount ? 'Custom: $count' : 'Custom',
                                ),
                                selected: customCount,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    refresh(() => customCount = true),
                              ),
                            ],
                          ),
                          // Any number from 1 to 30.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            alignment: Alignment.topCenter,
                            child: !customCount
                                ? const SizedBox(width: double.infinity)
                                : Row(
                                    children: [
                                      IconButton(
                                        tooltip: 'Fewer',
                                        icon: const Icon(Icons.remove_rounded),
                                        onPressed: count > 1
                                            ? () => refresh(() => count--)
                                            : null,
                                      ),
                                      Expanded(
                                        child: Slider(
                                          min: 1,
                                          max: 30,
                                          divisions: 29,
                                          label: '$count',
                                          value: count.toDouble(),
                                          onChanged: (v) =>
                                              refresh(() => count = v.round()),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'More',
                                        icon: const Icon(Icons.add_rounded),
                                        onPressed: count < 30
                                            ? () => refresh(() => count++)
                                            : null,
                                      ),
                                    ],
                                  ),
                          ),
                          if (source == PracticeSource.bank &&
                              topics.isNotEmpty &&
                              available > 0 &&
                              available < count)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'These topics have $available saved '
                                'question${available == 1 ? '' : 's'}, so '
                                'the session will have $available.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          label('Questions from'),
                          SegmentedButton<PracticeSource>(
                            showSelectedIcon: false,
                            // Signed out, only AI and Both are greyed: Bank
                            // still works and stays visibly selected.
                            segments: [
                              const ButtonSegment(
                                value: PracticeSource.bank,
                                label: Text('Bank'),
                              ),
                              ButtonSegment(
                                value: PracticeSource.ai,
                                label: const Text('AI'),
                                enabled: hasKey,
                              ),
                              ButtonSegment(
                                value: PracticeSource.both,
                                label: const Text('Both'),
                                enabled: hasKey,
                              ),
                            ],
                            selected: {source},
                            onSelectionChanged: (s) =>
                                refresh(() => source = s.first),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              !hasKey
                                  ? signInForAi
                                  : switch (source) {
                                      PracticeSource.bank =>
                                        'Saved questions. Works offline. '
                                            'Ones you have not seen or got '
                                            'wrong come first.',
                                      PracticeSource.ai =>
                                        'The AI writes new questions now '
                                            '(needs internet, up to a minute). '
                                            'They are saved to the bank too.',
                                      PracticeSource.both =>
                                        'Half newly written by the AI, half '
                                            'from the saved bank.',
                                    },
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          label('Topics'),
                          TopicPicker(
                            selected: topics,
                            onChanged: (s) => refresh(() => topics = s),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('AI tutor'),
                            subtitle: Text(
                              hasKey
                                  ? 'Explains where your answer went wrong.'
                                  : '$signInForAi You still get the saved '
                                        'explanations.',
                            ),
                            value: tutor && hasKey,
                            onChanged: hasKey
                                ? (v) => refresh(() => tutor = v)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  PrimaryButton(
                    icon: Icons.play_arrow_rounded,
                    label: topics.isEmpty
                        ? 'Pick at least one topic'
                        : (canStart
                              ? 'Start'
                              : 'No saved questions in these topics'),
                    onPressed: canStart ? () => Navigator.pop(ctx, true) : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  if (start != true || !context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PracticeScreen(
        title: title,
        selectors: topics.toList(),
        aiTutor: tutor && hasKey,
        limit: count,
        source: source,
      ),
    ),
  );
}
