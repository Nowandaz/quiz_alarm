import 'dart:convert';

// The Settings screen: four groups that drop down, the new switches, and
// the sections that were removed.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quiz_alarm/screens/settings_screen.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/billing.dart';
import 'package:quiz_alarm/services/profile_picture.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:quiz_alarm/services/server_config.dart';
import 'package:quiz_alarm/services/sound_prefs.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

const _system = MethodChannel('brainwake/system');

Future<void> show(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<Account>.value(value: Account.instance),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester, String group) async {
  await tester.tap(find.text(group));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await resetApp();
    Billing.resetForTest();
    // The plan row asks the server; nothing real is ever called.
    Billing.httpClient = MockClient((_) async => http.Response('{}', 503));
  });
  tearDown(() => Entitlements.instance.setForTest(null));

  testWidgets('four groups, all closed at first', (tester) async {
    await show(tester);
    for (final group in ['General', 'Permissions', 'Account', 'Privacy']) {
      expect(find.text(group), findsOneWidget);
    }
    expect(find.text('Theme'), findsNothing);
    expect(find.text('Share alarm diagnostics'), findsNothing);
    expect(find.text('Sign in or create an account'), findsNothing);

    await open(tester, 'General');
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('24-hour clock'), findsOneWidget);

    await open(tester, 'Privacy');
    expect(find.text('Share alarm diagnostics'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms & conditions'), findsOneWidget);
    // General stays open: the groups fold one by one.
    expect(find.text('Theme'), findsOneWidget);

    await open(tester, 'General');
    expect(find.text('Theme'), findsNothing);
    await open(tester, 'Privacy');
    expect(find.text('Share alarm diagnostics'), findsNothing);
  });

  testWidgets('a profile picture can be added and removed', (tester) async {
    Account.instance.signInForTest();
    // A 1x1 PNG stands in for the gallery.
    ProfilePicture.pick = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    await ProfilePicture.load();
    await show(tester);
    await open(tester, 'Account');
    expect(find.textContaining('Tap to add a profile picture'), findsOneWidget);

    await tester.tap(find.textContaining('Tap to add a profile picture'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Choose a photo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(ProfilePicture.current.value, isNotNull);
    expect(find.textContaining('Tap to change your picture'), findsOneWidget);

    await tester.tap(find.textContaining('Tap to change your picture'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove picture'));
    await tester.pumpAndSettle();
    expect(ProfilePicture.current.value, isNull);
  });

  testWidgets('"What is stored" and "AI question generation" are gone', (
    tester,
  ) async {
    Account.instance.signInForTest();
    await show(tester);
    for (final group in ['Permissions', 'Account', 'Privacy']) {
      await open(tester, group);
    }
    expect(find.text('What is stored'), findsNothing);
    expect(find.textContaining('AI question generation'), findsNothing);
    expect(find.textContaining('Generate questions now'), findsNothing);
    expect(find.textContaining('AI requests left'), findsNothing);
    // What is still there.
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('the Account group shows the plan', (tester) async {
    Entitlements.instance.setForTest(PlanLevel.guest);
    await show(tester);
    await open(tester, 'Account');
    expect(find.text('Sign in or create an account'), findsOneWidget);
    expect(find.text('Plan: Guest'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);

    Entitlements.instance.setForTest(PlanLevel.free);
    await tester.pump();
    expect(find.text('Plan: Free'), findsOneWidget);
    expect(find.text('See the plans and upgrade'), findsOneWidget);

    Entitlements.instance.setForTest(PlanLevel.pro);
    await tester.pump();
    expect(find.text('Plan: Premium'), findsOneWidget);
  });

  testWidgets('"Mute right and wrong sounds" is saved', (tester) async {
    await show(tester);
    await open(tester, 'General');
    expect(SoundPrefs.muteAnswerSounds, isFalse);
    await tester.tap(find.text('Mute right and wrong sounds'));
    await tester.pumpAndSettle();
    expect(SoundPrefs.muteAnswerSounds, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('muteAnswerSounds'), isTrue);
    expect(
      find.text('Answers are marked silently. The alarm still rings.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Mute right and wrong sounds'));
    await tester.pumpAndSettle();
    expect(prefs.getBool('muteAnswerSounds'), isFalse);
  });

  testWidgets('no uninstall switch off Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await show(tester);
    await open(tester, 'Permissions');
    expect(find.text('Block uninstalling while an alarm rings'), findsNothing);
    expect(find.text('Nothing to allow on this device.'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  group('on Android', () {
    late List<MethodCall> calls;
    late bool protectionOn;
    late bool alarmRinging;

    void fakeAndroid(WidgetTester tester) {
      calls = [];
      protectionOn = false;
      alarmRinging = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_system, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'uninstallProtectionOn':
            return protectionOn;
          case 'requestUninstallProtection':
            return true;
          case 'removeUninstallProtection':
            if (alarmRinging) return false;
            protectionOn = false;
            return true;
          case 'openUrl':
            return true;
          case 'canUseFullScreenIntent':
            return true;
          case 'deviceInfo':
            return <String, dynamic>{'manufacturer': 'Google'};
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _system,
          null,
        ),
      );
    }

    testWidgets('blocking uninstalling: explained, asked, then shown as on', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAndroid(tester);
      await show(tester);
      await open(tester, 'Permissions');

      const title = 'Block uninstalling while an alarm rings';
      expect(find.text(title), findsOneWidget);
      expect(
        find.text(
          'While on, BrainWake cannot be uninstalled until you switch this '
          'off here.',
        ),
        findsOneWidget,
      );

      // Cancel changes nothing.
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.textContaining('device admin app'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'requestUninstallProtection'),
        isEmpty,
      );

      // Continue opens Android's page.
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'requestUninstallProtection'),
        hasLength(1),
      );

      // The user said yes there; back in the app the switch is read again.
      protectionOn = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text('On. To uninstall BrainWake, switch this off first.'),
        findsOneWidget,
      );

      // Not while an alarm rings.
      alarmRinging = true;
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        find.text('You can switch this off once the alarm is over.'),
        findsOneWidget,
      );
      expect(
        find.text('On. To uninstall BrainWake, switch this off first.'),
        findsOneWidget,
      );

      alarmRinging = false;
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        find.text('On. To uninstall BrainWake, switch this off first.'),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the legal pages open in the browser', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAndroid(tester);
      await show(tester);
      await open(tester, 'Privacy');
      await tester.tap(find.text('Privacy policy'));
      await tester.tap(find.text('Terms & conditions'));
      await tester.pumpAndSettle();
      expect(
        [
          for (final c in calls)
            if (c.method == 'openUrl') (c.arguments as Map)['url'],
        ],
        [ServerConfig.privacyUrl, ServerConfig.termsUrl],
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
