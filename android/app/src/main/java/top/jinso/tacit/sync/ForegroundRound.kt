package top.jinso.tacit.sync

/** A full round finished this recently already talked to the mailbox; a resume right after it only refreshes directly. */
internal const val FOREGROUND_REPEAT_WINDOW = 60_000L

/**
 * Opening the app right after a network or record trigger finished a full sync should not spend another
 * mailbox round (the relay has a daily quota). Backoff recovery (wait > 0) is never skipped.
 */
internal fun foregroundRoundIsRepeat(lastSync: Long, now: Long, wait: Long): Boolean =
    wait <= 0 && lastSync > 0 && now - lastSync in 0 until FOREGROUND_REPEAT_WINDOW
