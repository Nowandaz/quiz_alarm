package com.brainoclock.app

import android.app.Application
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Keeps a note of why the app crashed, for the next problem report.
 *
 * Android only records THAT an app crashed. This writes the error (the
 * last one only, a few thousand characters) to a small file in the app's
 * own storage before the crash goes on as usual; a report sent later
 * includes it so the cause can be found.
 */
class BrainApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val before = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val text = StringWriter()
                error.printStackTrace(PrintWriter(text))
                crashFile(this).writeText(
                    "${System.currentTimeMillis()}\n" +
                        "thread ${thread.name}\n" +
                        text.toString().take(MAX_CHARS)
                )
            } catch (e: Throwable) {
                // Nothing more can be done while crashing.
            }
            before?.uncaughtException(thread, error)
        }
    }

    companion object {
        const val MAX_CHARS = 4000
        fun crashFile(app: android.content.Context) = File(app.filesDir, "last_crash.txt")
    }
}
