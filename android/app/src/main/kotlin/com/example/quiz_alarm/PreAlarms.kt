package com.example.quiz_alarm

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject

/**
 * Schedules the "alarm in 5 minutes" heads-up notifications and remembers
 * them, because Android forgets every scheduled wake-up when the phone
 * restarts (and when the app is updated). BootReceiver puts them back from
 * this memory, so the app does not have to be opened first.
 */
object PreAlarms {
    private const val STORE = "pre_alarms"

    private fun pending(
        context: Context, id: Int, ringAt: Long, title: String?, body: String?
    ): PendingIntent {
        val intent = Intent(context, PreAlarmReceiver::class.java)
            .putExtra("alarm_id", id)
            .putExtra("ring_at", ringAt)
            .putExtra("title", title)
            .putExtra("body", body)
        return PendingIntent.getBroadcast(
            context, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun arm(
        context: Context, id: Int, at: Long, ringAt: Long, title: String?, body: String?
    ) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = pending(context, id, ringAt, title, body)
        val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
        try {
            if (exact) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            }
        } catch (e: SecurityException) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
        }
    }

    fun schedule(
        context: Context, id: Int, at: Long, ringAt: Long, title: String?, body: String?
    ) {
        arm(context, id, at, ringAt, title, body)
        val entry = JSONObject().put("at", at).put("ring_at", ringAt)
            .put("title", title ?: "").put("body", body ?: "")
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .edit().putString(id.toString(), entry.toString()).apply()
    }

    fun cancel(context: Context, id: Int) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.cancel(pending(context, id, 0L, null, null))
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(PreAlarmReceiver.notificationId(id))
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .edit().remove(id.toString()).apply()
    }

    /** Puts back every remembered heads-up that is still in the future. */
    fun restoreAll(context: Context) {
        val store = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val edit = store.edit()
        for ((key, value) in store.all) {
            try {
                val id = key.toInt()
                val entry = JSONObject(value as String)
                val at = entry.getLong("at")
                if (at > now) {
                    arm(
                        context, id, at, entry.optLong("ring_at", 0L),
                        entry.optString("title"), entry.optString("body")
                    )
                } else {
                    edit.remove(key) // its moment has passed
                }
            } catch (e: Exception) {
                edit.remove(key)
            }
        }
        edit.apply()
    }
}
