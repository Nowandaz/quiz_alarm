package com.example.quiz_alarm

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds a few small system calls the Dart side needs (see
 * lib/services/system_bridge.dart):
 *  - canUseFullScreenIntent: may an alarm open the quiz over the lock screen
 *    by itself? (Android 14+ lets the user switch this off per app.)
 *  - openFullScreenIntentSettings: opens the settings page for that switch.
 *  - bringToFront: shows the app when an alarm rings while it is in the
 *    background (needs the "display over other apps" permission).
 *  - openUrl: opens a web address in the browser (Google sign-in).
 *  - takeAuthLink / authLink: hands the brainwake://auth?... link the
 *    browser returns after Google sign-in (caught by AuthRedirectActivity)
 *    to the Dart side.
 *  - schedulePreAlarm / cancelPreAlarm: the "alarm in 5 minutes"
 *    notification (shown by PreAlarmReceiver); takeSkipAlarm / skipAlarm
 *    hand its "Skip" tap to the Dart side.
 *  - deviceInfo / exitReasons: details attached to problem reports.
 */
class MainActivity : FlutterActivity() {
    companion object {
        // The sign-in link the browser came back with (set by
        // AuthRedirectActivity), until the Dart side has taken it.
        @JvmStatic
        var pendingAuthLink: String? = null

        // The alarm whose heads-up notification had "Skip" tapped.
        @JvmStatic
        var pendingSkipAlarm: Int? = null
    }

    private fun preAlarmIntent(id: Int, title: String?, body: String?): PendingIntent {
        val intent = Intent(this, PreAlarmReceiver::class.java)
            .putExtra("alarm_id", id)
            .putExtra("title", title)
            .putExtra("body", body)
        return PendingIntent.getBroadcast(
            this, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private var channel: MethodChannel? = null

    override fun onResume() {
        super.onResume()
        val ch = channel ?: return
        pendingAuthLink?.let {
            pendingAuthLink = null
            ch.invokeMethod("authLink", it)
        }
        pendingSkipAlarm?.let {
            pendingSkipAlarm = null
            ch.invokeMethod("skipAlarm", it)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "brainwake/system")
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        try {
                            val url = call.argument<String>("url") ?: ""
                            val view = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(view)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "takeAuthLink" -> {
                        result.success(pendingAuthLink)
                        pendingAuthLink = null
                    }
                    "takeSkipAlarm" -> {
                        result.success(pendingSkipAlarm)
                        pendingSkipAlarm = null
                    }
                    "schedulePreAlarm" -> {
                        try {
                            val id = call.argument<Int>("id") ?: 0
                            val at = call.argument<Number>("at")?.toLong() ?: 0L
                            val pending = preAlarmIntent(
                                id, call.argument<String>("title"), call.argument<String>("body")
                            )
                            val alarms = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                            val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
                            try {
                                if (exact) {
                                    alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
                                } else {
                                    alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
                                }
                            } catch (e: SecurityException) {
                                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "cancelPreAlarm" -> {
                        try {
                            val id = call.argument<Int>("id") ?: 0
                            val alarms = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                            alarms.cancel(preAlarmIntent(id, null, null))
                            val manager =
                                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            manager.cancel(PreAlarmReceiver.notificationId(id))
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "deviceInfo" -> {
                        result.success(
                            mapOf(
                                "manufacturer" to Build.MANUFACTURER,
                                "model" to Build.MODEL,
                                "android" to Build.VERSION.RELEASE,
                                "sdk" to Build.VERSION.SDK_INT
                            )
                        )
                    }
                    "exitReasons" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= 30) {
                                val manager =
                                    getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                                val list = manager
                                    .getHistoricalProcessExitReasons(packageName, 0, 5)
                                    .map {
                                        mapOf(
                                            "reason" to it.reason,
                                            "at" to it.timestamp,
                                            "description" to (it.description ?: "")
                                        )
                                    }
                                result.success(list)
                            } else {
                                result.success(emptyList<Map<String, Any>>())
                            }
                        } catch (e: Exception) {
                            result.success(emptyList<Map<String, Any>>())
                        }
                    }
                    "canUseFullScreenIntent" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val manager =
                                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            result.success(manager.canUseFullScreenIntent())
                        } else {
                            result.success(true)
                        }
                    }
                    "openFullScreenIntentSettings" -> {
                        try {
                            val intent = if (Build.VERSION.SDK_INT >= 34) {
                                Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")
                                )
                            } else {
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "bringToFront" -> {
                        try {
                            val intent = packageManager.getLaunchIntentForPackage(packageName)
                            if (intent != null) {
                                intent.addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                                )
                                applicationContext.startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
