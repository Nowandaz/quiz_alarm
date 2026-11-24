// Errors the app notes for a problem report.
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_alarm/services/crash_log.dart';

import 'helpers.dart';

void main() {
  setUp(resetApp);

  test('the last five errors are kept, newest first, cut to size', () async {
    for (var i = 0; i < 7; i++) {
      await CrashLog.note('error $i ${'x' * 600}', StackTrace.current);
    }
    final list = await CrashLog.recent();
    expect(list, hasLength(CrashLog.keep));
    expect(list.first['error'], startsWith('error 6'));
    expect((list.first['error'] as String).length, 400);
    expect(
      (list.first['stack'] as String).length,
      lessThanOrEqualTo(CrashLog.maxChars),
    );
    expect(list.first['at'], isNotEmpty);
  });

  test('nothing noted: an empty list', () async {
    expect(await CrashLog.recent(), isEmpty);
  });
}
