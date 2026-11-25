package top.jinso.tacit.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.util.concurrent.CompletableFuture

class AudioRecordDeletionTest {
    @Test fun deletingHistoryUsesOnlyTheExactRecordAndNeverTouchesCaptureControls() {
        val deleted = mutableListOf<String>()
        val completed = CompletableFuture.completedFuture(Unit)
        val controller = AudioController(
            lazy { error("Historical deletion must not access the recording controls") },
            deleteHistoryAudio = { id ->
                deleted += id
                completed
            },
        )

        assertSame(completed, controller.deleteRecordAudio("old-record"))
        assertEquals(listOf("old-record"), deleted)
    }
}
