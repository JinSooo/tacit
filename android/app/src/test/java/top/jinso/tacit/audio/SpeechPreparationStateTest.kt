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

    @Test fun wrongFolderShowsAnInstructionInSpeechSettings() {
        val importing = SpeechPreparationState(SpeechPreparationPhase.IMPORTING)
        val finished = importing.finished(CompletionException(SpeechModelProblem("文件夹缺少语音模型文件，请重新选择")))

        assertEquals(SpeechPreparationPhase.ERROR, finished.phase)
        assertEquals("文件夹缺少语音模型文件，请重新选择", finished.message)
        assertFalse(finished.busy)
    }

    @Test fun exceptionDetailsAreNotShownToTheUser() {
        val error = IllegalArgumentException("模型损坏 /data/local/private-model")
        val finished = SpeechPreparationState().finished(error)
        assertEquals("模型准备失败，请检查网络、存储空间和模型文件后重试", finished.message)
    }

    @Test fun recordingPausesRemainVisibleWhenProcessingResumesAfterModelReplacement() {
        val ready = SpeechPreparationState(SpeechPreparationPhase.IMPORTING).finished(null)
        assertEquals(SpeechPreparationPhase.READY, ready.phase)
        assertTrue(ready.message.isEmpty())
        val processing = "正在录音，本地转写中"

        assertEquals("手机正在外放声音，暂不录音", recordingStatus(true, false, true, processing))
        assertEquals("麦克风正由其他应用使用，等待系统恢复", recordingStatus(true, true, true, processing))
        assertEquals(processing, recordingStatus(true, false, false, processing))
    }
}
