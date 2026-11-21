/// Buying a plan. The server decides what is for sale (one or more tiers,
/// each for a month or a year), prices a discount code, and takes the
/// money through Paystack: an M-Pesa prompt on the phone, or a card page.
/// This file asks for the plans, prices a code, starts a payment and asks
/// whether it went through. What is sold is time paid once: nothing
/// renews, and paying again adds days.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'server_config.dart';

class BillingException implements Exception {
  final String message;
  const BillingException(this.message);
  @override
  String toString() => message;
}

/// One way to buy a tier: so many days for a price.
class PlanOption {
  final String period; // "month" or "year"
  final int days;
  final num price;
  const PlanOption({
    required this.period,
    required this.days,
    required this.price,
  });
}

/// One plan the owner sells ("Pro", "Max"): what it gives and its prices.
class PremiumTier {
  final String id;
  final String name;
  final String description;
  final List<String> features;

  /// AI requests a day on this tier. 0 when the server did not say.
  final int aiDailyLimit;
  final bool premiumUnits;

  /// Never empty: a tier with nothing to buy is left out when reading.
  final List<PlanOption> options;
  const PremiumTier({
    required this.id,
    required this.name,
    required this.options,
    this.description = '',
    this.features = const [],
    this.aiDailyLimit = 0,
    this.premiumUnits = false,
  });

  /// The option for [period], or null when this tier is not sold that way.
  PlanOption? option(String period) {
    for (final o in options) {
      if (o.period == period) return o;
    }
    return null;
  }
}

/// What is for sale right now, and the plan the user is on.
class PremiumOffer {
  /// False while the owner has not switched buying on.
  final bool enabled;
  final String currency;

  /// Ways to pay the app knows, in the order to show them: "mpesa", "card".
  final List<String> methods;
  final List<PremiumTier> tiers;
  final bool premium;

  /// The tier the user is on. Empty on the free plan, and for premium
  /// that was given by hand.
  final String tier;
  final String tierName;

  /// When the plan ends. Null on the free plan, or for one with no end.
  final DateTime? expires;
  const PremiumOffer({
    required this.enabled,
    required this.premium,
    this.currency = '',
    this.methods = const [],
    this.tiers = const [],
    this.tier = '',
    this.tierName = '',
    this.expires,
  });

  /// "Free plan", "Pro until 21 Dec 2026", "Pro" or just "Premium".
  String get planLabel {
    if (!premium) return 'Free plan';
    final name = tierName.isEmpty ? 'Premium' : tierName;
    return expires == null ? name : '$name until ${Billing.day(expires!)}';
  }
}

/// The price of a tier for a period, after a discount code if one works.
class PriceQuote {
  final num price;
  final num fullPrice;
  final int percentOff;
  final String currency;

  /// The code as the server accepted it. Empty when it did not work.
  final String code;

  /// Why the code did not work, in the server's words. Empty when it did.
  final String codeMessage;
  const PriceQuote({
    required this.price,
    required this.fullPrice,
    required this.percentOff,
    required this.currency,
    required this.code,
    required this.codeMessage,
  });

  bool get applied => code.isNotEmpty;
}

/// A payment the server has opened. One of three things: an M-Pesa prompt
/// is on its way to the phone ([message]), a card page is ready ([url]),
/// or a code covered the whole price and it is already [paid].
class PaymentStart {
  final String reference;

  /// Set when nothing was left to pay.
  final PaymentStatus? paid;

  /// M-Pesa: what to tell the user ("Check your phone ...").
  final String message;

  /// Card: Paystack's page, and the address it goes to when finished.
  final String url;
  final String doneUrl;
  const PaymentStart({
    required this.reference,
    this.paid,
    this.message = '',
    this.url = '',
    this.doneUrl = '',
  });
}

enum PaymentState { pending, paid, failed }

/// The server's answer to "did this payment go through?".
class PaymentStatus {
  final PaymentState state;
  final bool premium;
  final String tier;
  final String tierName;
  final DateTime? expires;
  const PaymentStatus({
    required this.state,
    required this.premium,
    this.tier = '',
    this.tierName = '',
    this.expires,
  });
  bool get paid => state == PaymentState.paid;

  /// The plan's name for a sentence: "You are on Pro." / "... on premium."
  String get planName => tierName.isEmpty ? 'premium' : tierName;
}

class Billing {
  /// Tests replace this with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// Goes up by one whenever the user's plan changed (a payment was
  /// confirmed), so screens showing the plan can refresh.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Run when a payment is confirmed. main() sets it to a full download of
  /// the question bank, so the premium units arrive. Left empty in tests,
  /// which must not reach the network.
  static Future<void> Function()? onPaid;

  /// True while the premium screen is waiting for a payment. It does its
  /// own checking, so [checkPending] stands down: otherwise both would ask
  /// at once and the user would be told twice.
  static bool watching = false;

  static const String signInHint = 'Sign in to buy a plan.';

  /// Where the name of a started payment is kept, so it can still be
  /// checked if the app was closed while the user was paying.
  static const String pendingPref = 'pending_payment';
  static const String _pendingAtPref = 'pending_payment_at';

  /// The M-Pesa number last paid with, to save typing it again.
  static const String phonePref = 'mpesa_phone';

  /// A payment page nobody finished stays "pending" on the server for
  /// good. After this long the app stops asking about it. (A payment that
  /// does arrive later still counts: the server hears from Paystack.)
  static const Duration _giveUpAfter = Duration(days: 2);

  static PremiumOffer? _last;
  static String? _lastUser;

  /// The latest answer from [plans] for the signed-in account, if any.
  /// Lets a screen show the plan without waiting for the server.
  static PremiumOffer? get last =>
      _lastUser != null && _lastUser == Account.instance.userId ? _last : null;

  @visibleForTesting
  static void resetForTest() {
    _last = _lastUser = null;
    onPaid = null;
    watching = false;
  }

  /// "KES 1,100".
  static String money(num amount, String currency) =>
      '$currency ${NumberFormat('#,##0.##', 'en_US').format(amount)}';

  /// "21 Dec 2026", in the phone's own time.
  static String day(DateTime when) =>
      DateFormat('d MMM y', 'en_US').format(when.toLocal());

  static Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = await Account.instance.accessToken();
    if (token == null) {
      throw BillingException(
        Account.instance.isSignedIn
            ? 'Could not reach the server. Check your connection.'
            : signInHint,
      );
    }
    final uri = Uri.parse('${ServerConfig.apiUrl}$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };

    final http.Response res;
    try {
      // The server may itself have to ask Paystack (up to 20 seconds).
      res =
          await (method == 'GET'
                  ? httpClient.get(uri, headers: headers)
                  : httpClient.post(
                      uri,
                      headers: headers,
                      body: jsonEncode(body),
                    ))
              .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const BillingException(
        'The server took too long to answer. Try again.',
      );
    } catch (e) {
      throw const BillingException(
        'Could not reach the server. Check your connection.',
      );
    }

    dynamic data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (res.statusCode != 200) {
      final detail = data is Map ? data['detail'] : null;
      throw _ServerSaid(
        res.statusCode,
        detail is String && detail.isNotEmpty
            ? detail
            : 'The server answered ${res.statusCode}. Try again later.',
      );
    }
    if (data is! Map<String, dynamic>) {
      throw const BillingException('The server sent an unreadable reply.');
    }
    return data;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static String _text(Object? value) => value is String ? value : '';

  static PaymentStatus _status(Map<String, dynamic> data) => PaymentStatus(
    state: switch (data['status']) {
      'paid' => PaymentState.paid,
      'failed' => PaymentState.failed,
      _ => PaymentState.pending,
    },
    premium: data['premium'] == true,
    tier: _text(data['tier']),
    tierName: _text(data['tier_name']),
    expires: _date(data['expires']),
  );

  static PremiumTier? _tier(Object? t) {
    if (t is! Map || t['id'] is! String) return null;
    final options = [
      for (final o in t['options'] is List ? t['options'] as List : [])
        if (o is Map && o['period'] is String && o['price'] is num)
          PlanOption(
            period: o['period'] as String,
            days: (o['days'] as num?)?.toInt() ?? 0,
            price: o['price'] as num,
          ),
    ];
    // Nothing to buy on it, so nothing to show.
    if (options.isEmpty) return null;
    final name = _text(t['name']);
    return PremiumTier(
      id: t['id'] as String,
      name: name.isEmpty ? 'Premium' : name,
      description: _text(t['description']),
      features: [
        for (final f in t['features'] is List ? t['features'] as List : [])
          if (f is String && f.trim().isNotEmpty) f.trim(),
      ],
      aiDailyLimit: (t['ai_daily_limit'] as num?)?.toInt() ?? 0,
      premiumUnits: t['premium_units'] == true,
      options: options,
    );
  }

  /// What can be bought, and the plan the user is on now.
  static Future<PremiumOffer> plans() async {
    final user = Account.instance.userId;
    final data = await _call('GET', '/v1/pay/plans');
    final said = data['methods'] is List ? data['methods'] as List : [];
    final offer = PremiumOffer(
      enabled: data['enabled'] == true,
      currency: _text(data['currency']),
      // M-Pesa first: it is what most people here pay with. A way to pay
      // this version does not know is left out.
      methods: [
        for (final m in const ['mpesa', 'card'])
          if (said.contains(m)) m,
      ],
      tiers: [
        for (final t in data['tiers'] is List ? data['tiers'] as List : [])
          ?_tier(t),
      ],
      premium: data['premium'] == true,
      tier: _text(data['tier']),
      tierName: _text(data['tier_name']),
      expires: _date(data['expires']),
    );
    _last = offer;
    _lastUser = user;
    return offer;
  }

  /// A discount code as the server wants it: no spaces around it, and in
  /// capitals (codes are the same in either case).
  static String tidyCode(String code) => code.trim().toUpperCase();

  /// The price of [tier] for [period] with [code]. A code that does not
  /// work is not an error: the quote says why in [PriceQuote.codeMessage].
  static Future<PriceQuote> quote(
    String tier,
    String period,
    String code,
  ) async {
    final data = await _call(
      'POST',
      '/v1/pay/quote',
      body: {'tier': tier, 'period': period, 'code': tidyCode(code)},
    );
    final price = data['price'];
    if (price is! num) {
      throw const BillingException('The server sent an unreadable reply.');
    }
    return PriceQuote(
      price: price,
      fullPrice: data['full_price'] is num ? data['full_price'] as num : price,
      percentOff: (data['percent_off'] as num?)?.toInt() ?? 0,
      currency: _text(data['currency']),
      code: _text(data['code']),
      codeMessage: _text(data['code_message']),
    );
  }

  /// Opens a payment on the server. [method] is "mpesa" (with [phone]) or
  /// "card". Unless a code made it free, the payment is remembered so it
  /// can still be checked if the app is closed meanwhile.
  static Future<PaymentStart> start({
    required String tier,
    required String period,
    required String method,
    String code = '',
    String phone = '',
  }) async {
    final mpesa = method == 'mpesa';
    final data = await _call(
      'POST',
      '/v1/pay/start',
      body: {
        'tier': tier,
        'period': period,
        'code': tidyCode(code),
        'method': method,
        if (mpesa) 'phone': phone.trim(),
      },
    );
    final reference = data['reference'];
    if (reference is! String || reference.isEmpty) {
      throw const BillingException('The server sent an unreadable reply.');
    }
    final prefs = await SharedPreferences.getInstance();
    // The server took the number, so it is worth offering again next time.
    if (mpesa && phone.trim().isNotEmpty) {
      await prefs.setString(phonePref, phone.trim());
    }

    final status = _status(data);
    if (status.paid) {
      // A code covered everything: there is no payment to wait for.
      _confirmed(status);
      return PaymentStart(reference: reference, paid: status);
    }

    final url = _text(data['url']);
    if (!mpesa && url.isEmpty) {
      throw const BillingException('The server sent an unreadable reply.');
    }
    await prefs.setString(pendingPref, reference);
    await prefs.setInt(_pendingAtPref, DateTime.now().millisecondsSinceEpoch);
    return PaymentStart(
      reference: reference,
      message: _text(data['message']),
      url: url,
      doneUrl: _text(data['done_url']),
    );
  }

  /// The M-Pesa number the user paid with last time, or "".
  static Future<String> lastPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(phonePref) ?? '';
  }

  /// The plan changed: tell the screens and fetch what the plan unlocks.
  static void _confirmed(PaymentStatus status) {
    final known = last;
    if (known != null) {
      _last = PremiumOffer(
        enabled: known.enabled,
        currency: known.currency,
        methods: known.methods,
        tiers: known.tiers,
        premium: status.premium,
        tier: status.tier,
        tierName: status.tierName,
        expires: status.expires,
      );
    }
    // Not waited for: downloading the bank can take a while and the
    // user should see "paid" straight away.
    final paid = onPaid;
    if (paid != null) unawaited(paid().catchError((Object _) {}));
    changes.value++;
  }

  /// Asks whether the payment [reference] went through. Once it is paid or
  /// has failed it is no longer remembered as waiting.
  static Future<PaymentStatus> verify(String reference) async {
    final data = await _call(
      'GET',
      '/v1/pay/verify?reference=${Uri.encodeQueryComponent(reference)}',
    );
    final status = _status(data);
    if (status.state == PaymentState.pending) return status;

    final prefs = await SharedPreferences.getInstance();
    // Only the first answer for a payment acts on it, so two checks that
    // overlap do not announce the same payment twice.
    final first = prefs.getString(pendingPref) == reference;
    if (first) await forgetPending();
    if (status.paid && first) _confirmed(status);
    return status;
  }

  /// The payment that was started and not yet seen to finish, if any.
  static Future<String?> pendingReference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(pendingPref);
  }

  /// Stops remembering the started payment.
  static Future<void> forgetPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingPref);
    await prefs.remove(_pendingAtPref);
  }

  /// Checks the payment that was started earlier, if there is one. Null
  /// when there is nothing to check. Throws [BillingException] when the
  /// server could not be asked.
  static Future<PaymentStatus?> checkPending() async {
    if (watching || !Account.instance.isSignedIn) return null;
    final prefs = await SharedPreferences.getInstance();
    final reference = prefs.getString(pendingPref);
    if (reference == null) return null;
    final PaymentStatus status;
    try {
      status = await verify(reference);
    } on _ServerSaid catch (e) {
      // The payment belongs to another account (someone else signed in
      // on this phone since): it will never be this user's to check.
      if (e.status == 404) await forgetPending();
      rethrow;
    }
    if (status.state == PaymentState.pending) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        prefs.getInt(_pendingAtPref) ?? 0,
      );
      if (DateTime.now().difference(at) > _giveUpAfter) await forgetPending();
    }
    return status;
  }
}

/// A refusal from the server, with its status so the caller can tell
/// "not yours" from "try again later".
class _ServerSaid extends BillingException {
  final int status;
  const _ServerSaid(this.status, super.message);
}
