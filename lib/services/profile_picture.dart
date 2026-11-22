/// The profile picture a signed-in person chose for themselves.
///
/// It is a small copy of a photo from the phone's gallery, kept ON THIS
/// PHONE only (in the app's settings store, one per account). It is not
/// uploaded anywhere, so it does not follow the account to another phone.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';

class ProfilePicture {
  /// The current account's picture (null: none). Screens listen to this.
  static final ValueNotifier<Uint8List?> current = ValueNotifier(null);

  /// Bigger pictures than this are refused (the picker already shrinks
  /// them to a few dozen kilobytes; this is a backstop).
  static const int maxBytes = 400 * 1024;

  /// Picks the photo; tests replace it.
  @visibleForTesting
  static Future<Uint8List?> Function() pick = _pickFromGallery;

  static String? get _key {
    final id = Account.instance.userId;
    return Account.instance.isSignedIn && id != null
        ? 'profile_picture:$id'
        : null;
  }

  /// Reads the picture of whoever is signed in now. Call at startup and
  /// whenever the account changes.
  static Future<void> load() async {
    final key = _key;
    Uint8List? bytes;
    if (key != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(key);
        if (saved != null) bytes = base64Decode(saved);
      } catch (e) {
        debugPrint('Reading the profile picture failed: $e');
      }
    }
    current.value = bytes;
  }

  /// Lets the person choose a photo. Returns a message when it could not
  /// be used, null when it worked or they backed out.
  static Future<String?> choose() async {
    final key = _key;
    if (key == null) return 'Sign in to add a profile picture.';
    try {
      final bytes = await pick();
      if (bytes == null) return null;
      if (bytes.length > maxBytes) return 'That picture is too large.';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, base64Encode(bytes));
      current.value = bytes;
      return null;
    } catch (e) {
      debugPrint('Choosing a profile picture failed: $e');
      return 'Could not open that picture.';
    }
  }

  static Future<void> remove() async {
    final key = _key;
    if (key != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    }
    current.value = null;
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
