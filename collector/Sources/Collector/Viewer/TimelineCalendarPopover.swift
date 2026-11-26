import SwiftUI
// 只引入用到的类型：CollectorCore 里有个叫 Observation 的结构体，会挡住 @Observable 宏展开要找的 Observation 模块。
import enum CollectorCore.AppLanguage
import enum CollectorCore.L10n
import class CollectorCore.LanguageStore
import enum CollectorCore.TimelineCalendar

/// 按月缓存在月历弹窗里查到的活跃日期，切换后台时清空；区分在线权威结果与离线回退，并限制容量与新鲜期。
@MainActor @Observable final class ActiveDaysCache {
  private struct Entry {
    var dates: Set<String>
    var revision: Int?
    var loadedAt: Date?
    var authoritative: Bool
    var lastAccessed: Date
  }

  let maxEntries: Int
  let pastMonthTTL: TimeInterval
  private var entries: [String: Entry] = [:]

  init(maxEntries: Int = 24, pastMonthTTL: TimeInterval = 300) {
    self.maxEntries = max(1, maxEntries)
    self.pastMonthTTL = max(0, pastMonthTTL)
  }

  var count: Int { entries.count }

  func dates(for month: String, fallback: Set<String>) -> Set<String> {
    entries[month]?.dates ?? fallback
  }

  func seedIfEmpty(month: String, dates: Set<String>, now: Date = Date()) {
    guard entries[month] == nil, !dates.isEmpty else { return }
    entries[month] = Entry(dates: dates, revision: nil, loadedAt: nil, authoritative: false, lastAccessed: now)
    evictIfNeeded()
  }

  func needsLoad(month: String, revision: Int, isCurrentMonth: Bool, now: Date = Date()) -> Bool {
    guard let entry = entries[month], entry.authoritative, let loadedRevision = entry.revision, let loadedAt = entry.loadedAt else {
      return true
    }
    if loadedRevision != revision { return true }
    if isCurrentMonth { return true }
    return now.timeIntervalSince(loadedAt) >= pastMonthTTL
  }

  func store(month: String, dates: Set<String>, revision: Int, authoritative: Bool = true, now: Date = Date()) {
    if !authoritative {
      // 离线回退不能覆盖已有的在线结果，也不标为 authoritative，确保恢复连接或重新打开时会重新请求。
      if let existing = entries[month], existing.authoritative {
        entries[month]?.lastAccessed = now
        return
      }
      entries[month] = Entry(dates: dates, revision: nil, loadedAt: nil, authoritative: false, lastAccessed: now)
      evictIfNeeded()
      return
    }
    entries[month] = Entry(dates: dates, revision: revision, loadedAt: now, authoritative: true, lastAccessed: now)
    evictIfNeeded()
  }

  func clear() {
    entries.removeAll()
  }

  private func evictIfNeeded() {
    while entries.count > maxEntries {
      guard let oldestKey = entries.min(by: {
        if $0.value.lastAccessed != $1.value.lastAccessed {
          return $0.value.lastAccessed < $1.value.lastAccessed
        }
        return $0.key < $1.key
      })?.key else { break }
      entries.removeValue(forKey: oldestKey)
    }
  }
}

/// 暖纸/墨色/铜绿风格的自定义时间线月历弹窗，替代系统原生 `.graphical` DatePicker。
struct TimelineCalendarPopover: View {
  @Binding var selectedDay: Date
  let today: Date
  @Binding var isPresented: Bool
  let dataSource: any ViewerDataSource
  let cache: ActiveDaysCache
  let revision: Int

  @ObservedObject private var language = LanguageStore.shared
  @State private var displayedMonth: TimelineCalendar.Month

  private struct LoadKey: Equatable {
    let month: String
    let revision: Int
  }

  private let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 7)

  init(
    selectedDay: Binding<Date>,
    today: Date,
    isPresented: Binding<Bool>,
    dataSource: any ViewerDataSource,
    cache: ActiveDaysCache,
    revision: Int
  ) {
    _selectedDay = selectedDay
    self.today = today
    _isPresented = isPresented
    self.dataSource = dataSource
    self.cache = cache
    self.revision = revision
    _displayedMonth = State(
      initialValue: TimelineCalendar.Month(
        containing: selectedDay.wrappedValue,
        calendar: TimelineCalendar.protocolCalendar(from: ViewerCalendar.formatting)
      )
    )
  }

  private var calendar: Calendar { TimelineCalendar.protocolCalendar(from: ViewerCalendar.formatting) }
  private var monthKey: String { displayedMonth.key }
  private var canAdvance: Bool { TimelineCalendar.canAdvance(from: displayedMonth, today: today, calendar: calendar) }
  private var showsTodayShortcut: Bool {
    TimelineCalendar.showsJumpToToday(selectedDay: selectedDay, displayedMonth: displayedMonth, today: today, calendar: calendar)
  }

  private var activeDayKeys: Set<String> {
    cache.dates(for: monthKey, fallback: dataSource.cachedActiveDays(inMonth: monthKey))
  }

  var body: some View {
    let cal = calendar
    let lang = language.resolved
    let headers = TimelineCalendar.weekdayHeaders(calendar: cal, lang: lang)
    let cells = TimelineCalendar.cells(
      for: displayedMonth,
      selectedDay: selectedDay,
      today: today,
      activeDayKeys: activeDayKeys,
      calendar: cal
    )

    VStack(alignment: .leading, spacing: 12) {
      header(calendar: cal, lang: lang)

      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(Array(headers.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(.system(size: TextSize.caption, weight: .medium))
            .foregroundStyle(Palette.muted)
            .frame(width: 34, height: 20)
            .accessibilityHidden(true)
        }

        ForEach(cells) { cell in
          CalendarDayCell(cell: cell, calendar: cal, lang: lang) { date in
            selectedDay = date
            isPresented = false
          }
        }
      }

      if showsTodayShortcut {
        VStack(spacing: 8) {
          Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
          Button {
            selectedDay = cal.startOfDay(for: today)
            isPresented = false
          } label: {
            Text(L10n.backToToday)
              .font(.system(size: TextSize.body, weight: .medium))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 2)
          }
          .buttonStyle(.accentLink)
          .accessibilityLabel(L10n.backToToday)
        }
      }
    }
    .padding(16)
    .frame(width: 294)
    .background(Palette.paper)
    .onChange(of: selectedDay) { _, newDay in
      displayedMonth = TimelineCalendar.Month(containing: newDay, calendar: cal)
    }
    .task(id: LoadKey(month: monthKey, revision: revision)) {
      let targetMonth = monthKey
      cache.seedIfEmpty(month: targetMonth, dates: dataSource.cachedActiveDays(inMonth: targetMonth))
      let currentMonth = TimelineCalendar.Month(containing: today, calendar: cal).key
      while !Task.isCancelled {
        if cache.needsLoad(month: targetMonth, revision: revision, isCurrentMonth: targetMonth == currentMonth) {
          // 到期、修订变化或离线重试时绕过底层滑窗 LRU，直接向中枢取最新结果。
          if let fetched = try? await dataSource.activeDays(inMonth: targetMonth, bypassCache: true), !Task.isCancelled {
            cache.store(month: targetMonth, dates: fetched.dates, revision: revision, authoritative: fetched.authoritative)
            if fetched.authoritative {
              if targetMonth != currentMonth { break }
              try? await Task.sleep(for: .seconds(60))
              continue
            }
          }
          // 离线或请求失败时保持弹层可用，并在弹层持续打开期间短暂退避重试，连接恢复后自动更新。
          try? await Task.sleep(for: .seconds(10))
        } else {
          break
        }
      }
    }
  }

  private func header(calendar: Calendar, lang: AppLanguage) -> some View {
    HStack(spacing: 8) {
      Text(TimelineCalendar.monthTitle(displayedMonth, calendar: calendar, lang: lang))
        .font(.serif(TextSize.title))
        .foregroundStyle(Palette.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        CalendarMonthButton(icon: "caret-left", label: L10n.previousMonth, enabled: true) {
          displayedMonth = displayedMonth.shifted(byMonths: -1, calendar: calendar)
        }
        CalendarMonthButton(icon: "caret-right", label: L10n.nextMonth, enabled: canAdvance) {
          guard canAdvance else { return }
          displayedMonth = displayedMonth.shifted(byMonths: 1, calendar: calendar)
        }
      }
    }
  }
}

private struct CalendarMonthButton: View {
  let icon: String
  let label: String
  let enabled: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      PhIcon(icon, size: 13)
        .foregroundStyle(Palette.muted)
        .opacity(enabled ? 1 : 0.35)
        .frame(width: 28, height: 28)
        .background(hovering && enabled ? Palette.fill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .hoverState($hovering, enabled: enabled)
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct CalendarDayCell: View {
  let cell: TimelineCalendar.Cell
  let calendar: Calendar
  let lang: AppLanguage
  let select: (Date) -> Void
  @State private var hovering = false

  var body: some View {
    if let date = cell.date, let number = cell.dayNumber {
      Button { select(date) } label: {
        VStack(spacing: 2) {
          ZStack {
            if cell.isSelected {
              Circle().fill(Palette.accent)
            } else {
              if hovering && cell.isSelectable {
                Circle().fill(Palette.fill)
              }
              if cell.isToday {
                Circle().strokeBorder(Palette.accent.opacity(0.7), lineWidth: 1.25)
              }
            }
            Text("\(number)")
              .font(.system(size: TextSize.body, weight: cell.isSelected || cell.isToday ? .semibold : .regular))
              .monospacedDigit()
              .foregroundStyle(numberColor)
          }
          .frame(width: 26, height: 26)

          Circle()
            .fill(cell.hasActivity ? Palette.accent : Color.clear)
            .frame(width: 4, height: 4)
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!cell.isSelectable)
      .hoverState($hovering, enabled: cell.isSelectable)
      .accessibilityLabel(TimelineCalendar.dayAccessibilityLabel(
        date,
        isToday: cell.isToday,
        hasActivity: cell.hasActivity,
        calendar: calendar,
        lang: lang
      ))
      .accessibilityAddTraits(cell.isSelected ? .isSelected : [])
    } else {
      Color.clear
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
  }

  private var numberColor: Color {
    if cell.isSelected { return Palette.onAccent }
    if cell.isFuture { return Palette.muted.opacity(0.42) }
    if cell.isToday { return Palette.accent }
    return Palette.ink
  }
}
