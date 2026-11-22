/// The profile picture a signed-in person chose for themselves.
///
/// It is a small copy of a photo from the phone's gallery. The phone keeps
/// its own copy (in the app's settings store, one per account) so it shows
/// at once and without internet. The account keeps one too, in a private
/// storage bucket on the server (`avatars/<user id>/avatar.jpg`), so the
/// picture follows the account to another phone.
///
/// A change that could not reach the server is remembered and sent again
/// by the next [sync].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'server_config.dart';

class ProfilePicture {
  /// The current account's picture (null: none). Screens listen to this.
  static final ValueNotifier<Uint8List?> current = ValueNotifier(null);

  /// Bigger pictures than this are refused (the picker already shrinks
  /// them to a few dozen kilobytes; this is a backstop).
  static const int maxBytes = 400 * 1024;

  /// Picks the photo; tests replace it.
  @visibleForTesting
  static Future<Uint8List?> Function() pick = _pickFromGallery;

  /// Talks to the server; tests replace it with a fake.
  @visibleForTesting
  static http.Client httpClient = http.Client();

  static const String _bucket = 'avatars';
  static const String _upload = 'upload';
  static const String _delete = 'delete';

  // The accounts whose server picture was already asked for since the app
  // started, so a sync does not ask again every time.
  static final Set<String> _asked = {};

  static String? get _userId {
    final id = Account.instance.userId;
    return Account.instance.isSignedIn && id != null ? id : null;
  }

  static String _key(String id) => 'profile_picture:$id';

  /// Holds 'upload' or 'delete' while the server still has to hear of a
  /// change.
  static String _pendingKey(String id) => 'profile_picture_pending:$id';

  /// Reads the picture of whoever is signed in now. Call at startup and
  /// whenever the account changes.
  static Future<void> load() async {
    final id = _userId;
    Uint8List? bytes;
    if (id != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(_key(id));
        if (saved != null) bytes = base64Decode(saved);
      } catch (e) {
        debugPrint('Reading the profile picture failed: $e');
      }
    }
    current.value = bytes;
  }

  /// Lets the person choose a photo. It shows at once and is then sent to
  /// the server (if that fails, the next [sync] tries again). Returns a
  /// message when the photo could not be used, null when it worked or
  /// they backed out.
  static Future<String?> choose() async {
    final id = _userId;
    if (id == null) return 'Sign in to add a profile picture.';
    try {
      final bytes = await pick();
      if (bytes == null) return null;
      if (bytes.length > maxBytes) return 'That picture is too large.';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(id), base64Encode(bytes));
      await prefs.setString(_pendingKey(id), _upload);
      current.value = bytes;
      await _flush(id, prefs);
      return null;
    } catch (e) {
      debugPrint('Choosing a profile picture failed: $e');
      return 'Could not open that picture.';
    }
  }

  /// Removes the picture from this phone and from the server (if the
  /// server cannot be reached, the next [sync] tries again).
  static Future<void> remove() async {
    final id = _userId;
    current.value = null;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(id));
      await prefs.setString(_pendingKey(id), _delete);
      await _flush(id, prefs);
    } catch (e) {
      debugPrint('Removing the profile picture failed: $e');
    }
  }

  static Future<void>? _syncing;

  /// Brings the phone and the server in line: sends a change that is
  /// still waiting, or, when this phone has no picture, fetches the
  /// account's one. Call after sign-in, at startup and with the regular
  /// sync. Does nothing when signed out. Never throws.
  static Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  static Future<void> _sync() async {
    try {
      final id = _userId;
      if (id == null) return;
      final prefs = await SharedPreferences.getInstance();
      if (await _flush(id, prefs)) return;
      if (prefs.getString(_key(id)) != null || _asked.contains(id)) return;

      final token = await Account.instance.accessToken();
      if (token == null) return;
      final res = await httpClient
          .get(
            Uri.parse(
              '${ServerConfig.supabaseUrl}/storage/v1/object/authenticated/'
              '$_bucket/$id/avatar.jpg',
            ),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 400 || res.statusCode == 404) {
        _asked.add(id); // no picture on the server
        return;
      }
      if (res.statusCode != 200) return;
      _asked.add(id);
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > maxBytes) return;
      // Chosen or removed here while the download ran: that wins.
      if (prefs.getString(_key(id)) != null ||
          prefs.getString(_pendingKey(id)) != null) {
        return;
      }
      await prefs.setString(_key(id), base64Encode(bytes));
      if (_userId == id) current.value = bytes;
    } catch (e) {
      debugPrint('Syncing the profile picture failed (will try again): $e');
    }
  }

  /// Deletes the server's copy only (the account is about to be deleted).
  /// Best effort: never throws.
  static Future<void> deleteFromServer() async {
    final id = _userId;
    if (id == null) return;
    try {
      await _deleteOnServer(id);
    } catch (e) {
      debugPrint('Deleting the profile picture on the server failed: $e');
    }
  }

  /// Marks this phone's picture (if there is one) to be sent again by the
  /// next [sync].
  static Future<void> markNeedsUpload() async {
    final id = _userId;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_key(id)) != null) {
        await prefs.setString(_pendingKey(id), _upload);
      }
    } catch (e) {
      debugPrint('Could not mark the profile picture for upload: $e');
    }
  }

  /// Forgets this phone's copy and anything waiting to be sent (the
  /// account was deleted).
  static Future<void> forgetLocal() async {
    final id = _userId;
    current.value = null;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(id));
      await prefs.remove(_pendingKey(id));
    } catch (e) {
      debugPrint('Clearing the profile picture failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    current.value = null;
    _asked.clear();
    _syncing = null;
  }

  // ----------------------------------------------------------------- server

  /// Sends the change that is waiting for [id], if any. True when there
  /// was one (sent or not). Never throws.
  static Future<bool> _flush(String id, SharedPreferences prefs) async {
    final pending = prefs.getString(_pendingKey(id));
    if (pending == null) return false;
    try {
      var done = false;
      if (pending == _upload) {
        final saved = prefs.getString(_key(id));
        done = saved == null || await _uploadToServer(id, base64Decode(saved));
      } else {
        done = await _deleteOnServer(id);
      }
      // Only cleared if nothing else was chosen meanwhile.
      if (done && prefs.getString(_pendingKey(id)) == pending) {
        await prefs.remove(_pendingKey(id));
      }
    } catch (e) {
      debugPrint('Sending the profile picture failed (will try again): $e');
    }
    return true;
  }

  static Map<String, String> _headers(String token) => {
    'apikey': ServerConfig.supabaseKey,
    'Authorization': 'Bearer $token',
  };

  static Uri _object(String id) => Uri.parse(
    '${ServerConfig.supabaseUrl}/storage/v1/object/$_bucket/$id/avatar.jpg',
  );

  /// What kind of picture the bytes are, from how they start (null: not
  /// one the server accepts).
  static String? _contentType(Uint8List b) {
    bool starts(List<int> sig, [int at = 0]) {
      if (b.length < at + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[at + i] != sig[i]) return false;
      }
      return true;
    }

    if (starts(const [0xFF, 0xD8])) return 'image/jpeg';
    if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return 'image/png';
    }
    if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
        starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    return null;
  }

  /// True when the server has the picture now, or will never take it
  /// (too large, or a kind it does not accept: such a picture stays on
  /// this phone only), so there is nothing to try again.
  static Future<bool> _uploadToServer(String id, Uint8List bytes) async {
    final type = _contentType(bytes);
    if (type == null) return true;
    final token = await Account.instance.accessToken();
    if (token == null) return false;
    final res = await httpClient
        .post(
          _object(id),
          headers: {
            ..._headers(token),
            'Content-Type': type,
            'x-upsert': 'true',
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode >= 200 && res.statusCode < 300) return true;
    debugPrint('Profile picture: the server answered ${res.statusCode}');
    return res.statusCode == 413 || res.statusCode == 415;
  }

  /// True when the server no longer has the picture.
  static Future<bool> _deleteOnServer(String id) async {
    final token = await Account.instance.accessToken();
    if (token == null) return false;
    final res = await httpClient
        .delete(_object(id), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    // 400/404: there was none.
    return (res.statusCode >= 200 && res.statusCode < 300) ||
        res.statusCode == 400 ||
        res.statusCode == 404;
  }

  static Future<Uint8List?> _pickFromGallery() async {
    // Shrunk while picking: a profile picture is shown small.
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 320,
      maxHeight: 320,
      imageQuality: 80,
    );
    return file?.readAsBytes();
  }
}
