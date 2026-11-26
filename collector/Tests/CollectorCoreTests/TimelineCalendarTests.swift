import Foundation
import Testing
@testable import CollectorCore

private func gregorianCalendar(firstWeekday: Int = 1) -> Calendar {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
  cal.firstWeekday = firstWeekday
  return cal
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
  calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

@Test func calendarGridAlignsFirstWeekdayAndMonthLength() {
  // 2026-11-01 is Sunday (weekday = 1), 30 days.
  let sunCal = gregorianCalendar(firstWeekday: 1)
  let today = makeDate(2026, 11, 26, calendar: sunCal)
  let selected = makeDate(2026, 11, 20, calendar: sunCal)
  let month = TimelineCalendar.Month(year: 2026, month: 11)
  let active: Set<String> = ["2026-11-01", "2026-11-20", "2026-11-26", "2026-11-28"]

  let sunCells = TimelineCalendar.cells(for: month, selectedDay: selected, today: today, activeDayKeys: active, calendar: sunCal)
  #expect(sunCells.count == 35)
  #expect(sunCells.first?.dayNumber == 1)
  #expect(sunCells.first?.dayKey == "2026-11-01")
  #expect(sunCells.first?.hasActivity == true)
  #expect(sunCells.compactMap(\.dayNumber) == Array(1...30))

  // Monday-first calendar shifts Nov 1 (Sunday) to column 7 -> 6 leading blanks.
  let monCal = gregorianCalendar(firstWeekday: 2)
  let monCells = TimelineCalendar.cells(for: month, selectedDay: selected, today: today, activeDayKeys: active, calendar: monCal)
  #expect(monCells.count == 42)
  #expect(monCells.prefix(6).allSatisfy { $0.date == nil })
  #expect(monCells[6].dayNumber == 1)
  #expect(monCells.compactMap(\.dayNumber) == Array(1...30))
}

@Test func calendarMarksSelectedTodayFutureAndActivityStates() {
  let cal = gregorianCalendar(firstWeekday: 1)
  let today = makeDate(2026, 11, 26, calendar: cal)
  let selected = makeDate(2026, 11, 20, calendar: cal)
  let month = TimelineCalendar.Month(year: 2026, month: 11)
  let active: Set<String> = ["2026-11-20", "2026-11-26", "2026-11-29"]

  let cells = TimelineCalendar.cells(for: month, selectedDay: selected, today: today, activeDayKeys: active, calendar: cal)
  let byKey = Dictionary(uniqueKeysWithValues: cells.compactMap { cell in cell.dayKey.map { ($0, cell) } })

  #expect(byKey["2026-11-20"]?.isSelected == true)
  #expect(byKey["2026-11-20"]?.isToday == false)
  #expect(byKey["2026-11-20"]?.hasActivity == true)
  #expect(byKey["2026-11-20"]?.isSelectable == true)

  #expect(byKey["2026-11-26"]?.isToday == true)
  #expect(byKey["2026-11-26"]?.isSelected == false)
  #expect(byKey["2026-11-26"]?.isFuture == false)
  #expect(byKey["2026-11-26"]?.hasActivity == true)
  #expect(byKey["2026-11-26"]?.isSelectable == true)

  // Future dates are disabled and never display activity dots.
  #expect(byKey["2026-11-27"]?.isFuture == true)
  #expect(byKey["2026-11-27"]?.isSelectable == false)
  #expect(byKey["2026-11-29"]?.isFuture == true)
  #expect(byKey["2026-11-29"]?.hasActivity == false)
}

@Test func calendarHandlesMonthBoundariesAndLeapYears() {
  let cal = gregorianCalendar(firstWeekday: 1)
  let jan = TimelineCalendar.Month(year: 2026, month: 1)
  #expect(jan.shifted(byMonths: -1, calendar: cal) == TimelineCalendar.Month(year: 2025, month: 12))
  #expect(TimelineCalendar.Month(year: 2025, month: 12).shifted(byMonths: 1, calendar: cal) == jan)
  #expect(jan.key == "2026-01")

  let febLeap = TimelineCalendar.cells(
    for: TimelineCalendar.Month(year: 2024, month: 2),
    selectedDay: makeDate(2024, 2, 10, calendar: cal),
    today: makeDate(2026, 11, 26, calendar: cal),
    activeDayKeys: ["2024-02-29"],
    calendar: cal
  )
  #expect(febLeap.compactMap(\.dayNumber).count == 29)
  #expect(febLeap.first { $0.dayKey == "2024-02-29" }?.hasActivity == true)

  let febCommon = TimelineCalendar.cells(
    for: TimelineCalendar.Month(year: 2026, month: 2),
    selectedDay: makeDate(2026, 2, 10, calendar: cal),
    today: makeDate(2026, 11, 26, calendar: cal),
    activeDayKeys: [],
    calendar: cal
  )
  #expect(febCommon.compactMap(\.dayNumber).count == 28)

  let today = makeDate(2026, 11, 26, calendar: cal)
  #expect(TimelineCalendar.canAdvance(from: TimelineCalendar.Month(year: 2026, month: 10), today: today, calendar: cal) == true)
  #expect(TimelineCalendar.canAdvance(from: TimelineCalendar.Month(year: 2026, month: 11), today: today, calendar: cal) == false)
  #expect(TimelineCalendar.canAdvance(from: TimelineCalendar.Month(year: 2026, month: 12), today: today, calendar: cal) == false)

  #expect(TimelineCalendar.showsJumpToToday(selectedDay: today, displayedMonth: TimelineCalendar.Month(year: 2026, month: 11), today: today, calendar: cal) == false)
  #expect(TimelineCalendar.showsJumpToToday(selectedDay: makeDate(2026, 11, 25, calendar: cal), displayedMonth: TimelineCalendar.Month(year: 2026, month: 11), today: today, calendar: cal) == true)
  #expect(TimelineCalendar.showsJumpToToday(selectedDay: today, displayedMonth: TimelineCalendar.Month(year: 2026, month: 10), today: today, calendar: cal) == true)
}

@Test func calendarLocalizationAndActiveDaysResponseDecoding() throws {
  let sunCal = gregorianCalendar(firstWeekday: 1)
  let monCal = gregorianCalendar(firstWeekday: 2)
  #expect(TimelineCalendar.weekdayHeaders(calendar: sunCal, lang: .zh) == ["日", "一", "二", "三", "四", "五", "六"])
  #expect(TimelineCalendar.weekdayHeaders(calendar: monCal, lang: .zh) == ["一", "二", "三", "四", "五", "六", "日"])
  #expect(TimelineCalendar.weekdayHeaders(calendar: sunCal, lang: .en) == ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
  #expect(TimelineCalendar.weekdayHeaders(calendar: monCal, lang: .en) == ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])

  let nov = TimelineCalendar.Month(year: 2026, month: 11)
  #expect(TimelineCalendar.monthTitle(nov, calendar: sunCal, lang: .zh) == "2026 年 11 月")
  #expect(TimelineCalendar.monthTitle(nov, calendar: sunCal, lang: .en) == "November 2026")

  let day = makeDate(2026, 11, 26, calendar: sunCal)
  #expect(TimelineCalendar.dayAccessibilityLabel(day, isToday: true, hasActivity: true, calendar: sunCal, lang: .zh) == "2026 年 11 月 26 日，今天，有记录")
  #expect(TimelineCalendar.dayAccessibilityLabel(day, isToday: true, hasActivity: true, calendar: sunCal, lang: .en) == "November 26, 2026, Today, has activity")

  let data = Data(#"{"month":"2026-11","dates":["2026-11-03","2026-11-26"]}"#.utf8)
  let decoded = try HubJSON.decoder().decode(ActiveDaysResponse.self, from: data)
  #expect(decoded == ActiveDaysResponse(month: "2026-11", dates: ["2026-11-03", "2026-11-26"]))
}

@Test func calendarUsesGregorianProtocolKeysUnderNonGregorianSystemCalendar() {
  var buddhist = Calendar(identifier: .buddhist)
  buddhist.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
  buddhist.firstWeekday = 2

  let greg = gregorianCalendar(firstWeekday: 2)
  let today = makeDate(2026, 11, 26, calendar: greg)
  let selected = makeDate(2026, 11, 15, calendar: greg)

  let month = TimelineCalendar.Month(containing: today, calendar: buddhist)
  #expect(month == TimelineCalendar.Month(year: 2026, month: 11))
  #expect(month.key == "2026-11")
  #expect(TimelineCalendar.monthTitle(month, calendar: buddhist, lang: .zh) == "2026 年 11 月")
  #expect(TimelineCalendar.monthTitle(month, calendar: buddhist, lang: .en) == "November 2026")
  #expect(TimelineCalendar.dayAccessibilityLabel(today, isToday: true, hasActivity: true, calendar: buddhist, lang: .en) == "November 26, 2026, Today, has activity")

  let cells = TimelineCalendar.cells(
    for: month,
    selectedDay: selected,
    today: today,
    activeDayKeys: ["2026-11-15", "2026-11-26"],
    calendar: buddhist
  )
  let byKey = Dictionary(uniqueKeysWithValues: cells.compactMap { cell in cell.dayKey.map { ($0, cell) } })
  #expect(byKey["2026-11-15"]?.isSelected == true)
  #expect(byKey["2026-11-15"]?.hasActivity == true)
  #expect(byKey["2026-11-26"]?.isToday == true)
  #expect(byKey["2026-11-26"]?.hasActivity == true)
  #expect(cells.prefix(6).allSatisfy { $0.date == nil })
}
