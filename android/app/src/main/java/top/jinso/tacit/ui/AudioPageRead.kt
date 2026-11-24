package top.jinso.tacit.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** Only the active home page retries. A new change notification starts a fresh attempt via collectLatest. */
internal suspend fun <T> retryAudioPageRead(
    onFailure: () -> Unit,
    wait: suspend (Long) -> Unit = { delay(it) },
    read: suspend () -> T,
): T {
    var backoff = 1_000L
    while (true) {
        try {
            return read()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            onFailure()
            wait(backoff)
            backoff = (backoff * 2).coerceAtMost(30_000L)
        }
    }
}
