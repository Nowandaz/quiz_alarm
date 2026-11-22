// Marking of typed answers on the phone: spelling mistakes are forgiven,
// but never one that changes what the answer means.
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/services/answer_grader.dart';

bool ok(String user, String answer, [List<String> alts = const []]) =>
    AnswerGrader.grade(user, answer, alts: alts).correct;

void main() {
  tearDown(() => AnswerGrader.knownTerms = {});

  group('tidying', () {
    test('case, accents, punctuation and Greek letters', () {
      expect(
        AnswerGrader.normalizeText('  N-Acetylcysteine. '),
        'n acetylcysteine',
      );
      expect(AnswerGrader.normalizeText('Sjögren’s / Café'), 'sjogren s cafe');
      expect(AnswerGrader.normalizeText('β-blocker'), 'beta blocker');
      expect(AnswerGrader.normalizeText('TNF-α'), 'tnf alpha');
      expect(AnswerGrader.normalizeText('1,000 mL'), '1000 ml');
      expect(AnswerGrader.normalizeText('0.5'), '0.5');
      expect(AnswerGrader.normalizeText("isn't"), 'is not');
    });

    test('filler words are dropped, but not when they are the answer', () {
      expect(AnswerGrader.termKey('the loop of Henle'), 'loophenle');
      expect(AnswerGrader.termKey('It is the liver'), 'liver');
      expect(AnswerGrader.termKey('of'), 'of');
      expect(ok('of', 'Of'), isTrue);
    });

    test('a letter that names something is kept', () {
      expect(AnswerGrader.termKey('vitamin A'), 'vitamina');
      expect(AnswerGrader.termKey('a vitamin'), 'vitamin');
      expect(ok('vitamin a', 'Vitamin A'), isTrue);
      expect(ok('vitamin d', 'Vitamin A'), isFalse);
      expect(ok('vitamin', 'Vitamin A'), isFalse);
      expect(ok('hepatitis b', 'Hepatitis A'), isFalse);
      expect(ok('hepatitis a', 'Hepatitis A'), isTrue);
      expect(ok('b cell', 'T cell'), isFalse);
      expect(ok('tcell', 'T cell'), isTrue);
      expect(ok('protein s', 'Protein C'), isFalse);
    });

    test('British and American spellings are the same word', () {
      for (final (uk, us) in const [
        ('haemoglobin', 'hemoglobin'),
        ('oedema', 'edema'),
        ('oesophagus', 'esophagus'),
        ('tumour', 'tumor'),
        ('ionise', 'ionize'),
        ('hypokalaemia', 'hypokalemia'),
      ]) {
        final r = AnswerGrader.grade(us, uk);
        expect(r.correct, isTrue, reason: '$us for $uk');
        expect(r.exact, isTrue, reason: 'no typo is counted for $us');
        expect(ok(uk, us), isTrue);
      }
      // "ph" and "f" stay different letters (one typo).
      expect(AnswerGrader.grade('sulfur', 'Sulphur').exact, isFalse);
    });
  });

  group('typos by length', () {
    test('none up to 4 letters, one up to 8, two from 9', () {
      expect(AnswerGrader.allowedTypos(4), 0);
      expect(AnswerGrader.allowedTypos(5), 1);
      expect(AnswerGrader.allowedTypos(8), 1);
      expect(AnswerGrader.allowedTypos(9), 2);
    });

    test('everyday misspellings pass', () {
      expect(ok('paracetemol', 'Paracetamol'), isTrue);
      expect(ok('acetaminophen', 'Paracetamol', ['Acetaminophen']), isTrue);
      expect(ok('adrenalin', 'Adrenaline'), isTrue);
      expect(ok('warfrin', 'Warfarin'), isTrue);
      expect(ok('asprin', 'Aspirin'), isTrue);
      expect(ok('mitochondrion', 'Mitochondria'), isTrue);
      expect(ok('mitocondria', 'Mitochondria'), isTrue);
      expect(ok('naloxon', 'Naloxone'), isTrue);
      // Two neighbouring letters swapped count as one typo.
      expect(ok('aspiirn', 'Aspirin'), isTrue);
      expect(ok('wafrarin', 'Warfarin'), isTrue);
    });

    test('too many typos, or any typo in a short word, fail', () {
      expect(ok('ACh', 'ACE'), isFalse);
      expect(ok('ace', 'ACE'), isTrue);
      expect(ok('naltrexone', 'Naloxone'), isFalse);
      expect(ok('asprn', 'Aspirin'), isFalse);
      expect(ok('nal', 'Naloxone'), isFalse);
      expect(ok('n', 'Naloxone'), isFalse);
    });

    test('the right spelling is handed back when a typo was forgiven', () {
      final typo = AnswerGrader.grade(
        'n-acetylcystine',
        'N-acetylcysteine (NAC)',
      );
      expect(typo.correct, isTrue);
      expect(typo.exact, isFalse);
      expect(typo.corrected, 'N-acetylcysteine');
      expect(typo.hint, 'Spelling: N-acetylcysteine');
      final exact = AnswerGrader.grade('n acetylcysteine', 'N-acetylcysteine');
      expect(exact.exact, isTrue);
      expect(exact.corrected, isNull);
      expect(exact.hint, isNull);
    });
  });

  group('sliding window', () {
    test('spaces and hyphens do not matter', () {
      const answer = 'N-acetylcysteine';
      expect(ok('n acetyl cysteine', answer), isTrue);
      expect(ok('n-acetylcysteine', answer), isTrue);
      expect(ok('nacetylcysteine', answer), isTrue);
      expect(ok('N Acetyl-Cysteine', answer), isTrue);
      expect(ok('beta lactams', 'Beta-lactams'), isTrue);
      expect(ok('betalactams', 'Beta-lactams'), isTrue);
    });

    test('the answer is found inside a sentence', () {
      expect(ok('give an acetylcysteine dose', 'N-acetylcysteine'), isTrue);
      expect(ok('it is naloxone', 'Naloxone'), isTrue);
      expect(ok('IM adrenaline', 'Adrenaline'), isTrue);
      expect(ok('the loop of henle', 'Loop of Henle'), isTrue);
    });

    test('a very short answer must be a word by itself', () {
      expect(ok('ok', 'K'), isFalse);
      expect(ok('k', 'K'), isTrue);
      expect(ok('it is k', 'K'), isTrue);
      expect(ok('b6', 'Pyridoxine', ['B6']), isTrue);
      expect(ok('b 6', 'Pyridoxine', ['B6']), isFalse);
    });
  });

  group('locks', () {
    test('digits are never mistyped', () {
      for (final good in ['COX-1', 'COX 1', 'cox1']) {
        expect(ok(good, 'COX-1'), isTrue, reason: good);
      }
      expect(ok('COX-2', 'COX-1'), isFalse);
      expect(ok('IL-2', 'IL-1'), isFalse);
      expect(ok('IL 1', 'IL-1'), isTrue);
      expect(ok('5-HT2', '5-HT3'), isFalse);
      expect(ok('5ht3', '5-HT3'), isTrue);
      expect(ok('interleukin 2', 'Interleukin 1'), isFalse);
      expect(ok('interleukn 1', 'Interleukin 1'), isTrue);
      expect(ok('interleukin 12', 'Interleukin 1'), isFalse);
      expect(ok('vitamin b12', 'Vitamin B1'), isFalse);
      expect(ok('vitamin d3', 'Vitamin B3'), isFalse);
    });

    test('Roman numerals are numbers', () {
      expect(ok('factor VII', 'Factor VIII'), isFalse);
      expect(ok('factor viii', 'Factor VIII'), isTrue);
      expect(ok('factor 8', 'Factor VIII'), isTrue);
      expect(ok('type II', 'Type I'), isFalse);
      expect(ok('type 1', 'Type I'), isTrue);
      expect(ok('facter viii', 'Factor VIII'), isTrue);
      expect(ok('angiotensin I', 'Angiotensin II'), isFalse);
    });

    test('Greek letters are never mistyped', () {
      expect(ok('beta blocker', 'Alpha blocker'), isFalse);
      expect(ok('α blocker', 'Alpha blocker'), isTrue);
      expect(ok('alpha bloker', 'Alpha-blocker'), isTrue);
      expect(ok('TNF beta', 'TNF-α'), isFalse);
      expect(ok('gamma globulin', 'Delta globulin'), isFalse);
    });
  });

  group('typos that change the meaning are refused', () {
    test('opposites', () {
      expect(ok('hyperkalaemia', 'Hypokalaemia'), isFalse);
      expect(ok('hypokalaemia', 'Hyperkalaemia'), isFalse);
      expect(ok('hypertension', 'Hypotension'), isFalse);
      expect(ok('hypotenson', 'Hypotension'), isTrue);
      expect(ok('hpertension', 'Hypertension'), isTrue);
      expect(ok('antagonist', 'Agonist'), isFalse);
      expect(ok('agonist', 'Antagonist'), isFalse);
      expect(ok('adduction', 'Abduction'), isFalse);
      expect(ok('efferent', 'Afferent'), isFalse);
      expect(ok('intracellular', 'Intercellular'), isFalse);
      expect(ok('decreased', 'Increased'), isFalse);
      expect(ok('microcytic', 'Macrocytic'), isFalse);
    });

    test('look-alike terms', () {
      expect(ok('ilium', 'Ileum'), isFalse);
      expect(ok('nephrotic syndrome', 'Nephritic syndrome'), isFalse);
      expect(ok('prednisone', 'Prednisolone'), isFalse);
      expect(ok('quinine', 'Quinidine'), isFalse);
      expect(ok('methanol', 'Ethanol'), isFalse);
      expect(ok('lactase', 'Lactose'), isFalse);
      expect(ok('cortisol', 'Cortisone'), isFalse);
    });

    test('a changed first letter, or letters added at the front', () {
      expect(ok('parotid', 'Carotid'), isFalse);
      expect(ok('felodipine', 'Amlodipine'), isFalse);
      expect(ok('atypical', 'Typical'), isFalse);
      expect(ok('systole', 'Asystole'), isFalse);
      expect(ok('anaerobic', 'Aerobic'), isFalse);
      expect(ok('irreversible', 'Reversible'), isFalse);
      expect(ok('repolarisation', 'Depolarisation'), isFalse);
      // Two first letters swapped, or a filler word stuck on, are typos.
      expect(ok('apracetamol', 'Paracetamol'), isTrue);
      expect(ok('an acetylcysteine', 'N-acetylcysteine'), isTrue);
    });

    test('two typos need the first three letters right', () {
      expect(ok('ampicillin', 'Amoxicillin'), isFalse);
      expect(ok('amoxicilin', 'Amoxicillin'), isTrue);
      expect(ok('amoxycilin', 'Amoxicillin'), isTrue);
      expect(ok('hemorage', 'Haemorrhage'), isTrue);
    });

    test('endings that change the meaning', () {
      expect(ok('diverticulitis', 'Diverticulosis'), isFalse);
      expect(ok('colostomy', 'Colectomy'), isFalse);
      expect(ok('creatine', 'Creatinine'), isFalse);
    });

    test('another answer from the bank', () {
      expect(ok('cefalexin', 'Cefalotin'), isTrue);
      AnswerGrader.knownTerms = {AnswerGrader.termKey('Cefalexin')};
      expect(ok('cefalexin', 'Cefalotin'), isFalse);
      expect(ok('cefalotn', 'Cefalotin'), isTrue);
      // An accepted alternative of this very question is not "another".
      expect(ok('cefalexin', 'Cefalotin', ['Cefalexin']), isTrue);
    });

    test('"not X" is not X', () {
      expect(ok('not aspirin', 'Aspirin'), isFalse);
      expect(ok('anything except aspirin', 'Aspirin'), isFalse);
      expect(ok('never an aspirin', 'Aspirin'), isFalse);
      expect(ok('it isn\'t aspirin', 'Aspirin'), isFalse);
      expect(ok('without contrast', 'Contrast'), isFalse);
      expect(ok('no change', 'No change'), isTrue);
      expect(ok('not ibuprofen but aspirin', 'Aspirin'), isTrue);
    });
  });

  group('concepts and synonyms', () {
    test('the alternatives are other wordings of the same thing', () {
      expect(ok('epinephrine', 'Adrenaline', ['Epinephrine']), isTrue);
      expect(ok('epinephrin', 'Adrenaline', ['Epinephrine']), isTrue);
      expect(ok('atropine', 'Adrenaline', ['Epinephrine']), isFalse);
    });

    test('a trailing bracket is another wording', () {
      const answer = 'N-acetylcysteine (NAC)';
      expect(ok('NAC', answer), isTrue);
      expect(ok('n acetylcysteine', answer), isTrue);
      expect(ok('nacl', answer), isFalse);
      expect(
        AnswerGrader.buildForms(
          answer,
          const [],
        ).single.concepts.single.wordings,
        ['N-acetylcysteine', 'NAC'],
      );
      expect(ok('epinephrine', 'Adrenaline (epinephrine)'), isTrue);
      expect(ok('B1', 'Thiamine (B1)'), isTrue);
    });

    test('a bracket that only adds a detail is not an answer', () {
      expect(ok('adrenaline', 'Adrenaline (IM)'), isTrue);
      expect(ok('im', 'Adrenaline (IM)'), isFalse);
      expect(ok('first line', 'Metformin (first line)'), isFalse);
      expect(ok('metformin', 'Metformin (first line)'), isTrue);
      expect(ok('500 mg', 'Paracetamol (500 mg)'), isFalse);
    });

    test('"X or Y" and "X / Y" are two wordings', () {
      expect(ok('epinephrine', 'Adrenaline or epinephrine'), isTrue);
      expect(ok('adrenaline', 'Adrenaline / epinephrine'), isTrue);
      expect(ok('epinephrine', 'Adrenaline/Epinephrine'), isTrue);
      // Not for units and the like.
      expect(
        AnswerGrader.buildForms(
          'Na+/K+ ATPase',
          const [],
        ).single.concepts.single.wordings,
        ['Na+/K+ ATPase'],
      );
    });

    test('every part of a multi-part answer is needed, in any order', () {
      const answer = 'Metabolic acidosis + respiratory alkalosis';
      expect(
        ok('metabolic acidosis and respiratory alkalosis', answer),
        isTrue,
      );
      expect(ok('respiratory alkalosis, metabolic acidosis', answer), isTrue);
      expect(ok('resp. alkalosis with metabolic acidosis', answer), isFalse);
      // The words are all there, but they say the opposite.
      expect(
        ok('metabolic alkalosis and respiratory acidosis', answer),
        isFalse,
      );

      final half = AnswerGrader.grade('metabolic acidosis', answer);
      expect(half.correct, isFalse);
      expect(half.matched, ['Metabolic acidosis']);
      expect(half.missing, ['respiratory alkalosis']);
      expect(half.hint, 'Missing: respiratory alkalosis');
    });

    test('";", "," and "and" separate parts too', () {
      expect(ok('vomiting and nausea', 'Nausea and vomiting'), isTrue);
      expect(ok('nausea', 'Nausea and vomiting'), isFalse);
      expect(ok('liver, kidney', 'Kidney; liver'), isTrue);
      expect(ok('kidney', 'Kidney, liver'), isFalse);
      // Not inside a bracket or a number.
      expect(
        AnswerGrader.buildForms(
          'Loop diuretics (furosemide, bumetanide)',
          [],
        ).single.concepts.single.wordings,
        ['Loop diuretics', 'furosemide', 'bumetanide'],
      );
      expect(
        AnswerGrader.buildForms('1,000', []).single.concepts,
        hasLength(1),
      );
    });

    test('alternatives with the same parts add wordings by position', () {
      const answer = 'Adrenaline + hydrocortisone';
      const alts = ['Epinephrine + cortisol', 'Anaphylaxis kit'];
      expect(ok('epinephrine and hydrocortisone', answer, alts), isTrue);
      expect(ok('cortisol, adrenaline', answer, alts), isTrue);
      expect(ok('epinephrine and adrenaline', answer, alts), isFalse);
      // An alternative without parts answers the whole question.
      expect(ok('anaphylaxis kit', answer, alts), isTrue);
    });

    test('one word cannot stand for two parts', () {
      expect(
        ok('nausea', 'Nausea and vomiting', ['Vomiting and nausea']),
        isFalse,
      );
    });

    test('in a multi-part answer "or" is an ordinary word', () {
      final forms = AnswerGrader.buildForms('Left or right + up or down', []);
      expect(forms.single.concepts.map((c) => c.wordings), [
        ['Left or right'],
        ['up or down'],
      ]);
    });
  });

  group('numbers', () {
    test('are compared as numbers', () {
      expect(ok('0.50', '0.5'), isTrue);
      expect(ok('.5', '0.5'), isFalse); // not a number as typed
      expect(ok('1000', '1,000'), isTrue);
      expect(ok('1,000', '1000'), isTrue);
      expect(ok('0.6', '0.5'), isFalse);
      expect(ok('15', '5'), isFalse);
      expect(ok('about 40', '40'), isTrue);
      expect(ok('140', '40'), isFalse);
    });

    test('the unit may be left out but not changed', () {
      expect(ok('40', '40 mg'), isTrue);
      expect(ok('40 mg', '40 mg'), isTrue);
      expect(ok('40mg', '40 mg'), isTrue);
      expect(ok('40 milligrams', '40 mg'), isTrue);
      expect(ok('40 g', '40 mg'), isFalse);
      expect(ok('40 mcg', '40 mg'), isFalse);
      expect(ok('90 percent', '90%'), isTrue);
      expect(ok('2 hours', '2 h'), isTrue);
      expect(ok('2 days', '2 hours'), isFalse);
      expect(ok('5 mmol/L', '5 mmol/L'), isTrue);
      expect(ok('5 mg/dl', '5 mmol/L'), isFalse);
    });

    test('a number inside a name is still a name', () {
      expect(ok('5-HT3', '5-HT3'), isTrue);
      expect(ok('5', '5-HT3'), isFalse);
    });
  });

  group('listing everything', () {
    test('earns nothing', () {
      final r = AnswerGrader.grade(
        'aspirin, ibuprofen, paracetamol, morphine',
        'Aspirin',
      );
      expect(r.correct, isFalse);
      expect(r.shotgun, isTrue);
      expect(ok('aspirin or ibuprofen', 'Aspirin'), isTrue);
      expect(
        ok('aspirin / ibuprofen / codeine / morphine', 'Aspirin'),
        isFalse,
      );
    });

    test('a long multi-part answer is fine', () {
      expect(ok('a, b6, c, d', 'A + B6 + C + D'), isTrue);
    });
  });

  test('empty texts are wrong', () {
    expect(ok('', 'Naloxone'), isFalse);
    expect(ok('   ', 'Naloxone'), isFalse);
    expect(ok('naloxone', ''), isFalse);
    expect(ok('?!', 'Naloxone'), isFalse);
  });
}
