import SwiftUI
import CollectorCore

struct DayNavigation: ToolbarContent {
  @Binding var day: Date
  @Binding var picking: Bool
  var today = Calendar.current.startOfDay(for: Date())

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      ControlGroup {
        Button { shift(-1) } label: { PhIcon("caret-left", size: PhIcon.toolbar) }
          .help("前一天").accessibilityLabel("前一天").keyboardShortcut("[", modifiers: .command)
        Button("今天") { day = today }.disabled(day >= today).keyboardShortcut("t", modifiers: .command)
        Button { shift(1) } label: { PhIcon("caret-right", size: PhIcon.toolbar) }
          .help("后一天").accessibilityLabel("后一天").keyboardShortcut("]", modifiers: .command).disabled(day >= today)
      }
      Button { picking = true } label: { PhIcon("calendar-blank", size: PhIcon.toolbar) }
        .help("跳到日期").accessibilityLabel("跳到日期")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
          DatePicker("", selection: Binding(get: { day }, set: {
            day = Calendar.current.startOfDay(for: $0)
            picking = false
          }), in: ...Date(), displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden().padding(12)
            .environment(\.locale, Locale(identifier: "zh_CN")).environment(\.calendar, ViewerCalendar.chinese)
        }
    }
  }

  private func shift(_ days: Int) {
    guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: day), shifted <= today else { return }
    day = shifted
  }
}
