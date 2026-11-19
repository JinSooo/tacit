package top.jinso.tacit.sources

import org.junit.Assert.*
import org.junit.Test

class CollectorLogicTest {
    private fun event(time: Long, kind: UsageKind, app: String = "reader", activity: String = "page") = UsageEvent(time, kind, app, activity)

    @Test fun unfinishedUsageIsReplayedWithoutInventingAnEnd() {
        val first = usageIntervals(listOf(event(10, UsageKind.RESUME)), 0, 20)
        assertTrue(first.intervals.isEmpty())
        assertEquals(10L, first.cursor)
        val next = usageIntervals(listOf(event(10, UsageKind.RESUME), event(25, UsageKind.PAUSE)), first.cursor, 30)
        assertEquals(listOf(UsageInterval("reader", 10, 25)), next.intervals)
        assertEquals(30L, next.cursor)
    }

    @Test fun locksCloseUsageAndSuppressLockscreenActivityAcrossScans() {
        val first = usageIntervals(listOf(event(10, UsageKind.RESUME), event(15, UsageKind.LOCK),
            event(16, UsageKind.RESUME, "lockscreen")), 0, 20)
        assertEquals(listOf(UsageInterval("reader", 10, 15)), first.intervals)
        assertEquals(15L, first.cursor)
        val second = usageIntervals(listOf(event(15, UsageKind.LOCK), event(16, UsageKind.RESUME, "lockscreen"),
            event(22, UsageKind.RESUME, "another"), event(25, UsageKind.UNLOCK),
            event(26, UsageKind.RESUME), event(29, UsageKind.PAUSE)), first.cursor, 30)
        assertEquals(listOf(UsageInterval("reader", 26, 29)), second.intervals)
    }

    @Test fun oldActivityPauseCannotCloseNewActivityAndDuplicateResumeCannotResetStart() {
        val result = usageIntervals(listOf(event(10, UsageKind.RESUME), event(12, UsageKind.RESUME),
            event(20, UsageKind.RESUME, activity = "other"), event(21, UsageKind.PAUSE),
            event(25, UsageKind.PAUSE, activity = "other")), 0, 30)
        assertEquals(listOf(UsageInterval("reader", 10, 20), UsageInterval("reader", 20, 25)), result.intervals)
    }

    @Test fun noStartBeforeEnableOrResumeBoundaryIsFabricated() {
        val result = usageIntervals(listOf(event(30, UsageKind.PAUSE), event(40, UsageKind.RESUME),
            event(50, UsageKind.PAUSE)), 20, 50)
        assertTrue(result.intervals.isEmpty())
        assertEquals(40L, result.cursor)
        assertEquals(listOf(UsageInterval("reader", 40, 50)),
            usageIntervals(listOf(event(40, UsageKind.RESUME), event(50, UsageKind.PAUSE)), 40, 60).intervals)
    }

    @Test fun rebootDoesNotBridgeTwoSessions() {
        val result = usageIntervals(listOf(event(10, UsageKind.RESUME), event(12, UsageKind.RESET),
            event(15, UsageKind.RESUME), event(20, UsageKind.UNLOCK), event(21, UsageKind.RESUME),
            event(25, UsageKind.PAUSE)), 0, 30)
        assertEquals(listOf(UsageInterval("reader", 10, 12), UsageInterval("reader", 21, 25)), result.intervals)
    }

    @Test fun blockedAppBoundaryCannotExtendPreviousAppUsage() {
        val result = usageIntervals(listOf(event(10, UsageKind.RESUME), event(15, UsageKind.RESUME, "", ""),
            event(20, UsageKind.RESUME), event(25, UsageKind.PAUSE)), 0, 30)
        assertEquals(listOf(UsageInterval("reader", 10, 15), UsageInterval("reader", 20, 25)), result.intervals)
    }

    @Test(expected = IllegalArgumentException::class)
    fun unorderedScanCannotAdvanceCursor() {
        usageIntervals(listOf(event(20, UsageKind.RESUME), event(10, UsageKind.PAUSE)), 0, 30)
    }

    @Test fun referencesAreBoundedDeviceScopedAndUnambiguous() {
        val a = sourceRef("device1", "android.notification", "private-key", "abc", "def")
        assertEquals(a, sourceRef("device1", "android.notification", "private-key", "abc", "def"))
        assertNotEquals(a, sourceRef("device2", "android.notification", "private-key", "abc", "def"))
        assertNotEquals(sourceRef("d", "s", "ab", "c"), sourceRef("d", "s", "a", "bc"))
        assertFalse(a.contains("private-key"))
        assertFalse(a.contains("device1"))
        assertTrue(a.length < 128)
    }
}
