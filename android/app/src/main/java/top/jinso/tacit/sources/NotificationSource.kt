package top.jinso.tacit.sources

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.lang.ref.WeakReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import top.jinso.tacit.core.Draft

class NotificationSource : NotificationListenerService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private data class Pending(val notification: StatusBarNotification, val app: String, val generation: Long)
    private val queue = SerialQueue<Pending>(128)

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = WeakReference(this)
        val prefs = Sources.app(this).prefs
        if (!prefs.allows(Sources.NOTIFICATION)) {
            requestUnbind()
            return
        }
        // Never enumerate activeNotifications: binding must not backfill existing content.
        prefs.setStatus(Sources.NOTIFICATION, "等待新通知")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val app = Sources.app(this)
        val source = Sources.NOTIFICATION
        val packageName = sbn.packageName
        if (!app.prefs.allowsChatNotification(packageName)) return
        val generation = Sources.generation.get()
        when (queue.offer(Pending(sbn, packageName, generation))) {
            SerialQueue.Offer.FULL -> app.prefs.setStatus(source, "通知队列已满，部分新通知未记录")
            SerialQueue.Offer.QUEUED -> Unit
            SerialQueue.Offer.START -> scope.launch {
                while (isActive) {
                    val pending = queue.poll { item ->
                        item.generation == Sources.generation.get() && app.prefs.allowsChatNotification(item.app)
                    } ?: break
                    save(pending)
                }
            }
        }
    }

    private fun save(pending: Pending) {
        val app = Sources.app(this)
        val source = Sources.NOTIFICATION
        val sbn = pending.notification
        val packageName = pending.app
        try {
            fun allowed() = scope.isActive && pending.generation == Sources.generation.get() && app.prefs.allowsChatNotification(packageName)
            if (!allowed() || sbn.postTime < app.prefs.since(source)) return
            val preview = chatPreview(sbn.notification, packageName) ?: return
            synchronized(Sources) {
                if (!allowed()) return
                val id = app.vault.ingest(Draft(
                    source, preview.conversation, preview.body, start = sbn.postTime,
                    sourceRef = sourceRef(app.prefs.device, source, packageName, sbn.key,
                        sbn.postTime.toString(), preview.conversation, preview.sender.orEmpty(), preview.message),
                ))
                if (id != null) app.prefs.setStatus(source, "已接收新聊天通知")
            }
        } catch (_: Exception) {
            app.prefs.setStatus(source, "通知读取失败")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        queue.clear()
        if (instance.get() === this) instance.clear()
        // Rebinding is explicit through Sources.refresh; do not loop against an OS revocation.
    }

    override fun onDestroy() {
        scope.cancel()
        queue.clear()
        if (instance.get() === this) instance.clear()
        super.onDestroy()
    }

    companion object {
        private var instance = WeakReference<NotificationSource>(null)
        /** The system is actually delivering notifications; a granted permission alone does not mean this. */
        internal val connected: Boolean get() = instance.get() != null
        internal fun unbind() { instance.get()?.let { it.queue.clear(); runCatching { it.requestUnbind() } } }
    }
}
