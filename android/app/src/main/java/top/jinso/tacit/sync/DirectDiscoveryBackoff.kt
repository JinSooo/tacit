package top.jinso.tacit.sync

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class DirectDiscoveryBackoff(private val now: () -> Long) {
    private val mutex = Mutex()
    private var failed: Failure? = null

    private data class Failure(val route: Any, val until: Long, val error: MacUnavailable)

    suspend fun find(route: Any, canRelay: Boolean, discover: suspend () -> String): String = mutex.withLock {
        failed?.let { if (canRelay && it.route == route && now() < it.until) throw it.error }
        try {
            discover().also { failed = null }
        } catch (error: MacUnavailable) {
            // A search cut short by the time budget proves nothing; only a full miss starts the backoff.
            if (!error.incomplete) failed = Failure(route, now() + TIMELINE_RECHECK, error)
            throw error
        }
    }
}
