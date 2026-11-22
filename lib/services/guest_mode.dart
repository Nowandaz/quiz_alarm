/// Remembers that the person chose "Continue without an account" on the
/// welcome screen, so the app opens straight away the next time.
///
/// The choice is forgotten when they sign in: after signing out again the
/// welcome screen comes back, and offers the same choice once more.
library;

import 'package:shared_preferences/shared_preferences.dart';

class GuestMode {
  static const String pref = 'guest_mode';

  static Future<bool> chosen() async =>
      (await SharedPreferences.getInstance()).getBool(pref) ?? false;

  static Future<void> choose() async =>
      (await SharedPreferences.getInstance()).setBool(pref, true);

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(pref);
}
