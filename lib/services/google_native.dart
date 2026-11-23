/// Google sign-in with Android's own account picker (it shows the app's
/// name and never opens a browser).
///
/// It needs an "Android" client in the Google Cloud project that matches
/// this app's package name and the key the app is signed with. Until that
/// exists, or on a phone without Google Play services, [signIn] answers
/// [GoogleNativeOutcome.unavailable] and the caller falls back to
/// signing in through the browser.
library;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'server_config.dart';

enum GoogleNativeOutcome { signedIn, cancelled, unavailable }

class GoogleNativeResult {
  final GoogleNativeOutcome outcome;

  /// Google's proof of who signed in, to hand to the server.
  final String? idToken;

  /// Why it could not be used (for the log).
  final String? reason;
  const GoogleNativeResult(this.outcome, {this.idToken, this.reason});
}

class GoogleNative {
  /// Only Android has the picker set up.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Does the picking; tests replace it.
  @visibleForTesting
  static Future<GoogleNativeResult> Function() pick = _pick;

  static Future<void>? _ready;

  static Future<GoogleNativeResult> signIn() async {
    if (!supported) {
      return const GoogleNativeResult(
        GoogleNativeOutcome.unavailable,
        reason: 'not Android',
      );
    }
    return pick();
  }

  static Future<GoogleNativeResult> _pick() async {
    try {
      // The "web" client id says which server the proof is meant for.
      _ready ??= GoogleSignIn.instance.initialize(
        serverClientId: ServerConfig.googleWebClientId,
      );
      await _ready;
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        return const GoogleNativeResult(
          GoogleNativeOutcome.unavailable,
          reason: 'Google gave no proof of sign-in',
        );
      }
      return GoogleNativeResult(GoogleNativeOutcome.signedIn, idToken: token);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return const GoogleNativeResult(GoogleNativeOutcome.cancelled);
      }
      _ready = null;
      debugPrint(
        'Native Google sign-in unavailable: ${e.code} ${e.description}',
      );
      return GoogleNativeResult(
        GoogleNativeOutcome.unavailable,
        reason: '${e.code.name}: ${e.description ?? ''}',
      );
    } catch (e) {
      _ready = null;
      debugPrint('Native Google sign-in failed: $e');
      return GoogleNativeResult(GoogleNativeOutcome.unavailable, reason: '$e');
    }
  }

  /// Forgets the chosen Google account, so the picker asks again next
  /// time. Never throws.
  static Future<void> forget() async {
    if (!supported || _ready == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('Forgetting the Google account failed: $e');
    }
  }
}
