/// Keeps the list of units, sections, topics and progress in memory for the
/// screens, and reloads it whenever the question bank or the plan changes.
///
/// The bank is a tree: unit -> (subunit) -> section -> topic. A unit may
/// also hold topics that are in no section ([unfiledTopics]).
library;

import 'package:material_ui/material_ui.dart';

import '../data/question_repository.dart';
import '../models/models.dart';
import 'entitlements.dart';
import 'question_service.dart';

class BankProvider extends ChangeNotifier {
  List<StudyUnit> units = [];

  /// Subunits and sections of every unit, in the order they are shown.
  List<Section> sections = [];
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
      final x = await QuestionRepository.getSections();
      final t = await QuestionRepository.getTopics();
      final s = await QuestionRepository.getStats();
      archived = await QuestionRepository.getArchivedUnits();
      units = u;
      sections = x;
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

  // ------------------------------------------------- subunits and sections

  Section? sectionById(String? id) =>
      id == null ? null : sections.where((x) => x.id == id).firstOrNull;

  /// The subunit [section] is in, or null.
  Section? parentOf(Section section) {
    final parent = sectionById(section.parentId);
    return parent != null && parent.isSubunit ? parent : null;
  }

  /// What a unit holds at its top level: its subunits, and the sections
  /// that are in no subunit.
  List<Section> sectionsOf(String unitId) => sections
      .where((x) => x.unitId == unitId && (x.isSubunit || parentOf(x) == null))
      .toList();

  /// The sections of a subunit.
  List<Section> childrenOf(String sectionId) =>
      sections.where((x) => !x.isSubunit && x.parentId == sectionId).toList();

  /// [sectionsOf] without the ones that hold no topic: what the screens
  /// list.
  List<Section> filledSectionsOf(String unitId) =>
      sectionsOf(unitId).where((x) => topicsUnder(x.id).isNotEmpty).toList();

  /// [childrenOf] without the sections that hold no topic.
  List<Section> filledChildrenOf(String sectionId) =>
      childrenOf(sectionId).where((x) => topicsIn(x.id).isNotEmpty).toList();

  /// The topics filed straight under a section.
  List<Topic> topicsIn(String sectionId) =>
      topics.where((t) => t.sectionId == sectionId).toList();

  /// Every topic beneath a section or a subunit.
  List<Topic> topicsUnder(String sectionId) => [
    ...topicsIn(sectionId),
    for (final child in childrenOf(sectionId)) ...topicsIn(child.id),
  ];

  /// The section a topic is filed under, or null (also when the section
  /// it names is not on the phone).
  Section? sectionOf(Topic topic) {
    final section = sectionById(topic.sectionId);
    return section != null && !section.isSubunit ? section : null;
  }

  /// Topics of a unit that are in no section ("Other topics").
  List<Topic> unfiledTopics(String unitId) =>
      topicsOf(unitId).where((t) => sectionOf(t) == null).toList();

  /// [topics] added up: questions, answered and mastered. Locked topics
  /// have no figures, so they add nothing.
  TopicStats statsFor(Iterable<Topic> topics) {
    var total = 0, seen = 0, mastered = 0;
    for (final t in topics) {
      final s = statsOf(t.id);
      total += s.total;
      seen += s.seen;
      mastered += s.mastered;
    }
    return TopicStats(total: total, seen: seen, mastered: mastered);
  }

  /// The figures of everything beneath a section or a subunit.
  TopicStats sectionStats(String sectionId) => statsFor(topicsUnder(sectionId));

  /// True when [topics] is not empty and the plan opens none of them.
  bool allLocked(Iterable<Topic> topics) =>
      topics.isNotEmpty && !topics.any(isOpen);

  /// Whether every topic beneath a section or a subunit is locked.
  bool isSectionLocked(String sectionId) => allLocked(topicsUnder(sectionId));

  /// Where a topic sits, for a line under its name: "Pathology", or
  /// "Pathology · Blood film" when it is in a section (left out when
  /// the section is simply called what the topic is).
  String placeOf(Topic topic) {
    final unit = units.where((u) => u.id == topic.unitId).firstOrNull;
    final section = sectionOf(topic);
    return [
      if (unit != null) unit.name,
      if (section != null &&
          section.name.toLowerCase() != topic.name.toLowerCase())
        section.name,
    ].join(' \u00b7 ');
  }

  /// Whether the section or the subunit [topic] is in is called something
  /// containing [query] (lower case).
  bool sectionMatches(Topic topic, String query) {
    final section = sectionOf(topic);
    if (section == null) return false;
    return section.name.toLowerCase().contains(query) ||
        (parentOf(section)?.name.toLowerCase().contains(query) ?? false);
  }

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
    sections: sections,
    archived: archived,
  );

  /// What an alarm stores for the ticked [topicIds]
  /// (see QuestionRepository.selectorsFor).
  List<String> selectorsFor(Set<String> topicIds) =>
      QuestionRepository.selectorsFor(topicIds, units, sections, topics);

  /// Topic ids a stored selection stands for. Empty selection = empty set
  /// here (the caller shows that as "All topics").
  Set<String> selectedIds(Iterable<String> selectors) =>
      selectors.where((s) => s.trim().isNotEmpty).isEmpty
      ? <String>{}
      : QuestionRepository.resolveIn(
          selectors,
          units,
          topics,
          sections: sections,
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
