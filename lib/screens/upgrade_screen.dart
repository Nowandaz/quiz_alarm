/// The premium screen: the plan the user is on, what premium adds, the
/// plans for sale, and paying. Paying happens on Paystack's page in the
/// phone's browser; this screen waits for the user to come back and then
/// asks the server whether the payment went through.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../services/billing.dart';
import '../services/system_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

/// Opens the premium screen. Finishes when the user comes back from it.
Future<void> showUpgrade(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const UpgradeScreen()),
);

class UpgradeScreen extends StatefulWidget {
  const UpgradeScreen({super.key});

  /// Tests replace opening the browser with this.
  @visibleForTesting
  static Future<bool> Function(String url)? openUrl;

  @override
  State<UpgradeScreen> createState() => _UpgradeScreenState();
}

enum _Step { choosing, waiting, paid }

class _UpgradeScreenState extends State<UpgradeScreen>
    with WidgetsBindingObserver {
  PremiumOffer? _offer;
  String? _loadError;

  String? _selected; // plan id
  _Step _step = _Step.choosing;
  bool _busy = false;

  /// The payment being waited for.
  String? _reference;

  /// The latest thing to tell the user, and whether it is bad news.
  String? _note;
  bool _noteIsError = false;

  /// When premium ends, as the server said after the payment.
  PaymentStatus? _paid;

  bool get _canPayHere =>
      UpgradeScreen.openUrl != null ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Billing.watching = false;
    super.dispose();
  }

  /// Back from the browser: most likely the user has just paid.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _Step.waiting) _check();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final offer = await Billing.plans();
      if (!mounted) return;
      setState(() {
        _offer = offer;
        final ids = [for (final p in offer.plans) p.id];
        if (!ids.contains(_selected)) {
          _selected = ids.isEmpty ? null : ids.first;
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
  }

  Future<void> _pay(PremiumPlan plan) async {
    if (_busy) return;
    if (!_canPayHere) {
      setState(
        () => _say(
          'Paying is only available in the Android app for now.',
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
      final payment = await Billing.start(plan.id);
      final opened = await (UpgradeScreen.openUrl ?? SystemBridge.openUrl)(
        payment.url,
      );
      if (!opened) {
        // Nobody saw the payment page, so there is nothing to wait for.
        await Billing.forgetPending();
        throw const BillingException(
          'Could not open the payment page. Try again.',
        );
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _reference = payment.reference;
        _setStep(_Step.waiting);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _say(e.toString(), error: true);
      });
    }
  }

  Future<void> _check() async {
    final reference = _reference;
    if (reference == null || _busy) return;
    setState(() {
      _busy = true;
      _say(null);
    });
    try {
      final status = await Billing.verify(reference);
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (status.state) {
          case PaymentState.paid:
            _paid = status;
            // The plan line at the top follows the new plan.
            _offer = Billing.last ?? _offer;
            _setStep(_Step.paid);
          case PaymentState.failed:
            _reference = null;
            _setStep(_Step.choosing);
            _say(
              'That payment did not go through. You have not been charged '
              'twice; try again.',
              error: true,
            );
          case PaymentState.pending:
            _say(
              'Not confirmed yet. If you paid, it can take a minute. Try '
              'again shortly.',
            );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _say(e.toString(), error: true);
      });
    }
  }

  /// Stops waiting. The payment stays remembered: if the user did pay,
  /// the app notices the next time it is opened.
  void _cancel() => setState(() {
    _reference = null;
    _setStep(_Step.choosing);
    _say(null);
  });

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: AppBackground(
        child: SafeArea(
          child: offer == null
              ? _loadError == null
                    ? const Center(child: CircularProgressIndicator())
                    : _LoadFailed(message: _loadError!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _hero(context, offer),
                    const SizedBox(height: 20),
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

  /// The plan the user is on, and what premium adds.
  Widget _hero(BuildContext context, PremiumOffer offer) {
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
          const SizedBox(height: 14),
          Text(
            'BrainWake Premium',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: AppTheme.display,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          const _Benefit(
            Icons.library_books_rounded,
            'Every unit in the question bank, including the premium ones.',
          ),
          const _Benefit(
            Icons.auto_awesome,
            'A much higher daily AI allowance, for new questions and the '
            'tutor.',
          ),
          const _Benefit(
            Icons.favorite_rounded,
            'Supports new questions being added.',
          ),
        ],
      ),
    );
  }

  List<Widget> _choosing(BuildContext context, PremiumOffer offer) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.62);
    final note = _note == null
        ? const <Widget>[]
        : [_Note(_note!, error: _noteIsError), const SizedBox(height: 14)];

    if (!offer.enabled || offer.plans.isEmpty) {
      return [
        ...note,
        Text(
          offer.premium
              ? 'More premium time is not on sale right now.'
              : 'Premium is not on sale yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: muted),
        ),
      ];
    }

    final plan = offer.plans.firstWhere(
      (p) => p.id == _selected,
      orElse: () => offer.plans.first,
    );
    return [
      Text(
        offer.premium ? 'Add more time' : 'Choose a plan',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      for (final p in offer.plans)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _PlanCard(
            plan: p,
            saving: _saving(offer, p),
            // Someone already on premium is buying extra time on top.
            adding: offer.premium,
            selected: p.id == plan.id,
            onTap: _busy ? null : () => setState(() => _selected = p.id),
          ),
        ),
      const SizedBox(height: 6),
      ...note,
      PrimaryButton(
        onPressed: _busy ? null : () => _pay(plan),
        label: _busy ? 'Opening the payment page...' : 'Pay ${plan.priceLabel}',
      ),
      const SizedBox(height: 12),
      Text(
        "You pay on Paystack's secure page with a card or M-Pesa. Nothing "
        'renews by itself.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: muted),
      ),
    ];
  }

  /// What the year plan saves against twelve separate months, as
  /// "Save KES 1,100". Null when it saves nothing or cannot be compared.
  String? _saving(PremiumOffer offer, PremiumPlan plan) {
    if (plan.id != 'year') return null;
    for (final month in offer.plans) {
      if (month.id != 'month' || month.currency != plan.currency) continue;
      final saved = month.price * 12 - plan.price;
      if (saved > 0) return 'Save ${Billing.money(saved, plan.currency)}';
    }
    return null;
  }

  List<Widget> _waiting(BuildContext context) {
    final theme = Theme.of(context);
    return [
      GlossCard(
        child: Column(
          children: [
            Icon(
              Icons.open_in_browser_rounded,
              size: 36,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Finish paying in your browser, then come back here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_note != null) ...[
              const SizedBox(height: 14),
              _Note(_note!, error: _noteIsError),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                onPressed: _busy ? null : _check,
                label: _busy ? 'Checking...' : 'I have paid, check now',
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _thanks(BuildContext context) {
    final theme = Theme.of(context);
    final expires = _paid?.expires;
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
              expires == null
                  ? 'You are on premium.'
                  : 'You are on premium until ${Billing.day(expires)}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Thank you. The premium units are downloading now.',
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

/// One line of "what premium gives".
class _Benefit extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Benefit(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ],
      ),
    );
  }
}

/// A plan the user can pick: what it is, its price, and the saving.
class _PlanCard extends StatelessWidget {
  final PremiumPlan plan;
  final String? saving;
  final bool adding;
  final bool selected;
  final VoidCallback? onTap;
  const _PlanCard({
    required this.plan,
    required this.saving,
    required this.adding,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
            padding: const EdgeInsets.fromLTRB(16, 16, 18, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                width: 2,
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.10),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        adding
                            ? 'Add ${plan.days} more days'
                            : '${plan.days} days of premium',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (saving != null) ...[
                        const SizedBox(height: 6),
                        Pill(saving!, color: AppColors.success),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  plan.priceLabel,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFamily: AppTheme.display,
                    fontWeight: FontWeight.w700,
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
