/// "Set up alarms": everything on the phone that alarms depend on, in one
/// place. First what Android itself can be asked for, each with its state
/// and one button; then the steps for this make of phone, each with where
/// the setting is and a button that opens it.
library;

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/phone_setup.dart';
import '../widgets/alarm_health.dart';
import '../services/system_bridge.dart';

class PhoneSetupScreen extends StatefulWidget {
  const PhoneSetupScreen({super.key});

  @override
  State<PhoneSetupScreen> createState() => _PhoneSetupScreenState();
}

class _PhoneSetupScreenState extends State<PhoneSetupScreen>
    with WidgetsBindingObserver {
  PhoneGuide? _guide;
  Set<String> _done = {};

  // What Android can still be asked for (empty: all allowed).
  List<AlarmProblem> _problems = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a settings page: the states may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final guide = await PhoneSetup.guide();
    final done = await PhoneSetup.doneSteps();
    final problems = await findAlarmProblems();
    if (!mounted) return;
    setState(() {
      _guide = guide;
      _done = done;
      _problems = problems;
    });
  }

  Future<void> _open(SetupStep step) async {
    switch (step.opens) {
      case SetupOpens.appSettings:
        await openAppSettings();
      case SetupOpens.autostart:
        await SystemBridge.openAutostartSettings();
      case SetupOpens.overlay:
        await Permission.systemAlertWindow.request();
      case SetupOpens.nothing:
        break;
    }
  }

  Future<void> _tick(SetupStep step, bool done) async {
    await PhoneSetup.setDone(step.title, done);
    setState(() => done ? _done.add(step.title) : _done.remove(step.title));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guide = _guide;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up alarms')),
      body: guide == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                Card(
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Permissions', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        if (_problems.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Everything alarms need is allowed.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final p in _problems)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        p.detail,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed: () async {
                                    await p.fix();
                                    await _load();
                                  },
                                  child: Text(
                                    p.action == 'Fix' ? 'Allow' : p.action,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Text(
                  '${guide.phones} close apps to save battery. When that '
                  'happens to an alarm app, its alarms are cancelled and '
                  'ring late or not at all. These settings stop it. '
                  'Do each one once.',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                const SizedBox(height: 12),
                for (final (i, step) in guide.steps.indexed)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i + 1}. ${step.title}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.place_outlined,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  step.where,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              step.choose,
                              style: const TextStyle(height: 1.35),
                            ),
                          ),
                          Row(
                            children: [
                              Checkbox(
                                value: _done.contains(step.title),
                                onChanged: (v) => _tick(step, v ?? false),
                              ),
                              const Expanded(child: Text('Done')),
                              if (step.opens != SetupOpens.nothing)
                                TextButton.icon(
                                  onPressed: () => _open(step),
                                  icon: const Icon(
                                    Icons.open_in_new_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Open settings'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'The names can differ a little between models. If a button '
                  'opens the wrong page, follow the path shown. Afterwards '
                  'open Brain O\' Clock once so your alarms are set again.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ],
            ),
    );
  }
}
