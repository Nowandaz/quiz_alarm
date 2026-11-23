/// What the app shows when someone taps a thing their plan does not open:
/// a small sheet that says what would open it, with one button to get
/// there (create an account, see the plans, or check the plan again).
library;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../screens/account_screen.dart';
import '../screens/upgrade_screen.dart';
import '../services/entitlements.dart';
import '../services/update_check.dart';
import 'app_widgets.dart';

/// Opens the sign in / create account screen. It closes by itself once
/// the person is signed in, and can be left with the back button.
Future<void> openSignIn(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
);

/// Shows the "this is locked" sheet.
///
/// [title] names the locked thing. [message] says what opens it for
/// someone with an account (e.g. "AI is part of Pro."); guests read the
/// same, or [guestMessage] when given, and are sent to create an account
/// first. With
/// [accountIsEnough] the thing only needs an account, so nobody is sent
/// to the plans.
Future<void> showLockedSheet(
  BuildContext context, {
  required String title,
  String message = 'This is part of Pro.',
  String? guestMessage,
  bool accountIsEnough = false,
}) {
  final plan = Entitlements.instance;
  final guest = plan.isGuest;
  // A paid plan that could not be confirmed: the plans are no help,
  // reaching the server is.
  final recheck = !guest && plan.needsCheck;
  final text = guest
      ? (guestMessage ?? message)
      : recheck
      ? plan.unlockHint
      : message;
  final label = guest || accountIsEnough
      ? 'Create account'
      : recheck
      ? 'Check now'
      : 'See plans';

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(text, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 18),
              PrimaryButton(
                label: label,
                onPressed: () async {
                  Navigator.pop(sheet);
                  if (guest || accountIsEnough) {
                    await openSignIn(context);
                  } else if (recheck) {
                    await checkPlanNow(context);
                  } else {
                    await showUpgrade(context);
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// What a locked AI feature says, everywhere.
const String aiIsPro = 'AI is part of Pro.';

/// Told to someone who taps a topic their plan does not open.
Future<void> showTopicLockedSheet(BuildContext context, Topic topic) {
  // A 'free' topic (and a topic of the user's own) only needs an account.
  final needsAccountOnly = topic.isCustom || topic.access == TopicAccess.free;
  return showLockedSheet(
    context,
    title: topic.name,
    message: 'This topic is part of Pro.',
    guestMessage: needsAccountOnly
        ? 'Create a free account to open this topic.'
        : null,
    accountIsEnough: needsAccountOnly,
  );
}

/// Told to a guest who tries to add an alarm with three already.
Future<void> showAlarmLimitSheet(BuildContext context) => showLockedSheet(
  context,
  title: 'Alarm limit reached',
  guestMessage:
      'Guests can set ${Entitlements.guestAlarmLimit} alarms. Create a free '
      'account for unlimited alarms.',
  accountIsEnough: true,
);

/// Asks the server about the plan and says so if it still cannot be
/// confirmed.
Future<void> checkPlanNow(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Entitlements.instance.refresh();
  if (!Entitlements.instance.needsCheck) return;
  messenger?.showSnackBar(
    const SnackBar(
      content: Text(
        'Still could not check your plan. Connect to the internet and '
        'try again.',
      ),
    ),
  );
}

/// The banner on the home screen in the last days of a paid plan
/// ([Entitlements.endsSoon]): when it ends, and a way to renew. Its close
/// button hides it until the next calendar day.
class PlanEndingBanner extends StatefulWidget {
  const PlanEndingBanner({super.key});

  /// Holds the day (yyyy-mm-dd) on which the banner was closed.
  static const String dismissedPref = 'plan_ending_dismissed';

  /// "Your Pro ends in 3 days." and the like, by calendar day.
  static String message(Entitlements plan) {
    final name = plan.planName;
    final end = plan.expires;
    final now = plan.time;
    if (end == null) return 'Your $name ends soon.';
    if (!now.isBefore(end)) return 'Your $name has ended.';
    final days = DateTime(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime(now.year, now.month, now.day)).inHours;
    // Rounded, so a day of 23 or 25 hours (clock change) counts as one.
    return switch ((days / 24).round()) {
      0 => 'Your $name ends today.',
      1 => 'Your $name ends tomorrow.',
      final n => 'Your $name ends in $n days.',
    };
  }

  @override
  State<PlanEndingBanner> createState() => _PlanEndingBannerState();
}

class _PlanEndingBannerState extends State<PlanEndingBanner> {
  // Hidden until it is known whether it was closed today.
  bool _hidden = true;

  static String _today() {
    final t = Entitlements.instance.time;
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var closed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      closed = prefs.getString(PlanEndingBanner.dismissedPref) == _today();
    } catch (_) {}
    if (mounted) setState(() => _hidden = closed);
  }

  Future<void> _close() async {
    setState(() => _hidden = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PlanEndingBanner.dismissedPref, _today());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 2, 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.event_rounded, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Follows the plan: the day count changes under it.
                ListenableBuilder(
                  listenable: Entitlements.instance,
                  builder: (context, _) => Text(
                    PlanEndingBanner.message(Entitlements.instance),
                    style: TextStyle(
                      color: ink,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
                Text(
                  'Plans do not renew by themselves.',
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.8),
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => showUpgrade(context),
            child: const Text('Renew'),
          ),
          IconButton(
            tooltip: 'Hide until tomorrow',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 20, color: ink),
            onPressed: _close,
          ),
        ],
      ),
    );
  }
}

/// The banner on the home screen while a paid plan cannot be confirmed.
/// It does not block anything: alarms keep working.
/// "A new version is out", with the way to get it. Shown on the home
/// screen while [UpdateCheck.available] has something.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<AppRelease?>(
      valueListenable: UpdateCheck.available,
      builder: (context, release, _) {
        if (release == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(
                Icons.system_update_rounded,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Version ${release.version} is out',
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      release.notes.isEmpty
                          ? 'Download it and install over this one. '
                                'Your alarms and progress stay.'
                          : release.notes,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        height: 1.3,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: UpdateCheck.dismiss,
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: UpdateCheck.open,
                child: const Text('Get it'),
              ),
              const SizedBox(width: 6),
            ],
          ),
        );
      },
    );
  }
}

class PlanCheckBanner extends StatefulWidget {
  const PlanCheckBanner({super.key});

  @override
  State<PlanCheckBanner> createState() => _PlanCheckBannerState();
}

class _PlanCheckBannerState extends State<PlanCheckBanner> {
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    await checkPlanNow(context);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your plan needs checking. Connect to the internet to unlock '
              'your Pro features.',
              style: TextStyle(color: scheme.onErrorContainer, height: 1.3),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _check,
            child: Text(_busy ? 'Checking...' : 'Check now'),
          ),
        ],
      ),
    );
  }
}
