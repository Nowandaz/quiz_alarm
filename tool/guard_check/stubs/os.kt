@file:Suppress("UNUSED_PARAMETER")
package android.os
object Build { object VERSION { @JvmField val SDK_INT = 35 } }
class Looper { companion object { @JvmStatic fun getMainLooper(): Looper = Looper() } }
class Handler(l: Looper) { fun postDelayed(r: Runnable, ms: Long): Boolean = true }
