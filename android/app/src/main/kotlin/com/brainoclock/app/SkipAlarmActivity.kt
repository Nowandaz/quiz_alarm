package com.brainoclock.app

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * Opened by "Skip this alarm" on the heads-up notification. It has no
 * screen: it keeps the request for the Dart side (see MainActivity), brings
 * the app to the screen and closes. Other apps cannot start it (not
 * exported), so only our own notification can ask for an alarm to be
 * skipped.
 */
class SkipAlarmActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        if (received != null && received.action == PreAlarmReceiver.ACTION_SKIP) {
            val alarmId = received.getIntExtra("alarm_id", 0)
            val ringAt = received.getLongExtra("ring_at", 0L)
            // "alarm id:ring time", so a late tap cannot skip the wrong ring.
            MainActivity.pendingSkipAlarm = alarmId.toString() + ":" + ringAt.toString()
            try {
                val manager =
                    getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(PreAlarmReceiver.notificationId(alarmId))
            } catch (e: Exception) {
            }
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            launch.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
            startActivity(launch)
        }
        finish()
    }
}
