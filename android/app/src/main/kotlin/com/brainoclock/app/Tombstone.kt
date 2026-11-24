package com.brainoclock.app

/**
 * Reads Android's record of a crash in native code (a "tombstone", which
 * ApplicationExitInfo hands out in protobuf form) and says, in a few
 * lines, what matters: the signal, the reason given, and the code the
 * crashed thread was running. Nothing but plain Kotlin, so it can be
 * tested off the phone.
 *
 * Field numbers are those of AOSP's tombstone.proto:
 *   Tombstone: tid = 6, signal_info = 10, abort_message = 14,
 *              causes = 15, threads (map<tid, Thread>) = 16
 *   Signal:    name = 2, code_name = 4, fault_address = 8
 *   Cause:     human_readable = 1
 *   Thread:    id = 1, name = 2, current_backtrace = 4
 *   Frame:     function_name = 4, file_name = 6
 */
object Tombstone {
    private class Field(val number: Int, val wire: Int, val value: Long, val bytes: ByteArray?)

    /** The fields of one message; stops quietly at anything malformed. */
    private fun fields(data: ByteArray, from: Int = 0, to: Int = data.size): List<Field> {
        val out = ArrayList<Field>()
        var i = from
        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (i < to) {
                val b = data[i++].toInt() and 0xff
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) return result
                shift += 7
                if (shift > 63) break
            }
            throw IllegalStateException("bad varint")
        }
        try {
            while (i < to) {
                val key = varint()
                val number = (key ushr 3).toInt()
                when ((key and 7).toInt()) {
                    0 -> out.add(Field(number, 0, varint(), null))
                    1 -> { i += 8; out.add(Field(number, 1, 0, null)) }
                    5 -> { i += 4; out.add(Field(number, 5, 0, null)) }
                    2 -> {
                        val length = varint().toInt()
                        if (length < 0 || i + length > to) return out
                        out.add(Field(number, 2, 0, data.copyOfRange(i, i + length)))
                        i += length
                    }
                    else -> return out
                }
            }
        } catch (e: Exception) {
            // Cut off (only the start of a big record is read): keep what was found.
        }
        return out
    }

    private fun text(bytes: ByteArray?): String =
        if (bytes == null) "" else String(bytes, Charsets.UTF_8).trim()

    /** A short account of the crash, or "" when [data] is not such a record. */
    fun summary(data: ByteArray, maxFrames: Int = 24, maxChars: Int = 3000): String {
        val top = fields(data)
        if (top.isEmpty()) return ""
        val crashedTid = top.firstOrNull { it.number == 6 && it.wire == 0 }?.value
        val lines = ArrayList<String>()

        top.firstOrNull { it.number == 10 && it.bytes != null }?.let { signal ->
            val f = fields(signal.bytes!!)
            val name = text(f.firstOrNull { it.number == 2 }?.bytes)
            val code = text(f.firstOrNull { it.number == 4 }?.bytes)
            val address = f.firstOrNull { it.number == 8 && it.wire == 0 }?.value
            lines.add(
                "Signal: " + listOf(name, code).filter { it.isNotEmpty() }.joinToString(" / ") +
                    (if (address != null) " at 0x" + java.lang.Long.toHexString(address) else "")
            )
        }
        text(top.firstOrNull { it.number == 14 }?.bytes).let { if (it.isNotEmpty()) lines.add("Abort: $it") }
        for (cause in top.filter { it.number == 15 && it.bytes != null }) {
            val why = text(fields(cause.bytes!!).firstOrNull { it.number == 1 }?.bytes)
            if (why.isNotEmpty()) lines.add("Cause: $why")
        }

        // The crashed thread is the one whose number the record names.
        var fallback: List<Field>? = null
        var crashed: List<Field>? = null
        for (entry in top.filter { it.number == 16 && it.bytes != null }) {
            val pair = fields(entry.bytes!!)
            val thread = fields(pair.firstOrNull { it.number == 2 }?.bytes ?: continue)
            if (fallback == null) fallback = thread
            val tid = pair.firstOrNull { it.number == 1 }?.value
            if (crashedTid != null && tid == crashedTid) {
                crashed = thread
                break
            }
        }
        val thread = crashed ?: fallback
        if (thread != null) {
            val name = text(thread.firstOrNull { it.number == 2 }?.bytes)
            lines.add((if (crashed != null) "Crashed thread: " else "First thread: ") + name)
            var n = 0
            for (frame in thread.filter { it.number == 4 && it.bytes != null }) {
                if (n++ >= maxFrames) break
                val f = fields(frame.bytes!!)
                val function = text(f.firstOrNull { it.number == 4 }?.bytes)
                val file = text(f.firstOrNull { it.number == 6 }?.bytes).substringAfterLast('/')
                lines.add("  #$n " + (if (function.isEmpty()) "(unknown)" else function.take(140)) +
                    (if (file.isEmpty()) "" else "  [$file]"))
            }
        }
        return lines.joinToString("\n").take(maxChars)
    }
}
