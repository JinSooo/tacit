package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test

class ConversationPolicyTest {
    @Test fun tenMinuteBoundaryAndMeetingIdentityAreBothRequired() {
        assertTrue(AudioPolicy.adjacent(30_000, 630_000, "mic:", "mic:"))
        assertFalse(AudioPolicy.adjacent(30_000, 630_001, "mic:", "mic:"))
        assertFalse(AudioPolicy.adjacent(30_000, 30_000, "mic:meeting", "mic:"))
        assertFalse(AudioPolicy.adjacent(30_000, 30_000, "mic:a", "mic:b"))
        assertFalse(AudioPolicy.adjacent(30_000, 30_000, "import:a", "import:b"))
        assertFalse(AudioPolicy.adjacent(30_000, 29_000, "mic:", "mic:"))
    }
    @Test fun manyVadSegmentsInOneConversationDoNotMeetTwoConversationThreshold() {
        assertFalse(AudioPolicy.candidate(1, 30.0))
        assertTrue(AudioPolicy.candidate(2, 15.0))
        assertTrue(AudioPolicy.candidate(1, 45.0))
    }
    @Test fun presenceIsConversationLocalAndMustStillBeRetained() {
        assertFalse(AudioPolicy.conversationAllowed(false, true, true))
        assertFalse(AudioPolicy.conversationAllowed(true, false, true))
        assertTrue(AudioPolicy.conversationAllowed(true, true, true))
        assertFalse(AudioPolicy.conversationAllowed(true, true, false))
    }
    @Test fun presenceNeedsTwentySecondsOfMe() {
        assertFalse(AudioPolicy.mePresent(11.7))
        assertTrue(AudioPolicy.mePresent(20.0))
    }
    @Test fun silenceTransitionsInvalidateBufferedAudioIncludingQuickSilenceAndResume() {
        val gate = CaptureSilenceGate()
        assertFalse(gate.drop(0))
        gate.update(true); assertTrue(gate.drop(0)); assertTrue(gate.drop(gate.revision))
        val silentRevision = gate.revision
        gate.update(false); assertTrue(gate.drop(silentRevision)); assertFalse(gate.drop(gate.revision))
        val beforeRead = gate.revision
        gate.update(true); gate.update(false)
        assertTrue(gate.drop(beforeRead))
    }
}
