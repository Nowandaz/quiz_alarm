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

  test('when the plan ends it locks and asks for a check', () async {
    await start();
    await buy(expires: clock.add(const Duration(days: 2)));
    clock = clock.add(const Duration(days: 2, minutes: 1));
    expect(plan.needsCheck, isTrue);
    expect(plan.level, PlanLevel.free);
    expect(plan.canSetVolume, isFalse);
    expect(plan.expires, isNull);
    expect(plan.unlockHint, contains('internet'));

    // The server confirms a renewal: open again.
    await buy(expires: clock.add(const Duration(days: 30)));
    expect(plan.needsCheck, isFalse);
    expect(plan.level, PlanLevel.pro);
  });

  test('a plan not confirmed for more than 7 days locks', () async {
    await start();
    await buy(); // no end date
    clock = clock.add(const Duration(days: 7));
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
