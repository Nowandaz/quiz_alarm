package com.example.quiz_alarm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Shows the "alarm in 5 minutes" heads-up: one long vibration and a
 * notification with a "Skip this alarm" button, for someone who is already
 * awake. MainActivity schedules it (schedulePreAlarm); the Skip button
 * opens SkipAlarmActivity, which passes the request on to the app.
 *
 * It knows when the alarm itself rings (ring_at). Delivered late, once the
 * alarm has started, it shows nothing: a Skip tapped then would be about
 * the wrong ring. For the same reason it disappears at ring time.
 */
class PreAlarmReceiver : BroadcastReceiver() {
    companion object {
        const val CHANNEL = "alarm_heads_up"
        const val ACTION_SKIP = "com.example.quiz_alarm.SKIP_ALARM"

        // Kept apart from the alarm plugin's own notification ids.
        @JvmStatic
        fun notificationId(alarmId: Int): Int = 1_500_000_000 + alarmId
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            val alarmId = intent.getIntExtra("alarm_id", 0)
            val ringAt = intent.getLongExtra("ring_at", 0L)
            val untilRing = ringAt - System.currentTimeMillis()
            if (ringAt > 0L && untilRing <= 0L) return
            val title = intent.getStringExtra("title") ?: "Alarm in 5 minutes"
            val body = intent.getStringExtra("body") ?: "Already up? Tap Skip to cancel this one."
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val buzz = longArrayOf(0, 1800)

            if (Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel(
                    CHANNEL, "Alarm heads-up", NotificationManager.IMPORTANCE_HIGH
                )
                channel.description = "A vibration five minutes before an alarm rings"
                channel.enableVibration(true)
                channel.vibrationPattern = buzz
                channel.setSound(null, null)
                manager.createNotificationChannel(channel)
            }

            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val skip = PendingIntent.getActivity(
                context, alarmId,
                Intent(context, SkipAlarmActivity::class.java)
                    .setAction(ACTION_SKIP)
                    .putExtra("alarm_id", alarmId)
                    .putExtra("ring_at", ringAt)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                flags
            )
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val open = if (launch == null) null else PendingIntent.getActivity(context, 0, launch, flags)

            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setVibrate(buzz)
            }
            @Suppress("DEPRECATION")
            val skipAction = Notification.Action.Builder(0, "Skip this alarm", skip).build()
            builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setCategory(Notification.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .addAction(skipAction)
            if (open != null) builder.setContentIntent(open)
            // Gone by itself when the alarm starts.
            if (Build.VERSION.SDK_INT >= 26) {
                builder.setTimeoutAfter(if (ringAt > 0L) untilRing else 5 * 60 * 1000L)
            }

            manager.notify(notificationId(alarmId), builder.build())
        } catch (e: Exception) {
            // A heads-up that cannot be shown must never crash the app.
        }
    }
}
