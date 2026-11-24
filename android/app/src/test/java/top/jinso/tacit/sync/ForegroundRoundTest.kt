package top.jinso.tacit.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundRoundTest {
    // 2026-11-25 review: a resume queued behind a network-triggered round must not cost a second mailbox round.
    @Test fun resumeRightAfterAFullRoundOnlyRefreshesDirectly() {
        assertTrue(foregroundRoundIsRepeat(lastSync = 1_000_000, now = 1_030_000, wait = 0))
    }

    @Test fun staleOrMissingRoundRunsInFull() {
        assertFalse(foregroundRoundIsRepeat(lastSync = 1_000_000, now = 1_000_000 + FOREGROUND_REPEAT_WINDOW, wait = 0))
        assertFalse(foregroundRoundIsRepeat(lastSync = 0, now = 1_000_000, wait = 0))
        // A clock that moved backwards proves nothing about a recent round.
        assertFalse(foregroundRoundIsRepeat(lastSync = 2_000_000, now = 1_000_000, wait = 0))
    }

    @Test fun backoffRecoveryIsNeverSkipped() {
        assertFalse(foregroundRoundIsRepeat(lastSync = 1_000_000, now = 1_010_000, wait = 60_000))
    }
}
