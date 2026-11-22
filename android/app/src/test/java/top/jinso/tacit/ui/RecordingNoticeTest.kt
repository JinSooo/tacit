package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.audio.AudioState

class RecordingNoticeTest {
    @Test fun normalRecordingSaysNothing() {
        assertNull(recordingNotice(AudioState(true, true, "正在录音，本地转写中"), wanted = true, macProblem = null))
        // Opening the app restarts recording; the moment before the service is up stays quiet too.
        assertNull(recordingNotice(AudioState(false, true, "录音未启动"), wanted = true, macProblem = null))
    }

    @Test fun offOrBrokenGetsOneLine() {
        val off = recordingNotice(AudioState(false, true, "录音已停止"), wanted = false, macProblem = null)!!
        assertTrue(off.start)
        val failed = recordingNotice(AudioState(false, true, "无法启动录音，请保持页面可见后重试"), wanted = true, macProblem = null)!!
        assertTrue(failed.start)
        assertEquals("手机正在外放声音，暂不录音",
            recordingNotice(AudioState(true, true, "手机正在外放声音，暂不录音"), wanted = true, macProblem = null)?.text)
        assertEquals(SettingsRoutes.SPEECH, recordingNotice(AudioState(true, false, "正在录音，音频已加密保存"), true, null)?.route)
        assertEquals(SettingsRoutes.MAC, recordingNotice(AudioState(true, true, "正在录音，本地转写中"), true, "未连接 Mac")?.route)
    }
}
