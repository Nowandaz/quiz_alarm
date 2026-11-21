package com.example.quiz_alarm

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * A doorway with no screen of its own. It receives two things from outside
 * the app, keeps them for the Dart side (see MainActivity), brings the app
 * to the screen the same way tapping its icon would, and closes:
 *  - the brainwake://auth?... link the browser opens after Google sign-in;
 *  - "Skip this alarm" tapped on the heads-up notification.
 */
class AuthRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        if (received != null && received.action == PreAlarmReceiver.ACTION_SKIP) {
            val alarmId = received.getIntExtra("alarm_id", 0)
            MainActivity.pendingSkipAlarm = alarmId
            try {
                val manager =
                    getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(PreAlarmReceiver.notificationId(alarmId))
            } catch (e: Exception) {
            }
        } else {
            MainActivity.pendingAuthLink = received?.data?.toString()
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
