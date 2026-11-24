package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException

class SpeechPreparationStateTest {
    @Test fun cancellationDuringValidationKeepsExistingModelAndEndsProgress() {
        val validating = SpeechPreparationState(SpeechPreparationPhase.VALIDATING, cancelling = true)
        val finished = validating.finished(CompletionException(ExecutionException(CancellationException())))

        assertEquals(SpeechPreparationPhase.CANCELLED, finished.phase)
        assertEquals("已取消，未更换现有模型", finished.message)
        assertFalse(finished.busy)
        assertFalse(finished.cancelling)
    }

    @Test fun wrongFolderShowsTheMissingFileInSpeechSettings() {
        val importing = SpeechPreparationState(SpeechPreparationPhase.IMPORTING)
        val finished = importing.finished(CompletionException(IllegalArgumentException("缺少模型文件：tokens.txt")))

        assertEquals(SpeechPreparationPhase.ERROR, finished.phase)
        assertEquals("缺少模型文件：tokens.txt", finished.message)
        assertFalse(finished.busy)
    }

    @Test fun recordingPausesRemainVisibleWhenProcessingResumesAfterModelReplacement() {
        val ready = SpeechPreparationState(SpeechPreparationPhase.IMPORTING).finished(null)
        assertEquals(SpeechPreparationPhase.READY, ready.phase)
        val processing = "正在录音，本地转写中"

        assertEquals("手机正在外放声音，暂不录音", recordingStatus(true, false, true, processing))
        assertEquals("麦克风正由其他应用使用，等待系统恢复", recordingStatus(true, true, true, processing))
        assertEquals(processing, recordingStatus(true, false, false, processing))
    }
}
