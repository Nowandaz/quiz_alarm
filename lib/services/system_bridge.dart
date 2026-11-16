/// A few Android system calls that Flutter has no plugin for here
/// (implemented in android/.../MainActivity.kt). On every other platform
/// they quietly do nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemBridge {
  static const MethodChannel _channel = MethodChannel('brainwake/system');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> _call(String method, {required bool fallback}) async {
    if (!_android) return fallback;
    try {
      return (await _channel.invokeMethod<bool>(method)) ?? fallback;
    } catch (e) {
      debugPrint('System call $method failed: $e');
      return fallback;
    }
  }

  /// Whether an alarm may open the quiz over the lock screen by itself.
  /// Android 14+ lets the user switch this off ("Full screen
  /// notifications"); when it is off the alarm only shows a notification.
  static Future<bool> canUseFullScreenIntent() =>
      _call('canUseFullScreenIntent', fallback: true);

  /// Opens the system page with the "Full screen notifications" switch.
  static Future<bool> openFullScreenIntentSettings() =>
      _call('openFullScreenIntentSettings', fallback: false);

  /// Brings the app to the screen (used when an alarm rings while the app
  /// is in the background).
  static Future<bool> bringToFront() => _call('bringToFront', fallback: false);
}
