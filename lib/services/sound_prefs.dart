/// The "Mute right and wrong sounds" setting: whether the short sounds
/// after each answer in a quiz are played. The alarm sound itself is
/// never affected by this.
library;

import 'package:shared_preferences/shared_preferences.dart';

class SoundPrefs {
  /// Where the setting is saved (a yes/no, off unless switched on).
  static const String muteAnswerSoundsKey = 'muteAnswerSounds';

  static bool _mute = false;

  /// True when the right/wrong sounds should stay silent. Reads what
  /// [load] or [setMuteAnswerSounds] last saw.
  static bool get muteAnswerSounds => _mute;

  /// Reads the saved setting. Call before a quiz starts.
  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _mute = prefs.getBool(muteAnswerSoundsKey) ?? false;
  }

  static Future<void> setMuteAnswerSounds(bool mute) async {
    _mute = mute;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(muteAnswerSoundsKey, mute);
  }
}
