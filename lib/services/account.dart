/// The user's account: signing up, signing in and out, and keeping the
/// sign-in alive. Talks to Supabase's sign-in service directly over HTTPS.
///
/// An account is required to use the app (the sign-in screen comes first).
/// Alarms that are already set still ring without one, and without
/// internet. The account is what the server knows the user by: syncing
/// progress, the AI, and paid features later.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'server_config.dart';

/// What happened when someone tried to create an account.
class SignUpResult {
  /// Null on success, otherwise a sentence to show.
  final String? error;

  /// True when the account exists but the emailed link must be opened
  /// before signing in.
  final bool needsConfirmation;
  const SignUpResult({this.error, this.needsConfirmation = false});
}

class Account extends ChangeNotifier {
  Account._();
  static final Account instance = Account._();

  static const String _storageKey = 'account_session';
  static const String _verifierKey = 'account_oauth_verifier';

  /// Where the browser sends the user back after Google sign-in (the
  /// Android app claims this address in its manifest).
  static const String oauthRedirect = 'brainwake://auth';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// Tests replace this with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  String? _email;
  String? _userId;
  String? _accessToken;
  String? _refreshToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _refreshing;

  /// Why the last Google sign-in failed, for the sign-in screen to show.
  final ValueNotifier<String?> oauthError = ValueNotifier<String?>(null);

  bool get isSignedIn => _refreshToken != null;
  String? get email => _email;
  String? get userId => _userId;

  // ---------------------------------------------------------------- storage

  /// Reads the saved sign-in at app start.
  Future<void> load() async {
    try {
      final raw = await _secure.read(key: _storageKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _email = data['email'] as String?;
      _userId = data['user_id'] as String?;
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String?;
      _expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (data['expires_at'] as int?) ?? 0,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Reading the saved sign-in failed: $e');
    }
  }

  Future<void> _save() async {
    try {
      if (_refreshToken == null) {
        await _secure.delete(key: _storageKey);
      } else {
        await _secure.write(
          key: _storageKey,
          value: jsonEncode({
            'email': _email,
            'user_id': _userId,
            'access_token': _accessToken,
            'refresh_token': _refreshToken,
            'expires_at': _expiresAt.millisecondsSinceEpoch,
          }),
        );
      }
    } catch (e) {
      debugPrint('Saving the sign-in failed: $e');
    }
  }

  Future<void> _adopt(Map<String, dynamic> session) async {
    final user = session['user'];
    _accessToken = session['access_token'] as String?;
    _refreshToken = session['refresh_token'] as String?;
    final seconds = (session['expires_in'] as num?)?.toInt() ?? 3600;
    _expiresAt = DateTime.now().add(Duration(seconds: seconds));
    if (user is Map) {
      _email = user['email'] as String? ?? _email;
      _userId = user['id'] as String? ?? _userId;
    }
    await _save();
    notifyListeners();
  }

  Future<void> _clear() async {
    _email = _userId = _accessToken = _refreshToken = null;
    await _save();
    notifyListeners();
  }

  /// Puts the app in a signed-in state without a server (tests only).
  @visibleForTesting
  void signInForTest({
    String email = 'test@example.com',
    String userId = 'test-user',
  }) {
    _email = email;
    _userId = userId;
    _accessToken = 'test-token';
    _refreshToken = 'test-refresh';
    _expiresAt = DateTime.now().add(const Duration(hours: 1));
  }

  @visibleForTesting
  void resetForTest() {
    _email = _userId = _accessToken = _refreshToken = null;
    _refreshing = null;
  }

  // ----------------------------------------------------------------- server

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) {
    return httpClient
        .post(
          Uri.parse('${ServerConfig.supabaseUrl}/auth/v1$path'),
          headers: {
            'Content-Type': 'application/json',
            'apikey': ServerConfig.supabaseKey,
            'Authorization': 'Bearer $bearer',
          }..removeWhere((k, v) => v == 'Bearer null'),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
  }

  /// Turns a failed reply into a sentence a person can act on.
  static String _reason(http.Response res) {
    String code = '';
    String message = '';
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is Map) {
        code = '${data['error_code'] ?? data['error'] ?? ''}';
        message =
            '${data['msg'] ?? data['error_description'] ?? data['message'] ?? ''}';
      }
    } catch (_) {}
    switch (code) {
      case 'invalid_credentials':
      case 'invalid_grant':
        return 'Wrong email or password.';
      case 'email_not_confirmed':
        return 'Open the confirmation link we emailed you, then sign in.';
      case 'user_already_exists':
      case 'email_exists':
        return 'There is already an account with this email. Sign in instead.';
      case 'weak_password':
        return 'Choose a longer password (at least 6 characters).';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Too many attempts. Wait a few minutes and try again.';
      case 'email_address_invalid':
      case 'validation_failed':
        return message.isEmpty ? 'Check the email address.' : message;
    }
    if (message.isNotEmpty) return message;
    return 'The server answered ${res.statusCode}. Try again.';
  }

  static String _network(Object e) => e is TimeoutException
      ? 'The server took too long to answer. Check your connection.'
      : 'Could not reach the server. Check your connection.';

  // ---------------------------------------------------------------- actions

  /// Returns null on success, otherwise a sentence to show.
  Future<String?> signIn(String email, String password) async {
    try {
      final res = await _post('/token?grant_type=password', {
        'email': email.trim(),
        'password': password,
      });
      if (res.statusCode != 200) return _reason(res);
      await _adopt(jsonDecode(utf8.decode(res.bodyBytes)));
      return null;
    } catch (e) {
      return _network(e);
    }
  }

  // The web page the emailed "set a new password" link opens.
  static const String _resetPage = 'https://amkausome.onrender.com';

  /// Emails a link for setting a new password. Null on success,
  /// otherwise a sentence to show.
  Future<String?> resetPassword(String email) async {
    try {
      final res = await _post(
        '/recover?redirect_to=${Uri.encodeQueryComponent(_resetPage)}',
        {'email': email.trim()},
      );
      return res.statusCode == 200 ? null : _reason(res);
    } catch (e) {
      return _network(e);
    }
  }

  Future<SignUpResult> signUp(String email, String password) async {
    try {
      final res = await _post(
        '/signup?redirect_to=${Uri.encodeQueryComponent('${ServerConfig.apiUrl}/confirmed')}',
        {'email': email.trim(), 'password': password},
      );
      if (res.statusCode != 200) return SignUpResult(error: _reason(res));
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is Map<String, dynamic> && data['access_token'] != null) {
        await _adopt(data);
        return const SignUpResult();
      }
      return const SignUpResult(needsConfirmation: true);
    } catch (e) {
      return SignUpResult(error: _network(e));
    }
  }

  /// The web address that starts Google sign-in in the browser. A secret
  /// made here is kept on the phone and later proves that the reply
  /// belongs to this request (PKCE).
  Future<String> googleSignInUrl({Random? random}) async {
    final rng = random ?? Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final verifier = List.generate(
      64,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
    await _secure.write(key: _verifierKey, value: verifier);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return Uri.parse('${ServerConfig.supabaseUrl}/auth/v1/authorize')
        .replace(
          queryParameters: {
            'provider': 'google',
            'redirect_to': oauthRedirect,
            'code_challenge': challenge,
            'code_challenge_method': 's256',
          },
        )
        .toString();
  }

  /// Finishes Google sign-in with the link the browser came back with.
  /// Returns null on success, otherwise a sentence to show.
  Future<String?> completeOAuth(Uri link) async {
    final params = {
      ...link.queryParameters,
      if (link.fragment.contains('=')) ...Uri.splitQueryString(link.fragment),
    };
    final code = params['code'];
    if (code == null || code.isEmpty) {
      final reason = params['error_description'] ?? params['error'];
      return reason == null
          ? 'Google sign-in was cancelled.'
          : 'Google sign-in failed: ${reason.replaceAll('+', ' ')}';
    }
    try {
      final verifier = await _secure.read(key: _verifierKey);
      if (verifier == null) {
        return 'Google sign-in was started somewhere else. Try again.';
      }
      final res = await _post('/token?grant_type=pkce', {
        'auth_code': code,
        'code_verifier': verifier,
      });
      if (res.statusCode != 200) return _reason(res);
      await _secure.delete(key: _verifierKey);
      await _adopt(jsonDecode(utf8.decode(res.bodyBytes)));
      return null;
    } catch (e) {
      return _network(e);
    }
  }

  Future<void> signOut() async {
    final token = _accessToken;
    await _clear();
    if (token == null) return;
    try {
      // "local": this phone only. Without it every device signed in to
      // the account (and the admin site) would be signed out as well.
      await _post('/logout?scope=local', const {}, bearer: token);
    } catch (_) {
      // Signed out on this phone either way.
    }
  }

  /// A token that proves who the user is to the server, refreshed when it
  /// is about to run out. Null when signed out or the server cannot be
  /// reached.
  Future<String?> accessToken() {
    if (_refreshToken == null) return Future.value(null);
    final fresh = _expiresAt.isAfter(
      DateTime.now().add(const Duration(seconds: 60)),
    );
    if (fresh && _accessToken != null) return Future.value(_accessToken);
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh() async {
    try {
      final res = await _post('/token?grant_type=refresh_token', {
        'refresh_token': _refreshToken,
      });
      if (res.statusCode == 200) {
        await _adopt(jsonDecode(utf8.decode(res.bodyBytes)));
        return _accessToken;
      }
      // The sign-in was ended on the server (password changed, account
      // removed): forget it here too.
      if (res.statusCode == 400 || res.statusCode == 401) await _clear();
    } catch (e) {
      debugPrint('Refreshing the sign-in failed: $e');
    }
    return null;
  }
}
