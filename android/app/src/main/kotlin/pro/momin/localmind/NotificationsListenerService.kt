package pro.momin.localmind

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/** One captured notification row inside the listener ring. */
data class NotificationEntry(
    val key: String,
    val packageName: String,
    val title: String,
    val text: String,
    val postedAtMillis: Long
)

/**
 * Notification listener whose purpose is to expose a session-scoped ring of
 * recently posted notifications to the `notifications.read_recent` tool.
 * Nothing is persisted: the ring lives and dies with this service instance
 * (which follows the app's listener grant), and Dart-side consumers filter
 * and format the rows (`since_minutes` / `package` / `max` stay Dart-side).
 */
class NotificationsListenerService : NotificationListenerService() {

    /** Ring of captured entries, newest-first (addFirst), capped at [RING_CAPACITY]. */
    private val ring = ArrayDeque<NotificationEntry>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "Notifications listener connected")
        instance = this
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val entry = extract(sbn) ?: return
        // Dedupe consecutive identical posts: re-posts of the same
        // notification key also carry the same post time, so keep the ring
        // stable instead of doubling a row on every \"group summary\" update.
        val currentFirst = ring.firstOrNull()
        if (currentFirst != null &&
            currentFirst.key == entry.key &&
            currentFirst.postedAtMillis == entry.postedAtMillis
        ) {
            return
        }
        ring.addFirst(entry)
        while (ring.size > RING_CAPACITY) {
            ring.removeLast()
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) = Unit

    override fun onListenerDisconnected() {
        Log.i(TAG, "Notifications listener disconnected")
        instance = null
        super.onListenerDisconnected()
    }

    /** Null-friendly title/text/subtext extraction for the tool output. */
    private fun extract(sbn: StatusBarNotification?): NotificationEntry? {
        if (sbn == null) return null
        val extras = sbn.notification?.extras ?: return null
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
        val subtext = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim()
        if (title.isNullOrBlank() && text.isNullOrBlank() && subtext.isNullOrBlank()) {
            // Silent/no-content notifications carry no readable text.
            return null
        }
        return NotificationEntry(
            key = sbn.key ?: "",
            packageName = sbn.packageName ?: "",
            title = title ?: "",
            text = text ?: subtext ?: "",
            postedAtMillis = sbn.postTime
        )
    }

    /** Snapshot of the whole ring, newest-first (Dart-side filtering). */
    fun snapshot(): List<NotificationEntry> = ring.toList()

    companion object {
        private const val TAG = "LocalMindNotif"

        /** Ring capacity shared with the Dart contract (see
         *  notificationRingCapacity in notifications_store.dart). */
        const val RING_CAPACITY = 200

        /** Set while the listener is connected, cleared on disconnect. */
        @JvmStatic
        @Volatile
        var instance: NotificationsListenerService? = null
            private set
    }
}
