/// A few Android system calls that Flutter has no plugin for here
/// (implemented in android/.../MainActivity.kt). On every other platform
/// they quietly do nothing.
library;

import 'dart:async';

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

  /// Opens the phone maker's "autostart" page (falls back to the app's own
  /// settings page).
  static Future<bool> openAutostartSettings() =>
      _call('openAutostartSettings', fallback: false);

  /// Phone makers that only let an app start by itself (after a restart,
  /// or once it was swiped away) if the user allows "autostart" for it.
  /// Android has no way to read that switch, so the app can only ask.
  static const Set<String> _autostartMakers = {
    'xiaomi',
    'redmi',
    'poco',
    'tecno',
    'infinix',
    'itel',
    'oppo',
    'realme',
    'vivo',
    'iqoo',
    'huawei',
    'honor',
    'oneplus',
  };

  static Future<bool> needsAutostart() async {
    if (!_android) return false;
    final maker = '${(await deviceInfo())['manufacturer'] ?? ''}'.toLowerCase();
    return _autostartMakers.any(maker.contains);
  }

  /// Call with true while an alarm is ringing and false once it is over.
  /// While true the screen stays awake (also in power saving mode) and the
  /// quiz may show over the lock screen. While false the app sits behind
  /// the lock screen like any other app.
  static Future<void> setAlarmScreen(bool ringing) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('setAlarmScreen', {'on': ringing});
    } catch (e) {
      debugPrint('setAlarmScreen failed: $e');
    }
  }

  /// Shows a plain notification (for example "Missed alarm"). Tapping it
  /// opens the app. [id] keeps notices of different alarms apart.
  static Future<bool> showNotice({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_android) return false;
    try {
      return (await _channel.invokeMethod<bool>('showNotice', {
            'id': id,
            'title': title,
            'body': body,
          })) ??
          false;
    } catch (e) {
      debugPrint('showNotice failed: $e');
      return false;
    }
  }

  /// Whether "cannot be uninstalled" protection is switched on (the app
  /// is a device admin app).
  static Future<bool> uninstallProtectionOn() =>
      _call('uninstallProtectionOn', fallback: false);

  /// Opens Android's page that asks the user to switch the protection on.
  /// Check [uninstallProtectionOn] when the app comes back.
  static Future<bool> requestUninstallProtection() =>
      _call('requestUninstallProtection', fallback: false);

  /// Switches the protection off. Refused (false) while an alarm rings.
  static Future<bool> removeUninstallProtection() =>
      _call('removeUninstallProtection', fallback: false);

  /// Brings the app to the screen (used when an alarm rings while the app
  /// is in the background).
  static Future<bool> bringToFront() => _call('bringToFront', fallback: false);

  /// Places the "alarm in 5 minutes" notification for alarm [id] at [at]
  /// (replacing an earlier one for the same alarm).
  static Future<void> schedulePreAlarm(
    int id, {
    required DateTime at,
    required DateTime ringAt,
    required String title,
    required String body,
  }) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<bool>('schedulePreAlarm', {
        'id': id,
        'at': at.millisecondsSinceEpoch,
        'ringAt': ringAt.millisecondsSinceEpoch,
        'title': title,
        'body': body,
      });
    } on MissingPluginException {
      // No Android side (tests, other platforms).
    } catch (e) {
      debugPrint('Placing the heads-up notification failed: $e');
    }
  }

  static Future<void> cancelPreAlarm(int id) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<bool>('cancelPreAlarm', {'id': id});
    } on MissingPluginException {
      // No Android side (tests, other platforms).
    } catch (e) {
      debugPrint('Removing the heads-up notification failed: $e');
    }
  }

  /// Android's identifier for this app on this phone (empty when it
  /// cannot be read). It survives uninstalling and reinstalling.
  static Future<String> installKey() async {
    if (!_android) return '';
    try {
      return (await _channel.invokeMethod<String>('installKey')) ?? '';
    } catch (e) {
      debugPrint('Reading the install key failed: $e');
      return '';
    }
  }

  /// Phone model and Android version, for problem reports.
  static Future<Map<String, dynamic>> deviceInfo() async {
    if (!_android) {
      return {'platform': kIsWeb ? 'web' : defaultTargetPlatform.name};
    }
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'deviceInfo',
      );
      return info ?? {};
    } catch (e) {
      debugPrint('Reading the device details failed: $e');
      return {};
    }
  }

  /// Why Android last ended the app (Android 11+), newest first: each
  /// entry has "reason", "at" (ms) and "description". Shows whether the
  /// app was force-stopped or killed to save battery.
  static Future<List<Map<String, dynamic>>> exitReasons() async {
    if (!_android) return const [];
    try {
      final list = await _channel.invokeListMethod<Map>('exitReasons');
      return [for (final m in list ?? const <Map>[]) m.cast<String, dynamic>()];
    } catch (e) {
      debugPrint('Reading the exit reasons failed: $e');
      return const [];
    }
  }

  /// The error noted when the app last crashed in its Android code:
  /// "at" (ms) and "text". Null when it never did.
  static Future<Map<String, dynamic>?> lastCrash() async {
    if (!_android) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('lastCrash');
      return m;
    } catch (e) {
      debugPrint('Reading the last crash failed: $e');
      return null;
    }
  }

  /// Guards an alarm the app has just set: should the phone close the
  /// app (or the app crash) while it rings, Android rings it again within
  /// seconds (RingGuard.kt). [id] is the number the alarm is registered
  /// under and [at] the moment it is due.
  static Future<void> watchRing(int id, DateTime at) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<bool>('watchRing', {
        'id': id,
        'at': at.millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Could not guard alarm $id: $e');
    }
  }

  /// How many times an alarm had to be brought back because the phone
  /// closed the app, and when last ("count", "last_at" in ms).
  static Future<Map<String, dynamic>> ringRevivals() async {
    if (!_android) return const {};
    try {
      return await _channel.invokeMapMethod<String, dynamic>('ringRevivals') ??
          const {};
    } catch (e) {
      return const {};
    }
  }

  /// Opens a web address in the phone's browser. False if it could not.
  static Future<bool> openUrl(String url) async {
    if (!_android) return false;
    try {
      return (await _channel.invokeMethod<bool>('openUrl', {'url': url})) ??
          false;
    } catch (e) {
      debugPrint('Opening the browser failed: $e');
      return false;
    }
  }

  /// Starts passing things the Android side hands over to the app: sign-in
  /// links (brainwake://auth?...) to [onAuthLink], and a tap on "Skip" in
  /// the heads-up notification to [onSkipAlarm] (with the alarm's id).
  /// Covers the one that opened the app and those arriving while it runs.
  static Future<void> listen({
    required void Function(String link) onAuthLink,
    required void Function(int alarmId, DateTime? ringAt) onSkipAlarm,
  }) async {
    if (!_android) return;
    // Android sends "alarm id:ring time in ms". The same tap can arrive
    // twice (once pushed, once fetched); the second is ignored.
    String? lastSkip;
    void skip(Object? value) {
      if (value is! String || value == lastSkip) return;
      lastSkip = value;
      final parts = value.split(':');
      final id = int.tryParse(parts.first);
      final at = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (id == null) return;
      onSkipAlarm(
        id,
        at == null || at <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(at),
      );
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'authLink' && call.arguments is String) {
        onAuthLink(call.arguments as String);
      } else if (call.method == 'skipAlarm') {
        skip(call.arguments);
        // Tell Android it arrived, so it is not handed over again.
        unawaited(_channel.invokeMethod<Object?>('takeSkipAlarm'));
      }
    });
    try {
      final link = await _channel.invokeMethod<String>('takeAuthLink');
      if (link != null) onAuthLink(link);
      skip(await _channel.invokeMethod<Object?>('takeSkipAlarm'));
    } catch (e) {
      debugPrint('Reading what Android handed over failed: $e');
    }
  }
}
