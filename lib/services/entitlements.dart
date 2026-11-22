/// What the person using the app is allowed to do, by plan.
///
/// There are four levels:
/// - **guest**: no account. Up to three alarms and the two starter topics
///   that ship with the app.
/// - **free**: signed in, no paid plan. Unlimited alarms and two more
///   topics; the AI, trends and the rest of the question bank are locked.
/// - **pro** and **ultra**: paid plans. Everything, including choosing an
///   alarm's volume. (Ultra differs on the server: a higher AI allowance.)
///
/// A paid plan is only trusted for as long as the server said it runs.
/// The app remembers when the plan ends and asks the server again at that
/// moment. Online, an ended plan locks at once. Offline (the plan may
/// have been renewed, and the phone cannot know), the paid features stay
/// open for three more days and then lock until the app has reached the
/// server again ([needsCheck]). So a phone kept offline cannot keep a plan
/// that has run out. A plan with no end date is re-checked every three
/// days for the same reason.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'account.dart';
import 'billing.dart';

enum PlanLevel { guest, free, pro, ultra }

/// Who may use a topic of the question bank (set per topic on the admin
/// site): anyone, anyone with an account, or paid plans only.
class TopicAccess {
  static const String guest = 'guest';
  static const String free = 'free';
  static const String paid = 'paid';
}

class Entitlements extends ChangeNotifier {
  Entitlements._() {
    Account.instance.addListener(_accountChanged);
    Billing.changes.addListener(refresh);
  }
  static final Entitlements instance = Entitlements._();

  /// Alarms a guest may have.
  static const int guestAlarmLimit = 3;

  /// How long after a plan's end the paid features stay open when the
  /// app cannot reach the server.
  static const Duration offlineGrace = Duration(days: 3);

  /// How long a plan WITHOUT an end date is trusted without hearing from
  /// the server.
  static const Duration recheckEvery = Duration(days: 3);

  static const String _storageKey = 'entitlement';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  // What the server last said, and when.
  String _user = '';
  String _tier = '';
  String _tierName = '';
  bool _premium = false;
  DateTime? _expires;
  DateTime _checkedAt = DateTime.fromMillisecondsSinceEpoch(0);
  // The latest moment this phone's clock was seen at, to notice a clock
  // turned back to stretch a plan.
  DateTime _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _expiryTimer;
  PlanLevel? _forced; // tests only

  /// The clock; tests replace it.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// The time by the clock the plan is judged with.
  DateTime get time => now();

  // ------------------------------------------------------------------ level

  bool get _hasStoredPlan =>
      Account.instance.isSignedIn &&
      _user == Account.instance.userId &&
      _premium;

  /// True when a paid plan is remembered but cannot be trusted right now:
  /// it ended more than [offlineGrace] ago, it has no end date and has
  /// not been confirmed for too long, or the phone's clock was turned
  /// back. Paid features are locked until the
  /// app reaches the server ([refresh]).
  bool get needsCheck {
    if (_forced != null || !_hasStoredPlan) return false;
    final t = now();
    final end = _expires;
    if (end != null) {
      if (!t.isBefore(end.add(offlineGrace))) return true;
    } else if (t.difference(_checkedAt) > recheckEvery) {
      return true;
    }
    if (t.isBefore(_lastSeen.subtract(const Duration(minutes: 10)))) {
      return true;
    }
    return false;
  }

  PlanLevel get level {
    if (_forced != null) return _forced!;
    if (!Account.instance.isSignedIn) return PlanLevel.guest;
    if (!_hasStoredPlan || needsCheck) return PlanLevel.free;
    return _tier == 'ultra' ? PlanLevel.ultra : PlanLevel.pro;
  }

  bool get isGuest => level == PlanLevel.guest;
  bool get isPaid => level.index >= PlanLevel.pro.index;

  /// "Pro", "Ultra", "Free" or "Guest", for showing.
  String get planName => switch (level) {
    PlanLevel.guest => 'Guest',
    PlanLevel.free => 'Free',
    _ => _tierName.isEmpty ? 'Premium' : _tierName,
  };

  /// When the paid plan ends (null: not on one, or it has no end date).
  DateTime? get expires => isPaid ? _expires : null;

  /// True in the days after the plan's end while the app has not been
  /// able to ask the server: still open, but about to lock.
  bool get endingOffline {
    final end = _expires;
    return _forced == null &&
        _hasStoredPlan &&
        end != null &&
        !now().isBefore(end) &&
        !needsCheck;
  }

  /// Plans ending within this many days are announced ([endsSoon]).
  static const int endsSoonDays = 3;

  /// Whole days until the paid plan ends, rounding up (a plan with one
  /// hour left has 1 day left; 0 at or after its end). Null when not on a
  /// paid plan or it has no end date.
  int? get daysLeft {
    final end = expires;
    if (end == null) return null;
    final left = end.difference(now());
    if (left <= Duration.zero) return 0;
    return (left.inMicroseconds / Duration.microsecondsPerDay).ceil();
  }

  /// True when a paid plan ends in [endsSoonDays] days or less, or has
  /// ended but is still open because the server could not be asked
  /// ([endingOffline]).
  bool get endsSoon {
    final days = daysLeft;
    return days != null && days <= endsSoonDays;
  }

  // ------------------------------------------------------------ what's open

  /// How many alarms may exist (null = no limit).
  int? get maxAlarms => isGuest ? guestAlarmLimit : null;

  bool canAddAlarm(int existing) => maxAlarms == null || existing < maxAlarms!;

  /// New questions from the AI, the tutor and AI marking.
  bool get canUseAi => isPaid;

  /// Trends and detailed figures in Reports (overall accuracy is for all).
  bool get canSeeTrends => isPaid;

  /// Choosing (and locking) an alarm's own volume. Without it every alarm
  /// rings at full volume.
  bool get canSetVolume => isPaid;

  /// Whether a topic with this access setting is open at this level.
  bool canOpenTopic(String access) => switch (access) {
    TopicAccess.guest => true,
    TopicAccess.free => !isGuest,
    _ => isPaid,
  };

  /// One short sentence saying what would open a locked thing.
  String get unlockHint => isGuest
      ? 'Create a free account to unlock this.'
      : needsCheck
      ? 'Connect to the internet so your plan can be checked.'
      : 'This is part of Pro.';

  // ---------------------------------------------------------------- storage

  Future<void> load() async {
    try {
      final raw = await _secure.read(key: _storageKey);
      if (raw != null) {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        _user = '${d['user'] ?? ''}';
        _tier = '${d['tier'] ?? ''}';
        _tierName = '${d['tier_name'] ?? ''}';
        _premium = d['premium'] == true;
        _expires = d['expires'] is int
            ? DateTime.fromMillisecondsSinceEpoch(d['expires'] as int)
            : null;
        _checkedAt = DateTime.fromMillisecondsSinceEpoch(
          (d['checked_at'] as int?) ?? 0,
        );
        _lastSeen = DateTime.fromMillisecondsSinceEpoch(
          (d['last_seen'] as int?) ?? 0,
        );
      }
    } catch (e) {
      debugPrint('Reading the saved plan failed: $e');
    }
    await _touchClock();
    _armTimer();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await _secure.write(
        key: _storageKey,
        value: jsonEncode({
          'user': _user,
          'tier': _tier,
          'tier_name': _tierName,
          'premium': _premium,
          'expires': _expires?.millisecondsSinceEpoch,
          'checked_at': _checkedAt.millisecondsSinceEpoch,
          'last_seen': _lastSeen.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      debugPrint('Saving the plan failed: $e');
    }
  }

  /// Notes the current time as "seen", unless the clock went backwards.
  Future<void> _touchClock() async {
    final t = now();
    if (t.isAfter(_lastSeen)) {
      _lastSeen = t;
      await _save();
    }
  }

  // ----------------------------------------------------------------- server

  /// Records what the server says the account's plan is.
  Future<void> apply({
    required bool premium,
    required String tier,
    required String tierName,
    required DateTime? expires,
  }) async {
    final before = level;
    _user = Account.instance.userId ?? '';
    _premium = premium;
    _tier = premium ? tier : '';
    _tierName = premium ? tierName : '';
    _expires = premium ? expires : null;
    _checkedAt = now();
    _lastSeen = _checkedAt;
    await _save();
    _armTimer();
    if (level != before || before == PlanLevel.free) notifyListeners();
  }

  Future<void>? _refreshing;

  /// Asks the server for the account's plan. Safe to call often; does
  /// nothing when signed out, and keeps what it had when offline.
  Future<void> refresh() {
    if (_forced != null || !Account.instance.isSignedIn) {
      return Future.value();
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    try {
      final offer = await Billing.plans();
      await apply(
        premium: offer.premium,
        tier: offer.tier,
        tierName: offer.tierName,
        expires: offer.expires,
      );
    } catch (e) {
      debugPrint('Could not check the plan: $e');
      await _touchClock();
    }
  }

  /// At the moment the plan ends, asks the server (it may have been
  /// renewed; if not, the server's answer locks the paid features). With
  /// no answer, they lock when the offline days are over.
  void _armTimer() {
    _expiryTimer?.cancel();
    final end = _expires;
    if (!_hasStoredPlan || end == null) return;
    final t = now();
    final next = t.isBefore(end) ? end : end.add(offlineGrace);
    final wait = next.difference(t);
    if (wait.isNegative || wait > const Duration(days: 20)) return;
    _expiryTimer = Timer(wait + const Duration(seconds: 1), () {
      notifyListeners();
      _armTimer();
      refresh();
    });
  }

  void _accountChanged() {
    notifyListeners();
    refresh();
  }

  // ------------------------------------------------------------------ tests

  /// Fixes the level without any server or storage (tests only). Null
  /// goes back to working it out.
  @visibleForTesting
  void setForTest(PlanLevel? level) {
    _forced = level;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _forced = null;
    _user = _tier = _tierName = '';
    _premium = false;
    _expires = null;
    _checkedAt = _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
    _expiryTimer?.cancel();
    now = DateTime.now;
  }
}
