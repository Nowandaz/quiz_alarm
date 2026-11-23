/// The plans screen: the plan the user is on, the tiers for sale (by the
/// month or the year), a discount code, and paying. M-Pesa is paid without
/// leaving the app: the phone gets a prompt and this screen keeps asking
/// the server until it went through. A card is paid on Paystack's own page,
/// shown inside the app. Someone without an account is asked to create
/// one first: a plan belongs to an account.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/account.dart';
import '../services/billing.dart';
import '../services/entitlements.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/lock_prompt.dart';
import 'card_pay_page.dart';

/// Opens the plans screen. Finishes when the user comes back from it.
Future<void> showUpgrade(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const UpgradeScreen()),
);

class UpgradeScreen extends StatefulWidget {
  const UpgradeScreen({super.key});

  /// Shows Paystack's card page and says whether it reached the end
  /// (true) or the user closed it (false). Tests replace it, because a
  /// web view cannot run there.
  @visibleForTesting
  static Future<bool> Function(
    BuildContext context,
    String url,
    String doneUrl,
  )?
  openCardPage;

  /// How often the server is asked about a payment being waited for, and
  /// for how long before the screen stops asking by itself.
  @visibleForTesting
  static Duration pollEvery = const Duration(seconds: 4);
  @visibleForTesting
  static Duration pollFor = const Duration(minutes: 2);

  @override
  State<UpgradeScreen> createState() => _UpgradeScreenState();
}

enum _Step { choosing, waiting, paid }

class _UpgradeScreenState extends State<UpgradeScreen>
    with WidgetsBindingObserver {
  PremiumOffer? _offer;
  String? _loadError;

  String _period = 'month';
  String? _tierId;
  String _method = '';
  final TextEditingController _phone = TextEditingController();

  /// The discount code: what is typed, the price it gave, or why not.
  final TextEditingController _code = TextEditingController();
  PriceQuote? _quote;

  /// The code as it was sent when [_quote] was asked for.
  String _applied = '';
  String? _codeError;
  bool _quoting = false;

  /// Goes up with every price asked for, so a slow answer for an earlier
  /// tier or period is thrown away.
  int _quoteRound = 0;

  _Step _step = _Step.choosing;
  bool _busy = false;

  /// The payment being waited for, what to tell the user meanwhile, and
  /// whether it is an M-Pesa prompt (or a card being confirmed).
  String? _reference;
  String _waitMessage = '';
  bool _waitingForMpesa = true;
  Timer? _poll;

  /// How many more times to ask before giving the user the choice.
  int _pollsLeft = 0;
  bool _timedOut = false;
  bool _checking = false;

  /// The latest thing to tell the user, and whether it is bad news.
  String? _note;
  bool _noteIsError = false;

  /// The plan as the server said after the payment.
  PaymentStatus? _paid;

  bool get _cardHere => UpgradeScreen.openCardPage != null || canShowCardPage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    Billing.lastPhone().then((phone) {
      if (mounted && _phone.text.isEmpty) _phone.text = phone;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Nobody is looking any more, so stop asking. The payment stays
    // remembered and the app checks it the next time it is opened.
    _poll?.cancel();
    Billing.watching = false;
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Back in the app: most likely the user has just approved the payment.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _Step.waiting) _check();
  }

  Future<void> _load() async {
    // Plans are read for an account; a guest is shown "create one" instead.
    if (!Account.instance.isSignedIn) return;
    setState(() => _loadError = null);
    try {
      final offer = await Billing.plans();
      // What the server just said is the plan: the rest of the app
      // follows at once.
      unawaited(
        Entitlements.instance.apply(
          premium: offer.premium,
          tier: offer.tier,
          tierName: offer.tierName,
          expires: offer.expires,
        ),
      );
      if (!mounted) return;
      setState(() {
        _offer = offer;
        final ids = [for (final t in offer.tiers) t.id];
        if (!ids.contains(_tierId)) {
          // Start on the plan the user already has, else the first one.
          _tierId = ids.contains(offer.tier)
              ? offer.tier
              : ids.isEmpty
              ? null
              : ids.first;
        }
        // Monthly first, unless nothing is sold by the month.
        _period = offer.tiers.any((t) => t.option('month') != null)
            ? 'month'
            : 'year';
        if (!offer.methods.contains(_method)) {
          _method = offer.methods.isEmpty ? '' : offer.methods.first;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  void _say(String? text, {bool error = false}) {
    _note = text;
    _noteIsError = error;
  }

  void _setStep(_Step step) {
    _step = step;
    Billing.watching = step == _Step.waiting;
    if (step != _Step.waiting) {
      _poll?.cancel();
      _poll = null;
    }
  }

  // ---- What is chosen -------------------------------------------------

  PremiumTier get _tier => _offer!.tiers.firstWhere(
    (t) => t.id == _tierId,
    orElse: () => _offer!.tiers.first,
  );

  /// How [tier] is sold for the chosen period. A tier that is not sold
  /// that way shows the way it is sold.
  PlanOption _optionOf(PremiumTier tier) =>
      tier.option(_period) ?? tier.options.first;

  /// The code's price, when a working code is applied.
  PriceQuote? get _discount => _quote;

  num get _total => _discount?.price ?? _optionOf(_tier).price;

  void _choose({String? tier, String? period}) {
    if (_busy) return;
    setState(() {
      _tierId = tier ?? _tierId;
      _period = period ?? _period;
      _say(null);
    });
    // The code may be worth something else here, or nothing.
    if (_discount != null) _applyCode(code: _applied);
  }

  /// Asks the server what [code] (or the typed one) does to the price.
  /// True when it works.
  Future<bool> _applyCode({String? code}) async {
    final wanted = Billing.tidyCode(code ?? _code.text);
    if (wanted.isEmpty) {
      setState(_dropCode);
      return false;
    }
    final round = ++_quoteRound;
    setState(() {
      _quoting = true;
      _codeError = null;
    });
    try {
      final tier = _tier;
      final quote = await Billing.quote(
        tier.id,
        _optionOf(tier).period,
        wanted,
      );
      if (!mounted || round != _quoteRound) return false;
      setState(() {
        _quoting = false;
        _quote = quote.applied ? quote : null;
        _applied = quote.applied ? wanted : '';
        _codeError = quote.applied
            ? null
            : quote.codeMessage.isEmpty
            ? 'That code is not valid.'
            : quote.codeMessage;
      });
      return quote.applied;
    } catch (e) {
      if (!mounted || round != _quoteRound) return false;
      setState(() {
        _dropCode();
        _codeError = e.toString();
      });
      return false;
    }
  }

  /// Back to the full price. An answer still on its way is ignored.
  void _dropCode() {
    _quoteRound++;
    _quote = null;
    _applied = '';
    _codeError = null;
    _quoting = false;
  }

  // ---- Paying ---------------------------------------------------------

  Future<void> _pay() async {
    if (_busy || _quoting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final offer = _offer!;
    final tier = _tier;
    final option = _optionOf(tier);

    // A code that was typed but not applied: price it first, so the user
    // sees what they will pay before anything is charged.
    final typed = Billing.tidyCode(_code.text);
    if (typed != _applied) {
      await _applyCode();
      return;
    }

    final free = _total <= 0;
    // Nothing to pay needs no phone, so it goes the way that asks for none.
    final method = free && offer.methods.contains('card') ? 'card' : _method;
    final phone = _phone.text.trim();
    if (!free && method == 'mpesa' && phone.isEmpty) {
      setState(
        () => _say(
          'Enter your M-Pesa number, for example 0712 345 678.',
          error: true,
        ),
      );
      return;
    }
    if (!free && method == 'card' && !_cardHere) {
      setState(
        () => _say(
          'Card payment is only available in the phone app.',
          error: true,
        ),
      );
      return;
    }

    setState(() {
      _busy = true;
      _say(null);
    });
    try {
      final payment = await Billing.start(
        tier: tier.id,
        period: option.period,
        code: _applied,
        method: method,
        phone: phone,
      );
      if (!mounted) return;
      if (payment.paid != null) {
        setState(() => _showPaid(payment.paid!));
      } else if (method == 'mpesa') {
        setState(() {
          _busy = false;
          _startWaiting(
            payment.reference,
            payment.message.isEmpty
                ? 'Check your phone and enter your M-Pesa PIN.'
                : payment.message,
            mpesa: true,
          );
        });
      } else {
        await _payByCard(payment);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _say(e.toString(), error: true);
      });
    }
  }

  /// Shows Paystack's page, then asks the server how it ended.
  Future<void> _payByCard(PaymentStart payment) async {
    // The home screen also checks payments when the app comes back to the
    // front; this screen is doing it, so it must not.
    Billing.watching = true;
    final finished = await (UpgradeScreen.openCardPage ?? showCardPage)(
      context,
      payment.url,
      payment.doneUrl,
    );
    if (!mounted) return;
    PaymentStatus? status;
    try {
      status = await Billing.verify(payment.reference);
    } catch (e) {
      debugPrint('Could not check the card payment: $e');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      Billing.watching = false;
      if (status?.paid == true) {
        _showPaid(status!);
      } else if (status?.state == PaymentState.failed) {
        _say(_failedText, error: true);
      } else if (finished) {
        // Paid on the page, but the money has not been confirmed yet.
        _startWaiting(
          payment.reference,
          'Confirming your payment. This takes a moment.',
          mpesa: false,
        );
      } else {
        _say(
          'The card payment was not finished. If you did pay, your plan '
          'will change shortly.',
        );
      }
    });
  }

  static const String _failedText =
      'That payment did not go through. Nothing was charged. Try again.';

  void _showPaid(PaymentStatus status) {
    _busy = false;
    _paid = status;
    _reference = null;
    // Unlocks the paid features straight away, without a restart.
    unawaited(
      Entitlements.instance.apply(
        premium: status.premium,
        tier: status.tier,
        tierName: status.tierName,
        expires: status.expires,
      ),
    );
    // The plan line at the top follows the new plan.
    _offer = Billing.last ?? _offer;
    _say(null);
    _setStep(_Step.paid);
  }

  void _startWaiting(String reference, String message, {required bool mpesa}) {
    _reference = reference;
    _waitMessage = message;
    _waitingForMpesa = mpesa;
    _say(null);
    _setStep(_Step.waiting);
    _startPolling();
  }

  /// Asks the server every few seconds, for a couple of minutes.
  void _startPolling() {
    _timedOut = false;
    _pollsLeft =
        UpgradeScreen.pollFor.inMilliseconds ~/
        UpgradeScreen.pollEvery.inMilliseconds;
    _poll?.cancel();
    _poll = Timer.periodic(UpgradeScreen.pollEvery, (_) {
      _pollsLeft--;
      _check();
    });
  }

  /// One question to the server about the payment being waited for.
  /// [asked] is true when the user tapped "Check again": only then is a
  /// problem reaching the server worth showing.
  Future<void> _check({bool asked = false}) async {
    final reference = _reference;
    if (reference == null || _checking || !mounted) return;
    _checking = true;
    if (asked) setState(() => _say(null));
    PaymentStatus? status;
    String? problem;
    try {
      status = await Billing.verify(reference);
    } catch (e) {
      problem = e.toString();
    }
    _checking = false;
    // Cancelled, or the screen was left, while the server was answering.
    if (!mounted || _reference != reference) return;
    setState(() {
      if (status?.paid == true) {
        _showPaid(status!);
      } else if (status?.state == PaymentState.failed) {
        _reference = null;
        _setStep(_Step.choosing);
        _say(_failedText, error: true);
      } else if (asked) {
        if (problem != null) {
          _say(problem, error: true);
        } else {
          // Still on its way: keep watching for a while longer.
          _startPolling();
        }
      } else if (!_timedOut && _pollsLeft <= 0) {
        _timedOut = true;
        _poll?.cancel();
        _poll = null;
      }
    });
  }

  /// Stops waiting. The payment stays remembered: if the user did pay,
  /// the app notices the next time it is opened.
  void _cancel() => setState(() {
    _reference = null;
    _setStep(_Step.choosing);
    _say(null);
  });

  // ---- What is shown --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return Scaffold(
      appBar: AppBar(title: const Text('Plans')),
      body: AppBackground(
        child: SafeArea(
          child: !Account.instance.isSignedIn
              ? _AccountFirst(
                  onSignIn: () async {
                    await openSignIn(context);
                    if (mounted) _load();
                  },
                )
              : offer == null
              ? _loadError == null
                    ? const Center(child: CircularProgressIndicator())
                    : _LoadFailed(message: _loadError!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _header(context, offer),
                    const SizedBox(height: 16),
                    ...switch (_step) {
                      _Step.choosing => _choosing(context, offer),
                      _Step.waiting => _waiting(context),
                      _Step.paid => _thanks(context),
                    },
                  ],
                ),
        ),
      ),
    );
  }

  /// The plan the user is on.
  Widget _header(BuildContext context, PremiumOffer offer) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlossCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pill(
            offer.planLabel,
            icon: offer.premium
                ? Icons.workspace_premium_rounded
                : Icons.person_outline_rounded,
            color: offer.premium ? scheme.primary : null,
          ),
          const SizedBox(height: 12),
          Text(
            'Brain O\' Clock plans',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: AppTheme.display,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'You pay once. Nothing renews by itself.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.62),
            ),
          ),
          // A paid plan the phone could not confirm for a while.
          if (Entitlements.instance.needsCheck) ...[
            const SizedBox(height: 8),
            Text(
              Entitlements.instance.unlockHint,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _choosing(BuildContext context, PremiumOffer offer) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.62);
    final note = _note == null
        ? const <Widget>[]
        : [_Note(_note!, error: _noteIsError), const SizedBox(height: 14)];

    if (!offer.enabled || offer.tiers.isEmpty || offer.methods.isEmpty) {
      return [
        ...note,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            offer.premium
                ? 'More time is not on sale right now.'
                : 'Plans are not on sale yet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
        ),
      ];
    }

    final tier = _tier;
    final discount = _discount;
    final free = _total <= 0;
    final money = Billing.money(_total, offer.currency);
    final heading = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w700,
    );
    // The switch is only worth showing when it changes something.
    final bothWays = offer.tiers.any((t) => t.options.length > 1);

    return [
      if (bothWays) ...[
        _Segments(
          items: const [('month', 'Monthly', null), ('year', 'Yearly', null)],
          selected: _period,
          onChanged: _busy ? null : (period) => _choose(period: period),
        ),
        const SizedBox(height: 12),
      ],
      for (final t in offer.tiers)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _TierCard(
            tier: t,
            option: _optionOf(t),
            currency: offer.currency,
            // Buying the plan you are on adds its days on top.
            yours: offer.premium && offer.tier == t.id,
            selected: t.id == tier.id,
            onTap: _busy ? null : () => _choose(tier: t.id),
          ),
        ),
      const SizedBox(height: 8),
      Text('Have a code?', style: heading),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _code,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              // Codes are the same in either case; capitals read best.
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, next) => next.copyWith(text: next.text.toUpperCase()),
                ),
              ],
              onChanged: (text) {
                // The price shown must match the code in the box.
                if (_quote == null && _codeError == null && !_quoting) return;
                if (_quote != null && Billing.tidyCode(text) == _applied) {
                  return;
                }
                setState(_dropCode);
              },
              onSubmitted: (_) => _applyCode(),
              decoration: const InputDecoration(
                hintText: 'Discount code',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: _busy || _quoting ? null : _applyCode,
            child: Text(_quoting ? 'Checking...' : 'Apply'),
          ),
        ],
      ),
      if (_codeError != null) ...[
        const SizedBox(height: 8),
        Text(_codeError!, style: TextStyle(color: scheme.error, height: 1.35)),
      ],
      if (discount != null) ...[
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${discount.code.toUpperCase()} applied: ${discount.percentOff}% off',
                style: const TextStyle(
                  color: AppColors.success,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text('${tier.name} now costs', style: TextStyle(color: muted)),
            Text(
              Billing.money(discount.fullPrice, offer.currency),
              style: TextStyle(
                color: muted,
                decoration: TextDecoration.lineThrough,
              ),
            ),
            Text(
              money,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 20),
      // Nothing to pay means no way of paying to choose.
      if (!free) ...[
        Text('Pay with', style: heading),
        const SizedBox(height: 8),
        _Segments(
          items: [
            for (final m in offer.methods)
              m == 'mpesa'
                  ? (m, 'M-Pesa', Icons.phone_android_rounded)
                  : (m, 'Card', Icons.credit_card_rounded),
          ],
          selected: _method,
          onChanged: _busy
              ? null
              : (method) => setState(() {
                  _method = method;
                  _say(null);
                }),
        ),
        if (_method == 'mpesa') ...[
          const SizedBox(height: 10),
          TextField(
            controller: _phone,
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
              LengthLimitingTextInputFormatter(16),
            ],
            decoration: const InputDecoration(
              labelText: 'M-Pesa number',
              hintText: '0712 345 678',
              prefixIcon: Icon(Icons.phone_android_rounded),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
      ...note,
      PrimaryButton(
        onPressed: _busy || _quoting ? null : _pay,
        label: _busy
            ? 'One moment...'
            : free
            ? 'Get ${tier.name} free'
            : _method == 'mpesa'
            ? 'Pay $money with M-Pesa'
            : 'Pay $money by card',
      ),
      const SizedBox(height: 12),
      Text(
        free
            ? 'Your code covers the whole price. There is nothing to pay.'
            : _method == 'mpesa'
            ? 'A payment request comes to your phone. You approve it with '
                  'your M-Pesa PIN.'
            : 'Your card details go straight to Paystack. Brain O\' Clock never '
                  'sees them.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: muted),
      ),
    ];
  }

  List<Widget> _waiting(BuildContext context) {
    final theme = Theme.of(context);
    return [
      GlossCard(
        child: Column(
          children: [
            if (_timedOut)
              Icon(
                Icons.hourglass_bottom_rounded,
                size: 36,
                color: theme.colorScheme.primary,
              )
            else
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3.5),
              ),
            const SizedBox(height: 16),
            Text(
              !_timedOut
                  ? _waitMessage
                  : _waitingForMpesa
                  ? 'Still waiting for M-Pesa. If you approved it, tap Check '
                        'again.'
                  : 'Still waiting for the payment. If you paid, tap Check '
                        'again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!_timedOut) ...[
              const SizedBox(height: 8),
              Text(
                'Keep this screen open. It changes by itself when the '
                'payment arrives.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                ),
              ),
            ],
            if (_note != null) ...[
              const SizedBox(height: 14),
              _Note(_note!, error: _noteIsError),
            ],
            const SizedBox(height: 18),
            if (_timedOut)
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  onPressed: _checking ? null : () => _check(asked: true),
                  label: _checking ? 'Checking...' : 'Check again',
                ),
              ),
            TextButton(onPressed: _cancel, child: const Text('Cancel')),
          ],
        ),
      ),
    ];
  }

  List<Widget> _thanks(BuildContext context) {
    final theme = Theme.of(context);
    final paid = _paid!;
    final name = paid.tierName.isEmpty ? 'Premium' : paid.tierName;
    return [
      GlossCard(
        child: Column(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 44,
              color: AppColors.success,
            ),
            const SizedBox(height: 12),
            Text(
              paid.expires == null
                  ? 'You are on $name.'
                  : 'You are on $name until ${Billing.day(paid.expires!)}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Thank you. Anything new in your plan is downloading now.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                onPressed: () => Navigator.pop(context),
                label: 'Done',
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

/// A row of choices where one is on: "Monthly / Yearly", "M-Pesa / Card".
class _Segments extends StatelessWidget {
  final List<(String id, String label, IconData? icon)> items;
  final String selected;
  final ValueChanged<String>? onChanged;
  const _Segments({
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          for (final (id, label, icon) in items)
            Expanded(
              child: Semantics(
                button: true,
                selected: id == selected,
                child: Material(
                  color: id == selected
                      ? scheme.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onChanged == null ? null : () => onChanged!(id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 11,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (icon != null) ...[
                            Icon(
                              icon,
                              size: 18,
                              color: id == selected
                                  ? scheme.primary
                                  : scheme.onSurface.withValues(alpha: 0.62),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: id == selected
                                    ? scheme.primary
                                    : scheme.onSurface.withValues(alpha: 0.62),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tier the user can pick: its name, what it gives and its price.
class _TierCard extends StatelessWidget {
  final PremiumTier tier;
  final PlanOption option;
  final String currency;
  final bool yours;
  final bool selected;
  final VoidCallback? onTap;
  const _TierCard({
    required this.tier,
    required this.option,
    required this.currency,
    required this.yours,
    required this.selected,
    required this.onTap,
  });

  /// What the year saves against twelve separate months, as
  /// "Save KES 1,100". Null when it saves nothing or cannot be compared.
  String? get _saving {
    final month = tier.option('month');
    if (option.period != 'year' || month == null) return null;
    final saved = month.price * 12 - option.price;
    return saved > 0 ? 'Save ${Billing.money(saved, currency)}' : null;
  }

  /// The feature lines, with the daily AI allowance added when none of
  /// them already gives the number.
  List<String> get _lines {
    final limit = tier.aiDailyLimit;
    final said = RegExp('(^|[^0-9])$limit([^0-9]|\$)');
    return [
      ...tier.features,
      if (limit > 0 && !tier.features.any(said.hasMatch))
        '$limit AI requests a day',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.62);
    final saving = _saving;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: scheme.onSurface.withValues(alpha: selected ? 0.07 : 0.03),
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                width: 2,
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.10),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            tier.name,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: AppTheme.display,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (yours) Pill('Your plan', color: scheme.primary),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ],
                ),
                if (tier.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    tier.description,
                    style: TextStyle(color: muted, height: 1.35),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: Billing.money(option.price, currency),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: AppTheme.display,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text: ' / ${option.period}',
                            style: TextStyle(color: muted),
                          ),
                        ],
                      ),
                    ),
                    if (saving != null) Pill(saving, color: AppColors.success),
                    if (yours && option.days > 0)
                      Pill('Adds ${plural(option.days, 'day')}'),
                  ],
                ),
                const SizedBox(height: 10),
                for (final line in _lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.check_rounded,
                            size: 17,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            line,
                            style: const TextStyle(height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A message in a tinted box: red for a problem, plain otherwise.
class _Note extends StatelessWidget {
  final String text;
  final bool error;
  const _Note(this.text, {required this.error});

  @override
  Widget build(BuildContext context) {
    final color = error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: error ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: TextStyle(color: color, height: 1.35)),
    );
  }
}

/// Shown to someone without an account: a plan needs one.
class _AccountFirst extends StatelessWidget {
  final VoidCallback onSignIn;
  const _AccountFirst({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_add_alt_1_rounded,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Create an account first',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'A plan belongs to your account, so it follows you to a new '
              'phone. Creating one is free.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            PrimaryButton(label: 'Create account', onPressed: onSignIn),
          ],
        ),
      ),
    );
  }
}

/// The plans could not be read: say why and offer another go.
class _LoadFailed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _LoadFailed({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
