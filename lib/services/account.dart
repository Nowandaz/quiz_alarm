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

import 'google_native.dart';
import 'profile_picture.dart';
import 'server_config.dart';
import 'sync_service.dart';

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

  /// The version (date) of the Terms and Privacy Policy a new account
  /// agrees to. Change it when the legal pages change.
  static const String termsVersion = '2026-11-22';

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
    _recovery = null;
    recovering.value = false;
  }

  // ----------------------------------------------------------------- server

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
    bool put = false,
  }) {
    final uri = Uri.parse('${ServerConfig.supabaseUrl}/auth/v1$path');
    final headers = {
      'Content-Type': 'application/json',
      'apikey': ServerConfig.supabaseKey,
      'Authorization': ?(bearer == null ? null : 'Bearer $bearer'),
    };
    return (put
            ? httpClient.put(uri, headers: headers, body: jsonEncode(body))
            : httpClient.post(uri, headers: headers, body: jsonEncode(body)))
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
      case 'same_password':
        return 'That is your current password. Choose a different one.';
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

  /// Emails a link for setting a new password. Null on success,
  /// otherwise a sentence to show.
  Future<String?> resetPassword(String email) async {
    try {
      final res = await _post(
        // The link in the email opens this app, which then asks for the
        // new password (see completeOAuth and setNewPassword).
        '/recover?redirect_to=${Uri.encodeQueryComponent(oauthRedirect)}',
        {'email': email.trim()},
      );
      return res.statusCode == 200 ? null : _reason(res);
    } catch (e) {
      return _network(e);
    }
  }

  /// Creates an account. The sign-up form only calls this once the
  /// person has agreed to the terms; when (and to which version) is kept
  /// with the account. [now] is for tests.
  Future<SignUpResult> signUp(
    String email,
    String password, {
    DateTime? now,
  }) async {
    try {
      final res = await _post(
        // The confirmation link opens this app, already signed in.
        '/signup?redirect_to=${Uri.encodeQueryComponent(oauthRedirect)}',
        {
          'email': email.trim(),
          'password': password,
          'data': {
            'terms_accepted_at': (now ?? DateTime.now())
                .toUtc()
                .toIso8601String(),
            'terms_version': termsVersion,
          },
        },
      );
      if (res.statusCode != 200) return SignUpResult(error: _reason(res));
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is Map<String, dynamic> && data['access_token'] != null) {
        await _adopt(data);
        return const SignUpResult();
      }
      // For an email that already has an account the server answers as if
      // a new one was made (so strangers cannot test who has an account),
      // but sends no confirmation email. The give-away is an empty
      // "identities" list. Saying "account created" then would leave the
      // person waiting for an email that never comes.
      if (data is Map &&
          data['identities'] is List &&
          (data['identities'] as List).isEmpty) {
        return const SignUpResult(
          error:
              'There is already an account with this email. Sign in instead, '
              'or tap "Forgot password?" on the Sign in tab.',
        );
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

  /// Signs in with the proof Android's own Google account picker gave
  /// (see google_native.dart). Returns null on success, otherwise a
  /// sentence to show.
  Future<String?> signInWithGoogleToken(String idToken) async {
    try {
      final res = await _post('/token?grant_type=id_token', {
        'provider': 'google',
        'id_token': idToken,
      });
      if (res.statusCode != 200) return _reason(res);
      await _adopt(jsonDecode(utf8.decode(res.bodyBytes)));
      return null;
    } catch (e) {
      return _network(e);
    }
  }

  /// Finishes Google sign-in with the link the browser came back with.
  /// Returns null on success, otherwise a sentence to show.
  Future<String?> completeOAuth(Uri link) async {
    final params = {
      ...link.queryParameters,
      if (link.fragment.contains('=')) ...Uri.splitQueryString(link.fragment),
    };
    // A link from an email (confirm the address, or set a new password)
    // arrives already carrying a sign-in.
    final access = params['access_token'];
    final refresh = params['refresh_token'];
    if (access != null && refresh != null) {
      final session = {
        'access_token': access,
        'refresh_token': refresh,
        'expires_in': int.tryParse(params['expires_in'] ?? '') ?? 3600,
      };
      if (params['type'] == 'recovery') {
        // Not signed in yet: first the new password is asked for.
        await _clear();
        _recovery = session;
        recovering.value = true;
        return null;
      }
      return _adoptEmailLink(session);
    }
    // A link from one of our own emails: it carries a one-time code that
    // is exchanged here for the sign-in (so the email never has to show
    // the server's address).
    final tokenHash = params['token_hash'];
    if (tokenHash != null && tokenHash.isNotEmpty) {
      final type = params['type'] ?? 'signup';
      try {
        final res = await _post('/verify', {
          'type': type,
          'token_hash': tokenHash,
        });
        if (res.statusCode != 200) {
          return res.statusCode == 401 || res.statusCode == 403
              ? 'That link has expired or was already used. Ask for a new one.'
              : _reason(res);
        }
        final session = jsonDecode(utf8.decode(res.bodyBytes));
        if (session is! Map<String, dynamic> ||
            session['access_token'] == null) {
          return 'That link could not be used. Ask for a new one.';
        }
        if (type == 'recovery') {
          await _clear();
          _recovery = session;
          recovering.value = true;
          return null;
        }
        return await _adoptEmailLink(session);
      } catch (e) {
        return _network(e);
      }
    }
    if (params['error_code'] == 'otp_expired') {
      return 'That link has expired or was already used. Ask for a new one.';
    }
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

  /// True while a "set a new password" link has been opened and the new
  /// password is still to be typed. The sign-in screen watches this.
  final ValueNotifier<bool> recovering = ValueNotifier<bool>(false);
  Map<String, dynamic>? _recovery;

  /// Signs in with what an emailed link carried, after asking the server
  /// who it belongs to.
  Future<String?> _adoptEmailLink(Map<String, dynamic> session) async {
    try {
      final res = await httpClient
          .get(
            Uri.parse('${ServerConfig.supabaseUrl}/auth/v1/user'),
            headers: {
              'apikey': ServerConfig.supabaseKey,
              'Authorization': 'Bearer ${session['access_token']}',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return _reason(res);
      await _adopt({
        ...session,
        'user': jsonDecode(utf8.decode(res.bodyBytes)),
      });
      return null;
    } catch (e) {
      return _network(e);
    }
  }

  /// Finishes "Forgot password?": saves [password] as the new one and
  /// signs in. Returns null on success, otherwise a sentence to show.
  Future<String?> setNewPassword(String password) async {
    final session = _recovery;
    if (session == null) {
      return 'Open the link in the email again, then choose a password.';
    }
    try {
      final res = await _post(
        '/user',
        {'password': password},
        bearer: session['access_token'] as String,
        put: true,
      );
      if (res.statusCode != 200) return _reason(res);
      _recovery = null;
      recovering.value = false;
      await _adopt({
        ...session,
        'user': jsonDecode(utf8.decode(res.bodyBytes)),
      });
      return null;
    } catch (e) {
      return _network(e);
    }
  }

  /// Gives up on setting a new password (back to the sign-in form).
  void cancelRecovery() {
    _recovery = null;
    recovering.value = false;
  }

  Future<void> signOut() async {
    final token = _accessToken;
    await _clear();
    // So the Google account picker asks again next time.
    unawaited(GoogleNative.forget());
    if (token == null) return;
    try {
      // "local": this phone only. Without it every device signed in to
      // the account (and the admin site) would be signed out as well.
      await _post('/logout?scope=local', const {}, bearer: token);
    } catch (_) {
      // Signed out on this phone either way.
    }
  }

  /// Deletes the account and everything the server holds for it, for
  /// good. On success this phone is signed out and the person's history
  /// is cleared from it, so the next account starts clean (alarms stay:
  /// they belong to the phone). Returns null on success, otherwise a
  /// sentence to show; nothing is changed on the phone when it fails.
  Future<String?> deleteAccount() async {
    final token = await accessToken();
    if (token == null) return _network('signed out or offline');
    // The picture first, while the account can still prove who it is.
    await ProfilePicture.deleteFromServer();
    Future<void> keepPicture() => ProfilePicture.markNeedsUpload();
    try {
      final res = await httpClient
          .post(
            Uri.parse(
              '${ServerConfig.supabaseUrl}/rest/v1/rpc/delete_my_account',
            ),
            headers: {
              'Content-Type': 'application/json',
              'apikey': ServerConfig.supabaseKey,
              'Authorization': 'Bearer $token',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 && res.statusCode != 204) {
        // The account stays, so its picture goes back up with the next sync.
        await keepPicture();
        return _reason(res);
      }
    } catch (e) {
      await keepPicture();
      return _network(e);
    }
    await ProfilePicture.forgetLocal();
    try {
      await SyncService.forgetLocalHistory();
    } catch (e) {
      // The account is gone either way; signing out must still happen.
      debugPrint('Clearing local history failed: $e');
    }
    // No call to the server's sign-out: the account no longer exists.
    await _clear();
    return null;
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
