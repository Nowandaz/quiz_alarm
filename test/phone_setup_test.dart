// The "Set up this phone" guide: the right steps for each make of phone.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/screens/phone_setup_screen.dart';
import 'package:quiz_alarm/services/phone_setup.dart';

import 'helpers.dart';

void main() {
  setUp(resetApp);

  test('each make of phone gets its own guide', () {
    expect(PhoneSetup.guideFor('Xiaomi'), PhoneSetup.xiaomi);
    expect(PhoneSetup.guideFor('POCO'), PhoneSetup.xiaomi);
    expect(PhoneSetup.guideFor('TECNO MOBILE LIMITED'), PhoneSetup.transsion);
    expect(PhoneSetup.guideFor('INFINIX'), PhoneSetup.transsion);
    expect(PhoneSetup.guideFor('OPPO'), PhoneSetup.oppo);
    expect(PhoneSetup.guideFor('realme'), PhoneSetup.oppo);
    expect(PhoneSetup.guideFor('vivo'), PhoneSetup.vivo);
    expect(PhoneSetup.guideFor('HONOR'), PhoneSetup.huawei);
    expect(PhoneSetup.guideFor('samsung'), PhoneSetup.samsung);
    expect(PhoneSetup.guideFor('Google'), PhoneSetup.other);
    expect(PhoneSetup.guideFor(''), PhoneSetup.other);
  });

  test('every step says where the setting is and what to choose', () {
    for (final g in [
      PhoneSetup.xiaomi,
      PhoneSetup.transsion,
      PhoneSetup.oppo,
      PhoneSetup.vivo,
      PhoneSetup.huawei,
      PhoneSetup.samsung,
      PhoneSetup.other,
    ]) {
      expect(g.steps, isNotEmpty);
      expect(g.steps.map((s) => s.title).toSet(), hasLength(g.steps.length));
      for (final s in g.steps) {
        expect(s.where.length, greaterThan(15), reason: s.title);
        expect(s.choose.length, greaterThan(10), reason: s.title);
      }
    }
  });

  test('ticked steps are remembered', () async {
    await PhoneSetup.setDone('Switch on Autostart', true);
    expect(await PhoneSetup.doneSteps(), {'Switch on Autostart'});
    await PhoneSetup.setDone('Switch on Autostart', false);
    expect(await PhoneSetup.doneSteps(), isEmpty);
  });

  testWidgets('the screen lists the steps with a way to tick them', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PhoneSetupScreen()));
    for (
      var i = 0;
      i < 25 && find.text("Permissions").evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
    }
    // The phone's own permissions come first, then the maker's steps.
    expect(find.text('Permissions'), findsOneWidget);
    // Not an Android phone in tests: the general guide.
    expect(find.textContaining('Stop the battery saver'), findsOneWidget);
    expect(find.text('Open settings'), findsWidgets);
    await tester.tap(find.byType(Checkbox).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(await tester.runAsync(PhoneSetup.doneSteps), hasLength(1));
  });
}
