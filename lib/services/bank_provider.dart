/// Keeps the list of units, topics and progress in memory for the screens,
/// and reloads it whenever the question bank or the plan changes.
library;

import 'package:material_ui/material_ui.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import 'entitlements.dart';
import 'question_service.dart';

class BankProvider extends ChangeNotifier {
  List<StudyUnit> units = [];
  List<Topic> topics = [];
  Map<String, TopicStats> stats = {};

  /// Ids of the units the user archived. They stay in [units] and
  /// [topics] (an alarm set on one still works and is still described);
  /// the screens that offer choices use [activeUnits] / [activeTopics].
  Set<String> archived = {};
  bool isLoading = true;
  String? error;

  BankProvider() {
    QuestionService.changes.addListener(reload);
    // The plan decides which topics are open and how many questions count.
    Entitlements.instance.addListener(reload);
    reload();
  }

  Future<void> reload() async {
    try {
      final u = await QuestionRepository.getUnits();
      final t = await QuestionRepository.getTopics();
      final s = await QuestionRepository.getStats();
      archived = await QuestionRepository.getArchivedUnits();
      units = u;
      topics = t;
      stats = s;
      error = null;
    } catch (e) {
      error = 'The question bank could not be opened: $e';
    }
    isLoading = false;
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  /// Whether the plan opens [topic] (see QuestionRepository.isOpen).
  bool isOpen(Topic topic) => QuestionRepository.isOpen(topic);

  /// Topics that can be chosen right now: open, and not archived. This
  /// is what "all topics" stands for.
  List<Topic> get openTopics => activeTopics.where(isOpen).toList();

  List<Topic> topicsOf(String unitId) =>
      topics.where((t) => t.unitId == unitId).toList();

  TopicStats statsOf(String topicId) => stats[topicId] ?? const TopicStats();

  bool isArchived(String unitId) => archived.contains(unitId);

  /// Units that are not archived: what Banks, the topic picker and
  /// practice set-up offer.
  List<StudyUnit> get activeUnits =>
      units.where((u) => !archived.contains(u.id)).toList();

  List<StudyUnit> get archivedUnits =>
      units.where((u) => archived.contains(u.id)).toList();

  /// Topics of the units that are not archived.
  List<Topic> get activeTopics =>
      topics.where((t) => !archived.contains(t.unitId)).toList();

  /// Hides a unit or brings it back. Only hides: nothing is deleted.
  Future<void> setArchived(String unitId, bool value) async {
    await QuestionRepository.setUnitArchived(unitId, value);
    await reload();
  }

  /// Short label for a stored selection, e.g. "Pharmacology".
  String describe(Iterable<String> selectors) => QuestionRepository.describeIn(
    selectors,
    units,
    topics,
    archived: archived,
  );

  /// Topic ids a stored selection stands for. Empty selection = empty set
  /// here (the caller shows that as "All topics").
  Set<String> selectedIds(Iterable<String> selectors) =>
      selectors.where((s) => s.trim().isNotEmpty).isEmpty
      ? <String>{}
      : QuestionRepository.resolveIn(
          selectors,
          units,
          topics,
          archived: archived,
        ).toSet();

  @override
  void dispose() {
    QuestionService.changes.removeListener(reload);
    Entitlements.instance.removeListener(reload);
    _disposed = true;
    super.dispose();
  }
}
