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

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _deleteSelected(AlarmProvider provider) async {
    final n = _selected.length;
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
    await provider.deleteAlarms(ids);
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

  void _openEditor(BuildContext context, [AlarmItem? alarm]) {
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
          child: Stack(
            children: [
              ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  6,
                  16,
                  90 + MediaQuery.paddingOf(context).bottom,
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
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.07,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    next == null
                                        ? Icons.notifications_off_rounded
                                        : Icons.notifications_active_rounded,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      next == null
                                          ? 'No alarm is switched on'
                                          : 'Next alarm '
                                                '${describeTimeUntil(next.$2, now)} '
                                                '(${formatClock(next.$2, use24Hour: use24)})',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                    _EmptyAlarms(
                      key: TourKeys.addAlarm,
                      onAdd: () => _openEditor(context),
                    ),
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
                        onToggle: (v) {
                          a.isEnabled = v;
                          provider.updateAlarm(a);
                        },
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
              ),
              if (provider.alarms.isNotEmpty && !selecting)
                Positioned(
                  right: 16,
                  // Sits just above the navigation bar on every screen size.
                  bottom: 12 + MediaQuery.paddingOf(context).bottom,
                  child: PrimaryButton(
                    key: TourKeys.addAlarm,
                    icon: Icons.add_rounded,
                    label: 'Add Alarm',
                    onPressed: () => _openEditor(context),
                  ),
                ),
            ],
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
    final current = {for (final a in widget.alarms) a.id: a};
    final next = <AlarmItem>[];
    for (final a in _shown) {
      if (current.containsKey(a.id)) {
        next.add(current[a.id]!);
        _leaving.remove(a.id); // deleted then re-added
      } else {
        next.add(a);
        _leaving.add(a.id);
      }
    }
    final shownIds = _shown.map((a) => a.id).toSet();
    next.addAll(widget.alarms.where((a) => !shownIds.contains(a.id)));
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

class _EmptyAlarms extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyAlarms({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.alarm_add_rounded, size: 32),
            ),
            const SizedBox(height: 14),
            Text('No alarms yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Set one and wake up by answering questions.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              icon: Icons.add_rounded,
              label: 'Add Alarm',
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
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = alarm;
    final on = a.isEnabled;
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
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (a.activeDays.isEmpty)
                      const Pill('Once', icon: Icons.looks_one_rounded)
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
