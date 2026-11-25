package top.jinso.tacit.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class UiFormatTest {
    @Test fun sourceNamesUseUserFacingLabels() {
        assertEquals("手机录音", sourceName("android.audio"))
        assertEquals("对话", sourceName("mac.audio"))
        assertEquals("手机聊天", sourceName("android.notification"))
        assertEquals("手机应用", sourceName("android.usage"))
        assertEquals("AI 补写", sourceName("manual.agent"))
        assertEquals("终端", sourceName("mac.shell"))
        assertEquals("Git", sourceName("mac.git"))
        assertEquals("剪贴板", sourceName("mac.clipboard"))
        assertEquals("文件", sourceName("mac.file"))
        assertEquals("日历", sourceName("mac.calendar"))
        assertEquals("其他", sourceName("unknown.source"))
    }

    @Test fun detailTimeShowsOneClockWithinAMinuteAndBothDatesAcrossMidnight() {
        fun time(local: String) = LocalDateTime.parse(local).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val start = time("2026-11-25T23:59:10")
        assertEquals("2026 年 11 月 25 日 23:59 · 不到 1 分钟",
            detailTimeLabel(start, time("2026-11-25T23:59:45"), true))
        assertEquals("2026 年 11 月 25 日 23:59–2026 年 11 月 26 日 00:00 · 1 分钟",
            detailTimeLabel(start, time("2026-11-26T00:00:25"), true))
        assertEquals("1,234", countLabel(1234))
    }
}
