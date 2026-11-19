package top.jinso.tacit.sources

import android.app.Notification
import android.app.Person
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatNotificationDeviceTest {
    private fun builder() = Notification.Builder(
        InstrumentationRegistry.getInstrumentation().targetContext, "test-chat",
    )
    private val me = Person.Builder().setName("我").build()
    private val sender = Person.Builder().setName("小李").build()

    @Test fun latestStructuredIncomingMessageIgnoresHistoryAndPresentationText() {
        val style = Notification.MessagingStyle(me).setConversationTitle("项目组").setGroupConversation(true)
            .addHistoricMessage(Notification.MessagingStyle.Message("历史", 1L, sender))
            .addMessage("旧消息", 2L, sender)
            .addMessage("新消息", 3L, sender)
        val notification = builder().setContentTitle("折叠摘要").setContentText("预览").setStyle(style).build()
        assertEquals(ChatPreview("项目组", "小李", "新消息"), chatPreview(notification, WECHAT_PACKAGE))
    }

    @Test fun privateGroupSummaryInlineReplyAndOutgoingUpdatesDoNotBecomeRecords() {
        val text = builder().setContentTitle("项目组").setContentText("新消息")
        assertNull(chatPreview(text.setVisibility(Notification.VISIBILITY_SECRET).build(), WECHAT_PACKAGE))
        assertNull(chatPreview(text.setVisibility(Notification.VISIBILITY_PRIVATE).setGroup("test-chat")
            .setGroupSummary(true).build(), WECHAT_PACKAGE))
        assertNull(chatPreview(builder().setContentTitle("项目组").setContentText("我回复的内容")
            .setRemoteInputHistory(arrayOf("回复")).build(), WECHAT_PACKAGE))
        val outgoing = Notification.MessagingStyle(me).addMessage("旧消息", 2L, sender)
            .addMessage(Notification.MessagingStyle.Message("我发的消息", 3L, null as Person?))
        assertNull(chatPreview(builder().setStyle(outgoing).build(), WECHAT_PACKAGE))
    }
}
