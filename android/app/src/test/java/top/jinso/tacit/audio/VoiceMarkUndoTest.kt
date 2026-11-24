package top.jinso.tacit.audio

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.sync.MacVoiceprint

class VoiceMarkUndoTest {
    @Test fun undoRecognizesTheLocallyMarkedVoiceAgain() {
        val speaker = JSONObject().put("id", "voice").put("me", true)
        val undo = removeVoiceMark(speaker)
        assertFalse(isMeSpeaker(speaker, null))
        assertTrue(isMeSpeaker(restoreVoiceMark(listOf(speaker), undo), null))
    }

    @Test fun undoRestoresMacMatchingWithoutCreatingALocalMark() {
        val speaker = JSONObject().put("id", "voice").put("seconds", 20)
            .put("vector", JSONArray(listOf(1, 0)))
        val mac = MacVoiceprint(floatArrayOf(1f, 0f), 0.5)
        assertTrue(isMeSpeaker(speaker, mac))
        val undo = removeVoiceMark(speaker)
        assertFalse(isMeSpeaker(speaker, mac))
        val restored = restoreVoiceMark(listOf(speaker), undo)
        assertTrue(isMeSpeaker(restored, mac))
        assertFalse(isMeSpeaker(restored, null))
    }

    @Test fun delayedUndoLeavesANewerLocalVoiceDecisionAlone() {
        val earlier = JSONObject().put("id", "earlier").put("me", true)
        val undo = removeVoiceMark(earlier)
        val newer = JSONObject().put("id", "newer").put("me", true)
        assertNull(restoreVoiceMark(listOf(earlier, newer), undo))
        assertFalse(isMeSpeaker(earlier, null))
        assertTrue(isMeSpeaker(newer, null))
    }
}
