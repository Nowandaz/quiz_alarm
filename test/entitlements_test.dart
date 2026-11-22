// What each plan level opens, and when a paid plan locks itself.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/services/account.dart';
import 'package:quiz_alarm/services/entitlements.dart';

import 'helpers.dart';

void main() {
  final plan = Entitlements.instance;
  var clock = DateTime(2026, 11, 1, 8);

  /// A fresh world in which the level is worked out, not fixed.
  Future<void> start({bool signedIn = true}) async {
    await resetApp(signedIn: signedIn);
    clock = DateTime(2026, 11, 1, 8);
    plan
      ..setForTest(null)
      ..now = () => clock;
  }

  Future<void> buy({String tier = 'pro', DateTime? expires}) => plan.apply(
    premium: true,
    tier: tier,
    tierName: tier == 'ultra' ? 'Ultra' : 'Pro',
    expires: expires,
  );

  tearDown(openAllFeatures);

  test('no account is a guest: three alarms, starter topics only', () async {
    await start(signedIn: false);
    expect(plan.level, PlanLevel.guest);
    expect(plan.planName, 'Guest');
    expect(plan.maxAlarms, Entitlements.guestAlarmLimit);
    expect(plan.canAddAlarm(2), isTrue);
    expect(plan.canAddAlarm(3), isFalse);
    expect(plan.canOpenTopic(TopicAccess.guest), isTrue);
    expect(plan.canOpenTopic(TopicAccess.free), isFalse);
    expect(plan.canOpenTopic(TopicAccess.paid), isFalse);
    expect(plan.canUseAi || plan.canSeeTrends || plan.canSetVolume, isFalse);
    expect(plan.needsCheck, isFalse);
    expect(plan.unlockHint, contains('account'));
  });

  test('signed in without a plan is free: any number of alarms, free '
      'topics, no AI, trends or volume', () async {
    await start();
    expect(plan.level, PlanLevel.free);
    expect(plan.maxAlarms, isNull);
    expect(plan.canAddAlarm(50), isTrue);
    expect(plan.canOpenTopic(TopicAccess.free), isTrue);
    expect(plan.canOpenTopic(TopicAccess.paid), isFalse);
    expect(plan.canOpenTopic('something else'), isFalse);
    expect(plan.canUseAi || plan.canSeeTrends || plan.canSetVolume, isFalse);
    expect(plan.unlockHint, 'This is part of Pro.');
  });

  test('a paid plan opens everything; Ultra is told apart', () async {
    await start();
    await buy(expires: clock.add(const Duration(days: 30)));
    expect(plan.level, PlanLevel.pro);
    expect(plan.planName, 'Pro');
    expect(plan.expires, clock.add(const Duration(days: 30)));
    expect(plan.canOpenTopic(TopicAccess.paid), isTrue);
    expect(plan.canUseAi && plan.canSeeTrends && plan.canSetVolume, isTrue);

    await buy(tier: 'ultra');
    expect(plan.level, PlanLevel.ultra);
    expect(plan.isPaid, isTrue);

    // The server says the plan is over.
    await plan.apply(premium: false, tier: '', tierName: '', expires: null);
    expect(plan.level, PlanLevel.free);
    expect(plan.needsCheck, isFalse);
  });

  test('days left are whole days, rounded up; "ends soon" is three days '
      'or less', () async {
    await start(signedIn: false);
    expect(plan.daysLeft, isNull);
    expect(plan.endsSoon, isFalse);

    await start();
    expect(plan.daysLeft, isNull); // free
    await buy(); // no end date
    expect(plan.daysLeft, isNull);
    expect(plan.endsSoon, isFalse);

    final end = clock.add(const Duration(days: 30));
    await buy(expires: end);
    expect(plan.daysLeft, 30);
    expect(plan.endsSoon, isFalse);

    clock = end.subtract(const Duration(days: 3, minutes: 1));
    expect(plan.daysLeft, 4);
    expect(plan.endsSoon, isFalse);

    clock = end.subtract(const Duration(days: 3));
    expect(plan.daysLeft, 3);
    expect(plan.endsSoon, isTrue);

    clock = end.subtract(const Duration(hours: 25));
    expect(plan.daysLeft, 2);
    clock = end.subtract(const Duration(minutes: 1));
    expect(plan.daysLeft, 1);
    expect(plan.endsSoon, isTrue);

    // Past the end, offline: still open, still "ends soon".
    clock = end.add(const Duration(days: 1));
    expect(plan.endingOffline, isTrue);
    expect(plan.daysLeft, 0);
    expect(plan.endsSoon, isTrue);

    // Locked: nothing to announce (the "needs checking" banner shows).
    clock = end.add(const Duration(days: 3, minutes: 1));
    expect(plan.needsCheck, isTrue);
    expect(plan.daysLeft, isNull);
    expect(plan.endsSoon, isFalse);
  });

  test('the plan is remembered across a restart', () async {
    await start();
    await buy(expires: clock.add(const Duration(days: 30)));
    plan.resetForTest();
    plan.now = () => clock;
    expect(plan.level, PlanLevel.free);
    await plan.load();
    expect(plan.level, PlanLevel.pro);
    expect(plan.planName, 'Pro');
  });

  test('another account on the phone does not inherit the plan', () async {
    await start();
    await buy();
    Account.instance.signInForTest(userId: 'someone-else');
    expect(plan.level, PlanLevel.free);
    expect(plan.needsCheck, isFalse);
  });

  test('offline, an ended plan stays open three days and then locks', () async {
    await start();
    final end = clock.add(const Duration(days: 2));
    await buy(expires: end);

    // Just after the end, with no word from the server: still open.
    clock = end.add(const Duration(minutes: 1));
    expect(plan.needsCheck, isFalse);
    expect(plan.level, PlanLevel.pro);
    expect(plan.endingOffline, isTrue);

    clock = end
        .add(const Duration(days: 3))
        .subtract(const Duration(minutes: 1));
    expect(plan.level, PlanLevel.pro);

    // Three days after the end: locked until the app is online.
    clock = end.add(const Duration(days: 3, minutes: 1));
    expect(plan.needsCheck, isTrue);
    expect(plan.endingOffline, isFalse);
    expect(plan.level, PlanLevel.free);
    expect(plan.canSetVolume, isFalse);
    expect(plan.expires, isNull);
    expect(plan.unlockHint, contains('internet'));

    // The server confirms a renewal: open again.
    await buy(expires: clock.add(const Duration(days: 30)));
    expect(plan.needsCheck, isFalse);
    expect(plan.level, PlanLevel.pro);
  });

  test('online, an ended plan locks as soon as the server says so', () async {
    await start();
    final end = clock.add(const Duration(days: 2));
    await buy(expires: end);
    clock = end.add(const Duration(minutes: 1));
    await plan.apply(premium: false, tier: '', tierName: '', expires: null);
    expect(plan.level, PlanLevel.free);
    expect(plan.needsCheck, isFalse);
  });

  test('a running plan does not lock for being offline', () async {
    await start();
    await buy(expires: clock.add(const Duration(days: 30)));
    clock = clock.add(const Duration(days: 20));
    expect(plan.needsCheck, isFalse);
    expect(plan.level, PlanLevel.pro);
  });

  test('a plan with no end date locks after 3 days without a check', () async {
    await start();
    await buy(); // no end date
    clock = clock.add(const Duration(days: 3));
    expect(plan.needsCheck, isFalse);
    expect(plan.level, PlanLevel.pro);
    clock = clock.add(const Duration(minutes: 1));
    expect(plan.needsCheck, isTrue);
    expect(plan.level, PlanLevel.free);
  });

  test('a clock turned back locks the plan', () async {
    await start();
    await buy(expires: clock.add(const Duration(days: 30)));
    clock = clock.subtract(const Duration(minutes: 5)); // a small correction
    expect(plan.needsCheck, isFalse);
    clock = clock.subtract(const Duration(days: 3));
    expect(plan.needsCheck, isTrue);
    expect(plan.level, PlanLevel.free);
  });

  test('a saved plan that cannot be read leaves the level free', () async {
    await start();
    FlutterSecureStorage.setMockInitialValues({'entitlement': 'not json'});
    await plan.load();
    expect(plan.level, PlanLevel.free);
  });
}
