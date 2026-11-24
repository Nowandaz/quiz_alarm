/// "Set up this phone": where each phone maker keeps the settings that
/// decide whether an alarm app is allowed to stay alive.
///
/// Xiaomi, Tecno, Infinix, Oppo and others close apps to save battery
/// (some every time the screen locks). Android cancels a closed app's
/// alarms, so the alarm then rings late or not at all. The app cannot
/// change these settings itself and cannot read most of them; it can
/// only show where they are, and notice afterwards that it was closed.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'system_bridge.dart';

/// What a step's button opens.
enum SetupOpens { appSettings, autostart, overlay, nothing }

class SetupStep {
  final String title;

  /// Where the setting is, as a path through the phone's Settings.
  final String where;

  /// What to choose there.
  final String choose;
  final SetupOpens opens;
  const SetupStep(
    this.title, {
    required this.where,
    required this.choose,
    this.opens = SetupOpens.nothing,
  });
}

class PhoneGuide {
  /// "Xiaomi, Redmi and POCO phones".
  final String phones;
  final List<SetupStep> steps;
  const PhoneGuide(this.phones, this.steps);
}

class PhoneSetup {
  static const String _app = "Brain O' Clock";

  static const SetupStep _overlay = SetupStep(
    'Let the quiz open over other apps',
    where: 'Settings > Apps > $_app > Display over other apps',
    choose: 'Switch it on, so a ringing alarm can bring the quiz up.',
    opens: SetupOpens.overlay,
  );

  static const PhoneGuide xiaomi = PhoneGuide('Xiaomi, Redmi and POCO phones', [
    SetupStep(
      'Stop the battery saver closing the app',
      where: 'Settings > Apps > Manage apps > $_app > Battery saver',
      choose: 'Choose "No restrictions".',
      opens: SetupOpens.appSettings,
    ),
    SetupStep(
      'Switch on Autostart',
      where: 'Settings > Apps > Manage apps > $_app > Autostart',
      choose: 'Switch it on.',
      opens: SetupOpens.autostart,
    ),
    SetupStep(
      'Lock the app in recent apps',
      where:
          'Open recent apps (swipe up and hold), then press and hold the '
          '$_app card',
      choose:
          'Tap the padlock. The lock-screen cleaner then leaves the app '
          'alone.',
    ),
    SetupStep(
      'Allow pop-ups and the lock screen',
      where: 'Settings > Apps > Manage apps > $_app > Other permissions',
      choose:
          'Allow "Display pop-up windows while running in the background" '
          'and "Show on Lock screen".',
      opens: SetupOpens.appSettings,
    ),
  ]);

  static const PhoneGuide transsion = PhoneGuide(
    'Tecno, Infinix and itel phones',
    [
      SetupStep(
        'Stop the battery saver closing the app',
        where: 'Settings > Apps > $_app > Battery',
        choose: 'Choose "Unrestricted" (or allow background activity).',
        opens: SetupOpens.appSettings,
      ),
      SetupStep(
        'Switch on Auto-start',
        where: 'Phone Master > Toolbox > Auto-start management',
        choose: 'Switch $_app on.',
        opens: SetupOpens.autostart,
      ),
      SetupStep(
        'Lock the app in recent apps',
        where: 'Open recent apps, then pull the $_app card down a little',
        choose:
            'A padlock appears on the card. "Clear all" then leaves the '
            'app running.',
      ),
      _overlay,
    ],
  );

  static const PhoneGuide oppo = PhoneGuide('Oppo, Realme and OnePlus phones', [
    SetupStep(
      'Allow background activity',
      where: 'Settings > Apps > App management > $_app > Battery usage',
      choose:
          'Switch on "Allow background activity" and '
          '"Allow auto launch".',
      opens: SetupOpens.appSettings,
    ),
    SetupStep(
      'Switch on Auto launch',
      where: 'Settings > Apps > Auto launch',
      choose: 'Switch $_app on.',
      opens: SetupOpens.autostart,
    ),
    SetupStep(
      'Lock the app in recent apps',
      where:
          'Open recent apps, then tap the three dots above the '
          '$_app card',
      choose: 'Tap "Lock".',
    ),
    _overlay,
  ]);

  static const PhoneGuide vivo = PhoneGuide('Vivo and iQOO phones', [
    SetupStep(
      'Allow high background power use',
      where: 'Settings > Battery > Background power consumption management',
      choose: 'Open $_app and choose "Don\'t restrict background power use".',
      opens: SetupOpens.appSettings,
    ),
    SetupStep(
      'Switch on Autostart',
      where: 'Settings > Apps > Autostart',
      choose: 'Switch $_app on.',
      opens: SetupOpens.autostart,
    ),
    SetupStep(
      'Lock the app in recent apps',
      where: 'Open recent apps, then pull the $_app card down',
      choose: 'A padlock appears on the card.',
    ),
    _overlay,
  ]);

  static const PhoneGuide huawei = PhoneGuide('Huawei and Honor phones', [
    SetupStep(
      'Manage the app\'s launch yourself',
      where: 'Settings > Apps > App launch > $_app',
      choose:
          'Switch off "Manage automatically", then keep all three '
          'switches on (Auto-launch, Secondary launch, Run in background).',
      opens: SetupOpens.autostart,
    ),
    SetupStep(
      'Lock the app in recent apps',
      where: 'Open recent apps, then pull the $_app card down',
      choose: 'A padlock appears on the card.',
    ),
    _overlay,
  ]);

  static const PhoneGuide samsung = PhoneGuide('Samsung phones', [
    SetupStep(
      'Stop the battery saver closing the app',
      where: 'Settings > Apps > $_app > Battery',
      choose: 'Choose "Unrestricted".',
      opens: SetupOpens.appSettings,
    ),
    SetupStep(
      'Keep it out of sleeping apps',
      where: 'Settings > Battery > Background usage limits',
      choose: 'Add $_app under "Never auto sleeping apps".',
    ),
    _overlay,
  ]);

  static const PhoneGuide other = PhoneGuide('This phone', [
    SetupStep(
      'Stop the battery saver closing the app',
      where: 'Settings > Apps > $_app > Battery (or App battery usage)',
      choose: 'Choose "Unrestricted".',
      opens: SetupOpens.appSettings,
    ),
    _overlay,
  ]);

  /// The guide for a phone maker's name ("Xiaomi", "TECNO MOBILE"...).
  static PhoneGuide guideFor(String manufacturer) {
    final m = manufacturer.toLowerCase();
    bool any(List<String> names) => names.any(m.contains);
    if (any(['xiaomi', 'redmi', 'poco'])) return xiaomi;
    if (any(['tecno', 'infinix', 'itel', 'transsion'])) return transsion;
    if (any(['oppo', 'realme', 'oneplus'])) return oppo;
    if (any(['vivo', 'iqoo'])) return vivo;
    if (any(['huawei', 'honor'])) return huawei;
    if (m.contains('samsung')) return samsung;
    return other;
  }

  /// The guide for this phone.
  static Future<PhoneGuide> guide() async =>
      guideFor('${(await SystemBridge.deviceInfo())['manufacturer'] ?? ''}');

  /// Steps the user ticked as done (the app cannot read most of them).
  static const String donePref = 'phone_setup_done';

  static Future<Set<String>> doneSteps() async =>
      ((await SharedPreferences.getInstance()).getStringList(donePref) ??
              const <String>[])
          .toSet();

  static Future<void> setDone(String title, bool done) async {
    final prefs = await SharedPreferences.getInstance();
    final all = (prefs.getStringList(donePref) ?? const <String>[]).toSet();
    done ? all.add(title) : all.remove(title);
    await prefs.setStringList(donePref, all.toList());
  }
}
