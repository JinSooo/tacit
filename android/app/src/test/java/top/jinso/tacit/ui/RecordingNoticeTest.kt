package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.audio.AudioState
import top.jinso.tacit.sources.Sources

class RecordingNoticeTest {
    @Test fun onlyTheHighestPriorityProblemIsShown() {
        val failure = "暂时无法开启录音，请稍后重试"
        val pause = "手机正在外放声音，暂不录音"
        val pending = AudioState(recording = false, modelsReady = false, message = failure)
        fun notice(state: AudioState, wanted: Boolean = true, microphone: Boolean = true, notifications: Boolean = true) =
            recordingNotice(state, wanted, microphone, notificationsBlocked = notifications, macRemoved = true)

        assertEquals(Sources.AUDIO, notice(pending, microphone = false)?.route)
        assertEquals("录音没有开启", notice(pending.copy(message = ""), wanted = false)?.text)
        assertEquals(failure, notice(pending)?.text)
        assertTrue(notice(pending, wanted = false)!!.start)

        val paused = pending.copy(recording = true, message = pause)
        assertEquals(SettingsRoutes.SPEECH, notice(paused)?.route)
        assertEquals(RecordingNotice(pause), notice(paused.copy(modelsReady = true)))

        val recording = paused.copy(modelsReady = true, message = "")
        assertTrue(notice(recording)!!.openNotifications)
        assertEquals(
            RecordingNotice("已在 Mac 上移除，请在 Mac 的 Tacit 里重新添加这台手机", SettingsRoutes.MAC),
            notice(recording, notifications = false),
        )
    }

    @Test fun normalRecordingAndAutomaticStartStayQuietWithoutARemovedMac() {
        val state = AudioState(recording = true, modelsReady = true, message = "")
        assertNull(recordingNotice(state, true, true, false, false))
        assertNull(recordingNotice(state.copy(recording = false), true, true, false, false))
    }
}
