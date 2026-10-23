package com.notifybridge.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationMergeTest {
    private data class Message(val text: String, val time: Long)

    @Test
    fun picksNewestWhenArrayIsChronological() {
        val messages = listOf(
            Message("old", 100),
            Message("new", 200)
        )
        assertEquals("new", NotificationMerge.newestByTime(messages) { it.time }?.text)
    }

    @Test
    fun picksNewestWhenArrayIsNewestFirst() {
        val messages = listOf(
            Message("new", 300),
            Message("middle", 200),
            Message("old", 100)
        )
        assertEquals("new", NotificationMerge.newestByTime(messages) { it.time }?.text)
    }

    @Test
    fun tiesPreferLaterEntry() {
        val messages = listOf(
            Message("first", 100),
            Message("second", 100)
        )
        assertEquals("second", NotificationMerge.newestByTime(messages) { it.time }?.text)
    }

    @Test
    fun emptyListReturnsNull() {
        assertNull(NotificationMerge.newestByTime(emptyList<Message>()) { it.time })
    }
}
