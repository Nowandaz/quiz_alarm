/// The thing that actually rings.
///
/// [NativeAlarmBackend] uses the `alarm` plugin (Android / iOS).
/// [SimulatedAlarmBackend] uses in-app timers and is used where the plugin
/// does not exist: the web "mini emulator", desktop and tests. It keeps its
/// schedule in SharedPreferences so it survives a reload like the real one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_bridge.dart';

/// One alarm to register with the system.
class AlarmRequest {
  final int id;
  final DateTime dateTime;
  final String audioPath;
  final bool vibrate;
  final double volume;
  final double fadeDuration;
  final String title;
  final String body;

  const AlarmRequest({
    required this.id,
    required this.dateTime,
    required this.audioPath,
    required this.title,
    required this.body,
    this.vibrate = true,
    this.volume = 1.0,
    this.fadeDuration = 0,
  });
}

/// "Alarm [id] started ringing."
class AlarmRing {
  final int id;
  final String title;
  const AlarmRing(this.id, this.title);
}

abstract class AlarmBackend {
  /// True when alarms are simulated inside the app (no OS alarm).
  bool get isSimulated;

  Future<void> init();

  /// Fires when an alarm starts ringing, including one that was already
  /// ringing when the app was opened.
  Stream<AlarmRing> get rings;

  /// Registers [request], replacing (and silencing) any alarm with its id.
  Future<void> set(AlarmRequest request);

  /// Cancels alarm [id] and silences it if it is ringing.
  Future<void> stop(int id);

  Future<bool> isRinging(int id);

  /// True when alarm [id] has come due but is not sounding yet because
  /// another alarm is ringing: it waits its turn. Registering it again
  /// now would cancel that ring.
  Future<bool> isWaiting(int id);

  /// When alarm [id] is registered to ring, or null if it is not registered.
  DateTime? scheduledTime(int id);

  /// The right backend for the device the app is running on.
  static AlarmBackend forPlatform() {
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return mobile ? NativeAlarmBackend() : SimulatedAlarmBackend();
  }
}

class NativeAlarmBackend implements AlarmBackend {
  @override
  bool get isSimulated => false;

  @override
  Future<void> init() => Alarm.init();

  /// `Alarm.ringing` always holds the alarms ringing right now (also one
  /// that was already ringing when the app was opened), so turn every id
  /// that newly appears in it into one ring event.
  @override
  late final Stream<AlarmRing> rings = () {
    var known = <int>{};
    return Alarm.ringing.expand((set) {
      final fresh = set.alarms.where((a) => !known.contains(a.id)).toList();
      known = set.alarms.map((a) => a.id).toSet();
      return fresh.map((a) => AlarmRing(a.id, a.notificationSettings.title));
    });
  }();

  @override
  Future<void> set(AlarmRequest r) async {
    final fade = Duration(milliseconds: (r.fadeDuration * 1000).round());
    final accepted = await Alarm.set(
      alarmSettings: AlarmSettings(
        id: r.id,
        dateTime: r.dateTime,
        assetAudioPath: r.audioPath,
        loopAudio: true,
        vibrate: r.vibrate,
        // Played on the phone's ALARM volume, raised to [r.volume] and
        // held there: the volume keys cannot turn it down while it rings.
        volumeSettings: fade > Duration.zero
            ? VolumeSettings.fade(
                volume: r.volume,
                fadeDuration: fade,
                volumeEnforced: true,
              )
            : VolumeSettings.fixed(volume: r.volume, volumeEnforced: true),
        notificationSettings: NotificationSettings(
          title: r.title,
          body: r.body,
          // Swiping the notification away must NOT stop the alarm; only
          // the quiz can. (The plugin puts the notification back.)
          androidStopAlarmOnDismiss: false,
          // The app's own mark (res/drawable*/ic_notification.png).
          icon: 'ic_notification',
          iconColor: const Color(0xFF8AB4F8),
        ),
        // Android alarms keep working after the app is swiped away, so
        // only iOS (where they do not) shows the "may not ring" warning.
        warningNotificationOnKill: defaultTargetPlatform == TargetPlatform.iOS,
        // Swiping the app away must not silence a ringing alarm.
        androidStopAlarmOnTermination: false,
        // Turns the screen on and shows the quiz over the lock screen.
        androidFullScreenIntent: true,
        // Two alarms may share a time, and an alarm that comes due while
        // another is ringing waits its turn. Without this the plugin
        // silently drops the second one.
        allowSameSecondScheduling: true,
        // An alarm more than 15 minutes late when the phone starts is
        // dropped rather than rung late. That is safe because every
        // weekday of a repeating alarm has its own registration (see
        // AlarmProvider), so a missed day does not affect the others.
        androidStaleAfter: const Duration(minutes: 15),
      ),
    );
    if (!accepted) {
      throw StateError('The phone refused to register alarm ${r.id}');
    }
    // A second wake-up a few seconds later, which rings the alarm again
    // if the phone closed the app while it rang. It ends by itself once
    // the alarm has been answered.
    await SystemBridge.watchRing(r.id, r.dateTime);
  }

  @override
  Future<void> stop(int id) async {
    await Alarm.stop(id);
  }

  @override
  Future<bool> isRinging(int id) => Alarm.isRinging(id);

  @override
  Future<bool> isWaiting(int id) async {
    try {
      final stored = await Alarm.getAlarm(id);
      if (stored == null) return false;
      // Only a recent one: an old leftover must never stop an alarm from
      // being registered again.
      final late = DateTime.now().difference(stored.dateTime);
      return !late.isNegative && late < const Duration(minutes: 30);
    } catch (_) {
      return false;
    }
  }

  @override
  DateTime? scheduledTime(int id) {
    for (final a in Alarm.scheduled.value.alarms) {
      if (a.id == id) return a.dateTime;
    }
    return null;
  }
}

class SimulatedAlarmBackend implements AlarmBackend {
  static const String _prefKey = 'simulated_alarms';

  /// Whether screens point out that alarms are simulated (the hint and
  /// the "ring now" bell). Off only when the app is filmed for a demo.
  static bool showHints = true;

  /// Set to false in tests so no audio plugin is touched.
  final bool playSound;

  SimulatedAlarmBackend({this.playSound = true});

  final StreamController<AlarmRing> _rings =
      StreamController<AlarmRing>.broadcast();
  final Map<int, AlarmRequest> _scheduled = {};
  final Map<int, Timer> _timers = {};
  final Set<int> _ringing = {};
  final List<AlarmRing> _backlog = [];
  AudioPlayer? _player;

  @override
  bool get isSimulated => true;

  @override
  Stream<AlarmRing> get rings async* {
    // Hand over rings that happened before anyone listened.
    while (_backlog.isNotEmpty) {
      yield _backlog.removeAt(0);
    }
    yield* _rings.stream;
  }

  @override
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null) return;
      final now = DateTime.now();
      for (final e in jsonDecode(raw) as List) {
        final r = AlarmRequest(
          id: e['id'] as int,
          dateTime: DateTime.fromMillisecondsSinceEpoch(e['at'] as int),
          audioPath: e['audio'] as String,
          title: e['title'] as String,
          body: e['body'] as String,
        );
        // A real alarm keeps ringing while the app is closed, so one
        // whose time has passed is treated as still ringing; future ones
        // are re-armed.
        if (r.dateTime.isAfter(now)) {
          _arm(r);
        } else {
          _scheduled[r.id] = r;
          _fire(r);
        }
      }
    } catch (e) {
      debugPrint('Simulated alarms could not be restored: $e');
    }
  }

  void _arm(AlarmRequest r) {
    _scheduled[r.id] = r;
    _timers[r.id]?.cancel();
    final wait = r.dateTime.difference(DateTime.now());
    _timers[r.id] = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => _fire(r),
    );
  }

  void _fire(AlarmRequest r) {
    _ringing.add(r.id);
    final ring = AlarmRing(r.id, r.title);
    if (_rings.hasListener) {
      _rings.add(ring);
    } else {
      _backlog.add(ring);
    }
    if (playSound) unawaited(_startSound(r));
  }

  Future<void> _startSound(AlarmRequest r) async {
    try {
      final player = _player ??= AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      final path = r.audioPath;
      await player.play(
        path.startsWith('assets/')
            ? AssetSource(path.substring('assets/'.length))
            : DeviceFileSource(path),
        volume: r.volume,
      );
    } catch (e) {
      debugPrint('Simulated alarm sound failed: $e');
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode([
        for (final r in _scheduled.values)
          {
            'id': r.id,
            'at': r.dateTime.millisecondsSinceEpoch,
            'audio': r.audioPath,
            'title': r.title,
            'body': r.body,
          },
      ]),
    );
  }

  @override
  Future<void> set(AlarmRequest request) async {
    await stop(request.id);
    _arm(request);
    await _save();
  }

  @override
  Future<void> stop(int id) async {
    _timers.remove(id)?.cancel();
    _scheduled.remove(id);
    final wasRinging = _ringing.remove(id);
    if (wasRinging && _ringing.isEmpty) {
      try {
        await _player?.stop();
      } catch (_) {}
    }
    await _save();
  }

  @override
  Future<bool> isRinging(int id) async => _ringing.contains(id);

  @override
  Future<bool> isWaiting(int id) async => false;

  @override
  DateTime? scheduledTime(int id) => _scheduled[id]?.dateTime;
}
