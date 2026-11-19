package top.jinso.tacit.core

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class PausePolicyTest {
    @Test fun deadlineStopsBeingPausedWithoutReopeningApp() {
        assertTrue(PausePolicy.active(true, 1000, 999))
        assertFalse(PausePolicy.active(true, 1000, 1000))
        assertTrue(PausePolicy.active(true, 0, Long.MAX_VALUE))
        assertFalse(PausePolicy.active(false, 1000, 1))
    }
    @Test fun tomorrowUsesLocalMidnightAcrossDst() {
        val now=Instant.parse("2026-03-08T06:30:00Z").toEpochMilli()
        assertEquals(Instant.parse("2026-03-09T04:00:00Z").toEpochMilli(),PausePolicy.tomorrow(now,ZoneId.of("America/New_York")))
    }
}
