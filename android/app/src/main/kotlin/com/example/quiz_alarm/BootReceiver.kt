package com.example.quiz_alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Runs when the phone has restarted or the app was updated, and puts the
 * heads-up notifications back (see PreAlarms). The alarms themselves are
 * restored by the alarm plugin's own receiver.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                try {
                    PreAlarms.restoreAll(context)
                } catch (e: Exception) {
                    // Never crash at start-up over a heads-up.
                }
            }
        }
    }
}
