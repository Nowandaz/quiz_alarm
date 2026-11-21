/// App-wide display settings: dark / light theme, the 12 or 24 hour clock
/// and the digital / analog clock face. Saved on the device.
library;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  bool _use24Hour = false;

  /// True = 18:30, false = 6:30 PM.
  bool get use24Hour => _use24Hour;

  bool _analogClock = false;

  /// True = the home clock shows an analog face.
  bool get analogClock => _analogClock;

  bool _headsUp = true;

  /// True = a vibration and notification five minutes before each alarm.
  bool get headsUp => _headsUp;

  ThemeProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkTheme') ?? true;
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    _use24Hour = prefs.getBool('use24Hour') ?? false;
    _analogClock = prefs.getBool('analogClock') ?? false;
    _headsUp = prefs.getBool('headsUp') ?? true;
    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkTheme', isDark);
  }

  Future<void> setAnalogClock(bool value) async {
    _analogClock = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('analogClock', value);
  }

  Future<void> setHeadsUp(bool value) async {
    _headsUp = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('headsUp', value);
  }

  Future<void> setUse24Hour(bool value) async {
    _use24Hour = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use24Hour', value);
  }
}

/// Clock time in the chosen format: "18:30" or "6:30 PM".
String formatClock(DateTime t, {required bool use24Hour}) =>
    DateFormat(use24Hour ? 'HH:mm' : 'h:mm a').format(t);

/// [formatClock] for a time of day.
String formatTimeOfDay(TimeOfDay t, {required bool use24Hour}) =>
    formatClock(DateTime(2020, 1, 1, t.hour, t.minute), use24Hour: use24Hour);
