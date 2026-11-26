package top.jinso.tacit.audio

import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import top.jinso.tacit.R
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException

class SpeechPreparationStateTest {
    private val chinese = TestStrings(AppLang.ZH)
    @Test fun cancellationDuringValidationKeepsExistingModelAndEndsProgress() {
        val validating = SpeechPreparationState(SpeechPreparationPhase.VALIDATING, cancelling = true)
        val finished = validating.finished(CompletionException(ExecutionException(CancellationException())))

        assertEquals(SpeechPreparationPhase.CANCELLED, finished.phase)
        assertEquals("已取消，未更换现有模型", finished.message?.resolve(chinese))
        assertFalse(finished.busy)
        assertFalse(finished.cancelling)
    }

    @Test fun wrongFolderShowsAnInstructionInSpeechSettings() {
        val importing = SpeechPreparationState(SpeechPreparationPhase.IMPORTING)
        val finished = importing.finished(CompletionException(SpeechModelProblem(R.string.model_folder_incomplete)))

        assertEquals(SpeechPreparationPhase.ERROR, finished.phase)
        assertEquals("文件夹缺少语音模型文件，请重新选择", finished.message?.resolve(chinese))
        assertFalse(finished.busy)
    }

    @Test fun exceptionDetailsAreNotShownToTheUser() {
        val error = IllegalArgumentException("模型损坏 /data/local/private-model")
        val finished = SpeechPreparationState().finished(error)
        assertEquals("模型准备失败，请检查网络、存储空间和模型文件后重试", finished.message?.resolve(chinese))
    }

    @Test fun recordingPausesRemainVisibleWhenProcessingResumesAfterModelReplacement() {
        val ready = SpeechPreparationState(SpeechPreparationPhase.IMPORTING).finished(null)
        assertEquals(SpeechPreparationPhase.READY, ready.phase)
        assertNull(ready.message)
        val processing = R.string.audio_processing_failed

        assertEquals(R.string.recording_speaker_playing, recordingStatus(true, false, true, processing))
        assertEquals(R.string.recording_mic_busy, recordingStatus(true, true, true, processing))
        assertEquals(processing, recordingStatus(true, false, false, processing))
    }
}
