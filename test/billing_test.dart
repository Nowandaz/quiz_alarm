// Buying a plan: the calls to the server, the payment that is remembered
// while the user pays, and the plans screen.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/screens/card_pay_page.dart';
import 'package:quiz_alarm/screens/upgrade_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/ai_client.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

const _pro = {
  'id': 'pro',
  'name': 'Pro',
  'description': 'Everything in the question bank and far more AI.',
  'features': [
    'Every unit in the question bank, including the premium ones',
    'New questions written for you',
  ],
  'ai_daily_limit': 200,
  'premium_units': true,
  'options': [
    {'period': 'month', 'days': 30, 'price': 300.0},
    {'period': 'year', 'days': 365, 'price': 2500.0},
  ],
};

/// Sold by the month only, and its features already give the AI number.
const _max = {
  'id': 'max',
  'name': 'Max',
  'description': 'For heavy use of the AI tutor.',
  'features': ['Everything in Pro', '1000 AI requests a day'],
  'ai_daily_limit': 1000,
  'premium_units': true,
  'options': [
    {'period': 'month', 'days': 30, 'price': 600.0},
  ],
};

const _offer = {
  'enabled': true,
  'currency': 'KES',
  'methods': ['mpesa', 'card'],
  'tiers': [_pro, _max],
  'premium': false,
  'tier': '',
  'tier_name': '',
  'expires': null,
};

const _onPro = {
  'premium': true,
  'tier': 'pro',
  'tier_name': 'Pro',
  'expires': '2026-12-21T10:00:00+00:00',
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

Future<PaymentStart> startMpesa() => Billing.start(
  tier: 'pro',
  period: 'month',
  method: 'mpesa',
  phone: '0712345678',
);

/// The last part of the address a request went to: "plans", "start"...
String call(http.Request request) => request.url.path.split('/').last;

void main() {
  setUp(() async {
    await resetApp(signedIn: true);
    Billing.resetForTest();
    UpgradeScreen.openCardPage = null;
  });

  test('plans are read with tiers, prices, ways to pay and the plan', () async {
    final requests = fakePay((_) => ok({..._offer, ..._onPro}));
    final offer = await Billing.plans();
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, endsWith('/v1/pay/plans'));
    expect(offer.enabled, isTrue);
    expect(offer.currency, 'KES');
    expect(offer.methods, ['mpesa', 'card']);
    expect(offer.tiers.map((t) => t.id), ['pro', 'max']);

    final pro = offer.tiers.first;
    expect(pro.name, 'Pro');
    expect(pro.description, startsWith('Everything in the question bank'));
    expect(pro.features, hasLength(2));
    expect(pro.aiDailyLimit, 200);
    expect(pro.premiumUnits, isTrue);
    expect(pro.options.map((o) => o.period), ['month', 'year']);
    expect(pro.option('month')!.days, 30);
    expect(
      Billing.money(pro.option('year')!.price, offer.currency),
      'KES 2,500',
    );

    // A tier may be sold one way only.
    final max = offer.tiers.last;
    expect(max.options, hasLength(1));
    expect(max.option('year'), isNull);
    expect(max.option('month')!.price, 600);

    expect(offer.premium, isTrue);
    expect(offer.tier, 'pro');
    expect(offer.tierName, 'Pro');
    expect(offer.expires, DateTime.utc(2026, 12, 21, 10));
    expect(offer.planLabel, 'Pro until ${Billing.day(offer.expires!)}');
    expect(Billing.last, same(offer));
  });

  test('plans without M-Pesa, and things this version does not know', () async {
    fakePay(
      (_) => ok({
        ..._offer,
        'methods': ['bank', 'card'],
        'tiers': [
          _max,
          // Nothing to buy on it, so it is left out.
          {'id': 'empty', 'name': 'Empty', 'options': []},
          'nonsense',
        ],
      }),
    );
    final offer = await Billing.plans();
    expect(offer.methods, ['card']);
    expect(offer.tiers.map((t) => t.id), ['max']);
  });

  test('M-Pesa is offered first whatever order the server gives', () async {
    fakePay(
      (_) => ok({
        ..._offer,
        'methods': ['card', 'mpesa'],
      }),
    );
    expect((await Billing.plans()).methods, ['mpesa', 'card']);
  });

  test('plan labels: free, a tier, and premium given by hand', () {
    const free = PremiumOffer(enabled: false, premium: false);
    const byHand = PremiumOffer(enabled: false, premium: true);
    const pro = PremiumOffer(enabled: true, premium: true, tierName: 'Pro');
    expect(free.planLabel, 'Free plan');
    expect(byHand.planLabel, 'Premium');
    expect(pro.planLabel, 'Pro');
    expect(Billing.day(DateTime(2026, 12, 21)), '21 Dec 2026');
    expect(
      const PaymentStatus(state: PaymentState.paid, premium: true).planName,
      'premium',
    );
  });

  test('a code that works gives the lower price', () async {
    final requests = fakePay(
      (_) => ok({
        'price': 150.0,
        'full_price': 300.0,
        'percent_off': 50,
        'currency': 'KES',
        'code': 'HALF',
        'code_message': '',
      }),
    );
    final quote = await Billing.quote('pro', 'month', ' half ');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, endsWith('/v1/pay/quote'));
    expect(requests.single.headers['Authorization'], 'Bearer test-token');
    // Sent tidy and in capitals: codes are the same in either case.
    expect(jsonDecode(requests.single.body), {
      'tier': 'pro',
      'period': 'month',
      'code': 'HALF',
    });
    expect(quote.applied, isTrue);
    expect(quote.price, 150);
    expect(quote.fullPrice, 300);
    expect(quote.percentOff, 50);
    expect(quote.code, 'HALF');
  });

  test('a code that does not work says why and leaves the price', () async {
    fakePay(
      (_) => ok({
        'price': 300.0,
        'full_price': 300.0,
        'percent_off': 0,
        'currency': 'KES',
        'code': '',
        'code_message': 'That code has expired.',
      }),
    );
    final quote = await Billing.quote('pro', 'month', 'OLD');
    expect(quote.applied, isFalse);
    expect(quote.price, 300);
    expect(quote.codeMessage, 'That code has expired.');
  });

  group('starting a payment', () {
    test('M-Pesa: remembered, with the message and the number', () async {
      final requests = fakePay(
        (_) => ok({
          'reference': 'bw_1',
          'status': 'pending',
          'message':
              'Check your phone (+254712345678) and enter your M-Pesa PIN.',
        }),
      );
      expect(await Billing.lastPhone(), '');
      final payment = await Billing.start(
        tier: 'pro',
        period: 'month',
        code: 'half',
        method: 'mpesa',
        phone: ' 0712345678 ',
      );
      expect(requests.single.method, 'POST');
      expect(requests.single.headers['Authorization'], 'Bearer test-token');
      expect(requests.single.url.path, endsWith('/v1/pay/start'));
      expect(jsonDecode(requests.single.body), {
        'tier': 'pro',
        'period': 'month',
        'code': 'HALF',
        'method': 'mpesa',
        'phone': '0712345678',
      });
      expect(payment.reference, 'bw_1');
      expect(payment.paid, isNull);
      expect(payment.message, contains('enter your M-Pesa PIN'));
      expect(await pending(), 'bw_1');
      expect(await Billing.pendingReference(), 'bw_1');
      // Offered again next time.
      expect(await Billing.lastPhone(), '0712345678');
    });

    test('card: remembered, with the page and where it ends', () async {
      final requests = fakePay(
        (_) => ok({
          'reference': 'bw_2',
          'status': 'pending',
          'url': 'https://checkout.paystack.com/x',
          'done_url': 'https://server.example/brainwake/paid',
        }),
      );
      final payment = await Billing.start(
        tier: 'max',
        period: 'month',
        method: 'card',
        // A number left in the box is nobody's business when paying by card.
        phone: '0712345678',
      );
      expect(jsonDecode(requests.single.body), {
        'tier': 'max',
        'period': 'month',
        'code': '',
        'method': 'card',
      });
      expect(payment.url, 'https://checkout.paystack.com/x');
      expect(payment.doneUrl, 'https://server.example/brainwake/paid');
      expect(payment.paid, isNull);
      expect(await pending(), 'bw_2');
      expect(await Billing.lastPhone(), '');
    });

    test('a card answer with no page is refused, nothing remembered', () async {
      fakePay((_) => ok({'reference': 'bw_2', 'status': 'pending'}));
      await expectLater(
        Billing.start(tier: 'pro', period: 'month', method: 'card'),
        throwsA(isA<BillingException>()),
      );
      expect(await pending(), isNull);
    });

    test('a free code is paid at once: nothing to wait for', () async {
      var fetched = 0;
      Billing.onPaid = () async => fetched++;
      fakePay((_) => ok(_offer));
      await Billing.plans();
      fakePay((_) => ok({'reference': 'bw_3', 'status': 'paid', ..._onPro}));
      final before = Billing.changes.value;
      final payment = await Billing.start(
        tier: 'pro',
        period: 'month',
        code: 'GIFT',
        method: 'card',
      );
      expect(payment.paid!.paid, isTrue);
      expect(payment.paid!.tierName, 'Pro');
      expect(payment.paid!.expires, DateTime.utc(2026, 12, 21, 10));
      expect(await pending(), isNull);
      expect(Billing.changes.value, before + 1);
      expect(fetched, 1);
      // The plan other screens show follows.
      expect(Billing.last!.premium, isTrue);
      expect(Billing.last!.tierName, 'Pro');
      expect(Billing.last!.tiers, hasLength(2));
    });

    test('a number the server refuses is not remembered', () async {
      fakePay(
        (_) =>
            refused(422, 'Enter your M-Pesa number, for example 0712 345 678.'),
      );
      await expectLater(
        Billing.start(
          tier: 'pro',
          period: 'month',
          method: 'mpesa',
          phone: '12',
        ),
        throwsA(
          isA<BillingException>().having(
            (e) => e.message,
            'message',
            'Enter your M-Pesa number, for example 0712 345 678.',
          ),
        ),
      );
      expect(await pending(), isNull);
      expect(await Billing.lastPhone(), '');
    });
  });

  group('checking a payment', () {
    setUp(() async {
      fakePay((_) => ok({'reference': 'bw_1', 'status': 'pending'}));
      await startMpesa();
    });

    test('paid: forgotten, screens told, the bank fetched once', () async {
      var fetched = 0;
      Billing.onPaid = () async => fetched++;
      final requests = fakePay(
        (_) => ok({
          'status': 'paid',
          'premium': true,
          'tier': 'pro',
          'tier_name': 'Pro',
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
      expect(status.tier, 'pro');
      expect(status.planName, 'Pro');
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
      startMpesa(),
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

  test('the card page: where it may go and when it is finished', () {
    const done = 'https://server.example/brainwake/paid';
    expect(
      cardPageMove('$done?reference=bw_1', doneUrl: done),
      CardPageMove.finished,
    );
    expect(
      cardPageMove('https://checkout.paystack.com/x', doneUrl: done),
      CardPageMove.allow,
    );
    expect(
      cardPageMove('https://bank.example/3ds', doneUrl: ''),
      CardPageMove.allow,
    );
    // No finish address given: nothing counts as finished.
    expect(cardPageMove('http://x.example/', doneUrl: ''), CardPageMove.block);
    for (final bad in [
      'http://checkout.paystack.com/x',
      'intent://pay#Intent;end',
      'tel:0712345678',
      'javascript:alert(1)',
      'about:blank',
      'not an address',
    ]) {
      expect(cardPageMove(bad, doneUrl: done), CardPageMove.block, reason: bad);
    }
    // Banks build their confirmation step in blank frames inside the page.
    expect(
      cardPageMove('about:blank', doneUrl: done, mainFrame: false),
      CardPageMove.allow,
    );
    expect(
      cardPageMove('http://x.example/', doneUrl: done, mainFrame: false),
      CardPageMove.block,
    );
  });

  group('the plans screen', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: UpgradeScreen()));
      await tester.pumpAndSettle();
    }

    /// Lets answers from the fake server arrive. Not pumpAndSettle: the
    /// waiting spinner never stops, and the clock must not jump to the
    /// next question to the server.
    Future<void> arrive(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Finder rich(String text) => find.text(text, findRichText: true);
    final codeBox = find.byType(TextField).first;
    final phoneBox = find.widgetWithText(TextField, 'M-Pesa number');
    final expires = Billing.day(DateTime.utc(2026, 12, 21, 10));

    http.Response quoteFor(http.Request request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final full = body['period'] == 'year' ? 2500.0 : 300.0;
      final (off, why) = switch (body['code']) {
        'HALF' => (50, ''),
        'GIFT' => (100, ''),
        'OLD' => (0, 'That code has expired.'),
        _ => (0, 'That code is not valid.'),
      };
      return ok({
        'price': full * (100 - off) / 100,
        'full_price': full,
        'percent_off': off,
        'currency': 'KES',
        'code': off == 0 ? '' : body['code'],
        'code_message': why,
      });
    }

    testWidgets('tiers, the period switch and the saving', (tester) async {
      fakePay((_) => ok(_offer));
      await open(tester);
      expect(find.text('Free plan'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Pro'), findsOneWidget);
      expect(find.text('Max'), findsOneWidget);
      expect(rich('KES 300 / month'), findsOneWidget);
      expect(rich('KES 600 / month'), findsOneWidget);
      expect(
        find.text(
          'Every unit in the question bank, including the premium ones',
        ),
        findsOneWidget,
      );
      // Added for Pro; Max already says its number.
      expect(find.text('200 AI requests a day'), findsOneWidget);
      expect(find.text('1000 AI requests a day'), findsOneWidget);
      expect(find.textContaining('Save KES'), findsNothing);
      expect(find.text('Your plan'), findsNothing);
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);

      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(rich('KES 2,500 / year'), findsOneWidget);
      expect(find.text('Save KES 1,100'), findsOneWidget);
      // Max is not sold by the year: it shows what it has.
      expect(rich('KES 600 / month'), findsOneWidget);
      expect(find.text('Pay KES 2,500 with M-Pesa'), findsOneWidget);
    });

    testWidgets('choosing a tier and a way to pay', (tester) async {
      fakePay((_) => ok(_offer));
      await open(tester);
      expect(phoneBox, findsOneWidget);
      await tester.tap(find.text('Max'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 600 with M-Pesa'), findsOneWidget);

      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 600 by card'), findsOneWidget);
      expect(phoneBox, findsNothing);
      expect(
        find.text(
          'Your card details go straight to Paystack. Brain O\' Clock never '
          'sees them.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('one option per tier: no switch. No M-Pesa: no number', (
      tester,
    ) async {
      fakePay(
        (_) => ok({
          ..._offer,
          'methods': ['card'],
          'tiers': [_max],
        }),
      );
      await open(tester);
      expect(find.text('Monthly'), findsNothing);
      expect(find.text('Yearly'), findsNothing);
      expect(find.text('M-Pesa'), findsNothing);
      expect(phoneBox, findsNothing);
      expect(find.text('Pay KES 600 by card'), findsOneWidget);
    });

    testWidgets('a tier sold by the year only starts on the year', (
      tester,
    ) async {
      fakePay(
        (_) => ok({
          ..._offer,
          'tiers': [
            {
              ..._pro,
              'options': [
                {'period': 'year', 'days': 365, 'price': 2500.0},
              ],
            },
          ],
        }),
      );
      await open(tester);
      expect(rich('KES 2,500 / year'), findsOneWidget);
      // Nothing to compare the year with, so no saving is claimed.
      expect(find.textContaining('Save KES'), findsNothing);
      expect(find.text('Pay KES 2,500 with M-Pesa'), findsOneWidget);
    });

    testWidgets('on a plan already: marked, and buying it adds days', (
      tester,
    ) async {
      fakePay((_) => ok({..._offer, ..._onPro}));
      await open(tester);
      expect(find.text('Pro until $expires'), findsOneWidget);
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Adds 30 days'), findsOneWidget);
      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(find.text('Adds 365 days'), findsOneWidget);
    });

    testWidgets('premium given by hand shows as Premium', (tester) async {
      fakePay(
        (_) => ok({..._offer, 'premium': true, 'tier': '', 'expires': null}),
      );
      await open(tester);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.text('Your plan'), findsNothing);
    });

    testWidgets('a code that works: the discount and the new price', (
      tester,
    ) async {
      final requests = fakePay(
        (request) => call(request) == 'plans' ? ok(_offer) : quoteFor(request),
      );
      await open(tester);
      await tester.enterText(codeBox, 'half');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      // Shown in capitals whatever was typed.
      expect(find.text('HALF'), findsOneWidget);
      expect(jsonDecode(requests.last.body), {
        'tier': 'pro',
        'period': 'month',
        'code': 'HALF',
      });
      expect(find.text('HALF applied: 50% off'), findsOneWidget);
      final full = tester.widget<Text>(find.text('KES 300'));
      expect(full.style!.decoration, TextDecoration.lineThrough);
      expect(find.text('KES 150'), findsOneWidget);
      expect(find.text('Pay KES 150 with M-Pesa'), findsOneWidget);

      // Another period is priced again with the same code.
      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body)['period'], 'year');
      expect(find.text('Pay KES 1,250 with M-Pesa'), findsOneWidget);

      // Changing the code takes the discount away until it is applied.
      await tester.enterText(codeBox, 'HAL');
      await tester.pumpAndSettle();
      expect(find.textContaining('applied'), findsNothing);
      expect(find.text('Pay KES 2,500 with M-Pesa'), findsOneWidget);
    });

    testWidgets('a code that does not work: the reason, the full price', (
      tester,
    ) async {
      fakePay(
        (request) => call(request) == 'plans' ? ok(_offer) : quoteFor(request),
      );
      await open(tester);
      await tester.enterText(codeBox, 'old');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final why = tester.widget<Text>(find.text('That code has expired.'));
      expect(
        why.style!.color,
        Theme.of(tester.element(find.byType(UpgradeScreen))).colorScheme.error,
      );
      expect(find.textContaining('applied'), findsNothing);
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);
    });

    testWidgets('paying with a typed code prices it first', (tester) async {
      final requests = fakePay(
        (request) => call(request) == 'plans' ? ok(_offer) : quoteFor(request),
      );
      await open(tester);
      await tester.enterText(phoneBox, '0712345678');
      await tester.enterText(codeBox, 'HALF');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await tester.pumpAndSettle();
      // Nothing was started: the user sees the new price first.
      expect(requests.map(call), ['plans', 'quote']);
      expect(find.text('Pay KES 150 with M-Pesa'), findsOneWidget);
    });

    testWidgets('a free code: no way to pay to choose, plan at once', (
      tester,
    ) async {
      final requests = fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'quote' => quoteFor(request),
          _ => ok({'reference': 'bw_3', 'status': 'paid', ..._onPro}),
        },
      );
      await open(tester);
      await tester.enterText(codeBox, 'GIFT');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('GIFT applied: 100% off'), findsOneWidget);
      expect(find.text('Pay with'), findsNothing);
      expect(phoneBox, findsNothing);
      expect(find.textContaining('Pay KES'), findsNothing);

      await tester.tap(find.text('Get Pro free'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body), {
        'tier': 'pro',
        'period': 'month',
        'code': 'GIFT',
        'method': 'card',
      });
      expect(find.text('You are on Pro until $expires.'), findsOneWidget);
      expect(find.text('Pro until $expires'), findsOneWidget);
      expect(await pending(), isNull);
      expect(Billing.watching, isFalse);
    });

    testWidgets('M-Pesa: waits, keeps asking, then paid', (tester) async {
      var answer = 'pending';
      final requests = fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({
            'reference': 'bw_9',
            'status': 'pending',
            'message':
                'Check your phone (+254712345678) and enter your M-Pesa PIN.',
          }),
          _ => ok({
            'status': answer,
            'premium': answer == 'paid',
            'tier': answer == 'paid' ? 'pro' : '',
            'tier_name': answer == 'paid' ? 'Pro' : '',
            'expires': answer == 'paid' ? '2026-12-21T10:00:00+00:00' : null,
          }),
        },
      );
      await open(tester);
      await tester.enterText(phoneBox, '0712 345 678');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await arrive(tester);
      expect(jsonDecode(requests.last.body), {
        'tier': 'pro',
        'period': 'month',
        'code': '',
        'method': 'mpesa',
        'phone': '0712 345 678',
      });
      expect(
        find.text(
          'Check your phone (+254712345678) and enter your M-Pesa PIN.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(Billing.watching, isTrue);
      expect(await pending(), 'bw_9');
      // Nothing is asked before the first wait is over.
      expect(requests.map(call), ['plans', 'start']);

      await tester.pump(const Duration(seconds: 4));
      await arrive(tester);
      expect(requests.map(call), ['plans', 'start', 'verify']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      answer = 'paid';
      await tester.pump(const Duration(seconds: 4));
      await arrive(tester);
      expect(find.text('You are on Pro until $expires.'), findsOneWidget);
      // The plan line at the top follows.
      expect(find.text('Free plan'), findsNothing);
      expect(find.text('Pro until $expires'), findsOneWidget);
      expect(Billing.watching, isFalse);
      expect(await pending(), isNull);

      // Paid: the asking has stopped.
      final asked = requests.length;
      await tester.pump(const Duration(seconds: 30));
      expect(requests, hasLength(asked));
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('M-Pesa: the remembered number is filled in', (tester) async {
      SharedPreferences.setMockInitialValues({Billing.phonePref: '0712345678'});
      fakePay((_) => ok(_offer));
      await open(tester);
      expect(find.text('0712345678'), findsOneWidget);
    });

    testWidgets('M-Pesa: after two minutes, Check again or Cancel', (
      tester,
    ) async {
      var answer = 'pending';
      final requests = fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({
            'reference': 'bw_9',
            'status': 'pending',
            'message': 'Check your phone.',
          }),
          _ => ok({'status': answer, 'premium': answer == 'paid'}),
        },
      );
      await open(tester);
      await tester.enterText(phoneBox, '0712345678');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await arrive(tester);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 4));
        await arrive(tester);
      }
      expect(
        find.text(
          'Still waiting for M-Pesa. If you approved it, tap Check again.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // It has stopped asking by itself.
      final asked = requests.length;
      await tester.pump(const Duration(seconds: 30));
      expect(requests, hasLength(asked));

      // Coming back to the app asks once more.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await arrive(tester);
      expect(requests, hasLength(asked + 1));

      answer = 'paid';
      await tester.tap(find.text('Check again'));
      await arrive(tester);
      expect(find.text('You are on premium.'), findsNothing);
      expect(find.text('You are on Premium.'), findsOneWidget);
    });

    testWidgets('M-Pesa: a payment that failed goes back to the plans', (
      tester,
    ) async {
      fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({'reference': 'bw_9', 'status': 'pending'}),
          _ => ok({'status': 'failed', 'premium': false, 'expires': null}),
        },
      );
      await open(tester);
      await tester.enterText(phoneBox, '0712345678');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await arrive(tester);
      // The server sent no words of its own.
      expect(
        find.text('Check your phone and enter your M-Pesa PIN.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That payment did not go through. Nothing was charged. Try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);
      expect(Billing.watching, isFalse);
      expect(await pending(), isNull);
    });

    testWidgets('M-Pesa: Cancel and leaving both stop the asking', (
      tester,
    ) async {
      final requests = fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({'reference': 'bw_9', 'status': 'pending'}),
          _ => ok({'status': 'pending', 'premium': false}),
        },
      );
      await open(tester);
      await tester.enterText(phoneBox, '0712345678');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await arrive(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);
      var asked = requests.length;
      await tester.pump(const Duration(seconds: 30));
      expect(requests, hasLength(asked));
      // Still remembered: the app checks it the next time it is opened.
      expect(await pending(), 'bw_9');
      expect(Billing.watching, isFalse);

      // Start again, then leave the screen while it waits.
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await arrive(tester);
      expect(Billing.watching, isTrue);
      asked = requests.length;
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(minutes: 1));
      expect(requests, hasLength(asked));
      expect(Billing.watching, isFalse);
    });

    testWidgets('M-Pesa: a number the server refuses is said so', (
      tester,
    ) async {
      final requests = fakePay(
        (request) => call(request) == 'plans'
            ? ok(_offer)
            : refused(
                422,
                'Enter your M-Pesa number, for example 0712 345 678.',
              ),
      );
      await open(tester);
      // An empty box is caught before the server is asked.
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter your M-Pesa number, for example 0712 345 678.'),
        findsOneWidget,
      );
      expect(requests.map(call), ['plans']);

      await tester.enterText(phoneBox, '12');
      await tester.tap(find.text('Pay KES 300 with M-Pesa'));
      await tester.pumpAndSettle();
      expect(requests.map(call), ['plans', 'start']);
      expect(
        find.text('Enter your M-Pesa number, for example 0712 345 678.'),
        findsOneWidget,
      );
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);
      expect(await pending(), isNull);
    });

    testWidgets('card: the page is shown, then the payment is checked', (
      tester,
    ) async {
      final shown = <String>[];
      UpgradeScreen.openCardPage = (_, url, doneUrl) async {
        shown.addAll([url, doneUrl]);
        return true;
      };
      final requests = fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({
            'reference': 'bw_9',
            'status': 'pending',
            'url': 'https://checkout.paystack.com/9',
            'done_url': 'https://server.example/brainwake/paid',
          }),
          _ => ok({'status': 'paid', ..._onPro}),
        },
      );
      await open(tester);
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay KES 300 by card'));
      await tester.pumpAndSettle();
      expect(shown, [
        'https://checkout.paystack.com/9',
        'https://server.example/brainwake/paid',
      ]);
      expect(requests.map(call), ['plans', 'start', 'verify']);
      expect(find.text('You are on Pro until $expires.'), findsOneWidget);
      expect(await pending(), isNull);
      expect(Billing.watching, isFalse);
    });

    testWidgets('card: closing the page early goes back to the plans', (
      tester,
    ) async {
      UpgradeScreen.openCardPage = (_, _, _) async => false;
      fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({
            'reference': 'bw_9',
            'status': 'pending',
            'url': 'https://checkout.paystack.com/9',
            'done_url': 'https://server.example/brainwake/paid',
          }),
          _ => ok({'status': 'pending', 'premium': false}),
        },
      );
      await open(tester);
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay KES 300 by card'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The card payment was not finished.'),
        findsOneWidget,
      );
      expect(find.text('Pay KES 300 by card'), findsOneWidget);
      // If they did pay after all, the app finds out later.
      expect(await pending(), 'bw_9');
      expect(Billing.watching, isFalse);
    });

    testWidgets('card: finished but not confirmed yet keeps asking', (
      tester,
    ) async {
      var answer = 'pending';
      UpgradeScreen.openCardPage = (_, _, _) async => true;
      fakePay(
        (request) => switch (call(request)) {
          'plans' => ok(_offer),
          'start' => ok({
            'reference': 'bw_9',
            'status': 'pending',
            'url': 'https://checkout.paystack.com/9',
            'done_url': 'https://server.example/brainwake/paid',
          }),
          _ => ok({'status': answer, ...(answer == 'paid' ? _onPro : {})}),
        },
      );
      await open(tester);
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay KES 300 by card'));
      await arrive(tester);
      expect(find.textContaining('Confirming your payment.'), findsOneWidget);
      answer = 'paid';
      await tester.pump(const Duration(seconds: 4));
      await arrive(tester);
      expect(find.text('You are on Pro until $expires.'), findsOneWidget);
    });

    testWidgets('card: where no page can be shown, it says so', (tester) async {
      // The test runs as an Android phone by default; pretend otherwise.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final requests = fakePay((_) => ok(_offer));
      await open(tester);
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay KES 300 by card'));
      await tester.pumpAndSettle();
      expect(
        find.text('Card payment is only available in the phone app.'),
        findsOneWidget,
      );
      // Nothing was started, so nothing is left waiting.
      expect(requests.map(call), ['plans']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('fits a small phone with everything showing', (tester) async {
      // An overflow anywhere fails the test by itself.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      fakePay(
        (request) => switch (call(request)) {
          'plans' => ok({..._offer, ..._onPro}),
          'quote' => quoteFor(request),
          _ => ok({'reference': 'bw_9', 'status': 'pending'}),
        },
      );
      await tester.pumpWidget(const MaterialApp(home: UpgradeScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();
      expect(find.text('Save KES 1,100'), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Apply'),
        200,
        scrollable: list,
      );
      await tester.enterText(codeBox, 'HALF');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final pay = find.text('Pay KES 1,250 with M-Pesa');
      await tester.scrollUntilVisible(pay, 200, scrollable: list);
      await tester.enterText(phoneBox, '0712345678');
      await tester.tap(pay);
      await arrive(tester);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('not on sale: says so and offers nothing to pay', (
      tester,
    ) async {
      fakePay((_) => ok({..._offer, 'enabled': false}));
      await open(tester);
      expect(find.text('Free plan'), findsOneWidget);
      expect(find.text('Plans are not on sale yet.'), findsOneWidget);
      expect(find.textContaining('Pay KES'), findsNothing);
      expect(find.text('Have a code?'), findsNothing);
    });

    testWidgets('a failed load can be tried again', (tester) async {
      fakePay((_) => refused(500, 'Something broke.'));
      await open(tester);
      expect(find.text('Something broke.'), findsOneWidget);
      fakePay((_) => ok(_offer));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Pay KES 300 with M-Pesa'), findsOneWidget);
    });
  });
}
