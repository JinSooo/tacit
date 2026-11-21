package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test

class AudioPolicyTest {
    @Test fun songsAreDroppedEvenWhenSingingLooksLikeSpeech() {
        // Reported case: songs played by the Mac became "is this your voice?" candidates on the phone.
        assertTrue(AudioPolicy.music(mapOf(137 to .82f, 0 to .9f)))
        assertTrue(AudioPolicy.music(mapOf(266 to .45f, 0 to .8f)))
        // Real talking on the same phone peaked at .29 for music-like classes.
        assertFalse(AudioPolicy.music(mapOf(0 to .77f, 137 to .29f)))
        assertFalse(AudioPolicy.music(emptyMap()))
    }
    @Test fun phoneSpeakerPlaybackPausesCaptureButHeadphonesDoNot() {
        val speaker = android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val wired = android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
        val bluetooth = android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
        // Reported case: short videos played aloud became "is this your voice?" candidates.
        assertTrue(AudioPolicy.speakerPlayback(true, listOf(speaker)))
        assertFalse(AudioPolicy.speakerPlayback(true, listOf(speaker, wired)))
        assertFalse(AudioPolicy.speakerPlayback(true, listOf(speaker, bluetooth)))
        assertFalse(AudioPolicy.speakerPlayback(false, listOf(speaker)))
    }
    @Test fun candidateRequiresDurationAsWellAsCount() {
        assertFalse(AudioPolicy.candidate(2, 14.99))
        assertFalse(AudioPolicy.candidate(1, 44.99))
        assertTrue(AudioPolicy.candidate(2, 15.0))
        assertTrue(AudioPolicy.candidate(1, 45.0))
    }
    @Test fun unknownAndOtherSpeakersMustNeverPassTheUserGate() {
        val me = AudioPolicy.unit(floatArrayOf(1f, 0f))
        assertFalse(AudioPolicy.mayTranscribe(null, me, true))
        assertFalse(AudioPolicy.mayTranscribe(me, me, false))
        assertFalse(AudioPolicy.mayTranscribe(me, floatArrayOf(0f, 1f), true))
        assertFalse(AudioPolicy.mayTranscribe(me, floatArrayOf(1f), true))
        assertTrue(AudioPolicy.mayTranscribe(me, me, true))
    }
    @Test fun retentionUsesCaptureTimeAndExactBoundary() {
        val now = 20 * 86_400_000L
        assertFalse(AudioPolicy.expired(now - 7 * 86_400_000L, now, 7))
        assertTrue(AudioPolicy.expired(now - 7 * 86_400_000L - 1, now, 7))
    }
    @Test fun invalidEmbeddingsAreRejected() {
        for (v in listOf(floatArrayOf(), floatArrayOf(0f, 0f), floatArrayOf(Float.NaN))) {
            try { AudioPolicy.unit(v); fail("Invalid vector accepted") } catch (_: IllegalArgumentException) { }
        }
        assertEquals(1.0, AudioPolicy.cosine(AudioPolicy.unit(floatArrayOf(3f, 4f)),
            AudioPolicy.unit(floatArrayOf(3f, 4f))), 1e-6)
    }
}
