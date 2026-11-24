package top.jinso.tacit.audio

import java.util.concurrent.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SpeechEngineReplacementTest {
    @Test fun queuedAudioUsesTheNewModelAfterReplacement() {
        var activeModel = "previous"
        var renderedWith: String? = null
        replaceSpeechEngine(
            closeEngine = { renderedWith = null },
            resumeProcessing = { renderedWith = activeModel },
            install = { activeModel = "updated" },
        )
        assertEquals("updated", renderedWith)
    }

    @Test fun cancelledReplacementResumesProcessingWithThePreviousModel() {
        var activeModel = "previous"
        var renderedWith: String? = null
        assertThrows(CancellationException::class.java) {
            replaceSpeechEngine(
                closeEngine = { renderedWith = null },
                resumeProcessing = { renderedWith = activeModel },
                install = { throw CancellationException() },
            )
        }
        assertEquals("previous", renderedWith)
    }
}
