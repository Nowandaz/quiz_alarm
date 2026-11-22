// The quiz shown while an alarm rings: the spelling hint, the "missing
// part" hint, and the "mute right and wrong sounds" setting.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/data/question_repository.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/screens/alarm_ring_screen.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/theme_provider.dart';

import 'helpers.dart';

/// Lets the database answer and the screen redraw.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  /// Every sound the screen asked the phone to play.
  late List<String> played;

  setUp(() async {
    await resetApp();
    played = [];
    AlarmRingScreen.debugOnSfx = played.add;
    // There is no sound player in tests: calls to it are answered with
    // nothing.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  tearDown(() {
    AlarmRingScreen.debugOnSfx = null;
    Entitlements.instance.setForTest(null);
  });

  FlutterExceptionHandler? report;

  /// Closes the screen and puts error reporting back (must happen before
  /// the test ends).
  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    FlutterError.onError = report;
  }

  /// Opens "Test alarm screen" on a topic holding one typed question.
  Future<void> ring(WidgetTester tester, {required String answer}) async {
    final topicId = await tester.runAsync(() async {
      final topic = await QuestionRepository.addCustomTopic('Ring test');
      await QuestionRepository.addQuestion(
        Question(
          id: 'ring-1',
          topicId: topic.id,
          topic: topic.name,
          type: QuestionType.saq,
          questionText: 'Antidote for paracetamol overdose?',
          correctAnswer: answer,
        ),
      );
      return topic.id;
    });
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The player's event streams have no other end here either.
    report = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is! MissingPluginException) report?.call(details);
    };
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: AlarmRingScreen(
            alarm: AlarmItem(
              id: 1,
              time: const TimeOfDay(hour: 7, minute: 0),
              topics: [topicId!],
              label: 'Morning',
              requiredStreak: 3,
            ),
            preview: true,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String text) async {
    debugPrint("TEXTS: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}");
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('Submit'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a forgiven typo shows the right spelling', (tester) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    await ring(tester, answer: 'N-acetylcysteine');
    await type(tester, 'n acetyl cystine');
    expect(find.text('Correct!'), findsOneWidget);
    expect(find.text('Spelling: N-acetylcysteine'), findsOneWidget);
    expect(played, ['correct']);
    await close(tester);
  });

  testWidgets('a missing part is named on the review card', (tester) async {
    Entitlements.instance.setForTest(PlanLevel.free);
    await ring(tester, answer: 'Metabolic acidosis + respiratory alkalosis');
    await type(tester, 'metabolic acidosis');
    expect(find.text('Not quite'), findsOneWidget);
    expect(find.text('Missing: respiratory alkalosis'), findsOneWidget);
    expect(played, ['wrong']);
    await close(tester);
  });

  testWidgets('muted: no right or wrong sound is played', (tester) async {
    await tester.runAsync(
      () => resetApp(prefs: {'muteAnswerSounds': true}),
    );
    Entitlements.instance.setForTest(PlanLevel.free);
    await ring(tester, answer: 'Naloxone');
    await type(tester, 'flumazenil');
    expect(find.text('Not quite'), findsOneWidget);
    expect(played, isEmpty);
    await close(tester);
  });
}
