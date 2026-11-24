/// Remembers the last few errors the app itself ran into, so a problem
/// report can say what went wrong. Nothing leaves the phone unless the
/// user sends a report (or has diagnostics sharing on).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CrashLog {
  static const String pref = 'app_errors';
  static const int keep = 5;
  static const int maxChars = 1500;

  /// Starts noting errors nothing else caught. Call once at start.
  static void install() {
    final before = FlutterError.onError;
    FlutterError.onError = (details) {
      note(details.exceptionAsString(), details.stack);
      before?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      note('$error', stack);
      return false; // let it be reported as usual too
    };
  }

  /// Adds one error (newest first, the last [keep] are kept). Never throws.
  static Future<void> note(String error, StackTrace? stack) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(pref) ?? <String>[];
      final lines = '${stack ?? ''}'.split('\n').take(12).join('\n');
      list.insert(
        0,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'error': error.length > 400 ? error.substring(0, 400) : error,
          'stack': lines.length > maxChars
              ? lines.substring(0, maxChars)
              : lines,
        }),
      );
      await prefs.setStringList(pref, list.take(keep).toList());
    } catch (_) {}
  }

  /// The noted errors, newest first.
  static Future<List<Map<String, dynamic>>> recent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return [
        for (final raw in prefs.getStringList(pref) ?? const <String>[])
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
      ];
    } catch (_) {
      return const [];
    }
  }
}
