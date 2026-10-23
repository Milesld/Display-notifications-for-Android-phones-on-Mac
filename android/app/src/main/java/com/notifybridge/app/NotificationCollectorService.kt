package com.notifybridge.app

import android.app.Notification
import android.content.ComponentName
import android.os.Bundle
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.util.LinkedHashMap

/**
 * Reads notifications that the user has explicitly granted access to and sends
 * a minimal JSON copy to the BLE relay service.
 *
 * Notification content can be hidden by the source app or by the lock screen
 * privacy settings. In that case only the visible text is forwarded.
 */
class NotificationCollectorService : NotificationListenerService() {
    companion object {
        private const val TAG = "NotifyBridge"
        private const val DEDUPE_WINDOW_MS = 3_000L
    }

    private data class MessagingMessage(val sender: String?, val text: String, val time: Long)

    private val recent = LinkedHashMap<String, Long>(128, 0.75f, true)
    private val recentLock = Any()
    private val lastMessageTimes = LinkedHashMap<String, Long>(128, 0.75f, true)
    private val lastMessageLock = Any()
    private val labelCache = HashMap<String, String>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        RelayState.listenerConnected = true
        Log.i(TAG, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        RelayState.listenerConnected = false
        Log.w(TAG, "Notification listener disconnected")
        try {
            requestRebind(ComponentName(this, NotificationCollectorService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Unable to request listener rebind", e)
        }
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (sbn.packageName == packageName) return

        val notification = sbn.notification ?: return
        val flags = notification.flags
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (!sbn.isClearable) return

        val extras = notification.extras ?: return
        var title = clean(extras.getCharSequence(Notification.EXTRA_TITLE))
        var text = clean(extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
            ?: clean(extras.getCharSequence(Notification.EXTRA_TEXT))

        val messaging = latestMessagingMessage(extras)
        if (messaging != null) {
            if (title.isNullOrEmpty()) title = clean(messaging.sender)
            if (messaging.text.isNotEmpty()) text = clean(messaging.text)
        }

        if (text.isNullOrEmpty()) {
            val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            if (lines != null && lines.isNotEmpty()) {
                text = clean(lines.last())
            }
        }
        if (text.isNullOrEmpty()) {
            text = clean(extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
        }
        if (text.isNullOrEmpty()) {
            text = clean(notification.tickerText)
        }

        if (title.isNullOrEmpty() && text.isNullOrEmpty()) return

        val notificationKey = sbn.key ?: "${sbn.packageName}:${sbn.id}"
        val messageTime = messaging?.time ?: 0L
        if (messageTime > 0) {
            val previous = synchronized(lastMessageLock) { lastMessageTimes[notificationKey] }
            if (previous != null && messageTime <= previous) {
                // The app reposted an existing conversation notification (for
                // example, a read-state update) without adding a new message.
                Log.d(TAG, "Skipping notification without a newer message")
                return
            }
        }

        // Use the conversation/notification key as the macOS identifier. An
        // update then replaces the previous card instead of adding a duplicate.
        val signature = buildString {
            append(notificationKey)
            append('|')
            append(title ?: "")
            append('|')
            append(text ?: "")
            append('|')
            append(messageTime)
        }
        if (isDuplicate(signature)) return

        val appLabel = applicationLabel(sbn.packageName)
        val postedAt = if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()

        val json = JSONObject()
            .put("v", 1)
            .put("type", "notification")
            .put("id", notificationKey)
            .put("app", appLabel)
            .put("pkg", sbn.packageName)
            .put("time", postedAt)

        if (!title.isNullOrEmpty()) json.put("title", title.take(200))
        if (!text.isNullOrEmpty()) json.put("text", text.take(1500))
        if (!notification.category.isNullOrEmpty()) json.put("category", notification.category)

        NotificationHub.emit(json.toString())
        if (messageTime > 0) {
            synchronized(lastMessageLock) {
                lastMessageTimes[notificationKey] = messageTime
                val iterator = lastMessageTimes.entries.iterator()
                while (lastMessageTimes.size > 128 && iterator.hasNext()) {
                    iterator.next()
                    iterator.remove()
                }
            }
        }
        Log.d(TAG, "Forwarded notification from ${sbn.packageName}")
    }

    private fun isDuplicate(signature: String): Boolean {
        synchronized(recentLock) {
            val now = SystemClock.elapsedRealtime()
            val previous = recent[signature]
            if (previous != null && now - previous < DEDUPE_WINDOW_MS) return true
            recent[signature] = now
            val iterator = recent.entries.iterator()
            while (recent.size > 128 && iterator.hasNext()) {
                iterator.next()
                iterator.remove()
            }
            return false
        }
    }

    private fun applicationLabel(pkg: String): String {
        synchronized(labelCache) {
            labelCache[pkg]?.let { return it }
        }
        val label = try {
            val info = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            pkg
        }
        synchronized(labelCache) { labelCache[pkg] = label }
        return label
    }

    /**
     * Apps using MessagingStyle put messages in EXTRA_MESSAGES, while EXTRA_TEXT
     * is often just "2 new messages". Select the message with the newest
     * timestamp rather than trusting array order: some OEM SMS apps list the
     * newest message first, which used to make us forward an old SMS again.
     */
    @Suppress("DEPRECATION")
    private fun latestMessagingMessage(extras: Bundle): MessagingMessage? {
        val raw = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return null
        val messages = raw.filterIsInstance<Bundle>()
        if (messages.isEmpty()) return null

        val message = NotificationMerge.newestByTime(messages) { it.getLong("time", 0L) } ?: return null
        val messageText = clean(message.getCharSequence("text")) ?: return null
        val sender = clean(message.getCharSequence("sender"))
        val messageTime = message.getLong("time", 0L)
        return MessagingMessage(sender, messageText, messageTime)
    }

    private fun clean(value: CharSequence?): String? {
        val text = value?.toString()?.trim() ?: return null
        return text.ifEmpty { null }
    }
}
