package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.sync.MacVoiceprint

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
        val mac = MacVoiceprint(floatArrayOf(2f, 0f), .49)
        fun voice(x: Float, y: Float, seconds: Double) =
            org.json.JSONObject().putVector("vector", floatArrayOf(x, y)).put("seconds", seconds)
        assertFalse(isMeSpeaker(null, mac))
        assertFalse(isMeSpeaker(voice(1f, 0f, 30.0), null))
        assertFalse(isMeSpeaker(voice(0f, 1f, 30.0), mac))
        assertFalse(isMeSpeaker(voice(1f, 0f, 30.0).put("ignored", true), mac))
        assertTrue(isMeSpeaker(voice(1f, 0f, 30.0), mac))
        assertTrue(isMeSpeaker(voice(0f, 1f, 1.0).put("me", true), null))
        // Reported case: one short playback voice that happened to resemble the user unlocked hours of video audio.
        assertFalse(isMeSpeaker(voice(1f, 0f, MAC_ME_MIN_SECONDS - .1), mac))
        assertEquals("我", transcriptSpeakerLabel(voice(1f, .2f, 30.0), mac) { 1 })
        assertEquals("对方 2", transcriptSpeakerLabel(voice(0f, 1f, 30.0), mac) { 2 })
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
