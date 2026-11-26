package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth

class TimelineDatePickerTest {
    @Test fun monthGridAlignsFirstWeekdayMarksContentAndDisablesFutureDays() {
        val today = LocalDate.of(2026, 11, 26)
        val selected = LocalDate.of(2026, 11, 24)
        val available = setOf(LocalDate.of(2026, 11, 1), selected, today)
        // 2026-11-01 is a Sunday: Monday-first has 6 leading empty slots.
        val zhCells = monthGrid(YearMonth.of(2026, 11), selected, today, available, DayOfWeek.MONDAY)
        assertEquals(0, zhCells.size % 7)
        assertEquals(6, zhCells.takeWhile { it.date == null }.size)
        assertEquals(LocalDate.of(2026, 11, 1), zhCells[6].date)
        assertTrue(zhCells[6].hasContent)
        assertTrue(zhCells[6].enabled)

        val selectedCell = zhCells.single { it.date == selected }
        assertTrue(selectedCell.isSelected)
        assertFalse(selectedCell.isToday)
        assertTrue(selectedCell.hasContent)
        assertTrue(selectedCell.enabled)

        val todayCell = zhCells.single { it.date == today }
        assertTrue(todayCell.isToday)
        assertFalse(todayCell.isSelected)
        assertTrue(todayCell.enabled)

        val futureCell = zhCells.single { it.date == LocalDate.of(2026, 11, 27) }
        assertFalse(futureCell.enabled)
        assertFalse(futureCell.hasContent)

        // Sunday-first has 0 leading empty slots for 2026-11-01.
        val enCells = monthGrid(YearMonth.of(2026, 11), selected, today, available, DayOfWeek.SUNDAY)
        assertEquals(0, enCells.size % 7)
        assertEquals(LocalDate.of(2026, 11, 1), enCells[0].date)
    }

    @Test fun nextMonthAndReturnToTodayRespectCurrentDate() {
        val today = LocalDate.of(2026, 11, 26)
        val currentMonth = YearMonth.of(2026, 11)
        val previousMonth = YearMonth.of(2026, 10)

        assertFalse(canGoToNextMonth(currentMonth, today))
        assertTrue(canGoToNextMonth(previousMonth, today))

        assertFalse(showsReturnToToday(today, currentMonth, today))
        assertTrue(showsReturnToToday(today.minusDays(1), currentMonth, today))
        assertTrue(showsReturnToToday(today, previousMonth, today))
    }

    @Test fun monthHeadingAndWeekdayHeadersFollowAppLanguage() {
        val month = YearMonth.of(2026, 11)
        assertEquals("2026 年 11 月", calendarMonthTitle(month, AppLang.ZH, TestStrings(AppLang.ZH)))
        assertEquals("November 2026", calendarMonthTitle(month, AppLang.EN, TestStrings(AppLang.EN)))

        val zhHeaders = calendarWeekdayHeaders(AppLang.ZH)
        assertEquals(7, zhHeaders.size)
        assertEquals("一", zhHeaders.first())
        assertEquals("日", zhHeaders.last())

        val enHeaders = calendarWeekdayHeaders(AppLang.EN)
        assertEquals(7, enHeaders.size)
        assertEquals("Sun", enHeaders.first())
        assertEquals("Sat", enHeaders.last())
    }
}
