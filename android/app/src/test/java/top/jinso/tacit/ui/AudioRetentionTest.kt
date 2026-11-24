package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.audio.AudioStorageUsage
import top.jinso.tacit.audio.AudioPolicy

class AudioRetentionTest {
    @Test fun keepingForeverDoesNotExpireEvenAnOldClip() {
        val days = checkNotNull(localRetentionDays("30", keepForever = true))
        val year = 365 * 86_400_000L
        assertFalse(AudioPolicy.expired(0L, 2 * year, days))
    }

    @Test fun acceptsTheSameFiniteWindowAsMac() {
        assertEquals(365, localRetentionDays("365", keepForever = false))
        assertNull(localRetentionDays("366", keepForever = false))
        assertNull(localRetentionDays("0", keepForever = false))
        assertEquals(7, localRetentionDays("007", keepForever = false))
    }

    @Test fun allowsCleanupForAVoiceprintEvenWhenThereAreNoClips() {
        assertFalse(AudioStorageUsage(0, false).canClear)
        assertTrue(AudioStorageUsage(0, true).canClear)
        assertTrue(AudioStorageUsage(1, false).canClear)
    }
}
