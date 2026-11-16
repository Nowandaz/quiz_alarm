package com.example.quiz_alarm

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
 */
class MainActivity : FlutterActivity() {
    companion object {
        // The sign-in link the browser came back with (set by
        // AuthRedirectActivity), until the Dart side has taken it.
        @JvmStatic
        var pendingAuthLink: String? = null
    }

    private var channel: MethodChannel? = null

    override fun onResume() {
        super.onResume()
        val link = pendingAuthLink ?: return
        val ch = channel ?: return
        pendingAuthLink = null
        ch.invokeMethod("authLink", link)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "brainwake/system")
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
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
