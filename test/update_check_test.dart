import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quiz_alarm/services/update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  late List<String> notices;
  late int calls;
  var clock = DateTime(2026, 11, 23, 8);

  void serve(String version, {String notes = 'Fixes.'}) {
    UpdateCheck.httpClient = MockClient((request) async {
      calls++;
      expect(request.url.path, '/rest/v1/app_releases');
      return http.Response(
        jsonEncode([
          {'version': version, 'notes': notes},
        ]),
        200,
      );
    });
  }

  setUp(() async {
    await resetApp();
    SharedPreferences.setMockInitialValues({});
    notices = [];
    calls = 0;
    clock = DateTime(2026, 11, 23, 8);
    UpdateCheck.available.value = null;
    UpdateCheck.now = () => clock;
    UpdateCheck.installedVersion = () async => '1.0.0';
    UpdateCheck.showNotice =
        ({required int id, required String title, required String body}) async {
          notices.add(body);
          return true;
        };
  });

  test('versions compare by their numbers', () {
    expect(UpdateCheck.isNewer('1.0.1', '1.0.0'), isTrue);
    expect(UpdateCheck.isNewer('1.0.10', '1.0.9'), isTrue);
    expect(UpdateCheck.isNewer('1.1', '1.0.9'), isTrue);
    expect(UpdateCheck.isNewer('1.0.0', '1.0.0+7'), isFalse);
    expect(UpdateCheck.isNewer('1.0.0', '1.0.1'), isFalse);
    expect(UpdateCheck.isNewer('nonsense', '1.0.0'), isFalse);
  });

  test('a newer version shows the banner and one notification', () async {
    serve('1.0.1', notes: 'Alarms stop after ten minutes.');
    await UpdateCheck.run();
    expect(UpdateCheck.available.value?.version, '1.0.1');
    expect(
      UpdateCheck.available.value?.notes,
      'Alarms stop after ten minutes.',
    );
    expect(notices, hasLength(1));
    expect(notices.single, contains('1.0.1'));

    // Later the same day: not asked again; the next day: asked, but no
    // second notification for the same version.
    await UpdateCheck.run();
    expect(calls, 1);
    clock = clock.add(const Duration(hours: 13));
    await UpdateCheck.run();
    expect(calls, 2);
    expect(notices, hasLength(1));
  });

  test('the installed version, or an older one, shows nothing', () async {
    serve('1.0.0');
    await UpdateCheck.run();
    expect(UpdateCheck.available.value, isNull);
    expect(notices, isEmpty);
  });

  test('"Later" hides the banner until a newer version still', () async {
    serve('1.0.1');
    await UpdateCheck.run();
    await UpdateCheck.dismiss();
    expect(UpdateCheck.available.value, isNull);
    await UpdateCheck.run(force: true);
    expect(UpdateCheck.available.value, isNull);

    serve('1.0.2');
    await UpdateCheck.run(force: true);
    expect(UpdateCheck.available.value?.version, '1.0.2');
    expect(notices, hasLength(2));
  });

  test('no connection changes nothing and is tried again', () async {
    UpdateCheck.httpClient = MockClient(
      (_) async => throw Exception('offline'),
    );
    await UpdateCheck.run();
    expect(UpdateCheck.available.value, isNull);
    serve('1.0.1');
    await UpdateCheck.run();
    expect(UpdateCheck.available.value?.version, '1.0.1');
  });
}
