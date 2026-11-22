package top.jinso.tacit.sources

import org.junit.Assert.*
import org.junit.Test

class ChatPreviewTest {
    @Test fun ordinaryWeChatPreviewCanExposeSeparateGroupAndSender() {
        val preview = plainChatPreview(WECHAT_PACKAGE, "项目组", null, "小李: 明天讨论")
        assertEquals(ChatPreview("项目组", "小李", "明天讨论"), preview)
        assertEquals("小李：明天讨论", preview?.body)
    }

    @Test fun explicitGroupAndSenderTakePriorityOverMessagePunctuation() {
        val preview = plainChatPreview(WECHAT_PACKAGE, "小李", "项目组", "议题: 排期")
        assertEquals(ChatPreview("项目组", "小李", "议题: 排期"), preview)
    }

    @Test fun missingSenderStaysUnknownAndEmptyPreviewsAreDropped() {
        assertEquals(ChatPreview("项目组", null, "明天讨论"),
            plainChatPreview("test.chat", "项目组", "项目组", "明天讨论"))
        assertNull(plainChatPreview(WECHAT_PACKAGE, "微信", null, " "))
    }

    @Test fun weChatUnreadCountIsNotPartOfSenderOrText() {
        assertEquals(ChatPreview("项目组", "小李", "明天讨论"), plainChatPreview(WECHAT_PACKAGE, "项目组", null, "[3条]小李: 明天讨论"))
        assertEquals(ChatPreview("小李", "小李", "明天讨论"), plainChatPreview(WECHAT_PACKAGE, "小李", null, "[2条]明天讨论"))
    }
}
