package com.example.quiz_alarm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator

/**
 * Shows the "alarm in 5 minutes" heads-up: three long vibrations and a
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
        // "v2": a channel's settings cannot be changed once created, and the
        // first version let the channel do the (single) vibration.
        const val CHANNEL = "alarm_heads_up_v2"
        private const val OLD_CHANNEL = "alarm_heads_up"

        // Three long buzzes in a row (wait, buzz, pause, buzz, pause, buzz).
        private val BUZZ = longArrayOf(0, 1500, 500, 1500, 500, 1500)
        const val ACTION_SKIP = "com.example.quiz_alarm.SKIP_ALARM"

        // Kept apart from the alarm plugin's own notification ids.
        @JvmStatic
        fun notificationId(alarmId: Int): Int = 1_500_000_000 + alarmId
    }

    /**
     * Three long vibrations, sent as an alarm. Alarm vibrations go through
     * even when the phone is on silent or its vibration settings are off,
     * the same way an alarm clock still sounds on a silenced phone.
     */
    private fun buzz(context: Context) {
        try {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator? ?: return
            if (!vibrator.hasVibrator()) return
            if (Build.VERSION.SDK_INT >= 33) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(BUZZ, -1),
                    VibrationAttributes.Builder()
                        .setUsage(VibrationAttributes.USAGE_ALARM)
                        .build()
                )
            } else if (Build.VERSION.SDK_INT >= 26) {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    VibrationEffect.createWaveform(BUZZ, -1),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(BUZZ, -1)
            }
        } catch (e: Exception) {
            // No vibration is not worth a crash.
        }
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

            if (Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel(
                    CHANNEL, "Alarm heads-up", NotificationManager.IMPORTANCE_HIGH
                )
                channel.description = "A vibration five minutes before an alarm rings"
                // The vibration is done by hand below (as an ALARM vibration,
                // which the phone's silent mode and "vibrate off" do not
                // mute); the channel itself stays quiet so it is not doubled.
                channel.enableVibration(false)
                channel.setSound(null, null)
                manager.createNotificationChannel(channel)
                try {
                    manager.deleteNotificationChannel(OLD_CHANNEL)
                } catch (e: Exception) {
                }
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
                Notification.Builder(context)
            }
            @Suppress("DEPRECATION")
            val skipAction = Notification.Action.Builder(0, "Skip this alarm", skip).build()
            builder
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(context.getColor(R.color.notification_tint))
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
            buzz(context)
        } catch (e: Exception) {
            // A heads-up that cannot be shown must never crash the app.
        }
    }
}
