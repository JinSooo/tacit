package top.jinso.tacit.ui.onboarding

import org.junit.Assert.*
import org.junit.Test

class CollectionHealthTest {
    private val chat = SourceHealth("android.notification", "聊天通知", true, true, "系统权限已允许")
    private val ready = CollectionHealth(
        paused = false, sources = listOf(chat), microphoneGranted = true, audioEnabled = true, audioCaptureWanted = true,
        audioRunning = true, audioStarting = false, audioSilenced = false,
        notificationsEnabled = true,
        audioChannel = ChannelAccess.ALLOWED,
        batteryExempt = true, backgroundRestricted = false, powerSave = false,
    )

    @Test fun `granted chat access that the system never delivers is reported`() {
        // Reported case: HyperOS refused to bind the listener without autostart; 108 WeChat notifications were lost
        // while the checklist said "已允许".
        assertTrue(recoveryIssues(ready.copy(notificationListenerConnected = true)).isEmpty())
        val issue = recoveryIssues(ready.copy(notificationListenerConnected = false)).single()
        assertEquals("聊天通知没有接通", issue.title)
        assertTrue(issue.detail.contains("自启动"))
        assertTrue(recoveryIssues(ready.copy(notificationListenerConnected = false, paused = true)).isEmpty())
    }

    @Test fun `stopped audio never asks for microphone recording or its notification`() {
        val stopped = ready.copy(sources = emptyList(), audioCaptureWanted = false,
            audioRunning = false, microphoneGranted = false, notificationsEnabled = false,
            audioChannel = ChannelAccess.BLOCKED)
        assertTrue(recoveryIssues(stopped).isEmpty())
        assertTrue(recoveryIssues(stopped.copy(microphoneGranted = true)).isEmpty())
        assertFalse(stopped.microphoneCaptureExpected)
        assertTrue(audioPermissionText(stopped).contains("未开启麦克风采集"))
        assertEquals("未开启麦克风采集", audioReadyText(stopped))
    }

    @Test fun `wanted capture survives cold start but deliberately stopped capture stays quiet`() {
        val restarted = ready.copy(sources = emptyList(), audioRunning = false)
        assertEquals(RecoveryAction.AUDIO, recoveryIssues(restarted).single().action)
        assertTrue(recoveryIssues(restarted.copy(audioCaptureWanted = false)).isEmpty())
        assertTrue(recoveryIssues(restarted.copy(paused = true)).isEmpty())
        assertEquals(RecoveryAction.SOURCE, recoveryIssues(restarted.copy(microphoneGranted = false)).single().action)
        assertEquals("当前未运行，需要手动开始", audioReadyText(restarted))
        assertEquals("需要麦克风权限", audioReadyText(restarted.copy(microphoneGranted = false)))
        assertEquals("系统权限尚未允许", audioPermissionText(restarted.copy(microphoneGranted = false)))
    }

    @Test fun `observed starting or running capture is still shown before the saved intent refreshes`() {
        val running = ready.copy(audioCaptureWanted = false)
        assertTrue(running.microphoneCaptureExpected)
        assertEquals("录音服务运行中", audioReadyText(running))
        val starting = running.copy(audioRunning = false, audioStarting = true)
        assertTrue(starting.microphoneCaptureExpected)
        assertEquals("正在启动", audioReadyText(starting))
        assertTrue(recoveryIssues(starting).isEmpty())
    }

    @Test fun `stopped capture remains quiet even if the audio runtime cannot be opened`() {
        val stopped = ready.copy(sources = emptyList(), audioCaptureWanted = false, audioRunning = null)
        assertTrue(recoveryIssues(stopped).isEmpty())
        assertEquals("未开启麦克风采集", audioReadyText(stopped))
        assertEquals(RecoveryAction.AUDIO, recoveryIssues(stopped.copy(audioCaptureWanted = true)).single().action)
    }

    @Test fun `audio stopped or cold process gets explicit manual recovery`() {
        val issue = recoveryIssues(ready.copy(audioRunning = false)).single()
        assertEquals(RecoveryAction.AUDIO, issue.action)
        assertTrue(issue.detail.contains("手动开始"))
        assertFalse(issue.title.contains("系统停止")) // We do not know why it stopped.
    }

    @Test fun `revoked microphone wins over stopped recording`() {
        val issue = recoveryIssues(ready.copy(microphoneGranted = false, audioRunning = false)).single()
        assertEquals(RecoveryAction.SOURCE, issue.action)
        assertEquals("android.audio", issue.source)
    }

    @Test fun `silenced audio asks to check access instead of restarting service`() {
        val issue = recoveryIssues(ready.copy(audioSilenced = true)).single()
        assertEquals(RecoveryAction.AUDIO, issue.action)
        assertTrue(issue.detail.contains("等待系统恢复"))
    }

    @Test fun `starting recording is not reported as interrupted`() {
        assertTrue(recoveryIssues(ready.copy(audioRunning = false, audioStarting = true)).isEmpty())
    }

    @Test fun `runtime read failure is not reported as stopped or healthy`() {
        val issue = recoveryIssues(ready.copy(audioRunning = null)).single()
        assertEquals("暂时无法检查录音", issue.title)
    }

    @Test fun `intentional pause suppresses permission and restart prompts`() {
        val health = ready.copy(paused = true, audioRunning = false, microphoneGranted = false,
            notificationsEnabled = false)
        assertTrue(recoveryIssues(health).isEmpty())
        assertEquals("已暂停", sourceStatus(chat, health))
    }

    @Test fun `disabled sources never ask for grants or restarts`() {
        val source = chat.copy(enabled = false, granted = false)
        val health = ready.copy(sources = listOf(source), audioEnabled = false, microphoneGranted = false,
            audioRunning = false, notificationsEnabled = false)
        assertTrue(recoveryIssues(health).isEmpty())
        assertEquals("未启用", sourceStatus(source, health))
    }

    @Test fun `notification denial is not proof that a foreground service stopped`() {
        val issues = recoveryIssues(ready.copy(notificationsEnabled = false))
        assertEquals(RecoveryAction.NOTIFICATIONS, issues.single().action)
        assertTrue(issues.single().detail.contains("可能仍在运行"))
    }

    @Test fun `blocked channel matters even with app notifications allowed`() {
        assertEquals(RecoveryAction.NOTIFICATIONS,
            recoveryIssues(ready.copy(audioChannel = ChannelAccess.BLOCKED)).single().action)
    }

    @Test fun `uncreated or unreadable channels are not invented permission failures`() {
        assertTrue(recoveryIssues(ready.copy(audioChannel = ChannelAccess.NOT_CREATED,
            notificationsEnabled = null)).isEmpty())
    }

    @Test fun `disabled recording channel does not prompt for notifications`() {
        assertTrue(recoveryIssues(ready.copy(audioEnabled = false, audioChannel = ChannelAccess.BLOCKED)).isEmpty())
    }

    @Test fun `other enabled sources losing permission remain actionable`() {
        val source = SourceHealth("android.usage", "应用使用", true, false, "系统权限尚未允许")
        val issue = recoveryIssues(ready.copy(sources = listOf(chat, source))).single()
        assertEquals("android.usage", issue.source)
        assertEquals(RecoveryAction.SOURCE, issue.action)
    }
}
