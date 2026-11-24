@file:Suppress("UNUSED_PARAMETER")
package android.app
import android.content.Context
import android.content.Intent
class PendingIntent(val id: Int) { companion object { const val FLAG_UPDATE_CURRENT = 1; const val FLAG_IMMUTABLE = 2
  @JvmStatic fun getBroadcast(c: Context, code: Int, i: Intent, flags: Int): PendingIntent = PendingIntent(code)
  @JvmStatic fun getActivity(c: Context, code: Int, i: Intent, flags: Int): PendingIntent = PendingIntent(-1) } }
class AlarmManager { companion object { const val RTC_WAKEUP = 0; val armed = HashMap<Int, Long>() }
  class AlarmClockInfo(val at: Long, show: PendingIntent)
  fun canScheduleExactAlarms(): Boolean = true
  fun setAlarmClock(info: AlarmClockInfo, op: PendingIntent) { armed[op.id] = info.at }
  fun setAndAllowWhileIdle(type: Int, at: Long, op: PendingIntent) { armed[op.id] = at }
  fun cancel(op: PendingIntent) { armed.remove(op.id) } }
