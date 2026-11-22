package com.example.quiz_alarm

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent

/**
 * The optional "cannot be uninstalled while an alarm rings" switch
 * (Settings in the app). When the user turns it on, BrainWake becomes a
 * "device admin app", and Android refuses to uninstall such an app until
 * that is switched off again.
 *
 * It can be switched off in the app (refused while an alarm rings) or in
 * Android's own settings. If someone tries the Android route while an
 * alarm is ringing, the phone is locked, which leaves the ringing alarm
 * on screen. That one action (locking the screen) is the only power the
 * app asks for; see res/xml/device_admin.xml.
 */
class AdminReceiver : DeviceAdminReceiver() {
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence {
        if (MainActivity.ringing) {
            try {
                val manager =
                    context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                manager.lockNow()
            } catch (e: Exception) {
                // Locking is a bonus; never crash over it.
            }
            return "An alarm is ringing. Answer it first."
        }
        return "BrainWake could then be uninstalled while an alarm is ringing."
    }
}
