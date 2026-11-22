/// Marks a typed (short-answer) reply against the stored answer, on the
/// phone, with no network. Pure Dart: no Flutter, no database.
///
/// The steps, in order:
///
/// 1. **Tidy both texts** ([normalizeText]): lower case, accents removed,
///    Greek letters written out (β becomes "beta"), every hyphen, slash
///    and punctuation mark turned into a space. Roman numerals become
///    digits ("factor VIII" = "factor 8"). Filler words (a, an, the, of,
///    to, is, are, it, its, by, in, on, for, with, and, or) are dropped,
///    but never when they are the whole answer, and "a" is kept when it
///    names something ("vitamin A", "hepatitis A").
/// 2. **Concepts and synonyms**: the stored answer is a list of things
///    that must all be said (split on " + ", ";", "," and " and "), and
///    each of them has a list of accepted wordings (the alternative
///    answers, a trailing bracket such as "(NAC)", and "X or Y").
/// 3. **Sliding window**: each wording is squeezed into one string with
///    no spaces and compared with every run of neighbouring words in the
///    reply, squeezed the same way. So "n acetyl cysteine" and
///    "n-acetylcysteine" are the same thing.
/// 4. **Typos**: none for a wording of up to 4 letters, one for 5 to 8,
///    two for 9 or more (swapping two neighbouring letters counts as
///    one). Digits, single letters that name something and Greek letters
///    may never be mistyped ("COX-1" is not "COX-2").
///
/// On top of that a typo is refused when it turns the word into its
/// opposite or a look-alike term ([confusables], [AnswerGrader.knownTerms])
/// or changes how the word starts, "not X" does not count as X, British and American spellings are
/// treated as equal, numbers are compared as numbers, and a reply that
/// lists many alternatives is not given the mark.
library;

import 'dart:math';

/// The outcome of marking one typed answer.
class GradeResult {
  final bool correct;

  /// True when every part matched with no typo at all.
  final bool exact;

  /// The parts of the answer found in the reply, and those not found.
  final List<String> matched;
  final List<String> missing;

  /// The properly spelled answer, when a typo was forgiven.
  final String? corrected;

  /// True when the reply listed so many alternatives that it was not
  /// given the mark even though the answer is among them.
  final bool shotgun;

  const GradeResult({
    required this.correct,
    this.exact = false,
    this.matched = const [],
    this.missing = const [],
    this.corrected,
    this.shotgun = false,
  });

  static const GradeResult wrong = GradeResult(correct: false);

  /// One short line for the feedback area, or null when there is
  /// nothing to add: the right spelling, or the part that was left out.
  String? get hint {
    if (correct) return corrected == null ? null : 'Spelling: $corrected';
    if (matched.isNotEmpty && missing.isNotEmpty) {
      return 'Missing: ${missing.join(', ')}';
    }
    return null;
  }
}

/// Word pieces that look alike but mean something else. A typo may not
/// turn one into the other: when the stored answer has one of a pair and
/// the reply has the other, the reply must match exactly.
const List<(String, String)> confusables = [
  // Opposites.
  ('hyper', 'hypo'),
  ('inter', 'intra'),
  ('abduct', 'adduct'),
  ('afferent', 'efferent'),
  ('agonist', 'antagonist'),
  ('increas', 'decreas'),
  ('systol', 'diastol'),
  ('brady', 'tachy'),
  ('oliguria', 'polyuria'),
  ('anterior', 'posterior'),
  ('superior', 'inferior'),
  ('proximal', 'distal'),
  ('flexion', 'extension'),
  ('flexor', 'extensor'),
  ('sympathetic', 'parasympathetic'),
  ('influx', 'efflux'),
  ('endo', 'exo'),
  ('macro', 'micro'),
  ('ante', 'anti'),
  // Look-alike terms.
  ('itis', 'osis'),
  ('ectomy', 'ostomy'),
  ('ectomy', 'otomy'),
  ('otomy', 'ostomy'),
  ('depolar', 'repolar'),
  ('ileum', 'ilium'),
  ('ileum', 'ileus'),
  ('insulin', 'inulin'),
  ('renin', 'rennin'),
  ('creatine', 'creatinine'),
  ('melanin', 'melatonin'),
  ('peritoneum', 'perineum'),
  ('digoxin', 'digitoxin'),
  ('malleus', 'malleolus'),
  ('sulfasalazine', 'sulfadiazine'),
  ('ileal', 'iliac'),
  ('perineal', 'peroneal'),
  ('dysphagia', 'dysphasia'),
  ('aphagia', 'aphasia'),
  ('nephritic', 'nephrotic'),
  ('prednisone', 'prednisolone'),
  ('cortisol', 'cortisone'),
  ('quinine', 'quinidine'),
  ('cytosine', 'cytokine'),
  ('cytosine', 'cytidine'),
  ('thymine', 'thiamine'),
  ('thymine', 'thymidine'),
  ('adenine', 'adenosine'),
  ('guanine', 'guanosine'),
  ('uracil', 'uridine'),
  ('absorption', 'adsorption'),
  ('ethanol', 'methanol'),
  ('ethane', 'methane'),
  ('lactase', 'lactose'),
  ('amylase', 'amylose'),
  ('sucrase', 'sucrose'),
  ('maltase', 'maltose'),
  ('lipase', 'ligase'),
  ('lipase', 'lyase'),
  ('ligase', 'lyase'),
  ('nitrate', 'nitrite'),
  ('sulfate', 'sulfite'),
  ('sulphate', 'sulphite'),
  ('chloride', 'chlorine'),
  ('iodide', 'iodine'),
  ('bromide', 'bromine'),
  ('fluoride', 'fluorine'),
  ('phosphate', 'phosphatase'),
  ('histamine', 'histidine'),
  ('glutamine', 'glutamate'),
  ('aspartate', 'asparagine'),
  ('aldosterone', 'androsterone'),
  ('ureter', 'urethra'),
  ('glycogen', 'glucagon'),
  ('metacarpal', 'metatarsal'),
  ('carpal', 'tarsal'),
  ('mitosis', 'meiosis'),
];

class AnswerGrader {
  /// Other answers in the question bank, squeezed with [termKey]. A typo
  /// that turns the reply into one of these (another real answer) is not
  /// forgiven. Empty until someone fills it; marking works without it.
  static Set<String> knownTerms = <String>{};

  /// How [knownTerms] entries are written: tidied, fillers dropped, no
  /// spaces.
  static String termKey(String text) => _collapse(_tokens(text).stripped).$1;

  /// Typos allowed for a wording of [length] letters (spaces not counted).
  static int allowedTypos(int length) =>
      length <= 4 ? 0 : (length <= 8 ? 1 : 2);

  /// Marks [user] against [answer] and the accepted [alts].
  static GradeResult grade(
    String user,
    String answer, {
    List<String> alts = const [],
  }) {
    if (user.trim().isEmpty || answer.trim().isEmpty) return GradeResult.wrong;
    final forms = buildForms(answer, alts);
    if (forms.isEmpty) return GradeResult.wrong;
    final reply = _tokens(user);
    final ownTerms = {
      for (final f in forms)
        for (final c in f.concepts)
          for (final s in c.synonyms) s.key,
    };

    _Outcome? best;
    for (final form in forms) {
      final outcome = _check(form, user, reply, ownTerms);
      if (outcome.complete) {
        best = outcome;
        break;
      }
      // Only the stored answer itself is used to say what is missing.
      best ??= outcome;
    }
    final o = best!;
    final matched = [
      for (final (i, c) in o.form.concepts.indexed)
        if (o.hits[i] != null) c.display,
    ];
    final missing = [
      for (final (i, c) in o.form.concepts.indexed)
        if (o.hits[i] == null) c.display,
    ];
    if (!o.complete) {
      return GradeResult(correct: false, matched: matched, missing: missing);
    }
    // Listing everything in the hope that one is right earns nothing.
    if (_items(user) > forms.first.concepts.length + 2) {
      return GradeResult(correct: false, matched: matched, shotgun: true);
    }
    final typo = o.hits.any((h) => h!.distance > 0);
    return GradeResult(
      correct: true,
      exact: !typo,
      matched: matched,
      corrected: !typo
          ? null
          : o.form.concepts.length == 1
          ? o.hits.single!.display
          : o.form.display,
    );
  }

  // ------------------------------------------------------------- concepts

  /// Turns the stored answer and its alternatives into the ways the
  /// question can be answered. Each way ("form") is a list of concepts
  /// that must all be present, in any order; each concept is a list of
  /// accepted wordings.
  ///
  /// - The answer is cut into concepts at " + ", ";", "," and " and "
  ///   (never inside brackets or numbers).
  /// - An alternative with the same number of parts adds a wording to
  ///   each concept, by position. An alternative with a different number
  ///   of parts is another whole way to answer.
  /// - A trailing bracket is another wording: "N-acetylcysteine (NAC)".
  ///   Brackets that only add a detail ("(IM)", "(500 mg)", "(in
  ///   adults)") are ignored instead.
  /// - "X or Y" and "X / Y" are two wordings of one concept, but only
  ///   when the answer has a single part: in a multi-part answer "or" is
  ///   read as an ordinary word, because there it usually joins parts.
  static List<AnswerForm> buildForms(String answer, List<String> alts) {
    final parts = _parts(answer);
    if (parts.isEmpty) return const [];
    final single = parts.length == 1;
    final main = [
      for (final p in parts) <_Synonym>[..._synonyms(p, allowOr: single)],
    ];
    final extra = <AnswerForm>[];
    for (final alt in alts) {
      final altParts = _parts(alt);
      if (altParts.isEmpty) continue;
      if (altParts.length == parts.length) {
        for (var i = 0; i < parts.length; i++) {
          main[i].addAll(_synonyms(altParts[i], allowOr: single));
        }
      } else {
        final one = altParts.length == 1;
        extra.add(
          AnswerForm._(alt.trim(), [
            for (final p in altParts)
              AnswerConcept._(_synonyms(p, allowOr: one)),
          ]),
        );
      }
    }
    return [
      AnswerForm._(answer.trim(), [for (final s in main) AnswerConcept._(s)]),
      ...extra,
    ].where((f) => f.concepts.every((c) => c.synonyms.isNotEmpty)).toList();
  }

  static final RegExp _partSeparator = RegExp(
    r'\s\+\s|;|\s+(?:and|&)\s+|,(?!\d{3}(?!\d))',
    caseSensitive: false,
  );

  static List<String> _parts(String text) => _splitTop(
    text,
    _partSeparator,
  ).map((p) => p.trim()).where((p) => _tokens(p).all.isNotEmpty).toList();

  /// Splits at [separator], except inside round brackets.
  static List<String> _splitTop(String text, RegExp separator) {
    final out = <String>[];
    var from = 0;
    for (final m in separator.allMatches(text)) {
      final before = text.substring(0, m.start);
      final depth =
          '('.allMatches(before).length - ')'.allMatches(before).length;
      if (depth > 0) continue;
      out.add(text.substring(from, m.start));
      from = m.end;
    }
    out.add(text.substring(from));
    return out;
  }

  static final RegExp _bracket = RegExp(r'\(([^()]*)\)');
  static final RegExp _orSeparator = RegExp(
    r'\s+or\s+|\s+/\s+|(?<=[A-Za-z]{4})/(?=[A-Za-z]{4})',
    caseSensitive: false,
  );

  /// Words that open a bracket which adds a detail instead of naming the
  /// answer again.
  static const Set<String> _detailWords = {
    'in',
    'for',
    'if',
    'when',
    'eg',
    'e',
    'ie',
    'i',
    'not',
    'usually',
    'especially',
    'approx',
    'approximately',
    'about',
    'at',
    'by',
    'with',
    'without',
    'via',
    'per',
    'first',
    'second',
    'third',
    'oral',
    'orally',
    'intravenous',
    'intramuscular',
    'subcutaneous',
    'topical',
    'high',
    'low',
    'acute',
    'chronic',
    'adults',
    'adult',
    'children',
    'see',
    'also',
    'or',
    'and',
    'the',
    'most',
    'mainly',
    'only',
    'any',
    'such',
    'due',
    'from',
    'on',
    'to',
    'as',
    'than',
    'less',
    'more',
    'over',
    'under',
    'early',
    'late',
    'both',
    'either',
    'left',
    'right',
    'mild',
    'severe',
    'then',
    'once',
    'twice',
    'daily',
    'stat',
    'dose',
    'max',
    'min',
    'im',
    'iv',
    'po',
    'sc',
    'pr',
    'od',
    'bd',
    'tds',
    'qds',
    'prn',
    'sl',
    'inh',
    'neb',
    '4',
  };

  /// The accepted wordings in one part of an answer.
  static List<_Synonym> _synonyms(String part, {required bool allowOr}) {
    final texts = <String>[];
    final base = part.replaceAll(_bracket, ' ').trim();
    final trailing = RegExp(r'\(([^()]*)\)\s*$').firstMatch(part);
    final whole = base.isEmpty ? part : base;
    texts.add(whole);
    if (allowOr) {
      final options = whole.split(_orSeparator);
      if (options.length > 1) texts.addAll(options);
    }
    if (trailing != null && base.isNotEmpty) {
      for (final inside in trailing.group(1)!.split(RegExp(r',|;|\s+or\s+'))) {
        if (_namesTheAnswer(inside, base)) texts.add(inside);
      }
    }
    final seen = <String>{};
    return [
      for (final t in texts)
        if (_Synonym.from(t) case final s? when seen.add(s.key)) s,
    ];
  }

  /// Whether a bracket's content is another name for [base] (an
  /// abbreviation of it, or a name of its own) instead of a detail.
  static bool _namesTheAnswer(String inside, String base) {
    final words = _tokens(inside).all.map((t) => t.raw).toList();
    if (words.isEmpty) return false;
    if (_detailWords.contains(words.first)) return false;
    final short = words.join();
    if (RegExp(r'^\d').hasMatch(short)) return false; // "(500 mg)"
    if (short.length >= 5) return true;
    if (RegExp(r'^[a-z]+\d+$').hasMatch(short)) return true; // "(B12)"
    // An abbreviation: its letters appear in order in the full name.
    final full = _tokens(base).all.map((t) => t.raw).join();
    if (short.length < 2 || short[0] != full[0]) return false;
    var at = 0;
    for (var i = 0; i < full.length && at < short.length; i++) {
      if (full[i] == short[at]) at++;
    }
    return at == short.length;
  }

  // ------------------------------------------------------------- matching

  static _Outcome _check(
    AnswerForm form,
    String user,
    _Reply reply,
    Set<String> ownTerms,
  ) {
    final candidates = [
      for (final c in form.concepts) _hits(c, user, reply, ownTerms),
    ];
    // Each concept needs words of its own: one word cannot stand for two.
    var best = List<_Hit?>.filled(form.concepts.length, null);
    var bestCount = -1;
    var bestCost = 0;
    final chosen = List<_Hit?>.filled(form.concepts.length, null);
    void place(int i, int count, int cost) {
      if (i == candidates.length) {
        if (count > bestCount || (count == bestCount && cost < bestCost)) {
          best = List.of(chosen);
          bestCount = count;
          bestCost = cost;
        }
        return;
      }
      for (final h in candidates[i]) {
        if (chosen.take(i).any((c) => c != null && c.overlaps(h))) continue;
        chosen[i] = h;
        place(i + 1, count + 1, cost + h.distance);
      }
      chosen[i] = null;
      place(i + 1, count, cost);
    }

    place(0, 0, 0);
    return _Outcome(form, best);
  }

  /// Every place in the reply where one of the concept's wordings is.
  static List<_Hit> _hits(
    AnswerConcept concept,
    String user,
    _Reply reply,
    Set<String> ownTerms,
  ) {
    final found = <(int, int), _Hit>{};
    void add(_Hit h) {
      final old = found[(h.start, h.end)];
      if (old == null || h.distance < old.distance) found[(h.start, h.end)] = h;
    }

    for (final syn in concept.synonyms) {
      if (syn.number != null) {
        if (_numberMatches(user, syn.number!)) {
          add(_Hit(0, reply.all.length, 0, syn.display));
        }
        continue;
      }
      for (final list in [reply.stripped, reply.all]) {
        _window(syn, list, reply, ownTerms, add);
      }
    }
    final hits = found.values.toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    return hits.take(12).toList();
  }

  static const Set<String> _negations = {
    'not',
    'no',
    'never',
    'except',
    'without',
    'non',
    'nor',
    'excluding',
  };

  static void _window(
    _Synonym syn,
    List<_Token> list,
    _Reply reply,
    Set<String> ownTerms,
    void Function(_Hit) add,
  ) {
    final target = syn.text;
    final allowed = allowedTypos(target.length);
    // A one- or two-letter answer ("K", "B6") must be a word by itself.
    final maxSize = target.length <= 2 ? 1 : max(3, syn.tokens + 2);
    for (var i = 0; i < list.length; i++) {
      for (var size = 1; size <= maxSize && i + size <= list.length; size++) {
        final (text, locks) = _collapse(list.sublist(i, i + size));
        if ((text.length - target.length).abs() > allowed) continue;
        final d = text == target
            ? 0
            : allowed == 0
            ? 99
            : _distance(target, syn.locks, text, locks);
        if (d > allowed) continue;
        if (d > 0) {
          // Two typos are only believed when the word starts right:
          // "ampicillin" is not a misspelt "amoxicillin".
          if (d > 1 && !_sameStem(target, text)) continue;
          // A typo may not make another real term out of the word.
          if (_flipsMeaning(target, text)) continue;
          if (_changesStart(target, text, firstIsFiller: list[i].filler)) {
            continue;
          }
          if (knownTerms.contains(text) && !ownTerms.contains(text)) continue;
        }
        if (_negated(reply.all, list[i].index, syn)) continue;
        add(_Hit(list[i].index, list[i + size - 1].index + 1, d, syn.display));
      }
    }
  }

  /// "not aspirin" does not count as "aspirin".
  static bool _negated(List<_Token> all, int start, _Synonym syn) {
    var i = start - 1;
    while (i >= 0 && all[i].filler) {
      i--;
    }
    if (i < 0) return false;
    final word = all[i].raw;
    return _negations.contains(word) && !syn.words.contains(word);
  }

  /// Typos are rarely in the first letter, but look-alike terms often
  /// differ exactly there ("carotid" and "parotid", "typical" and
  /// "atypical"). So a typo may not replace the first letter, and may not
  /// be nothing but letters added or dropped at the front. (A filler word
  /// stuck to the front, as in "an acetylcysteine", is let through.)
  static bool _changesStart(
    String target,
    String reply, {
    required bool firstIsFiller,
  }) {
    if (firstIsFiller) return false;
    if (reply.endsWith(target) || target.endsWith(reply)) return true;
    if (target.length < 2 || reply.length < 2) return false;
    return reply[0] != target[0] &&
        reply[1] != target[0] &&
        reply[0] != target[1];
  }

  /// How many first letters must agree before two typos are forgiven.
  static const int stemLetters = 3;

  static bool _sameStem(String a, String b) =>
      a.length >= stemLetters &&
      b.length >= stemLetters &&
      a.substring(0, stemLetters) == b.substring(0, stemLetters);

  static bool _flipsMeaning(String target, String reply) {
    bool has(String s, String piece, String other) =>
        (other.contains(piece) ? s.replaceAll(other, '') : s).contains(piece);
    for (final (a, b) in confusables) {
      final ta = has(target, a, b), tb = has(target, b, a);
      if (ta == tb) continue;
      final ra = has(reply, a, b), rb = has(reply, b, a);
      if (ta != ra && tb != rb) return true;
    }
    return false;
  }

  /// Edit distance where swapping two neighbouring letters counts once,
  /// and a locked letter (a digit, a naming letter, a Greek letter) can
  /// never be changed, dropped or added.
  static int _distance(String a, List<bool> la, String b, List<bool> lb) {
    const never = 100;
    final rows = List.generate(
      a.length + 1,
      (_) => List<int>.filled(b.length + 1, 0),
    );
    for (var i = 1; i <= a.length; i++) {
      rows[i][0] = rows[i - 1][0] + (la[i - 1] ? never : 1);
    }
    for (var j = 1; j <= b.length; j++) {
      rows[0][j] = rows[0][j - 1] + (lb[j - 1] ? never : 1);
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final same = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1);
        final locked = la[i - 1] || lb[j - 1];
        var best = rows[i - 1][j - 1] + (same ? 0 : (locked ? never : 1));
        best = min(best, rows[i - 1][j] + (la[i - 1] ? never : 1));
        best = min(best, rows[i][j - 1] + (lb[j - 1] ? never : 1));
        if (i > 1 &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1) &&
            !locked &&
            !la[i - 2] &&
            !lb[j - 2]) {
          best = min(best, rows[i - 2][j - 2] + 1);
        }
        rows[i][j] = min(best, never);
      }
    }
    return rows[a.length][b.length];
  }

  /// How many separate things the reply lists ("a, b or c" is three).
  static int _items(String user) => user
      .toLowerCase()
      .split(RegExp(r',(?!\d{3}(?!\d))|;|/|\n|\s+or\s+'))
      .map((s) => _tokens(s).stripped.map((t) => t.text).join(' '))
      .where((s) => s.isNotEmpty)
      .toSet()
      .length;

  // -------------------------------------------------------------- numbers

  static final RegExp _numberAnswer = RegExp(
    r'^\s*[<>≤≥~≈]?\s*([-−]?\d[\d,]*(?:\.\d+)?)\s*(\D.*)?$',
  );
  static final RegExp _numberInReply = RegExp(
    r'(?<![\w.])([-−]?\d+(?:\.\d+)?)\s*'
    r'((?:[a-zµμ°%]+)(?:\s*(?:/|per)\s*[a-zµμ]+)?)?',
  );

  /// Reads "0.5", "1,000" or "40 mg" as a number with an optional unit.
  /// Null when the text is not that (then it is matched as words).
  static _Number? _number(String text) {
    final m = _numberAnswer.firstMatch(text.toLowerCase());
    if (m == null) return null;
    final value = double.tryParse(
      m.group(1)!.replaceAll(',', '').replaceAll('−', '-'),
    );
    if (value == null) return null;
    final rest = (m.group(2) ?? '').trim();
    if (rest.isEmpty) return _Number(value, null);
    final unit = _unit(rest);
    return unit == null ? null : _Number(value, unit);
  }

  /// The number must be the same number ("0.50" is "0.5"). The unit may
  /// be left out, but a different unit is wrong.
  static bool _numberMatches(String user, _Number target) {
    final text = user.toLowerCase().replaceAll(
      RegExp(r'(?<=\d),(?=\d{3}(?!\d))'),
      '',
    );
    for (final m in _numberInReply.allMatches(text)) {
      final value = double.tryParse(m.group(1)!.replaceAll('−', '-'));
      if (value == null || (value - target.value).abs() > 1e-9) continue;
      if (target.unit == null) return true;
      final said = m.group(2);
      final unit = said == null
          ? null
          : _unit(said) ?? _unit(said.split(RegExp(r'\s|/')).first);
      if (unit == null || unit == target.unit) return true;
    }
    return false;
  }

  static const Map<String, String> _units = {
    '%': '%',
    'percent': '%',
    'percentage': '%',
    'mg': 'mg',
    'milligram': 'mg',
    'milligrams': 'mg',
    'g': 'g',
    'gram': 'g',
    'grams': 'g',
    'gm': 'g',
    'kg': 'kg',
    'kilogram': 'kg',
    'kilograms': 'kg',
    'ug': 'ug',
    'mcg': 'ug',
    'microgram': 'ug',
    'micrograms': 'ug',
    'ng': 'ng',
    'pg': 'pg',
    'l': 'l',
    'litre': 'l',
    'litres': 'l',
    'liter': 'l',
    'liters': 'l',
    'ml': 'ml',
    'millilitre': 'ml',
    'millilitres': 'ml',
    'cc': 'ml',
    'dl': 'dl',
    'ul': 'ul',
    'fl': 'fl',
    'mol': 'mol',
    'mmol': 'mmol',
    'umol': 'umol',
    'nmol': 'nmol',
    'meq': 'meq',
    'mosm': 'mosm',
    'osm': 'osm',
    'iu': 'iu',
    'u': 'iu',
    'unit': 'iu',
    'units': 'iu',
    'mmhg': 'mmhg',
    'kpa': 'kpa',
    'cmh2o': 'cmh2o',
    'bpm': 'bpm',
    'hz': 'hz',
    's': 's',
    'sec': 's',
    'secs': 's',
    'second': 's',
    'seconds': 's',
    'ms': 'ms',
    'msec': 'ms',
    'millisecond': 'ms',
    'milliseconds': 'ms',
    'min': 'min',
    'mins': 'min',
    'minute': 'min',
    'minutes': 'min',
    'h': 'h',
    'hr': 'h',
    'hrs': 'h',
    'hour': 'h',
    'hours': 'h',
    'd': 'd',
    'day': 'd',
    'days': 'd',
    'wk': 'wk',
    'wks': 'wk',
    'week': 'wk',
    'weeks': 'wk',
    'month': 'mo',
    'months': 'mo',
    'mo': 'mo',
    'y': 'y',
    'yr': 'y',
    'yrs': 'y',
    'year': 'y',
    'years': 'y',
    'mm': 'mm',
    'cm': 'cm',
    'm': 'm',
    'km': 'km',
    'um': 'um',
    'nm': 'nm',
    'c': 'c',
    '°c': 'c',
    'f': 'f',
    '°f': 'f',
    '°': 'deg',
    'degrees': 'deg',
    'kcal': 'kcal',
    'cal': 'cal',
    'kj': 'kj',
    'j': 'j',
    'mv': 'mv',
    'v': 'v',
    'gy': 'gy',
    'msv': 'msv',
    'sv': 'sv',
    'l/min': 'l/min',
    'lpm': 'l/min',
  };

  /// The unit in a standard spelling, or null if [text] is not a unit.
  static String? _unit(String text) {
    final t = text
        .toLowerCase()
        .replaceAll(RegExp(r'[µμ]'), 'u')
        .replaceAll(RegExp(r'\s+per\s+'), '/')
        .replaceAll(RegExp(r'[\s.]'), '');
    if (t.isEmpty) return null;
    final sides = t.split('/');
    final out = <String>[];
    for (final side in sides) {
      final unit = _units[side];
      if (unit == null) return null;
      out.add(unit);
    }
    return out.join('/');
  }

  // ---------------------------------------------------------------- words

  static const Map<String, String> _greek = {
    'α': 'alpha',
    'β': 'beta',
    'γ': 'gamma',
    'δ': 'delta',
    'ε': 'epsilon',
    'κ': 'kappa',
    'λ': 'lambda',
    'ω': 'omega',
    'σ': 'sigma',
    'ς': 'sigma',
    'θ': 'theta',
    'ζ': 'zeta',
    'π': 'pi',
  };
  static final Set<String> _greekWords = {..._greek.values, 'mu'};

  static const String _accented =
      'àáâãäåāăąçćčďèéêëēėęěğìíîïīįıłñńňòóôõöøōőřśšşťùúûüūůűýÿźżž';
  static const String _plain =
      'aaaaaaaaacccdeeeeeeeegiiiiiiilnnnoooooooorssstuuuuuuuyyzzz';

  /// Lower case, no accents, Greek letters as words, every punctuation
  /// mark a space (a decimal point inside a number is kept), single
  /// spaces.
  static String normalizeText(String input) {
    var s = input.toLowerCase();
    s = s.replaceAll(RegExp("n['’]t\\b"), ' not');
    s = s.replaceAll(RegExp(r'[̀-ͯ]'), '');
    s = s.replaceAllMapped(RegExp(r'[µμ](?=[a-z])'), (_) => 'u');
    s = s.replaceAll(RegExp(r'[µμ]'), ' mu ');
    final out = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final greek = _greek[ch];
      final at = _accented.indexOf(ch);
      if (greek != null) {
        out.write(' $greek ');
      } else if (ch == 'æ') {
        out.write('ae');
      } else if (ch == 'œ') {
        out.write('oe');
      } else if (ch == 'ß') {
        out.write('ss');
      } else if (at >= 0) {
        out.write(_plain[at]);
      } else {
        out.write(ch);
      }
    }
    s = out.toString();
    // "1,000" is one number; "0.5" keeps its point.
    s = s.replaceAll(RegExp(r'(?<=\d),(?=\d{3}(?!\d))'), '');
    s = s.replaceAll(RegExp(r'(?<=\d)\.(?=\d)'), '\u0001');
    s = s.replaceAll(RegExp(r'[^\p{L}\p{N}\s\u0001]', unicode: true), ' ');
    s = s.replaceAll('\u0001', '.');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const Set<String> _fillers = {
    'a',
    'an',
    'the',
    'of',
    'to',
    'is',
    'are',
    'it',
    'its',
    'by',
    'in',
    'on',
    'for',
    'with',
    'and',
    'or',
  };

  /// Words after which a single letter or a Roman numeral names
  /// something ("vitamin A", "type I"), so it is never a filler.
  static const Set<String> _designators = {
    'vitamin',
    'vit',
    'hepatitis',
    'hep',
    'type',
    'factor',
    'group',
    'class',
    'protein',
    'coenzyme',
    'influenza',
    'haemophilia',
    'hemophilia',
    'grade',
    'stage',
    'phase',
    'complex',
    'immunoglobulin',
    'ig',
    'apolipoprotein',
    'apo',
    'subunit',
    'chain',
    'fibre',
    'fiber',
    'fibres',
    'fibers',
    'kinase',
    'cyclin',
    'cyclosporin',
    'ciclosporin',
    'cyclosporine',
    'amphotericin',
    'coxsackie',
    'coxsackievirus',
    'streptococcus',
    'strep',
    'nerve',
    'cn',
    'level',
    'zone',
    'degree',
    'mobitz',
    'angiotensin',
    'collagen',
    'lipoxin',
    'thromboxane',
    'leukotriene',
    'prostaglandin',
    'substance',
    'antigen',
    'hla',
    'mhc',
    'schedule',
    'category',
    'toxin',
    'penicillin',
    'polymyxin',
    'variant',
    'strain',
    'serotype',
    'cranial',
  };

  static const Map<String, String> _roman = {
    'ii': '2',
    'iii': '3',
    'iv': '4',
    'vi': '6',
    'vii': '7',
    'viii': '8',
    'ix': '9',
    'xi': '11',
    'xii': '12',
    'xiii': '13',
    'xiv': '14',
    'xv': '15',
    'xvi': '16',
    'xvii': '17',
    'xviii': '18',
    'xix': '19',
    'xx': '20',
  };
  static const Map<String, String> _romanAfterName = {
    'i': '1',
    'v': '5',
    'x': '10',
  };

  /// British and American spellings made the same, on both sides, so the
  /// difference never costs a typo: ae/oe become e, -our becomes -or,
  /// -ise becomes -ize. ("ph" and "f" stay different.)
  static String foldSpelling(String word) {
    if (RegExp(r'\d').hasMatch(word)) return word;
    var w = word.replaceAll('ae', 'e').replaceAll('oe', 'e');
    if (w.length >= 5) {
      w = w.replaceFirstMapped(RegExp(r'our(s?)$'), (m) => 'or${m[1]}');
    }
    if (w.length >= 6) {
      w = w.replaceFirstMapped(
        RegExp(r'is(e|ed|es|ing|ation|ations|er|ers)$'),
        (m) => 'iz${m[1]}',
      );
    }
    return w;
  }

  static final RegExp _plainNumber = RegExp(r'^\d+(\.\d+)?$');

  /// "0.50" and "007" written the one way a number can be: "0.5", "7".
  static String _tidyNumber(String n) {
    var s = n.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  static _Reply _tokens(String input) {
    final raw = normalizeText(input).split(' ').where((w) => w.isNotEmpty);
    final words = <String>[];
    for (final w in raw) {
      final afterName = words.isNotEmpty && _designators.contains(words.last);
      final roman = _roman[w] ?? (afterName ? _romanAfterName[w] : null);
      words.add(roman ?? (_plainNumber.hasMatch(w) ? _tidyNumber(w) : w));
    }
    final all = <_Token>[];
    for (final (i, w) in words.indexed) {
      final afterName = i > 0 && _designators.contains(words[i - 1]);
      final filler =
          _fillers.contains(w) &&
          // "a" at the end or after "vitamin" is a name, not an article.
          (w != 'a' || (i < words.length - 1 && !afterName));
      all.add(
        _Token(
          index: i,
          raw: w,
          text: foldSpelling(w),
          filler: filler,
          // A naming letter ("T" in "T cell"), a short code with a
          // digit ("B12", "D3", "CD4") or a Greek letter.
          locked:
              w.length == 1 ||
              (w.length <= 4 && RegExp(r'\d').hasMatch(w)) ||
              _greekWords.contains(w),
        ),
      );
    }
    final stripped = all.where((t) => !t.filler).toList();
    return _Reply(all, stripped.isEmpty ? all : stripped);
  }

  /// The words squeezed together, with which letters are locked. Two
  /// numbers side by side keep a space, so "3 5" is never read as "35".
  static (String, List<bool>) _collapse(List<_Token> tokens) {
    final text = StringBuffer();
    final locks = <bool>[];
    bool digit(int unit) => unit >= 0x30 && unit <= 0x39;
    for (final t in tokens) {
      if (t.text.isEmpty) continue;
      if (text.isNotEmpty &&
          digit(text.toString().codeUnitAt(text.length - 1)) &&
          digit(t.text.codeUnitAt(0))) {
        text.write(' ');
        locks.add(true);
      }
      for (final unit in t.text.codeUnits) {
        locks.add(t.locked || digit(unit) || unit == 0x2e);
      }
      text.write(t.text);
    }
    return (text.toString(), locks);
  }
}

/// One way of answering a question: every concept must be present.
class AnswerForm {
  /// The stored text this way was built from.
  final String display;
  final List<AnswerConcept> concepts;
  AnswerForm._(this.display, this.concepts);
}

/// One thing the answer must say, with its accepted wordings.
class AnswerConcept {
  final List<_Synonym> _all;
  AnswerConcept._(this._all);

  // ignore: library_private_types_in_public_api
  List<_Synonym> get synonyms => _all;

  String get display => synonyms.first.display;

  /// The wordings squeezed for comparing (see [AnswerGrader.termKey]).
  List<String> get keys => [for (final s in _all) s.key];

  /// The wordings as stored, for tests and debugging.
  List<String> get wordings => [for (final s in synonyms) s.display];
}

class _Synonym {
  /// As stored, for showing ("N-acetylcysteine").
  final String display;

  /// Squeezed and tidied, for comparing ("nacetylcysteine").
  final String text;
  final List<bool> locks;
  final int tokens;
  final Set<String> words;
  final _Number? number;

  _Synonym._(
    this.display,
    this.text,
    this.locks,
    this.tokens,
    this.words,
    this.number,
  );

  String get key => text;

  static _Synonym? from(String stored) {
    final reply = AnswerGrader._tokens(stored);
    if (reply.all.isEmpty) return null;
    final (text, locks) = AnswerGrader._collapse(reply.stripped);
    return _Synonym._(stored.trim(), text, locks, reply.stripped.length, {
      for (final t in reply.all) t.raw,
    }, AnswerGrader._number(stored));
  }
}

class _Number {
  final double value;
  final String? unit;
  const _Number(this.value, this.unit);
}

class _Token {
  /// Position in the reply, counting every word.
  final int index;
  final String raw;

  /// [raw] with British/American spelling made the same.
  final String text;
  final bool filler;
  final bool locked;
  const _Token({
    required this.index,
    required this.raw,
    required this.text,
    required this.filler,
    required this.locked,
  });
}

class _Reply {
  final List<_Token> all;
  final List<_Token> stripped;
  const _Reply(this.all, this.stripped);
}

class _Hit {
  final int start;
  final int end;
  final int distance;
  final String display;
  const _Hit(this.start, this.end, this.distance, this.display);
  bool overlaps(_Hit o) => start < o.end && o.start < end;
}

class _Outcome {
  final AnswerForm form;
  final List<_Hit?> hits;
  _Outcome(this.form, this.hits);
  bool get complete => hits.every((h) => h != null);
}
