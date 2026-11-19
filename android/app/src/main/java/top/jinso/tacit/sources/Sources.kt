package top.jinso.tacit.sources

import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Process
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import top.jinso.tacit.TacitApp

object Sources {
    const val USAGE = "android.usage"
    const val NOTIFICATION = "android.notification"
    const val AUDIO = "android.audio"
    const val NOTE = "manual.note"
    const val CORRECTION = "manual.correction"
    val UPLOADABLE: Set<String> = setOf(AUDIO, NOTIFICATION, USAGE, NOTE, CORRECTION)

    internal val descriptors = listOf(
        SourceDescriptor(USAGE, "应用使用", "仅记录前台应用及使用时段。"),
        SourceDescriptor(NOTIFICATION, "聊天通知", "仅记录所选聊天应用的通知预览。"),
    )
    private const val PERIODIC = "tacit-usage-periodic"
    private const val IMMEDIATE = "tacit-usage-open"
    internal val generation = AtomicLong()
    internal fun app(context: Context) = context.applicationContext as TacitApp
    /** Call on app open AND immediately after every pause/resume or blacklist change.
     * Application.onCreate must not call this: explicit startup performs no collection.
     */
    @Synchronized fun refresh(context: Context) {
        generation.incrementAndGet()
        val prefs = app(context).prefs
        val now = System.currentTimeMillis()
        val work = WorkManager.getInstance(context)
        if (!prefs.allows(USAGE)) {
            dropUsage(context, now)
            work.cancelUniqueWork(PERIODIC)
            work.cancelUniqueWork(IMMEDIATE)
            prefs.setStatus(USAGE, if (prefs.enabled(USAGE)) "已暂停" else "已停用")
        } else {
            // Reset again on resume: nothing from the paused interval may be replayed.
            if (prefs.cursor("$USAGE.blocked") != 0L) {
                prefs.setCursor(USAGE, now)
                prefs.setCursor("$USAGE.blocked", 0)
            }
            work.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<UsageWorker>(15, TimeUnit.MINUTES).build())
            // Refresh invalidates the old generation; KEEP would drop this replacement while it exits.
            // UsageWorker's mutex plus cancellation/generation gates serialize the replacement safely.
            work.enqueueUniqueWork(IMMEDIATE, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<UsageWorker>().build())
        }
        if (prefs.allows(NOTIFICATION) && granted(context, NOTIFICATION)) {
            runCatching { NotificationListenerService.requestRebind(ComponentName(context, NotificationSource::class.java)) }
        } else {
            NotificationSource.unbind()
        }
        prefs.setStatus(NOTIFICATION, when {
            !prefs.enabled(NOTIFICATION) -> "已停用"
            !prefs.allows(NOTIFICATION) -> "已暂停"
            !granted(context, NOTIFICATION) -> "等待系统授权"
            else -> "等待新通知"
        })
    }

    @Synchronized fun setEnabled(context: Context, source: String, enabled: Boolean) {
        require(source in descriptors.map { it.id })
        val prefs = app(context).prefs
        generation.incrementAndGet()
        prefs.setEnabled(source, enabled)
        if (source == USAGE) {
            prefs.setCursor(USAGE, System.currentTimeMillis())
            prefs.setCursor("$USAGE.blocked", if (enabled) 0 else 1)
        }
        refresh(context)
    }

    @Synchronized fun setChatApps(context: Context, packages: Set<String>) {
        app(context).prefs.chatApps = packages
    }

    fun granted(context: Context, source: String): Boolean = runCatching {
        when (source) {
            USAGE -> context.getSystemService(AppOpsManager::class.java)
                .checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName) == AppOpsManager.MODE_ALLOWED
            NOTIFICATION -> {
                val target = ComponentName(context, NotificationSource::class.java)
                Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
                    .orEmpty().split(':').any { ComponentName.unflattenFromString(it) == target }
            }
            else -> false
        }
    }.getOrDefault(false)

    fun permissionIntent(context: Context, source: String): Intent = when (source) {
        USAGE -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, Uri.parse("package:${context.packageName}"))
        NOTIFICATION -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        else -> throw IllegalArgumentException("Unknown source")
    }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    @Synchronized internal fun dropUsage(context: Context, now: Long) {
        val prefs = app(context).prefs
        prefs.setCursor(USAGE, now)
        prefs.setCursor("$USAGE.blocked", 1)
    }
}

internal data class SourceDescriptor(val id: String, val title: String, val description: String)
