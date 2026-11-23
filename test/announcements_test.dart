import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/services/announcements.dart';
import 'package:quiz_alarm/services/entitlements.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  late List<String> notices;
  late List<Uri> asked;
  var clock = DateTime(2026, 11, 24, 8);
  var rows = <Map<String, dynamic>>[];

  Map<String, dynamic> row(int id, String title, {String? expires}) => {
    'id': id,
    'title': title,
    'body': 'Body $id',
    'link': '',
    'published_at': '2026-11-2${id}T06:00:00Z',
    'expires_at': expires,
  };

  setUp(() async {
    await resetApp();
    SharedPreferences.setMockInitialValues({});
    Announcements.resetForTest();
    notices = [];
    asked = [];
    rows = [];
    clock = DateTime(2026, 11, 24, 8);
    Announcements.now = () => clock;
    Announcements.showNotice =
        ({required int id, required String title, required String body}) async {
          notices.add(title);
          return true;
        };
    Announcements.httpClient = MockClient((request) async {
      asked.add(request.url);
      return http.Response(jsonEncode(rows), 200);
    });
  });
  tearDown(() => Entitlements.instance.setForTest(null));

  test('old messages are not news on a phone that just got the app', () async {
    rows = [row(2, 'Second'), row(1, 'First')];
    await Announcements.run();
    expect(Announcements.all.value.map((a) => a.title), ['Second', 'First']);
    expect(Announcements.unread.value, isNull);
    expect(notices, isEmpty);
  });

  test('a new message is notified once, shown as unread, then read', () async {
    rows = [row(1, 'First')];
    await Announcements.run();
    rows = [row(2, 'Pharmacology topics uploaded'), row(1, 'First')];
    clock = clock.add(const Duration(hours: 4));
    await Announcements.run();
    expect(notices, ['Pharmacology topics uploaded']);
    expect(Announcements.unread.value?.title, 'Pharmacology topics uploaded');

    // Again later: no second notification, still unread until dismissed.
    clock = clock.add(const Duration(hours: 4));
    await Announcements.run();
    expect(notices, hasLength(1));
    expect(Announcements.unread.value, isNotNull);

    await Announcements.markRead();
    expect(Announcements.unread.value, isNull);
    // It is kept for the list, also after a restart.
    Announcements.resetForTest();
    Announcements.now = () => clock;
    await Announcements.load();
    expect(Announcements.all.value, hasLength(2));
    expect(Announcements.unread.value, isNull);
  });

  test(
    'it asks at most every few hours, and for the person\'s level',
    () async {
      Entitlements.instance.setForTest(PlanLevel.free);
      await Announcements.run();
      await Announcements.run();
      expect(asked, hasLength(1));
      expect(asked.single.queryParameters['audience'], 'in.(all,free)');
      clock = clock.add(const Duration(hours: 3, minutes: 1));
      Entitlements.instance.setForTest(PlanLevel.ultra);
      await Announcements.run();
      expect(asked.last.queryParameters['audience'], 'in.(all,paid)');
    },
  );

  test('a message past its date is left out', () async {
    rows = [row(1, 'First')];
    await Announcements.run();
    rows = [row(2, 'Ended', expires: '2026-11-23T00:00:00Z'), row(1, 'First')];
    await Announcements.run(force: true);
    expect(Announcements.all.value.map((a) => a.title), ['First']);
    expect(notices, isEmpty);
  });

  test(
    'a phone back after a long time gets three notifications at most',
    () async {
      rows = [row(1, 'One')];
      await Announcements.run();
      rows = [for (var i = 6; i >= 1; i--) row(i, 'Message $i')];
      await Announcements.run(force: true);
      expect(notices, ['Message 4', 'Message 5', 'Message 6']);
    },
  );

  test('no connection changes nothing', () async {
    Announcements.httpClient = MockClient((_) async => throw Exception('off'));
    await Announcements.run();
    expect(Announcements.all.value, isEmpty);
  });
}
