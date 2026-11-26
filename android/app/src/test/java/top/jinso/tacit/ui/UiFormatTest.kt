package top.jinso.tacit.ui

import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import top.jinso.tacit.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class UiFormatTest {
    private val chinese = UiFormat(TestStrings(AppLang.ZH), AppLang.ZH, use24Hour = false)

    @Test fun englishLabelsHandleClockWidthDurationsAndPlurals() {
        val strings = TestStrings(AppLang.EN)
        val format = UiFormat(strings, AppLang.EN, use24Hour = false)
        val time = LocalDateTime.parse("2026-11-25T12:45:00").atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        assertEquals("12:45 PM", format.clock(time))
        assertEquals("12:45", UiFormat(strings, AppLang.EN, use24Hour = true).clock(time))
        assertEquals("Nov 25, 12:45 PM", format.dateAndClock(time))
        assertEquals("Less than a minute", format.durationLabel(10_000))
        assertEquals("9 hr 27 min", format.durationLabel(567 * 60_000L))
        assertEquals("Phone recording", format.sourceName("android.audio"))
        assertEquals("1 day", format.retentionLabel(1))
        assertEquals("2 days", format.retentionLabel(2))
        assertEquals("1 record", strings.quantity(R.plurals.record_count, 1, "1"))
        assertEquals("1,234 records", strings.quantity(R.plurals.record_count, 1234, "1,234"))
    }

    @Test fun sourceNamesUseUserFacingLabels() {
        assertEquals("手机录音", chinese.sourceName("android.audio"))
        assertEquals("对话", chinese.sourceName("mac.audio"))
        assertEquals("手机聊天", chinese.sourceName("android.notification"))
        assertEquals("手机应用", chinese.sourceName("android.usage"))
        assertEquals("AI 补写", chinese.sourceName("manual.agent"))
        assertEquals("终端", chinese.sourceName("mac.shell"))
        assertEquals("Git", chinese.sourceName("mac.git"))
        assertEquals("剪贴板", chinese.sourceName("mac.clipboard"))
        assertEquals("文件", chinese.sourceName("mac.file"))
        assertEquals("日历", chinese.sourceName("mac.calendar"))
        assertEquals("其他", chinese.sourceName("unknown.source"))
    }

    @Test fun detailTimeShowsOneClockWithinAMinuteAndBothDatesAcrossMidnight() {
        fun time(local: String) = LocalDateTime.parse(local).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val start = time("2026-11-25T23:59:10")
        assertEquals("2026 年 11 月 25 日 23:59 · 不到 1 分钟",
            chinese.detailTimeLabel(start, time("2026-11-25T23:59:45"), true))
        assertEquals("2026 年 11 月 25 日 23:59–2026 年 11 月 26 日 00:00 · 1 分钟",
            chinese.detailTimeLabel(start, time("2026-11-26T00:00:25"), true))
        assertEquals("1,234", countLabel(1234))
    }

    // 精简声音列表：设置页只管理“我”的声音，不平铺陌生人列表。
    @Test fun myVoiceOverviewShowsConfirmedMacSyncOrLongestPlayableCandidate() {
        fun voice(
            id: String,
            me: Boolean,
            seconds: Double,
            last: Long?,
            name: String? = null,
            ignored: Boolean = false,
            sampleAvailable: Boolean = true,
        ) = top.jinso.tacit.audio.AudioSpeaker(id, me, ignored, 1, seconds, sampleAvailable, name, 1, last)

        val day = LocalDateTime.parse("2026-11-25T10:00:00").atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val confirmed = myVoiceOverview(
            listOf(
                voice("a", true, 30.0, day - 86_400_000),
                voice("b", true, 90.0, day),
                voice("c", false, 600.0, null),
                voice("d", false, 40.0, day, ignored = true),
            ),
            macVoiceKnown = false,
        )
        assertEquals(listOf("b", "a"), confirmed.confirmed.map { it.id })
        assertFalse(confirmed.syncedFromMac)
        assertNull(confirmed.candidate)
        assertEquals("今天 10:00 · 共 1 分钟", chinese.speakerStatus(confirmed.confirmed[0], now = day + 3_600_000))
        assertEquals("昨天 10:00 · 不到 1 分钟", chinese.speakerStatus(confirmed.confirmed[1], now = day + 3_600_000))

        val macOnly = myVoiceOverview(listOf(voice("c", false, 600.0, day)), macVoiceKnown = true)
        assertTrue(macOnly.confirmed.isEmpty())
        assertTrue(macOnly.syncedFromMac)
        assertNull(macOnly.candidate)

        val unconfirmed = myVoiceOverview(
            listOf(
                voice("named", false, 300.0, day, name = "小林"),
                voice("expired", false, 200.0, day, sampleAvailable = false),
                voice("ignored", false, 180.0, day, ignored = true),
                voice("short", false, 25.0, day),
                voice("long", false, 90.0, day),
            ),
            macVoiceKnown = false,
        )
        assertTrue(unconfirmed.confirmed.isEmpty())
        assertFalse(unconfirmed.syncedFromMac)
        assertEquals("long", unconfirmed.candidate?.id)
        assertEquals("共 10 分钟", chinese.speakerStatus(voice("c", false, 600.0, null), now = day))
    }
}
