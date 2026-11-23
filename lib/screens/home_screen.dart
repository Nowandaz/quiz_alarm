/// The app shell: header, the three tabs (Alarms, Banks, Reports) in a
/// floating navigation bar that hides while scrolling down, and the hook
/// that opens the quiz when an alarm rings.
library;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/alarm_provider.dart';
import '../services/billing.dart';
import '../services/announcements.dart';
import '../services/entitlements.dart';
import '../services/update_check.dart';
import '../services/guest_mode.dart';
import '../widgets/lock_prompt.dart';
import '../services/system_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../services/account.dart';
import 'account_screen.dart';
import 'alarm_feedback.dart';
import '../widgets/coach_tour.dart';
import 'alarm_ring_screen.dart';
import 'messages_screen.dart';
import 'settings_screen.dart';
import 'tabs/alarm_tab.dart';
import 'tabs/question_bank_tab.dart';
import 'tabs/reports_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// The app opens on the welcome (sign-in) screen until the person signs
  /// in or chooses to go on without an account. The browser emulator can
  /// switch this off (open it with ?guest) to skip that screen.
  static bool requireAccount = true;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  // The bottom bar slides away while scrolling down a page and comes back
  // when scrolling up.
  bool _navHidden = false;
  final List<Widget> _tabs = const [
    AlarmTab(),
    QuestionBankTab(),
    ReportsTab(),
  ];
  static const List<String> _titles = [
    'Brain O\' Clock',
    'Question banks',
    'Reports',
  ];

  @override
  void initState() {
    super.initState();

    // Signing out brings the welcome screen back.
    Account.instance.addListener(_onAccount);

    // A payment started before the app was closed may have gone through.
    WidgetsBinding.instance.addObserver(this);
    _checkPayment();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<AlarmProvider>(context, listen: false);

      // What Android hands over: the link the browser returns after Google
      // sign-in, and "Skip" tapped on the heads-up notification.
      SystemBridge.listen(
        onAuthLink: (link) async {
          Account.instance.oauthError.value = await Account.instance
              .completeOAuth(Uri.parse(link));
        },
        onSkipAlarm: (id, ringAt) async {
          final done = await provider.skipNext(id, ringAt: ringAt);
          if (!mounted || done == null) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(done)));
        },
      );
      provider.addListener(_askAboutMissed);
      _askAboutMissed();
      // The app may have been opened by a ringing alarm: only then may it
      // show over the lock screen. Known once the alarms have been read.
      provider.loaded.then((_) {
        if (mounted) SystemBridge.setAlarmScreen(provider.isAlarmRinging);
      });
      // Already signed in: an old "without an account" choice is over.
      if (Account.instance.isSignedIn) GuestMode.clear();
      _welcome(simulated: provider.backend.isSimulated);

      provider.onAlarmTriggered = (alarm) async {
        if (!mounted) {
          provider.ringScreenClosed();
          return;
        }
        // If the app is in the background, come to the screen so the quiz
        // shows without the notification having to be tapped.
        if (!provider.backend.isSimulated &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          SystemBridge.bringToFront();
        }
        final result = await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AlarmRingScreen(alarm: alarm)),
        );
        if (result == 'snooze' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Snoozed for ${alarm.snoozeMinutes} minutes.'),
            ),
          );
        } else if (result == 'snooze_failed' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 8),
              content: Text(
                'The snooze could not be set, so this alarm will NOT ring '
                'again. Set another alarm if you still need one.',
              ),
            ),
          );
        }
        provider.ringScreenClosed();
        // A sign-in screen that was held back while the alarm rang.
        _requireAccount();
      };
    });
  }

  bool _gateOpen = false;

  bool _askingMissed = false;

  /// A ring that seems never to have happened: ask the user about it.
  Future<void> _askAboutMissed() async {
    if (!mounted || _askingMissed || _gateOpen) return;
    final provider = Provider.of<AlarmProvider>(context, listen: false);
    if (provider.isAlarmRinging) return;
    if (provider.timedOut.isNotEmpty) {
      // It rang but was not answered: find out why (clears the record).
      _askingMissed = true;
      await showTimedOutPrompt(context, provider.timedOut.first);
      _askingMissed = false;
      _askAboutMissed(); // the next one, if any
      return;
    }
    if (provider.missed.isEmpty) return;
    _askingMissed = true;
    final ring = provider.missed.first;
    await showAlarmFeedback(context, missed: ring);
    _askingMissed = false;
    provider.missedHandled(ring); // notifies, which asks about the next one
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _checkPayment();
    // The plan may have changed, or run out, while the app was away.
    Entitlements.instance.refresh();
    // Coming back to the app is also a moment to look for an update.
    UpdateCheck.run();
    Announcements.run();
    if (!Provider.of<AlarmProvider>(context, listen: false).isAlarmRinging) {
      SystemBridge.setAlarmScreen(false);
    }
  }

  /// Signed in: the "without an account" choice is over. Signed out: the
  /// welcome screen comes back (and offers that choice again).
  Future<void> _onAccount() async {
    if (Account.instance.isSignedIn) {
      await GuestMode.clear();
    } else {
      await _requireAccount();
    }
  }

  /// Asks about a payment that was started and not yet seen to finish.
  /// Runs in the background and says something only when it was paid:
  /// no internet or a slow server must never get in the way of an alarm.
  Future<void> _checkPayment() async {
    if (!Account.instance.isSignedIn) return;
    try {
      final status = await Billing.checkPending();
      if (!mounted || status == null || !status.paid) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment received. You are on ${status.planName}.'),
        ),
      );
    } catch (e) {
      debugPrint('Could not check the payment: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Account.instance.removeListener(_onAccount);
    super.dispose();
  }

  /// Shows the welcome screen until the user signs in or chooses to go on
  /// without an account. It sits on top of this screen rather than
  /// replacing it, so a ringing alarm can still open its quiz over it.
  Future<void> _requireAccount() async {
    if (!HomeScreen.requireAccount ||
        Account.instance.isSignedIn ||
        _gateOpen ||
        !mounted) {
      return;
    }
    _gateOpen = true; // held while the saved choice is read
    final guest = await GuestMode.chosen();
    _gateOpen = false;
    if (guest || Account.instance.isSignedIn || !mounted) return;
    // Never put the sign-in screen over a ringing alarm's quiz: it would
    // be unreachable while the alarm sounds. It comes up afterwards.
    if (Provider.of<AlarmProvider>(context, listen: false).isAlarmRinging) {
      return;
    }
    _gateOpen = true;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const AccountScreen(welcome: true),
      ),
    );
    _gateOpen = false;
  }

  /// First launch: offer the tour, then ask for the permissions alarms
  /// need. Later launches only ask for permissions not yet dealt with.
  Future<void> _welcome({required bool simulated}) async {
    // The welcome screen comes first, then the tour.
    await _requireAccount();
    if (!mounted) return;
    if (await AppTour.shouldShow() && mounted) {
      await AppTour.markSeen();
      if (!mounted) return;
      final wanted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Welcome to Brain O\' Clock'),
          content: const Text(
            'The alarm you can only switch off by answering revision '
            'questions.\n\nWant a one-minute tour of where everything is?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Show me around'),
            ),
          ],
        ),
      );
      if (wanted == true && mounted) await _runTour();
    }
    // The simulator has no OS permissions to ask for.
    if (!simulated && mounted) await _requestPermissions();
  }

  Future<void> _goToTab(int index) async {
    if (!mounted) return;
    setState(() {
      _currentIndex = index;
      _navHidden = false;
    });
  }

  /// The interactive tour: spotlights real elements, switching tabs as it
  /// goes, and ends back on the Alarms tab.
  Future<void> _runTour() async {
    await AppTour.run(context, [
      CoachStep(
        before: () => _goToTab(0),
        target: TourKeys.clock,
        title: 'Your clock',
        body:
            'Shows the time and how long until your next alarm. Tap the '
            'clock to switch between digital and analog.',
      ),
      CoachStep(
        target: TourKeys.addAlarm,
        title: 'Add an alarm',
        body:
            'Set the time and repeat days, then choose the topics it asks '
            'about, how many correct answers in a row it takes, the '
            'ringtone and the snooze length.',
      ),
      CoachStep(
        target: TourKeys.testQuiz,
        title: 'Try the quiz',
        body:
            'See what an alarm looks like without waiting for one. When a '
            'real alarm rings, this quiz opens by itself at full volume, '
            'and only the right answers stop it.',
      ),
      CoachStep(
        target: TourKeys.settings,
        title: 'Settings',
        body:
            'Dark or light theme, 12 or 24-hour clock, and the phone '
            'permissions alarms need. You can also replay this tour here.',
      ),
      CoachStep(
        before: () => _goToTab(1),
        target: TourKeys.navBanks,
        title: 'Question banks',
        body:
            'The questions your alarms use live here, and you can study '
            'them any time, even without internet.',
      ),
      CoachStep(
        target: TourKeys.practise,
        title: 'Practise',
        body:
            'Start a session: pick the topics, how many questions, and '
            'whether they come from the saved bank or are written fresh by '
            'the AI. Every answer comes with an explanation.',
      ),
      CoachStep(
        target: TourKeys.firstUnit,
        title: 'Units and topics',
        body:
            'Each card is a unit with your mastery so far. Tap it to see '
            'its topics, and inside a topic which questions you have done '
            'and which are still to do.',
      ),
      CoachStep(
        before: () => _goToTab(2),
        target: TourKeys.navReports,
        title: 'Reports',
        body: 'Your progress is tracked here automatically.',
      ),
      CoachStep(
        target: TourKeys.reportsHero,
        title: 'How you are doing',
        body:
            'Your overall accuracy, with accuracy per topic, how long '
            'alarms take you to switch off, and the history of every alarm '
            'and practice session below.',
      ),
      CoachStep(
        before: () => _goToTab(0),
        title: 'That is the tour',
        body:
            'Add your first alarm to get started. If your phone asks to '
            'allow notifications or full-screen alarms, please allow them '
            'so alarms can ring properly.',
      ),
    ]);
    await _goToTab(0);
  }

  Future<void> _requestPermissions() async {
    try {
      // 1. Request Notification Permission (Required for Android 13+)
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }

      // 2. Request Exact Alarm Permission (Required for Android 12+)
      if (await Permission.scheduleExactAlarm.isDenied) {
        await Permission.scheduleExactAlarm.request();
      }

      // 3. Battery optimization can delay or kill alarms on many phones.
      // Ask once only, so we don't nag on every launch.
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('asked_battery_opt') ?? false)) {
        await prefs.setBool('asked_battery_opt', true);
        if (!await Permission.ignoreBatteryOptimizations.isGranted) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      }

      // 4. Opening the quiz by itself when an alarm rings. Two system
      // switches control that; explain each once before sending the user
      // to it. Both can be changed later from Settings.
      if (!mounted) return;
      if (!(prefs.getBool('asked_full_screen') ?? false) &&
          !await SystemBridge.canUseFullScreenIntent()) {
        await prefs.setBool('asked_full_screen', true);
        if (mounted &&
            await _explain(
              'Show the quiz when an alarm rings',
              'So an alarm can wake the screen and open the questions by '
                  'itself, allow "Full screen notifications" for Brain O\' Clock '
                  'on the next page.',
            )) {
          await SystemBridge.openFullScreenIntentSettings();
        }
      }
      if (!mounted) return;
      if (!(prefs.getBool('asked_overlay') ?? false) &&
          !await Permission.systemAlertWindow.isGranted) {
        await prefs.setBool('asked_overlay', true);
        if (mounted &&
            await _explain(
              'Open over other apps',
              'If an alarm rings while you are using another app, Brain O\' Clock '
                  'can come to the front with the questions. For that, allow '
                  '"Display over other apps" on the next page.',
            )) {
          await Permission.systemAlertWindow.request();
        }
      }
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }
  }

  /// Explains a permission before the system page opens. True = go on.
  Future<bool> _explain(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = Text(_titles[_currentIndex]);

    return Scaffold(
      extendBody: true,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 10, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: const TextStyle(
                          fontFamily: AppTheme.display,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                        child: title,
                      ),
                    ),
                    if (_currentIndex == 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: FilledButton.icon(
                          onPressed: () => showAddTopicDialog(context),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Topic'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                        ),
                      ),
                    if (_currentIndex == 0)
                      IconButton(
                        key: TourKeys.settings,
                        tooltip: 'Settings',
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SettingsScreen(),
                            ),
                          );
                          // "Show the tour" in Settings.
                          if (result == 'tour' && mounted) _runTour();
                        },
                      ),
                  ],
                ),
              ),
              const UpdateBanner(),
              const MessageBanner(),
              ListenableBuilder(
                listenable: Entitlements.instance,
                builder: (context, _) => Entitlements.instance.needsCheck
                    ? const PlanCheckBanner()
                    : Entitlements.instance.endsSoon
                    ? const PlanEndingBanner()
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: NotificationListener<UserScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.axis != Axis.vertical) return false;
                    final hide = n.direction == ScrollDirection.reverse
                        ? true
                        : (n.direction == ScrollDirection.forward
                              ? false
                              : _navHidden);
                    if (hide != _navHidden) setState(() => _navHidden = hide);
                    return false;
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    child: KeyedSubtree(
                      key: ValueKey(_currentIndex),
                      child: _tabs[_currentIndex],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        offset: _navHidden ? const Offset(0, 1.6) : Offset.zero,
        child: SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.45 : 0.10,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) => setState(() {
                _currentIndex = i;
                _navHidden = false;
              }),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.alarm_rounded),
                  label: 'Alarms',
                ),
                NavigationDestination(
                  key: TourKeys.navBanks,
                  icon: const Icon(Icons.auto_stories_rounded),
                  label: 'Banks',
                ),
                NavigationDestination(
                  key: TourKeys.navReports,
                  icon: const Icon(Icons.insights_rounded),
                  label: 'Reports',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
