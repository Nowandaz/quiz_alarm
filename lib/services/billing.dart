/// Buying premium. The server decides what is for sale and at what price,
/// and opens a payment page (Paystack: card or M-Pesa) in the browser.
/// This file asks for the plans, starts a payment and asks whether it went
/// through. What is sold is premium time paid once: nothing renews, and
/// paying again adds days.
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

/// One thing that can be bought: so many days of premium for a price.
class PremiumPlan {
  final String id; // "month" or "year"
  final int days;
  final num price;
  final String currency;
  const PremiumPlan({
    required this.id,
    required this.days,
    required this.price,
    required this.currency,
  });

  /// "KES 300".
  String get priceLabel => Billing.money(price, currency);
}

/// What is for sale right now, and the plan the user is on.
class PremiumOffer {
  /// False while the owner has not switched buying on.
  final bool enabled;
  final List<PremiumPlan> plans;
  final bool premium;

  /// When premium ends. Null on the free plan, or for premium with no end.
  final DateTime? expires;
  const PremiumOffer({
    required this.enabled,
    required this.plans,
    required this.premium,
    this.expires,
  });

  /// "Free plan", "Premium until 21 Dec 2026" or just "Premium".
  String get planLabel => !premium
      ? 'Free plan'
      : expires == null
      ? 'Premium'
      : 'Premium until ${Billing.day(expires!)}';
}

/// A payment the server has opened: where to pay, and its name.
class PaymentStart {
  final String reference;
  final String url;
  const PaymentStart({required this.reference, required this.url});
}

enum PaymentState { pending, paid, failed }

/// The server's answer to "did this payment go through?".
class PaymentStatus {
  final PaymentState state;
  final bool premium;
  final DateTime? expires;
  const PaymentStatus({
    required this.state,
    required this.premium,
    this.expires,
  });
  bool get paid => state == PaymentState.paid;
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

  static const String signInHint = 'Sign in to buy premium.';

  /// Where the name of a started payment is kept, so it can still be
  /// checked if the app was closed while the user was paying.
  static const String pendingPref = 'pending_payment';
  static const String _pendingAtPref = 'pending_payment_at';

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

  /// What can be bought, and the plan the user is on now.
  static Future<PremiumOffer> plans() async {
    final user = Account.instance.userId;
    final data = await _call('GET', '/v1/pay/plans');
    final offer = PremiumOffer(
      enabled: data['enabled'] == true,
      plans: [
        for (final p in data['plans'] is List ? data['plans'] as List : [])
          if (p is Map && p['id'] is String && p['price'] is num)
            PremiumPlan(
              id: p['id'] as String,
              days: (p['days'] as num?)?.toInt() ?? 0,
              price: p['price'] as num,
              currency: '${p['currency'] ?? ''}',
            ),
      ],
      premium: data['premium'] == true,
      expires: _date(data['expires']),
    );
    _last = offer;
    _lastUser = user;
    return offer;
  }

  /// Opens a payment for [planId] on the server and remembers its name.
  /// The caller then shows [PaymentStart.url] in the browser.
  static Future<PaymentStart> start(String planId) async {
    final data = await _call('POST', '/v1/pay/start', body: {'plan': planId});
    final reference = data['reference'];
    final url = data['url'];
    if (reference is! String || url is! String || url.isEmpty) {
      throw const BillingException('The server sent an unreadable reply.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pendingPref, reference);
    await prefs.setInt(_pendingAtPref, DateTime.now().millisecondsSinceEpoch);
    return PaymentStart(reference: reference, url: url);
  }

  /// Asks whether the payment [reference] went through. Once it is paid or
  /// has failed it is no longer remembered as waiting.
  static Future<PaymentStatus> verify(String reference) async {
    final data = await _call(
      'GET',
      '/v1/pay/verify?reference=${Uri.encodeQueryComponent(reference)}',
    );
    final status = PaymentStatus(
      state: switch (data['status']) {
        'paid' => PaymentState.paid,
        'failed' => PaymentState.failed,
        _ => PaymentState.pending,
      },
      premium: data['premium'] == true,
      expires: _date(data['expires']),
    );
    if (status.state == PaymentState.pending) return status;

    final prefs = await SharedPreferences.getInstance();
    // Only the first answer for a payment acts on it, so two checks that
    // overlap do not announce the same payment twice.
    final first = prefs.getString(pendingPref) == reference;
    if (first) await forgetPending();
    if (status.paid && first) {
      final known = last;
      if (known != null) {
        _last = PremiumOffer(
          enabled: known.enabled,
          plans: known.plans,
          premium: status.premium,
          expires: status.expires,
        );
      }
      // Not waited for: downloading the bank can take a while and the
      // user should see "paid" straight away.
      final paid = onPaid;
      if (paid != null) unawaited(paid().catchError((Object _) {}));
      changes.value++;
    }
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
