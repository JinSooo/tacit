import Foundation

/// Hub `GET /v1/days/active?month=YYYY-MM` 与 `days.active` 设备操作的响应体。
public struct ActiveDaysResponse: Decodable, Equatable, Sendable {
  public let month: String
  public let dates: [String]

  public init(month: String, dates: [String]) {
    self.month = month
    self.dates = dates
  }
}

/// 时间线月历选择器的纯逻辑：月份导航、网格生成、未来日禁用、星期表头与无障碍文案。
public enum TimelineCalendar {
  public struct Month: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
      self.year = year
      self.month = month
    }

    public init(containing date: Date, calendar: Calendar = .current) {
      let c = calendar.dateComponents([.year, .month], from: date)
      self.year = c.year ?? 1970
      self.month = c.month ?? 1
    }

    public var key: String {
      String(format: "%04d-%02d", year, month)
    }

    public func startDate(calendar: Calendar = .current) -> Date? {
      calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    public func shifted(byMonths delta: Int, calendar: Calendar = .current) -> Month {
      guard let start = startDate(calendar: calendar),
            let shifted = calendar.date(byAdding: .month, value: delta, to: start) else {
        let total = year * 12 + (month - 1) + delta
        let nextYear = total >= 0 ? total / 12 : (total - 11) / 12
        let nextMonth = ((total % 12) + 12) % 12 + 1
        return Month(year: nextYear, month: nextMonth)
      }
      return Month(containing: shifted, calendar: calendar)
    }

    public static func < (lhs: Month, rhs: Month) -> Bool {
      lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
    }
  }

  public struct Cell: Identifiable, Hashable, Sendable {
    public let id: String
    public let date: Date?
    public let dayKey: String?
    public let dayNumber: Int?
    public let isSelected: Bool
    public let isToday: Bool
    public let isFuture: Bool
    public let hasActivity: Bool

    public var isSelectable: Bool { date != nil && !isFuture }
  }

  /// 是否允许翻到下一个月：不可超出包含 today 的自然月。
  public static func canAdvance(from displayed: Month, today: Date, calendar: Calendar = .current) -> Bool {
    displayed < Month(containing: today, calendar: calendar)
  }

  /// 当选中的不是今天或浏览的不是本月时，底部提供“回到今天”快捷入口。
  public static func showsJumpToToday(
    selectedDay: Date,
    displayedMonth: Month,
    today: Date,
    calendar: Calendar = .current
  ) -> Bool {
    let todayStart = calendar.startOfDay(for: today)
    let selectedStart = calendar.startOfDay(for: selectedDay)
    return selectedStart != todayStart || displayedMonth != Month(containing: todayStart, calendar: calendar)
  }

  /// 按 `calendar.firstWeekday` 排列的 7 列星期表头。
  public static func weekdayHeaders(calendar: Calendar, lang: AppLanguage = .current) -> [String] {
    let symbols = lang == .zh
      ? ["日", "一", "二", "三", "四", "五", "六"]
      : ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    let first = max(1, min(7, calendar.firstWeekday)) - 1
    return (0..<7).map { symbols[(first + $0) % 7] }
  }

  /// 顶部年月标题：中文“2026 年 11 月”，英文“November 2026”。
  public static func monthTitle(_ month: Month, calendar: Calendar = .current, lang: AppLanguage = .current) -> String {
    if lang == .zh {
      return "\(month.year) 年 \(month.month) 月"
    }
    guard let start = month.startDate(calendar: calendar) else { return month.key }
    let formatter = DateFormatter()
    formatter.locale = lang.locale()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMMM yyyy"
    return formatter.string(from: start)
  }

  /// 单个日期格子的 VoiceOver 描述：日期 + 今天/有记录状态。
  public static func dayAccessibilityLabel(
    _ date: Date,
    isToday: Bool,
    hasActivity: Bool,
    calendar: Calendar = .current,
    lang: AppLanguage = .current
  ) -> String {
    let dateText: String
    if lang == .zh {
      let c = calendar.dateComponents([.year, .month, .day], from: date)
      dateText = "\(c.year!) 年 \(c.month!) 月 \(c.day!) 日"
    } else {
      let formatter = DateFormatter()
      formatter.locale = lang.locale()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = "MMMM d, yyyy"
      dateText = formatter.string(from: date)
    }
    var parts = [dateText]
    if isToday { parts.append(L10n.text(zh: "今天", en: "Today", lang: lang)) }
    if hasActivity { parts.append(L10n.text(zh: "有记录", en: "has activity", lang: lang)) }
    return parts.joined(separator: L10n.text(zh: "，", en: ", ", lang: lang))
  }

  /// 生成一个月的 7 列月历网格（4–6 行，首尾非本月槽位为 nil）。
  public static func cells(
    for month: Month,
    selectedDay: Date,
    today: Date,
    activeDayKeys: Set<String>,
    calendar: Calendar = .current
  ) -> [Cell] {
    guard let start = month.startDate(calendar: calendar),
          let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
    let todayStart = calendar.startOfDay(for: today)
    let selectedStart = calendar.startOfDay(for: selectedDay)
    let firstWeekdayOfMonth = calendar.component(.weekday, from: start)
    let leadingBlanks = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7

    var result: [Cell] = []
    result.reserveCapacity(42)

    for index in 0..<leadingBlanks {
      result.append(Cell(id: "lead-\(index)", date: nil, dayKey: nil, dayNumber: nil,
                         isSelected: false, isToday: false, isFuture: false, hasActivity: false))
    }

    for day in range {
      guard let rawDate = calendar.date(from: DateComponents(year: month.year, month: month.month, day: day)) else { continue }
      let date = calendar.startOfDay(for: rawDate)
      let key = TimelineDay.key(date, calendar: calendar)
      let isFuture = date > todayStart
      result.append(Cell(
        id: key,
        date: date,
        dayKey: key,
        dayNumber: day,
        isSelected: date == selectedStart,
        isToday: date == todayStart,
        isFuture: isFuture,
        hasActivity: !isFuture && activeDayKeys.contains(key)
      ))
    }

    let trailing = (7 - (result.count % 7)) % 7
    for index in 0..<trailing {
      result.append(Cell(id: "trail-\(index)", date: nil, dayKey: nil, dayNumber: nil,
                         isSelected: false, isToday: false, isFuture: false, hasActivity: false))
    }
    return result
  }
}
