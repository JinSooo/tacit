package top.jinso.tacit.sources

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import top.jinso.tacit.core.Draft

class UsageWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) { scanLock.withLock { scan() } }

    private fun scan(): Result {
        val context = applicationContext
        val app = Sources.app(context)
        val prefs = app.prefs
        val source = Sources.USAGE
        val now = System.currentTimeMillis()
        val generation: Long
        val from: Long
        synchronized(Sources) {
            if (!prefs.allows(source) || !Sources.granted(context, source)) {
                Sources.dropUsage(context, now)
                prefs.setStatus(source, if (!prefs.enabled(source)) "已停用" else if (!prefs.allows(source)) "已暂停" else "等待系统授权")
                return Result.success()
            }
            if (prefs.cursor("$source.blocked") != 0L) {
                prefs.setCursor(source, now)
                prefs.setCursor("$source.blocked", 0)
            }
            generation = Sources.generation.get()
            // Bound OS queries and replay. A stale open interval is discarded, never given a synthetic end.
            from = maxOf(prefs.cursor(source, now), prefs.since(source), now - 6 * 60 * 60 * 1000L)
        }
        fun allowed(): Boolean = !isStopped && generation == Sources.generation.get() && prefs.allows(source)
        if (from >= now) return Result.success()
        try {
            if (!allowed()) return Result.success()
            val stream = context.getSystemService(UsageStatsManager::class.java).queryEvents(from, now)
                ?: return Result.retry()
            val events = ArrayList<UsageEvent>()
            val event = UsageEvents.Event()
            var count = 0
            while (stream.hasNextEvent()) {
                if (!allowed()) return Result.success()
                if (++count > 20_000) {
                    prefs.setStatus(source, "活动过多，本次未保存")
                    return Result.success() // Cursor unchanged: a partial scan must never commit.
                }
                stream.getNextEvent(event)
                val kind = when (event.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED -> UsageKind.RESUME
                    UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> UsageKind.PAUSE
                    UsageEvents.Event.SCREEN_NON_INTERACTIVE, UsageEvents.Event.KEYGUARD_SHOWN -> UsageKind.LOCK
                    UsageEvents.Event.KEYGUARD_HIDDEN -> UsageKind.UNLOCK
                    UsageEvents.Event.DEVICE_SHUTDOWN, UsageEvents.Event.DEVICE_STARTUP -> UsageKind.RESET
                    else -> null
                } ?: continue
                if (!allowed()) return Result.success()
                val packageName = event.packageName.orEmpty()
                // Keep only a boundary for blocked/self apps; never extract their activity names.
                val include = packageName.isNotBlank() && prefs.allows(source, packageName)
                events += UsageEvent(event.timeStamp, kind, if (include) packageName else "",
                    if (include) event.className.orEmpty() else "")
            }
            val result = usageIntervals(events, from, now)
            for (interval in result.intervals) {
                if (!allowed()) return Result.success()
                if (!prefs.allows(source, interval.app)) continue
                val label = runCatching { context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(interval.app, 0)).toString() }.getOrDefault(interval.app)
                app.vault.ingest(Draft(source, label, "",
                    start = interval.start, end = interval.end, app = interval.app,
                    sourceRef = sourceRef(prefs.device, source, interval.app, interval.start.toString(), interval.end.toString())))
            }
            synchronized(Sources) {
                if (allowed() && Sources.granted(context, source)) {
                    prefs.setCursor(source, result.cursor)
                    prefs.setStatus(source, "已检查新的使用记录")
                }
            }
            return Result.success()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: SecurityException) {
            Sources.dropUsage(context, now)
            prefs.setStatus(source, "等待系统授权")
            return Result.success()
        } catch (_: Exception) {
            prefs.setStatus(source, "读取失败，稍后重试")
            return Result.retry()
        }
    }

    companion object { private val scanLock = Mutex() }
}
