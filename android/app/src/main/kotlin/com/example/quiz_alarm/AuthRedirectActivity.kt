package com.example.quiz_alarm

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Catches the brainwake://auth?... link the browser opens after Google
 * sign-in. It shows nothing: it keeps the link for the Dart side (see
 * MainActivity), brings the app back to the screen the same way tapping its
 * icon would, and closes.
 */
class AuthRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MainActivity.pendingAuthLink = intent?.data?.toString()
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
