package top.jinso.tacit.ui

import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import top.jinso.tacit.R
import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.audio.AudioState
import top.jinso.tacit.sources.Sources

class RecordingNoticeTest {
    private val strings = TestStrings(AppLang.ZH)
    @Test fun onlyTheHighestPriorityProblemIsShown() {
        val failure = "暂时无法开启录音，请稍后重试"
        val pause = "手机正在外放声音，暂不录音"
        val pending = AudioState(recording = false, modelsReady = false, message = R.string.recording_start_failed)
        fun notice(state: AudioState, wanted: Boolean = true, microphone: Boolean = true, notifications: Boolean = true) =
            recordingNotice(state, wanted, microphone, notificationsBlocked = notifications, macRemoved = true, strings = strings, backgroundLimited = true)

        assertEquals(Sources.AUDIO, notice(pending, microphone = false)?.route)
        assertEquals("录音没有开启", notice(pending.copy(message = null), wanted = false)?.text)
        assertEquals(failure, notice(pending)?.text)
        assertTrue(notice(pending, wanted = false)!!.start)

        val paused = pending.copy(recording = true, message = R.string.recording_speaker_playing)
        assertEquals(SettingsRoutes.SPEECH, notice(paused)?.route)
        assertEquals(RecordingNotice(pause), notice(paused.copy(modelsReady = true)))

        val recording = paused.copy(modelsReady = true, message = null)
        assertTrue(notice(recording)!!.openNotifications)
        assertEquals(
            RecordingNotice("已在 Mac 上移除，请在 Mac 的 Tacit 里重新添加这台手机", SettingsRoutes.MAC),
            notice(recording, notifications = false),
        )
    }

    @Test fun backgroundRestrictionOnlyAppearsForEnabledRecordingWithModelsReady() {
        val state = AudioState(recording = true, modelsReady = true, message = null)
        fun notice(state: AudioState, wanted: Boolean) =
            recordingNotice(state, wanted, true, false, false, strings, backgroundLimited = true)

        assertEquals(SettingsRoutes.BACKGROUND, notice(state, true)?.route)
        assertEquals(SettingsRoutes.SPEECH, notice(state.copy(modelsReady = false), true)?.route)
        assertTrue(notice(state.copy(recording = false), false)!!.start)
    }

    @Test fun normalRecordingAndAutomaticStartStayQuietWithoutARemovedMac() {
        val state = AudioState(recording = true, modelsReady = true, message = null)
        assertNull(recordingNotice(state, true, true, false, false, strings))
        assertNull(recordingNotice(state.copy(recording = false), true, true, false, false, strings))
    }
}
