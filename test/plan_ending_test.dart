// The "your plan ends soon" banner on the home screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/screens/upgrade_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/widgets/lock_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  final plan = Entitlements.instance;
  var clock = DateTime(2026, 11, 22, 10);

  /// Signed in on [tier], ending at [end]; shows what the home screen
  /// shows above its tabs.
  Future<void> show(
    WidgetTester tester, {
    required DateTime end,
    String tier = 'Pro',
    Map<String, Object> prefs = const {},
  }) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await resetApp(signedIn: true, prefs: prefs);
      Billing.resetForTest();
      Billing.httpClient = MockClient((_) async => http.Response('{}', 503));
      clock = DateTime(2026, 11, 22, 10);
      plan
        ..setForTest(null)
        ..now = () => clock;
      await plan.apply(
        premium: true,
        tier: tier.toLowerCase(),
        tierName: tier,
        expires: end,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: plan,
            builder: (_, _) => plan.needsCheck
                ? const PlanCheckBanner()
                : plan.endsSoon
                ? const PlanEndingBanner()
                : const Text('nothing'),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  /// Lets a new clock time show.
  Future<void> at(WidgetTester tester, DateTime time) async {
    clock = time;
    plan.setForTest(null);
    await tester.pump();
    // A banner that has just appeared reads whether it was closed today.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  tearDown(openAllFeatures);

  testWidgets('says when the plan ends, by day', (tester) async {
    final end = DateTime(2026, 11, 25, 10);
    await show(tester, end: end);
    expect(find.text('Your Pro ends in 3 days.'), findsOneWidget);
    expect(find.text('Plans do not renew by themselves.'), findsOneWidget);
    expect(find.text('Renew'), findsOneWidget);

    await at(tester, DateTime(2026, 11, 23, 18));
    expect(find.text('Your Pro ends in 2 days.'), findsOneWidget);
    await at(tester, DateTime(2026, 11, 24, 23, 30));
    expect(find.text('Your Pro ends tomorrow.'), findsOneWidget);
    await at(tester, DateTime(2026, 11, 25, 0, 30));
    expect(find.text('Your Pro ends today.'), findsOneWidget);

    // Past the end and offline: still open for now.
    await at(tester, DateTime(2026, 11, 26, 9));
    expect(plan.endingOffline, isTrue);
    expect(find.text('Your Pro has ended.'), findsOneWidget);

    // Locked: the "needs checking" banner takes over, never both.
    await at(tester, DateTime(2026, 11, 28, 11));
    expect(find.byType(PlanEndingBanner), findsNothing);
    expect(find.byType(PlanCheckBanner), findsOneWidget);
  });

  testWidgets('not shown while the end is more than three days away', (
    tester,
  ) async {
    await show(tester, end: DateTime(2026, 11, 25, 10, 1), tier: 'Ultra');
    expect(find.text('nothing'), findsOneWidget);
    await at(tester, DateTime(2026, 11, 22, 10, 1));
    expect(find.text('Your Ultra ends in 3 days.'), findsOneWidget);
  });

  testWidgets('the close button hides it until the next day', (tester) async {
    await show(tester, end: DateTime(2026, 11, 24, 10));
    expect(find.text('Your Pro ends in 2 days.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.textContaining('Your Pro ends'), findsNothing);
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getString('plan_ending_dismissed'), '2026-11-22');

    // Opened again the same day: still hidden.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlanEndingBanner())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.textContaining('Your Pro ends'), findsNothing);

    // The next day it is back.
    clock = DateTime(2026, 11, 23, 7);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlanEndingBanner())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('Your Pro ends tomorrow.'), findsOneWidget);
  });

  testWidgets('Renew opens the plans', (tester) async {
    await show(tester, end: DateTime(2026, 11, 23, 10));
    expect(Account.instance.isSignedIn, isTrue);
    await tester.tap(find.text('Renew'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(UpgradeScreen), findsOneWidget);
  });
}
