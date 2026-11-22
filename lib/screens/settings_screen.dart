/// Settings, in four groups that drop down when their heading is tapped:
/// General (theme, clock, sounds), Permissions (what the phone must allow
/// for alarms, and blocking uninstalling while an alarm rings), Account
/// (sign in, plan, sync, deleting the account) and Privacy.
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/alarm_provider.dart';
import '../services/account.dart';
import '../services/ai_client.dart';
import '../services/billing.dart';
import '../services/entitlements.dart';
import '../services/profile_picture.dart';
import '../services/server_config.dart';
import '../services/sound_prefs.dart';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/sync_service.dart';
import '../services/system_bridge.dart';
import '../services/theme_provider.dart';
import 'account_screen.dart';
import 'alarm_feedback.dart';
import 'upgrade_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  /// The groups that are dropped down. Only General at first; nothing is
  /// remembered between visits.
  final Set<String> _open = {};

  /// Choose, change or remove the profile picture (saved with the account).
  Future<void> _editPicture() async {
    final has = ProfilePicture.current.value != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(has ? 'Choose another photo' : 'Choose a photo'),
              subtitle: const Text('Saved with your account.'),
              onTap: () => Navigator.pop(ctx, 'choose'),
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove picture'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == 'remove') await ProfilePicture.remove();
    if (choice != 'choose') return;
    final problem = await ProfilePicture.choose();
    if (problem != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  // "Mute right and wrong sounds".
  bool _muteAnswerSounds = SoundPrefs.muteAnswerSounds;

  // "Block uninstalling while an alarm rings" (Android device admin).
  bool _uninstallBlocked = false;

  // Android switches that let an alarm open the quiz by itself.
  bool _fullScreenOk = true;
  bool _overlayOk = true;
  bool _needsAutostart = false;

  // "Share alarm diagnostics". On until the user switches it off.
  bool _shareDiagnostics = true;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPlan();
    _loadAlarmAccess();
    _loadUninstallBlock();
    SoundPrefs.load().then((mute) {
      if (mounted) setState(() => _muteAnswerSounds = mute);
    });
    SharedPreferences.getInstance().then((prefs) {
      final share = prefs.getBool(SyncService.shareDiagnosticsPref) ?? true;
      if (mounted) setState(() => _shareDiagnostics = share);
    });
    SystemBridge.needsAutostart().then((v) {
      if (mounted && v) setState(() => _needsAutostart = true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from one of Android's own pages: read the switches again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAlarmAccess();
      _loadUninstallBlock();
    }
  }

  Future<void> _loadUninstallBlock() async {
    if (!_android) return;
    final on = await SystemBridge.uninstallProtectionOn();
    if (mounted) setState(() => _uninstallBlocked = on);
  }

  Future<void> _setUninstallBlock(bool on) async {
    if (!on) {
      // Refused while an alarm is ringing: that is the whole point.
      final removed = await SystemBridge.removeUninstallProtection();
      if (!mounted) return;
      if (removed) {
        setState(() => _uninstallBlocked = false);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You can switch this off once the alarm is over.'),
          ),
        );
      }
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block uninstalling'),
        content: const SingleChildScrollView(
          child: Text(
            'Android will ask you to make BrainWake a device admin app. '
            'BrainWake uses this for one thing only: to stop the app being '
            'uninstalled while an alarm is ringing. If someone tries to '
            'remove it during an alarm, the phone locks. You can switch it '
            'off here at any time when no alarm is ringing.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go != true) return;
    // Opens Android's page; the switch is read again when the app is
    // back on screen (didChangeAppLifecycleState).
    await SystemBridge.requestUninstallProtection();
    await _loadUninstallBlock();
  }

  Future<void> _setMuteAnswerSounds(bool mute) async {
    setState(() => _muteAnswerSounds = mute);
    await SoundPrefs.setMuteAnswerSounds(mute);
  }

  Future<void> _openUrl(String url) async {
    final opened = await SystemBridge.openUrl(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open this page in your browser: $url')),
      );
    }
  }

  Future<void> _loadAlarmAccess() async {
    if (!_android) return;
    try {
      final full = await SystemBridge.canUseFullScreenIntent();
      final overlay = await Permission.systemAlertWindow.isGranted;
      if (mounted) {
        setState(() {
          _fullScreenOk = full;
          _overlayOk = overlay;
        });
      }
    } catch (e) {
      debugPrint('Could not read alarm permissions: $e');
    }
  }

  /// The plan, for the "Premium" row (only when signed in and online).
  Future<void> _loadPlan() async {
    if (!Account.instance.isSignedIn) return;
    try {
      await Billing.plans();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Could not read the plan: $e');
    }
  }

  Future<void> _openUpgrade() async {
    await showUpgrade(context);
    if (mounted) setState(() {});
  }

  Future<void> _openAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
    );
    if (!mounted) return;
    _loadPlan();
    if (AiClient.available && Entitlements.instance.canUseAi) {
      // Top up the offline bank in the background now that the AI works.
      Provider.of<AlarmProvider>(context, listen: false).refillQuestionBank();
    }
  }

  Future<void> _signOut() async {
    await Account.instance.signOut();
    if (mounted) setState(() {});
  }

  Future<void> _setShareDiagnostics(bool value) async {
    setState(() => _shareDiagnostics = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SyncService.shareDiagnosticsPref, value);
  }

  /// Says what goes, then asks for the word DELETE before anything is
  /// removed: this cannot be undone, so one stray tap must not do it.
  Future<void> _deleteAccount() async {
    final typed = TextEditingController();
    var working = false;
    String? error;
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          final scheme = Theme.of(ctx).colorScheme;
          final confirmed = typed.text.trim() == 'DELETE';
          return AlertDialog(
            title: const Text('Delete your account?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your account and everything stored for it on our '
                    'server is deleted for good: answers, sessions, AI '
                    'questions, backups, reports. Alarms on this phone stay.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: typed,
                    enabled: !working,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => refresh(() {}),
                    decoration: InputDecoration(
                      labelText: 'Type DELETE to confirm',
                      errorText: error,
                      errorMaxLines: 3,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: working ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  // White reads on the red of both themes.
                  foregroundColor: Colors.white,
                ),
                onPressed: !confirmed || working
                    ? null
                    : () async {
                        refresh(() {
                          working = true;
                          error = null;
                        });
                        final problem = await Account.instance.deleteAccount();
                        if (!ctx.mounted) return;
                        if (problem == null) {
                          Navigator.pop(ctx, true);
                        } else {
                          refresh(() {
                            working = false;
                            error = problem;
                          });
                        }
                      },
                child: Text(working ? 'Deleting...' : 'Delete account'),
              ),
            ],
          );
        },
      ),
    );
    if (deleted != true || !mounted) return;
    // The sign-in screen comes up by itself (the home screen watches the
    // account); this says why.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Your account was deleted.')));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The plan row follows the plan (upgrade, expiry, sign-out).
    listenable: Entitlements.instance,
    builder: (context, _) => _build(context),
  );

  static const Widget _line = Divider(height: 1, indent: 16, endIndent: 16);

  /// One group: a heading that drops its rows down when tapped.
  Widget _group(String name, IconData icon, List<Widget> rows) {
    final theme = Theme.of(context);
    final open = _open.contains(name);
    return Card(
      key: ValueKey('group-$name'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(
              name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            trailing: Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
            onTap: () => setState(() {
              if (!_open.remove(name)) _open.add(name);
            }),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: !open
                ? const SizedBox(width: double.infinity)
                : Column(
                    children: [
                      for (final row in rows) ...[_line, row],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _group('General', Icons.tune_rounded, _general(context)),
          _group('Permissions', Icons.verified_user_outlined, _permissions()),
          _group('Account', Icons.account_circle_outlined, _account(context)),
          _group('Privacy', Icons.privacy_tip_outlined, _privacy()),
        ],
      ),
    );
  }

  List<Widget> _general(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return [
      Column(
        children: [
          ListTile(
            leading: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.dark_mode_rounded
                  : Icons.light_mode_rounded,
            ),
            title: const Text('Theme'),
            subtitle: Text(switch (themeProvider.themeMode) {
              ThemeMode.light => 'Always light',
              ThemeMode.dark => 'Always dark',
              ThemeMode.system =>
                'System default: follows your phone\'s setting',
            }),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ],
                selected: {themeProvider.themeMode},
                onSelectionChanged: (s) => themeProvider.setThemeMode(s.first),
              ),
            ),
          ),
        ],
      ),
      SwitchListTile(
        title: const Text('24-hour clock'),
        subtitle: Text(
          themeProvider.use24Hour
              ? 'Times show as 18:30'
              : 'Times show as 6:30 PM',
        ),
        secondary: const Icon(Icons.schedule_rounded),
        value: themeProvider.use24Hour,
        onChanged: (v) => themeProvider.setUse24Hour(v),
      ),
      SwitchListTile(
        title: const Text('Mute right and wrong sounds'),
        subtitle: Text(
          _muteAnswerSounds
              ? 'Answers are marked silently. The alarm still rings.'
              : 'A short sound plays after each answer in a quiz.',
        ),
        secondary: Icon(
          _muteAnswerSounds
              ? Icons.music_off_rounded
              : Icons.music_note_rounded,
        ),
        value: _muteAnswerSounds,
        onChanged: _setMuteAnswerSounds,
      ),
      const ListTile(
        leading: Icon(Icons.volume_up_rounded),
        title: Text('Alarm volume'),
        subtitle: Text(
          'Always the maximum. The phone volume is raised when an '
          'alarm rings and put back when you dismiss it.',
        ),
      ),
      SwitchListTile(
        title: const Text('Heads-up before an alarm'),
        subtitle: const Text(
          'Five minutes before, one long vibration and a '
          'notification. Already up? Tap Skip on it and that '
          'alarm will not ring.',
        ),
        secondary: const Icon(Icons.vibration_rounded),
        value: themeProvider.headsUp,
        onChanged: (v) async {
          final alarms = context.read<AlarmProvider>();
          await themeProvider.setHeadsUp(v);
          await alarms.refreshHeadsUps();
        },
      ),
      ListTile(
        leading: const Icon(Icons.explore_rounded),
        title: const Text('Show the tour'),
        subtitle: const Text(
          'Points out where everything is, on the real screens.',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        // The home screen runs the tour when Settings closes.
        onTap: () => Navigator.pop(context, 'tour'),
      ),
      ListTile(
        leading: const Icon(Icons.report_problem_outlined),
        title: const Text('Report an alarm problem'),
        subtitle: const Text(
          'An alarm did not ring, rang late or had no sound? '
          'Tell us; the technical details are attached for you.',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => showAlarmFeedback(context),
      ),
    ];
  }

  List<Widget> _permissions() {
    final rows = <Widget>[
      if (_needsAutostart)
        ListTile(
          leading: const Icon(Icons.restart_alt_rounded),
          title: const Text('Start by itself after a restart'),
          subtitle: const Text(
            'This phone needs "Autostart" switched on for '
            'BrainWake, or alarms and the heads-up can be lost '
            'when the phone restarts. Tap to open that page.',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: SystemBridge.openAutostartSettings,
        ),
      if (_android) ...[
        ListTile(
          leading: const Icon(Icons.fullscreen_rounded),
          title: const Text('Show quiz over the lock screen'),
          subtitle: Text(
            _fullScreenOk
                ? 'Allowed. An alarm wakes the screen and opens '
                      'the questions.'
                : 'Not allowed: alarms only show a notification. '
                      'Tap to allow "Full screen notifications".',
          ),
          trailing: Icon(
            _fullScreenOk
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
          ),
          onTap: () async {
            await SystemBridge.openFullScreenIntentSettings();
            await Future<void>.delayed(const Duration(seconds: 1));
            _loadAlarmAccess();
          },
        ),
        ListTile(
          leading: const Icon(Icons.layers_rounded),
          title: const Text('Open over other apps'),
          subtitle: Text(
            _overlayOk
                ? 'Allowed. The quiz comes to the front if an '
                      'alarm rings while you use another app.'
                : 'Not allowed. Tap to allow "Display over other '
                      'apps".',
          ),
          trailing: Icon(
            _overlayOk
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
          ),
          onTap: () async {
            await Permission.systemAlertWindow.request();
            _loadAlarmAccess();
          },
        ),
        SwitchListTile(
          title: const Text('Block uninstalling while an alarm rings'),
          subtitle: Text(
            _uninstallBlocked
                ? 'On. To uninstall BrainWake, switch this off first.'
                : 'While on, BrainWake cannot be uninstalled until you '
                      'switch this off here.',
          ),
          secondary: const Icon(Icons.shield_outlined),
          value: _uninstallBlocked,
          onChanged: _setUninstallBlock,
        ),
      ],
    ];
    return rows.isNotEmpty
        ? rows
        : const [
            ListTile(
              leading: Icon(Icons.check_circle_outline_rounded),
              title: Text('Nothing to allow on this device.'),
            ),
          ];
  }

  List<Widget> _account(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final account = context.watch<Account>();
    final plan = Entitlements.instance;
    final planRow = ListTile(
      leading: const Icon(Icons.workspace_premium_rounded),
      title: Text('Plan: ${plan.planName}'),
      subtitle: Text(
        plan.isPaid
            ? (Billing.last?.premium == true
                  ? Billing.last!.planLabel
                  : 'Everything is unlocked.')
            : plan.needsCheck
            ? plan.unlockHint
            : 'See the plans and upgrade',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: _openUpgrade,
    );
    if (!account.isSignedIn) {
      return [
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('Sign in or create an account'),
          subtitle: const Text(
            'Free. Keeps your progress safe and opens more topics.',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _openAccount,
        ),
        planRow,
      ];
    }
    return [
      ValueListenableBuilder<Uint8List?>(
        valueListenable: ProfilePicture.current,
        builder: (context, picture, _) => ListTile(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: scheme.surfaceContainerHighest,
            backgroundImage: picture == null ? null : MemoryImage(picture),
            child: picture == null
                ? Icon(Icons.person_rounded, color: scheme.onSurfaceVariant)
                : null,
          ),
          title: Text(account.email ?? 'Signed in'),
          subtitle: Text(
            picture == null
                ? 'Signed in. Tap to add a profile picture.'
                : 'Signed in. Tap to change your picture.',
          ),
          onTap: _editPicture,
        ),
      ),
      planRow,
      ValueListenableBuilder<bool>(
        valueListenable: SyncService.running,
        builder: (context, running, _) => ListTile(
          leading: const Icon(Icons.sync_rounded),
          title: const Text('Sync now'),
          subtitle: ValueListenableBuilder<String?>(
            valueListenable: SyncService.status,
            builder: (context, status, _) => Text(
              running
                  ? 'Syncing...'
                  : status ??
                        'Your progress and the question bank '
                            'sync by themselves.',
            ),
          ),
          onTap: running ? null : () => SyncService.run(),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.logout_rounded),
        title: const Text('Sign out'),
        onTap: _signOut,
      ),
      // Only an account that is signed in can be deleted.
      ListTile(
        leading: Icon(Icons.delete_forever_rounded, color: scheme.error),
        title: Text(
          'Delete account',
          style: TextStyle(color: scheme.error, fontWeight: FontWeight.w700),
        ),
        subtitle: const Text(
          'Removes your account and everything stored for it. '
          'This cannot be undone.',
        ),
        onTap: _deleteAccount,
      ),
    ];
  }

  List<Widget> _privacy() => [
    SwitchListTile(
      title: const Text('Share alarm diagnostics'),
      subtitle: const Text(
        'Sends a record of when alarms were set, rang and were '
        'dismissed, so problems can be found. Your answers are '
        'never shared with anyone else.',
      ),
      secondary: const Icon(Icons.monitor_heart_outlined),
      value: _shareDiagnostics,
      onChanged: _setShareDiagnostics,
    ),
    ListTile(
      leading: const Icon(Icons.policy_outlined),
      title: const Text('Privacy policy'),
      trailing: const Icon(Icons.open_in_new_rounded),
      onTap: () => _openUrl(ServerConfig.privacyUrl),
    ),
    ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text('Terms & conditions'),
      trailing: const Icon(Icons.open_in_new_rounded),
      onTap: () => _openUrl(ServerConfig.termsUrl),
    ),
  ];
}
