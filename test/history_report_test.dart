// An alarm that was never switched off by answering can be reported from
// History; other sessions cannot.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/history_screen.dart';
import 'package:quiz_alarm/services/theme_provider.dart';

import 'helpers.dart';

StudySession session(String kind, String? outcome, {int? alarmId}) =>
    StudySession(
      id: 1,
      kind: kind,
      title: 'Quiz Alarm',
      startedAt: DateTime(2026, 11, 25, 6, 30),
      outcome: outcome,
      alarmId: alarmId,
    );

void main() {
  setUp(resetApp);

  test('which sessions count as an alarm that was not finished', () {
    expect(session('alarm', null).alarmNotFinished, isTrue); // cut short
    expect(session('alarm', 'timed_out').alarmNotFinished, isTrue);
    expect(session('alarm', 'dismissed').alarmNotFinished, isFalse);
    expect(session('alarm', 'snoozed').alarmNotFinished, isFalse);
    expect(session('bank', null).alarmNotFinished, isFalse);
    expect(session('revision', 'finished').alarmNotFinished, isFalse);
  });

  test('a session remembers which alarm rang', () async {
    await QuestionRepository.ensureReady();
    final id = await QuestionRepository.startSession(
      'alarm',
      'Quiz Alarm',
      alarmId: 4242,
      requiredStreak: 2,
    );
    await QuestionRepository.startSession('bank', 'Practice');
    final all = await QuestionRepository.getSessions();
    expect(all.firstWhere((s) => s.id == id).alarmId, 4242);
    expect(all.firstWhere((s) => s.kind == 'bank').alarmId, isNull);
    // Never ended: it is one that can be reported.
    expect(all.firstWhere((s) => s.id == id).alarmNotFinished, isTrue);
  });

  testWidgets('only an unfinished alarm shows "Report this alarm"', (
    tester,
  ) async {
    Future<void> show(StudySession s) => tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: Scaffold(body: SessionCard(session: s)),
        ),
      ),
    );
    await show(session('alarm', null, alarmId: 7));
    expect(find.text('Report this alarm'), findsOneWidget);
    expect(find.textContaining('Not finished'), findsOneWidget);

    await show(session('alarm', 'timed_out', alarmId: 7));
    expect(find.text('Report this alarm'), findsOneWidget);

    await show(session('alarm', 'dismissed', alarmId: 7));
    expect(find.text('Report this alarm'), findsNothing);

    await show(session('bank', 'finished'));
    expect(find.text('Report this alarm'), findsNothing);
  });
}
