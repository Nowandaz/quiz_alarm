package com.example.quiz_alarm

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
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
 *  - openAutostartSettings: the phone maker's "autostart" page, where some
 *    brands decide whether an app may start by itself after a restart.
 *  - setAlarmScreen: while an alarm rings the screen is kept awake (also
 *    in power saving mode) and the quiz may show over the lock screen. At
 *    every other time the app stays BEHIND the lock screen like any other
 *    app, so a locked phone does not give access to the account.
 *  - uninstallProtectionOn / requestUninstallProtection /
 *    removeUninstallProtection: the optional "cannot be uninstalled while
 *    an alarm rings" switch (see AdminReceiver).
 */
class MainActivity : FlutterActivity() {
    companion object {
        // The sign-in link the browser came back with (set by
        // AuthRedirectActivity), until the Dart side has taken it.
        @JvmStatic
        var pendingAuthLink: String? = null

        // The alarm whose heads-up notification had "Skip" tapped.
        // ("alarm id:ring time", set by SkipAlarmActivity.)
        @JvmStatic
        var pendingSkipAlarm: String? = null

        // True while the quiz of a ringing alarm is on screen (set by the
        // Dart side). AdminReceiver reads it.
        @JvmStatic
        @Volatile
        var ringing: Boolean = false
    }

    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    // Takes the app back behind the lock screen if no alarm turned out to
    // be ringing (see showIfLocked).
    private val hideAgain = Runnable { if (!ringing) overLockScreen(false) }

    /** Lets this screen show over the lock screen and wake the display. */
    private fun overLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    /**
     * The app is being opened while the phone is locked. Normally only a
     * ringing alarm can do that, so show over the lock screen for a
     * moment; the Dart side then says whether an alarm really is ringing
     * (setAlarmScreen). If it does not, hide again.
     */
    private fun showIfLocked() {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isKeyguardLocked) return
        overLockScreen(true)
        handler.removeCallbacks(hideAgain)
        handler.postDelayed(hideAgain, 15000)
    }

    private fun admin() = ComponentName(this, AdminReceiver::class.java)

    private fun policyManager() =
        getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showIfLocked()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        showIfLocked()
    }

    override fun onDestroy() {
        handler.removeCallbacks(hideAgain)
        ringing = false
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        val ch = channel ?: return
        pendingAuthLink?.let {
            pendingAuthLink = null
            ch.invokeMethod("authLink", it)
        }
        // Kept until the Dart side has taken it (takeSkipAlarm): early in
        // a cold start nothing is listening yet and a pushed message could
        // be lost. Dart ignores the repeat.
        pendingSkipAlarm?.let { ch.invokeMethod("skipAlarm", it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "brainwake/system")
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlarmScreen" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        ringing = on
                        handler.removeCallbacks(hideAgain)
                        overLockScreen(on)
                        // Power saving mode shortens the screen timeout;
                        // this keeps the display awake while answering.
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "uninstallProtectionOn" -> {
                        result.success(
                            try {
                                policyManager().isAdminActive(admin())
                            } catch (e: Exception) {
                                false
                            }
                        )
                    }
                    "requestUninstallProtection" -> {
                        try {
                            startActivity(
                                Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                                    .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin())
                                    .putExtra(
                                        DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                        "Stops BrainWake being uninstalled while an alarm is ringing."
                                    )
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "removeUninstallProtection" -> {
                        if (ringing) {
                            result.success(false)
                        } else {
                            try {
                                policyManager().removeActiveAdmin(admin())
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
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
                            PreAlarms.schedule(
                                applicationContext,
                                call.argument<Int>("id") ?: 0,
                                call.argument<Number>("at")?.toLong() ?: 0L,
                                call.argument<Number>("ringAt")?.toLong() ?: 0L,
                                call.argument<String>("title"),
                                call.argument<String>("body")
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "cancelPreAlarm" -> {
                        try {
                            PreAlarms.cancel(applicationContext, call.argument<Int>("id") ?: 0)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openAutostartSettings" -> {
                        // Each maker hides this page somewhere else; try the
                        // known ones, then fall back to the app's own page.
                        val pages = listOf(
                            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
                            "com.transsion.phonemaster" to "com.cyin.himgr.autostart.AutoStartActivity",
                            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
                            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
                            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                            "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                        )
                        var opened = false
                        for ((pkg, cls) in pages) {
                            try {
                                startActivity(
                                    Intent().setComponent(ComponentName(pkg, cls))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                opened = true
                                break
                            } catch (e: Exception) {
                                // Not this maker's phone; try the next.
                            }
                        }
                        if (!opened) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                                opened = true
                            } catch (e: Exception) {
                            }
                        }
                        result.success(opened)
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
