import SwiftUI
import CollectorCore

struct DayNavigation: ToolbarContent {
  @Environment(ViewerStore.self) private var store
  @Binding var day: Date
  @Binding var picking: Bool
  var today = Calendar.current.startOfDay(for: Date())

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      ControlGroup {
        Button { shift(-1) } label: { PhIcon("caret-left", size: PhIcon.toolbar) }
          .help(L10n.previousDay).accessibilityLabel(L10n.previousDay).keyboardShortcut("[", modifiers: .command)
        Button(L10n.today) { day = today }.disabled(day >= today).keyboardShortcut("t", modifiers: .command)
        Button { shift(1) } label: { PhIcon("caret-right", size: PhIcon.toolbar) }
          .help(L10n.nextDay).accessibilityLabel(L10n.nextDay).keyboardShortcut("]", modifiers: .command).disabled(day >= today)
      }
      Button { picking = true } label: { PhIcon("calendar-blank", size: PhIcon.toolbar) }
        .help(L10n.jumpToDate).accessibilityLabel(L10n.jumpToDate)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
          TimelineCalendarPopover(
            selectedDay: $day,
            today: today,
            isPresented: $picking,
            dataSource: store.dataSource,
            cache: store.activeDaysCache,
            revision: store.revision
          )
        }
    }
  }

  private func shift(_ days: Int) {
    guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: day), shifted <= today else { return }
    day = shifted
  }
}
