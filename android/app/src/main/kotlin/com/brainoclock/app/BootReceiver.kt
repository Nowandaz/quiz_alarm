package com.brainoclock.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Runs when the phone has restarted or the app was updated, and puts back
 * what Android forgot: the heads-up notifications (PreAlarms), the guards
 * that bring a closed alarm back (RingGuard) and, after an update, the
 * alarms themselves (after a restart the alarm plugin's own receiver
 * restores those).
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
                try {
                    if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
                        RingGuard.rearmAlarms(context)
                    }
                    RingGuard.restoreAll(context)
                } catch (e: Throwable) {
                    // Never crash at start-up.
                }
            }
        }
    }
}
