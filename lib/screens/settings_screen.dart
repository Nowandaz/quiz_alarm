/// Settings: theme, clock, alarm permissions, the account, and a visible
/// status of the AI question generation (so failures are not silent).
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/alarm_provider.dart';
import '../services/account.dart';
import '../services/ai_client.dart';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/question_service.dart';
import '../services/sync_service.dart';
import '../services/system_bridge.dart';
import '../services/theme_provider.dart';
import 'account_screen.dart';
import 'alarm_feedback.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AiAllowance? _allowance;
  bool _generating = false;
  String? _lastStatus;

  // Android switches that let an alarm open the quiz by itself.
  bool _fullScreenOk = true;
  bool _overlayOk = true;
  bool _needsAutostart = false;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _loadAllowance();
    _loadStatus();
    _loadAlarmAccess();
    SystemBridge.needsAutostart().then((v) {
      if (mounted && v) setState(() => _needsAutostart = true);
    });
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

  Future<void> _loadStatus() async {
    final s = await QuestionService.lastStatus();
    if (mounted) setState(() => _lastStatus = s);
  }

  /// How much AI is left today (only when signed in and online).
  Future<void> _loadAllowance() async {
    if (!AiClient.available) {
      if (mounted) setState(() => _allowance = null);
      return;
    }
    try {
      final a = await AiClient.allowance();
      if (mounted) setState(() => _allowance = a);
    } catch (e) {
      debugPrint('Could not read the AI allowance: $e');
    }
  }

  Future<void> _openAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
    );
    if (!mounted) return;
    _loadAllowance();
    if (AiClient.available) {
      // Top up the offline bank in the background now that the AI works.
      Provider.of<AlarmProvider>(
        context,
        listen: false,
      ).refillQuestionBank().then((_) => _loadStatus());
    }
  }

  Future<void> _signOut() async {
    await Account.instance.signOut();
    if (mounted) setState(() => _allowance = null);
  }

  void _dialog(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Runs a top-up for every topic right now and shows exactly what
  /// happened, including the error if it fails.
  Future<void> _generateNow() async {
    setState(() => _generating = true);
    if (!AiClient.available) {
      setState(() => _generating = false);
      _dialog(
        'Sign in needed',
        'Sign in above to have the AI write questions.',
      );
      return;
    }
    final result = await QuestionService.topUp(const [], targetUnseen: 1 << 30);
    await _loadStatus();
    _loadAllowance();
    if (!mounted) return;
    setState(() => _generating = false);
    if (result.error != null) {
      _dialog(
        'Generation failed',
        '${result.added > 0 ? 'Added ${result.added} question(s), then:\n\n' : ''}'
            '${result.error}',
      );
    } else {
      _dialog(
        'Questions added',
        'Added ${result.added} new question(s). They are in Question Banks, '
            'marked "AI generated".',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final small = Theme.of(context).textTheme.bodySmall;
    final account = context.watch<Account>();
    final allowance = _allowance;

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
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Dark Theme'),
                  secondary: Icon(
                    isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  ),
                  value: isDark,
                  onChanged: (v) => themeProvider.toggleTheme(v),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
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
                const Divider(height: 1, indent: 16, endIndent: 16),
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
                const Divider(height: 1, indent: 16, endIndent: 16),
                const ListTile(
                  leading: Icon(Icons.volume_up_rounded),
                  title: Text('Alarm volume'),
                  subtitle: Text(
                    'Always the maximum. The phone volume is raised when an '
                    'alarm rings and put back when you dismiss it.',
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
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
                const Divider(height: 1, indent: 16, endIndent: 16),
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
                if (_needsAutostart) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
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
                ],
                if (_android) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
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
                  const Divider(height: 1, indent: 16, endIndent: 16),
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
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text('Account', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Alarms and the built-in questions work without an account. '
            'Signing in keeps your progress safe and turns on the AI.',
            style: small,
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: account.isSignedIn
                ? Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.account_circle_rounded),
                        title: Text(account.email ?? 'Signed in'),
                        subtitle: Text(
                          allowance == null
                              ? 'Signed in'
                              : !allowance.enabled
                              ? 'AI is switched off for now'
                              : '${allowance.plan == 'premium' ? 'Premium' : 'Free'} plan: '
                                    '${allowance.remaining} of ${allowance.limit} '
                                    'AI requests left today',
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
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
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(Icons.logout_rounded),
                        title: const Text('Sign out'),
                        onTap: _signOut,
                      ),
                    ],
                  )
                : ListTile(
                    leading: const Icon(Icons.account_circle_outlined),
                    title: const Text('Sign in or create an account'),
                    subtitle: const Text(
                      'Free. Syncs your progress, turns on the AI.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _openAccount,
                  ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'AI question generation',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'New questions are written automatically when the topics of your '
            'alarms have fewer than 5 unanswered questions left.',
            style: small,
          ),
          const SizedBox(height: 8),
          Text('Last run: ${_lastStatus ?? 'nothing generated yet'}'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _generating ? null : _generateNow,
            icon: _generating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(
              _generating
                  ? 'Writing questions (up to 2 minutes)...'
                  : 'Generate questions now',
            ),
          ),
        ],
      ),
    );
  }
}
