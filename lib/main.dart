/// App entry point: starts the alarm backend and wires up the providers.
library;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/account.dart';
import 'services/alarm_backend.dart';
import 'services/alarm_provider.dart';
import 'data/alarm_log.dart';
import 'data/question_repository.dart';
import 'services/bank_provider.dart';
import 'services/sync_service.dart';
import 'services/theme_provider.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = AlarmBackend.forPlatform();
  try {
    await backend.init();
  } catch (e) {
    debugPrint('Alarm backend failed to start: $e');
  }

  await Account.instance.load();

  // Syncing with the server: at start, shortly after anything of the
  // user's changes, and when they sign in or out.
  SyncService.enabled = true;
  QuestionRepository.onLocalChange = SyncService.schedule;
  Account.instance.addListener(
    () => SyncService.schedule(const Duration(seconds: 1)),
  );
  AlarmLog.onUrgent = () => SyncService.schedule(const Duration(seconds: 2));
  SyncService.loadStatus();
  SyncService.schedule(const Duration(seconds: 3));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<Account>.value(value: Account.instance),
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
        title: 'BrainWake Alarm',
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
