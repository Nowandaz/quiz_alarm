/// Multi-select of topics: units are listed first and open to show their
/// topics; with a search box and "all" tick boxes. Used when choosing what an
/// alarm asks about and what a revision session covers.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/bank_provider.dart';
import 'app_widgets.dart';

class TopicPicker extends StatefulWidget {
  /// Ids of the topics that are ticked.
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  const TopicPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<TopicPicker> createState() => _TopicPickerState();
}

class _TopicPickerState extends State<TopicPicker> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _open = {}; // units whose topics are showing
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Tick box state for a group: all, none, or some (null).
  bool? _state(Set<String> ids) {
    if (ids.isEmpty) return false;
    final n = ids.where(widget.selected.contains).length;
    return n == 0 ? false : (n == ids.length ? true : null);
  }

  /// Ticks every id in [ids], or unticks them all if they were all ticked.
  void _toggleAll(Set<String> ids) {
    final all = widget.selected.containsAll(ids);
    widget.onChanged(
      all ? widget.selected.difference(ids) : widget.selected.union(ids),
    );
  }

  void _toggle(String id) => widget.onChanged(
    widget.selected.contains(id)
        ? widget.selected.difference({id})
        : {...widget.selected, id},
  );

  @override
  Widget build(BuildContext context) {
    final bank = context.watch<BankProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (bank.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final everything = bank.topics.map((t) => t.id).toSet();

    Widget topicRow(String id, String name, int count) => InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _toggle(id),
      child: Padding(
        padding: const EdgeInsets.only(left: 30),
        child: Row(
          children: [
            Checkbox(
              value: widget.selected.contains(id),
              onChanged: (_) => _toggle(id),
            ),
            Expanded(child: Text(name)),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                plural(count, 'question'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );

    var anyMatch = false;
    final unitBlocks = <Widget>[];
    for (final unit in bank.units) {
      final topics = bank.topicsOf(unit.id);
      final unitMatches = unit.name.toLowerCase().contains(q);
      // While searching, show a unit's matching topics (or all of them if
      // the unit itself matches).
      final shown = !searching || unitMatches
          ? topics
          : topics.where((t) => t.name.toLowerCase().contains(q)).toList();
      if (searching && shown.isEmpty) continue;
      anyMatch = true;

      final ids = topics.map((t) => t.id).toSet();
      final picked = ids.where(widget.selected.contains).length;
      // The tick box acts on what is on screen: while searching that is
      // only the topics shown, never ones the search has hidden.
      final shownIds = shown.map((t) => t.id).toSet();
      final open = searching || _open.contains(unit.id);

      unitBlocks.add(
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              // The unit: tick = all its topics, tap = show its topics.
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: searching
                    ? null
                    : () => setState(() {
                        if (!_open.remove(unit.id)) _open.add(unit.id);
                      }),
                child: Row(
                  children: [
                    Checkbox(
                      tristate: true,
                      value: _state(shownIds),
                      onChanged: shownIds.isEmpty
                          ? null
                          : (_) => _toggleAll(shownIds),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(unit.name, style: theme.textTheme.titleSmall),
                          Text(
                            picked == 0
                                ? plural(topics.length, 'topic')
                                : '$picked of '
                                      '${plural(topics.length, 'topic')} selected',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (!searching)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            Icons.expand_more_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: !open
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        children: [
                          for (final t in shown)
                            topicRow(t.id, t.name, bank.statsOf(t.id).total),
                          const SizedBox(height: 6),
                        ],
                      ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search units and topics',
            prefixIcon: const Icon(Icons.search_rounded),
            isDense: true,
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
        const SizedBox(height: 4),
        if (!searching)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: everything.isEmpty ? null : () => _toggleAll(everything),
            child: Row(
              children: [
                Checkbox(
                  tristate: true,
                  value: _state(everything),
                  onChanged: everything.isEmpty
                      ? null
                      : (_) => _toggleAll(everything),
                ),
                Expanded(
                  child: Text('All units', style: theme.textTheme.titleSmall),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        ...unitBlocks,
        if (searching && !anyMatch)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Nothing matches "$_query".'),
          ),
      ],
    );
  }
}

/// Opens [TopicPicker] in a bottom sheet. Returns the chosen topic ids
/// (empty = all topics), or null if the sheet was dismissed.
Future<Set<String>?> showTopicPickerSheet(
  BuildContext context, {
  required Set<String> initial,
  String title = 'Topics',
}) {
  var current = {...initial};
  final allCount = context.read<BankProvider>().topics.length;
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8,
          ),
          child: Padding(
            // Room for the keyboard, so the list and Done stay in view
            // while searching.
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  // Every topic ticked means the same as none ticked.
                  current.isEmpty
                      ? 'All topics'
                      : current.length == allCount
                      ? 'All topics ($allCount)'
                      : '${plural(current.length, 'topic')} selected',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: TopicPicker(
                      selected: current,
                      onChanged: (s) => setSheetState(() => current = s),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, current),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
