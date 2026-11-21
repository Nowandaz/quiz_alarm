// The saved display settings (theme choice) and the wording the alarm
// editor builds from an alarm's values.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quiz_alarm/models/models.dart';
import 'package:quiz_alarm/services/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  group('theme', () {
    Future<ThemeMode> saved(Map<String, Object> prefs) async {
      await resetApp(prefs: prefs);
      return ThemeProvider.readThemeMode(await SharedPreferences.getInstance());
    }

    test('nothing saved means dark, as before', () async {
      expect(await saved({}), ThemeMode.dark);
    });

    test('the old yes/no setting is still honoured', () async {
      expect(await saved({'isDarkTheme': true}), ThemeMode.dark);
      expect(await saved({'isDarkTheme': false}), ThemeMode.light);
    });

    test('the three-way choice wins over the old setting', () async {
      expect(await saved({'themeMode': 'light'}), ThemeMode.light);
      expect(await saved({'themeMode': 'dark'}), ThemeMode.dark);
      expect(
        await saved({'themeMode': 'system', 'isDarkTheme': false}),
        ThemeMode.system,
      );
      // Something unreadable falls back to the old setting.
      expect(
        await saved({'themeMode': 'purple', 'isDarkTheme': false}),
        ThemeMode.light,
      );
    });

    test('a choice is saved and read back after a restart', () async {
      await resetApp(prefs: {'isDarkTheme': false});
      final settings = ThemeProvider();
      await settings.setThemeMode(ThemeMode.system);
      expect(settings.themeMode, ThemeMode.system);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('themeMode'), 'system');
      expect(ThemeProvider.readThemeMode(prefs), ThemeMode.system);
    });
  });

  group('alarm wording', () {
    test('the days an alarm rings on', () {
      expect(AlarmItem.describeDays(const []), 'Once');
      expect(AlarmItem.describeDays(const [7, 1, 2, 3, 4, 5, 6]), 'Every day');
      expect(AlarmItem.describeDays(const [5, 4, 3, 2, 1]), 'Weekdays');
      expect(AlarmItem.describeDays(const [7, 6]), 'Weekends');
      expect(AlarmItem.describeDays(const [5, 1, 3]), 'Mon, Wed, Fri');
      expect(AlarmItem.describeDays(const [6]), 'Sat');
    });

    test('each difficulty says what it asks for', () {
      expect(AlarmItem.presetStreaks.map(AlarmItem.difficultyName), [
        'Easy',
        'Medium',
        'Hard',
      ]);
      for (final streak in AlarmItem.presetStreaks) {
        expect(
          AlarmItem.difficultyMeaning(streak),
          '$streak correct answers in a row to stop the alarm.',
        );
      }
      expect(AlarmItem.difficultyEffort(AlarmItem.easyStreak), isNotEmpty);
      expect(AlarmItem.difficultyEffort(AlarmItem.mediumStreak), isEmpty);
      expect(AlarmItem.difficultyEffort(AlarmItem.hardStreak), isNotEmpty);
      // "Custom" starts above the hardest preset and ends at the most an
      // alarm accepts.
      expect(AlarmItem.customMinStreak, greaterThan(AlarmItem.hardStreak));
      expect(AlarmItem.customMaxStreak, AlarmItem.maxStreak);
      expect(AlarmItem.difficultyName(AlarmItem.customMinStreak), 'Custom');
    });
  });
}
