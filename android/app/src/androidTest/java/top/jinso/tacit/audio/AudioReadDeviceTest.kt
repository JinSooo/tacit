package top.jinso.tacit.audio

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Regression (2026-11-23, after a reinstall): the phone timeline kept spinning while a transcription
 * backlog drained, because page reads queued on the single processing thread.
 */
@RunWith(AndroidJUnit4::class)
class AudioReadDeviceTest {
    @Test fun pageReadsDoNotWaitForAProcessingDrain() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Load the index once first: on a phone with weeks of recordings the first decrypt alone takes seconds,
        // which is not what this test is about.
        AudioController(context).listClips().get(30, TimeUnit.SECONDS)
        val busy = CountDownLatch(1)
        val started = CountDownLatch(1)
        // Stand-in for a long drain: holds the processing thread but not the store lock, like real inference.
        val drain = AudioRuntime.get(context).submit { started.countDown(); busy.await(10, TimeUnit.SECONDS) }
        try {
            started.await(5, TimeUnit.SECONDS)
            val audio = AudioController(context)
            audio.listConversations().get(2, TimeUnit.SECONDS)
            audio.listSpeakers().get(2, TimeUnit.SECONDS)
            audio.macVoiceKnown().get(2, TimeUnit.SECONDS)
            audio.listClips().get(2, TimeUnit.SECONDS)
        } finally {
            busy.countDown()
            drain.get(10, TimeUnit.SECONDS)
        }
    }
}
