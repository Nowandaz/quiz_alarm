// Buying premium: the calls to the server, the payment that is remembered
// while the user pays in the browser, and the premium screen.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/screens/upgrade_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/ai_client.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

const _offer = {
  'enabled': true,
  'plans': [
    {'id': 'month', 'days': 30, 'price': 300, 'currency': 'KES'},
    {'id': 'year', 'days': 365, 'price': 2500, 'currency': 'KES'},
  ],
  'premium': false,
  'expires': null,
};

/// Makes the payment server answer with [reply]. Returns the requests.
List<http.Request> fakePay(http.Response Function(http.Request request) reply) {
  final requests = <http.Request>[];
  Billing.httpClient = MockClient((request) async {
    requests.add(request);
    return reply(request);
  });
  return requests;
}

http.Response refused(int code, String detail) =>
    http.Response(jsonEncode({'detail': detail}), code);

Future<String?> pending() async =>
    (await SharedPreferences.getInstance()).getString(Billing.pendingPref);

void main() {
  setUp(() async {
    await resetApp(signedIn: true);
    Billing.resetForTest();
    UpgradeScreen.openUrl = null;
  });

  test(
    'plans are read with the price, the days and the current plan',
    () async {
      final requests = fakePay(
        (_) => ok({
          ..._offer,
          'premium': true,
          'expires': '2026-12-21T10:00:00+00:00',
        }),
      );
      final offer = await Billing.plans();
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, endsWith('/v1/pay/plans'));
      expect(offer.enabled, isTrue);
      expect(offer.plans.map((p) => p.id), ['month', 'year']);
      expect(offer.plans.first.days, 30);
      expect(offer.plans.first.priceLabel, 'KES 300');
      expect(offer.plans.last.priceLabel, 'KES 2,500');
      expect(offer.premium, isTrue);
      expect(offer.expires, DateTime.utc(2026, 12, 21, 10));
      expect(offer.planLabel, 'Premium until ${Billing.day(offer.expires!)}');
      expect(Billing.last, same(offer));
    },
  );

  test('plan labels for free and for premium with no end', () {
    const free = PremiumOffer(enabled: false, plans: [], premium: false);
    const forever = PremiumOffer(enabled: false, plans: [], premium: true);
    expect(free.planLabel, 'Free plan');
    expect(forever.planLabel, 'Premium');
    expect(Billing.day(DateTime(2026, 12, 21)), '21 Dec 2026');
  });

  test('starting a payment remembers it and returns the page', () async {
    final requests = fakePay(
      (_) => ok({'reference': 'bw_1', 'url': 'https://checkout.example/x'}),
    );
    final payment = await Billing.start('month');
    expect(requests.single.method, 'POST');
    expect(requests.single.headers['Authorization'], 'Bearer test-token');
    expect(requests.single.url.path, endsWith('/v1/pay/start'));
    expect(jsonDecode(requests.single.body), {'plan': 'month'});
    expect(payment.reference, 'bw_1');
    expect(payment.url, 'https://checkout.example/x');
    expect(await pending(), 'bw_1');
    expect(await Billing.pendingReference(), 'bw_1');
  });

  group('checking a payment', () {
    setUp(() async {
      fakePay((_) => ok({'reference': 'bw_1', 'url': 'https://pay'}));
      await Billing.start('month');
    });

    test('paid: forgotten, screens told, the bank fetched once', () async {
      var fetched = 0;
      Billing.onPaid = () async => fetched++;
      final requests = fakePay(
        (_) => ok({
          'status': 'paid',
          'premium': true,
          'expires': '2026-12-21T10:00:00+00:00',
        }),
      );
      final before = Billing.changes.value;
      final status = await Billing.verify('bw_1');
      expect(requests.single.url.path, endsWith('/v1/pay/verify'));
      expect(requests.single.url.queryParameters, {'reference': 'bw_1'});
      expect(requests.single.headers['Authorization'], 'Bearer test-token');
      expect(status.state, PaymentState.paid);
      expect(status.premium, isTrue);
      expect(status.expires, DateTime.utc(2026, 12, 21, 10));
      expect(await pending(), isNull);
      expect(Billing.changes.value, before + 1);
      expect(fetched, 1);

      // A second answer for the same payment is not announced again.
      await Billing.verify('bw_1');
      expect(Billing.changes.value, before + 1);
      expect(fetched, 1);
    });

    test('still pending: kept for a later check', () async {
      fakePay(
        (_) => ok({'status': 'pending', 'premium': false, 'expires': null}),
      );
      final before = Billing.changes.value;
      final status = await Billing.checkPending();
      expect(status!.state, PaymentState.pending);
      expect(await pending(), 'bw_1');
      expect(Billing.changes.value, before);
    });

    test('failed: forgotten without touching the plan', () async {
      fakePay(
        (_) => ok({'status': 'failed', 'premium': false, 'expires': null}),
      );
      final before = Billing.changes.value;
      expect((await Billing.checkPending())!.state, PaymentState.failed);
      expect(await pending(), isNull);
      expect(Billing.changes.value, before);
    });

    test('checkPending reports a paid payment', () async {
      fakePay((_) => ok({'status': 'paid', 'premium': true, 'expires': null}));
      expect((await Billing.checkPending())!.paid, isTrue);
      expect(await pending(), isNull);
      // Nothing left to check.
      expect(await Billing.checkPending(), isNull);
    });

    test('an old payment nobody finished stops being asked about', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'pending_payment_at',
        DateTime.now().subtract(const Duration(days: 3)).millisecondsSinceEpoch,
      );
      fakePay(
        (_) => ok({'status': 'pending', 'premium': false, 'expires': null}),
      );
      expect((await Billing.checkPending())!.state, PaymentState.pending);
      expect(await pending(), isNull);
    });

    test("another account's payment is dropped", () async {
      fakePay((_) => refused(404, 'That payment is not one of yours.'));
      await expectLater(
        Billing.checkPending(),
        throwsA(isA<BillingException>()),
      );
      expect(await pending(), isNull);
    });

    test('a server hiccup keeps the payment for the next check', () async {
      fakePay((_) => refused(503, 'The payment service cannot be reached.'));
      await expectLater(
        Billing.checkPending(),
        throwsA(isA<BillingException>()),
      );
      expect(await pending(), 'bw_1');
    });

    test(
      'nothing is checked while signed out or while the screen waits',
      () async {
        final requests = fakePay(
          (_) => ok({'status': 'paid', 'premium': true}),
        );
        Billing.watching = true;
        expect(await Billing.checkPending(), isNull);
        Billing.watching = false;
        Account.instance.resetForTest();
        expect(await Billing.checkPending(), isNull);
        expect(requests, isEmpty);
        expect(await pending(), 'bw_1');
      },
    );
  });

  test('no started payment means nothing to check', () async {
    final requests = fakePay((_) => ok({'status': 'paid'}));
    expect(await Billing.checkPending(), isNull);
    expect(requests, isEmpty);
  });

  test("the server's own sentence is shown on failure", () async {
    fakePay((_) => refused(503, 'Buying premium is not available yet.'));
    await expectLater(
      Billing.start('month'),
      throwsA(
        isA<BillingException>().having(
          (e) => e.message,
          'message',
          'Buying premium is not available yet.',
        ),
      ),
    );
    expect(await pending(), isNull);

    Billing.httpClient = MockClient((_) async => http.Response('oops', 500));
    await expectLater(
      Billing.plans(),
      throwsA(
        isA<BillingException>().having(
          (e) => e.message,
          'message',
          'The server answered 500. Try again later.',
        ),
      ),
    );
  });

  test('no connection gives a plain sentence', () async {
    Billing.httpClient = MockClient((_) async => throw Exception('offline'));
    await expectLater(
      Billing.plans(),
      throwsA(
        isA<BillingException>().having(
          (e) => e.message,
          'message',
          'Could not reach the server. Check your connection.',
        ),
      ),
    );
  });

  test('signed out: asks to sign in, and calls nothing', () async {
    Account.instance.resetForTest();
    final requests = <http.Request>[];
    Billing.httpClient = MockClient((request) async {
      requests.add(request);
      return ok(_offer);
    });
    await expectLater(
      Billing.plans(),
      throwsA(
        isA<BillingException>().having(
          (e) => e.message,
          'message',
          Billing.signInHint,
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test('only the daily limit message offers an upgrade', () {
    expect(
      AiClient.isDailyLimit(
        "You have used today's 5 AI requests. They reset at midnight UTC.",
      ),
      isTrue,
    );
    expect(
      AiClient.isDailyLimit('Too many requests. Wait a minute and try again.'),
      isFalse,
    );
  });

  group('the premium screen', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: UpgradeScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the plans, the saving and the price to pay', (
      tester,
    ) async {
      fakePay((_) => ok(_offer));
      await open(tester);
      expect(find.text('Free plan'), findsOneWidget);
      expect(find.text('30 days of premium'), findsOneWidget);
      expect(find.text('365 days of premium'), findsOneWidget);
      expect(find.text('Save KES 1,100'), findsOneWidget);
      expect(find.text('Pay KES 300'), findsOneWidget);

      await tester.tap(find.text('365 days of premium'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 2,500'), findsOneWidget);
    });

    testWidgets('not on sale: says so and offers nothing to pay', (
      tester,
    ) async {
      fakePay((_) => ok({..._offer, 'enabled': false}));
      await open(tester);
      expect(find.text('Premium is not on sale yet.'), findsOneWidget);
      expect(find.textContaining('Pay KES'), findsNothing);
    });

    testWidgets('already premium: can add more days', (tester) async {
      fakePay((_) => ok({..._offer, 'premium': true, 'expires': null}));
      await open(tester);
      expect(find.text('Premium'), findsWidgets);
      expect(find.text('Add 30 more days'), findsOneWidget);
      expect(find.text('Pay KES 300'), findsOneWidget);
    });

    testWidgets('a failed load can be tried again', (tester) async {
      fakePay((_) => refused(500, 'Something broke.'));
      await open(tester);
      expect(find.text('Something broke.'), findsOneWidget);
      fakePay((_) => ok(_offer));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 300'), findsOneWidget);
    });

    testWidgets('paying: waits, then not confirmed, then paid', (tester) async {
      var answer = 'pending';
      final opened = <String>[];
      UpgradeScreen.openUrl = (url) async {
        opened.add(url);
        return true;
      };
      fakePay(
        (request) => switch (request.url.path.split('/').last) {
          'plans' => ok(_offer),
          'start' => ok({'reference': 'bw_9', 'url': 'https://pay/9'}),
          _ => ok({
            'status': answer,
            'premium': answer == 'paid',
            'expires': answer == 'paid' ? '2026-12-21T10:00:00+00:00' : null,
          }),
        },
      );
      await open(tester);
      await tester.tap(find.text('Pay KES 300'));
      await tester.pumpAndSettle();
      expect(opened, ['https://pay/9']);
      expect(
        find.text('Finish paying in your browser, then come back here.'),
        findsOneWidget,
      );
      expect(Billing.watching, isTrue);

      await tester.tap(find.text('I have paid, check now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not confirmed yet.'), findsOneWidget);

      // Coming back from the browser checks by itself.
      answer = 'paid';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('You are on premium until'), findsOneWidget);
      // The plan line at the top follows.
      expect(find.text('Free plan'), findsNothing);
      expect(find.textContaining('Premium until'), findsOneWidget);
      expect(Billing.watching, isFalse);
      expect(await pending(), isNull);
    });

    testWidgets('a payment that failed goes back to the plans', (tester) async {
      UpgradeScreen.openUrl = (_) async => true;
      fakePay(
        (request) => switch (request.url.path.split('/').last) {
          'plans' => ok(_offer),
          'start' => ok({'reference': 'bw_9', 'url': 'https://pay/9'}),
          _ => ok({'status': 'failed', 'premium': false, 'expires': null}),
        },
      );
      await open(tester);
      await tester.tap(find.text('Pay KES 300'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have paid, check now'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('That payment did not go through.'),
        findsOneWidget,
      );
      expect(find.text('Pay KES 300'), findsOneWidget);
    });

    testWidgets('a browser that will not open leaves nothing waiting', (
      tester,
    ) async {
      UpgradeScreen.openUrl = (_) async => false;
      fakePay(
        (request) => request.url.path.endsWith('plans')
            ? ok(_offer)
            : ok({'reference': 'bw_9', 'url': 'https://pay/9'}),
      );
      await open(tester);
      await tester.tap(find.text('Pay KES 300'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not open the payment page. Try again.'),
        findsOneWidget,
      );
      expect(await pending(), isNull);
    });
  });
}
