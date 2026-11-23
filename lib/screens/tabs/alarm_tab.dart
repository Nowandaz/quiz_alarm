/// Alarms tab: a hero card with the clock and the next alarm, then the
/// list of alarms.
library;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/alarm_provider.dart';
import '../../services/bank_provider.dart';
import '../../services/theme_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/alarm_health.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/coach_tour.dart';
import '../../widgets/clock_display.dart';
import '../../widgets/lock_prompt.dart';
import '../alarm_ring_screen.dart';
import '../edit_alarm_screen.dart';

class AlarmTab extends StatefulWidget {
  const AlarmTab({super.key});

  @override
  State<AlarmTab> createState() => _AlarmTabState();
}

class _AlarmTabState extends State<AlarmTab> {
  // Alarms ticked for deletion. Long-press an alarm to start selecting.
  final Set<int> _selected = {};

  // Below this height of the tab the "Add alarm" button stops floating
  // over the list (see build).
  static const double _shortScreen = 600;

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _deleteSelected(AlarmProvider provider) async {
    final n = _selected.length;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $n alarm${n == 1 ? '' : 's'}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    setState(_selected.clear);
    if (await provider.deleteAlarms(ids) > 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text(AlarmProvider.snoozeLockMessage)),
      );
    }
  }

  /// When the soonest enabled alarm will ring, and which one it is.
  (AlarmItem, DateTime)? _next(AlarmProvider provider) {
    final now = DateTime.now();
    (AlarmItem, DateTime)? best;
    for (final a in provider.alarms) {
      // What the phone has registered also covers a running snooze,
      // including the snooze of a ring-once alarm that already shows as off.
      final registered = provider.nextRing(a);
      if (!a.isEnabled && registered == null) continue;
      final when =
          registered ?? calculateNextTrigger(a.time, a.activeDays, now);
      if (best == null || when.isBefore(best.$2)) best = (a, when);
    }
    return best;
  }

  /// The switch on a card: says what happened once the phone has been
  /// told, so the user knows the alarm really is set (and for when).
  Future<void> _setEnabled(AlarmProvider provider, AlarmItem card, bool on) {
    final messenger = ScaffoldMessenger.of(context);
    final use24 = context.read<ThemeProvider>().use24Hour;
    return provider.setEnabled(card, on).then((done) {
      if (!done) {
        // Snoozed once: switching it off would be a way round the quiz.
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text(AlarmProvider.snoozeLockMessage)),
          );
        return;
      }
      // The card may hold the alarm as it was before an edit.
      final alarm = provider.alarms.where((a) => a.id == card.id).firstOrNull;
      if (alarm == null) return; // deleted meanwhile
      final next = on ? provider.nextRing(alarm) : null;
      final text = !on
          ? 'Alarm off'
          : next == null
          ? 'Alarm on'
          : describeAlarmSet(next, DateTime.now(), use24Hour: use24);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(duration: const Duration(seconds: 3), content: Text(text)),
        );
    });
  }

  void _openEditor(BuildContext context, [AlarmItem? alarm]) {
    // A new alarm at the plan's limit: say why not, and what lifts it.
    if (alarm == null && !context.read<AlarmProvider>().canAddAlarm) {
      showAlarmLimitSheet(context);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditAlarmScreen(existingAlarm: alarm),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final use24 = context.watch<ThemeProvider>().use24Hour;
    final theme = Theme.of(context);

    return Consumer<AlarmProvider>(
      builder: (context, provider, child) {
        _selected.removeWhere((id) => !provider.alarms.any((a) => a.id == id));
        final selecting = _selected.isNotEmpty;

        return PopScope(
          // Back leaves selection mode before it leaves the app.
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(_selected.clear);
          },
          child: LayoutBuilder(
            builder: (context, box) {
              final safeBottom = MediaQuery.paddingOf(context).bottom;
              final showAdd = provider.alarms.isNotEmpty && !selecting;
              // On a short screen the clock card and the "Your alarms" row
              // fill the whole view, so a floating button would sit on the
              // row and take its taps. There it gets a strip of its own
              // under the list instead.
              final docked = box.maxHeight < _shortScreen;
              final addButton = PrimaryButton(
                key: TourKeys.addAlarm,
                icon: Icons.add_rounded,
                label: 'Add alarm',
                onPressed: () => _openEditor(context),
              );
              final list = ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  6,
                  16,
                  // Room to scroll the last card clear of the floating
                  // button (12 below it + 56 tall + a gap above).
                  showAdd ? (docked ? 16 : 96 + safeBottom) : 24 + safeBottom,
                ),
                children: [
                  if (!provider.backend.isSimulated) const AlarmHealthBanner(),
                  EveryHalfMinute(
                    key: TourKeys.clock,
                    builder: (context) {
                      final now = DateTime.now();
                      final next = _next(provider);
                      return GlossCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    greetingFor(now.hour),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                Text(
                                  DateFormat('EEE d MMM').format(now),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Tap to switch between digital and analog.
                            const ClockDisplay(),
                            const SizedBox(height: 16),
                            _NextAlarmLine(
                              text: next != null
                                  // Only how long until the next ring.
                                  ? 'Next alarm '
                                        '${describeTimeUntil(next.$2, now)}'
                                  : 'No alarm is on',
                              on: next != null,
                              // With alarms that are all off, the line is
                              // the way to a new one. With none at all the
                              // welcome card below already offers it.
                              onTap: next == null && provider.alarms.isNotEmpty
                                  ? () => _openEditor(context)
                                  : null,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  if (selecting)
                    // Selection bar: how many are ticked, delete, cancel.
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Cancel selection',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(_selected.clear),
                        ),
                        Expanded(
                          child: Text(
                            '${_selected.length} selected',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _selected.addAll(provider.alarms.map((a) => a.id));
                          }),
                          child: const Text('All'),
                        ),
                        IconButton(
                          tooltip: 'Delete selected',
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            color: theme.colorScheme.error,
                          ),
                          onPressed: () => _deleteSelected(provider),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Your alarms',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        TextButton.icon(
                          key: TourKeys.testQuiz,
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text('Test the quiz'),
                          onPressed: () {
                            // A preview: it can be closed and does not touch
                            // any real alarm.
                            final sample = provider.alarms.isNotEmpty
                                ? provider.alarms.first
                                : AlarmItem(
                                    id: 1,
                                    time: TimeOfDay.now(),
                                    topics: const [],
                                  );
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AlarmRingScreen(
                                  alarm: sample,
                                  preview: true,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  if (provider.backend.isSimulated)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Simulator: alarms ring inside the app. Tap the bell '
                        'on an alarm to ring it in 3 s.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (provider.alarms.isEmpty)
                    _EmptyAlarms(onAdd: () => _openEditor(context)),
                  _AlarmList(
                    alarms: provider.alarms,
                    itemBuilder: (a) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _AlarmCard(
                        alarm: a,
                        topics: bank.describe(a.topics),
                        use24Hour: use24,
                        simulated: provider.backend.isSimulated,
                        selecting: selecting,
                        selected: _selected.contains(a.id),
                        onLongPress: () => _toggle(a.id),
                        onTap: selecting
                            ? () => _toggle(a.id)
                            : () => _openEditor(context, a),
                        snoozedUntil: provider.snoozedUntil(a),
                        nextRing: a.isEnabled
                            ? provider.nextRing(a) ??
                                  calculateNextTrigger(
                                    a.time,
                                    a.activeDays,
                                    DateTime.now(),
                                  )
                            : null,
                        onToggle: (v) => _setEnabled(provider, a, v),
                        onRingNow: () {
                          provider.ringSoon(a);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              duration: Duration(seconds: 2),
                              content: Text('Ringing in 3 s...'),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
              // The same widgets around the list in every case, so it keeps
              // its scroll position when the button comes or goes.
              return Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        list,
                        if (showAdd && !docked)
                          Positioned(
                            right: 16,
                            // Sits just above the navigation bar.
                            bottom: 12 + safeBottom,
                            child: addButton,
                          ),
                      ],
                    ),
                  ),
                  if (showAdd && docked)
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 6, 16, 8 + safeBottom),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: addButton,
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// The alarm cards. A new alarm slides in; a deleted one shrinks and fades
/// away instead of vanishing.
class _AlarmList extends StatefulWidget {
  final List<AlarmItem> alarms;
  final Widget Function(AlarmItem) itemBuilder;
  const _AlarmList({required this.alarms, required this.itemBuilder});

  @override
  State<_AlarmList> createState() => _AlarmListState();
}

class _AlarmListState extends State<_AlarmList> {
  // What is on screen, in order, including alarms that are animating out.
  late List<AlarmItem> _shown = List.of(widget.alarms);
  final Set<int> _leaving = {};
  bool _first = true;

  @override
  void didUpdateWidget(_AlarmList old) {
    super.didUpdateWidget(old);
    _first = false;
    // The list's own order (by time of day) is what shows. An alarm that
    // was just deleted stays at its old position while it animates out.
    final current = {for (final a in widget.alarms) a.id};
    final next = List.of(widget.alarms);
    for (var i = 0; i < _shown.length; i++) {
      final a = _shown[i];
      if (current.contains(a.id)) {
        _leaving.remove(a.id); // deleted then re-added
      } else {
        next.insert(i.clamp(0, next.length), a);
        _leaving.add(a.id);
      }
    }
    _shown = next;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final a in _shown)
          AppearDisappear(
            key: ValueKey(a.id),
            animateIn: !_first,
            leaving: _leaving.contains(a.id),
            onGone: () => setState(() {
              _shown.removeWhere((x) => x.id == a.id);
              _leaving.remove(a.id);
            }),
            child: IgnorePointer(
              ignoring: _leaving.contains(a.id),
              child: widget.itemBuilder(a),
            ),
          ),
      ],
    );
  }
}

/// The line at the bottom of the clock card: when the next alarm rings,
/// or that none will. With [onTap] it is a prompt that opens the editor.
class _NextAlarmLine extends StatelessWidget {
  final String text;
  final bool on;
  final VoidCallback? onTap;
  const _NextAlarmLine({required this.text, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                on
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_off_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown before the first alarm exists: how the app works in three steps
/// and the one thing to do next.
class _EmptyAlarms extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyAlarms({required this.onAdd});

  static const List<String> _steps = [
    'Set an alarm.',
    'When it rings, answer questions from your topics.',
    'Get enough right in a row and it stops.',
  ];

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
            Text(
              'Welcome to Brain O\' Clock',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'An alarm that only stops when you answer revision questions.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          fontFamily: AppTheme.display,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_steps[i])),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            // The only add button on screen in this state, so the tour
            // points here.
            PrimaryButton(
              key: TourKeys.addAlarm,
              icon: Icons.add_rounded,
              label: 'Add your first alarm',
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmCard extends StatelessWidget {
  final AlarmItem alarm;
  final String topics;
  final bool use24Hour;
  final bool simulated;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selecting;
  final bool selected;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRingNow;

  /// When a running snooze of this alarm will ring, if there is one.
  final DateTime? snoozedUntil;

  /// When this alarm rings next, while it is switched on.
  final DateTime? nextRing;

  const _AlarmCard({
    required this.onLongPress,
    required this.selecting,
    required this.selected,
    required this.alarm,
    required this.topics,
    required this.use24Hour,
    required this.simulated,
    required this.onTap,
    required this.onToggle,
    required this.onRingNow,
    this.snoozedUntil,
    this.nextRing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = alarm;
    // A running snooze will still ring, so the card shows as on.
    final snoozed = snoozedUntil != null;
    final on = a.isEnabled || snoozed;
    final ink = on ? scheme.onSurface : scheme.onSurfaceVariant;
    final t = DateTime(2020, 1, 1, a.time.hour, a.time.minute);
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Opacity(
      opacity: on ? 1 : 0.6,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            DateFormat(use24Hour ? 'HH:mm' : 'h:mm').format(t),
                            style: TextStyle(
                              fontFamily: AppTheme.display,
                              fontSize: 42,
                              height: 1.05,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.5,
                              color: ink,
                            ),
                          ),
                          if (!use24Hour) ...[
                            const SizedBox(width: 6),
                            Text(
                              DateFormat('a').format(t),
                              style: TextStyle(
                                fontFamily: AppTheme.display,
                                fontSize: 17,
                                fontWeight: FontWeight.w500,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (selecting)
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          size: 28,
                        ),
                      )
                    else ...[
                      if (simulated)
                        IconButton(
                          tooltip: 'Ring in 3 seconds',
                          icon: const Icon(Icons.notifications_active_outlined),
                          onPressed: onRingNow,
                        ),
                      Switch(value: on, onChanged: onToggle),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  a.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: ink),
                ),
                if (snoozed) ...[
                  const SizedBox(height: 8),
                  Pill(
                    'Snoozed. Rings at '
                    '${formatClock(snoozedUntil!, use24Hour: use24Hour)}',
                    icon: Icons.snooze_rounded,
                    color: scheme.primary,
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (a.activeDays.isEmpty)
                      // "Once" alone does not say which day it rings.
                      Pill(
                        nextRing == null
                            ? 'Once'
                            : 'Once \u00b7 '
                                  '${describeDay(nextRing!, DateTime.now())}',
                        icon: Icons.looks_one_rounded,
                      )
                    else
                      for (var d = 1; d <= 7; d++)
                        Container(
                          width: 24,
                          height: 24,
                          margin: const EdgeInsets.only(right: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: a.activeDays.contains(d)
                                ? scheme.primary
                                : Colors.transparent,
                            border: Border.all(
                              color: a.activeDays.contains(d)
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                            ),
                          ),
                          child: Text(
                            letters[d - 1],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: a.activeDays.contains(d)
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    const Spacer(),
                    Pill(
                      AlarmItem.difficultyName(a.requiredStreak),
                      icon: Icons.bolt_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.menu_book_rounded,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        topics,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
