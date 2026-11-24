/// App entry point: starts the alarm backend and wires up the providers.
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/crash_log.dart';
import 'services/account.dart';
import 'services/announcements.dart';
import 'services/alarm_backend.dart';
import 'services/alarm_provider.dart';
import 'data/alarm_log.dart';
import 'data/question_repository.dart';
import 'services/bank_provider.dart';
import 'services/billing.dart';
import 'services/entitlements.dart';
import 'services/profile_picture.dart';
import 'services/sync_service.dart';
import 'services/theme_provider.dart';
import 'services/update_check.dart';
import 'services/usage_ping.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Note errors, so a problem report can say what went wrong.
  CrashLog.install();
  final backend = AlarmBackend.forPlatform();
  try {
    await backend.init();
  } catch (e) {
    debugPrint('Alarm backend failed to start: $e');
  }

  await Account.instance.load();
  // What the plan opens. Read from the phone first (works offline), then
  // confirmed with the server in the background.
  final plan = Entitlements.instance;
  await plan.load();
  plan.refresh();

  // The profile picture of whoever is signed in: this phone's copy at
  // once, then brought in line with the account's copy on the server.
  Future<void> picture() async {
    await ProfilePicture.load();
    await ProfilePicture.sync();
  }

  await ProfilePicture.load();
  ProfilePicture.sync();
  Account.instance.addListener(picture);

  // The anonymous "this phone uses the app" note (once a day at most).
  UsagePing.send();
  // Is a newer version of the app out?
  UpdateCheck.run();
  // Messages from the team: the saved ones at once, then any new ones.
  await Announcements.load();
  Announcements.run();

  // Syncing with the server: at start, shortly after anything of the
  // user's changes, and when they sign in or out.
  SyncService.enabled = true;
  QuestionRepository.onLocalChange = SyncService.schedule;
  Account.instance.addListener(
    () => SyncService.schedule(const Duration(seconds: 1)),
  );
  AlarmLog.onUrgent = () => SyncService.schedule(const Duration(seconds: 2));
  SyncService.loadStatus();
  // A confirmed payment: fetch the whole bank so premium units arrive.
  Billing.onPaid = () => SyncService.run(fullBank: true);
  // The plan changed (bought, ran out, signed in or out): the server now
  // lets this phone see other questions, so the bank is fetched again.
  var level = plan.level;
  plan.addListener(() {
    if (plan.level == level) return;
    level = plan.level;
    SyncService.schedule(const Duration(seconds: 1));
    UsagePing.send();
  });
  SyncService.schedule(const Duration(seconds: 3));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<Account>.value(value: Account.instance),
        ChangeNotifierProvider<Entitlements>.value(value: plan),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => BankProvider()),
        ChangeNotifierProvider(create: (_) => AlarmProvider(backend: backend)),
      ],
      child: const QuizAlarmApp(),
    ),
  );
}

class QuizAlarmApp extends StatelessWidget {
  const QuizAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<ThemeProvider>(context);

    // The accent is the phone's own theme colour (Android 12+ wallpaper
    // colours). Where the phone has none, the app's own accent is used.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        title: 'Brain O\' Clock',
        debugShowCheckedModeBanner: false,
        themeMode: settings.themeMode,
        theme: AppTheme.light(lightDynamic?.primary),
        darkTheme: AppTheme.dark(darkDynamic?.primary),
        // Makes every standard time widget follow the 12/24 hour setting.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(alwaysUse24HourFormat: settings.use24Hour),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
