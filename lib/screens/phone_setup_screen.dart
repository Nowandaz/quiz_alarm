/// "Set up this phone for alarms": the steps for this make of phone,
/// each with where the setting is and a button that opens it. Also the
/// note on the first screen after the phone closed the app.
library;

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/phone_setup.dart';
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

  Future<void> _load() async {
    final guide = await PhoneSetup.guide();
    final done = await PhoneSetup.doneSteps();
    if (!mounted) return;
    setState(() {
      _guide = guide;
      _done = done;
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
      appBar: AppBar(title: const Text('Set up this phone')),
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

/// On the first screen after the phone force-closed the app: says what
/// happened (the alarms were cancelled until now) and leads to the guide.
class PhoneClosedBanner extends StatefulWidget {
  const PhoneClosedBanner({super.key});

  @override
  State<PhoneClosedBanner> createState() => _PhoneClosedBannerState();
}

class _PhoneClosedBannerState extends State<PhoneClosedBanner> {
  int? _closedAt;

  @override
  void initState() {
    super.initState();
    PhoneSetup.closedByPhone().then((at) {
      if (mounted && at != null) setState(() => _closedAt = at);
    });
  }

  void _dismiss() {
    final at = _closedAt;
    if (at != null) PhoneSetup.markSeen(at);
    setState(() => _closedAt = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_closedAt == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your phone closed Brain O\' Clock, which cancels its '
                  'alarms until the app is opened again. They are set '
                  'again now. A few settings stop this happening.',
                  style: TextStyle(color: scheme.onErrorContainer, height: 1.3),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _dismiss, child: const Text('Not now')),
              TextButton(
                onPressed: () {
                  _dismiss();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PhoneSetupScreen()),
                  );
                },
                child: const Text('Show me'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
