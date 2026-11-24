package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test

class SamplePlaybackTest {
    @Test fun tappingAgainStopsAlreadyPlayingAudio() {
        val playback = SamplePlayback()
        var playing = false
        val sample = checkNotNull(playback.toggle("voice-a"))
        playback.play(sample, start = { playing = true }, close = { playing = false })
        assertTrue(playing)
        assertEquals("voice-a", playback.speaker.value)
        assertNull(playback.toggle("voice-a"))
        assertFalse(playing)
        assertNull(playback.speaker.value)
    }

    @Test fun voiceDecisionStopsPendingPlaybackAndDiscardsTheLoadedSample() {
        val playback = SamplePlayback()
        val sample = checkNotNull(playback.toggle("voice-a"))
        playback.stop()
        var released = false
        playback.play(sample, start = { fail("Cancelled audio played") }, close = { released = true })
        assertTrue(released)
        assertNull(playback.speaker.value)
    }

    @Test fun aLateCompletionCannotStopTheNextSpeaker() {
        val playback = SamplePlayback()
        val old = checkNotNull(playback.toggle("voice-a"))
        val next = checkNotNull(playback.toggle("voice-b"))
        playback.finish(old)
        assertEquals("voice-b", playback.speaker.value)
        playback.finish(next)
        assertNull(playback.speaker.value)
    }
}
