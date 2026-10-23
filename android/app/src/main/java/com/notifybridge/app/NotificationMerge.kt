package com.notifybridge.app

/**
 * Pure helpers for notification updates. Keeping this separate from Android
 * framework classes makes the "newest message" rule testable on the JVM.
 */
object NotificationMerge {
    /** Returns the message with the greatest timestamp; ties go to the later list entry. */
    fun <T> newestByTime(messages: List<T>, timeOf: (T) -> Long): T? {
        var newest: T? = null
        var newestTime = Long.MIN_VALUE
        for (message in messages) {
            val time = timeOf(message)
            if (newest == null || time >= newestTime) {
                newest = message
                newestTime = time
            }
        }
        return newest
    }
}
