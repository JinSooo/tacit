import AppKit
import SwiftUI

/// 条带图的缩放窗口。放在引用类型里，事件监听闭包读到的总是最新的几何信息。
@MainActor @Observable final class StrataZoom {
  /// nil 表示看整天；否则是当前可见的时间段。
  var window: ClosedRange<Date>?
  @ObservationIgnored var full: ClosedRange<Date> = Date()...Date()
  @ObservationIgnored var plot: CGRect = .zero
  @ObservationIgnored var hoverX: CGFloat?
  @ObservationIgnored private var monitor: Any?

  static let minSpan: TimeInterval = 3 * 60

  func visible(_ full: ClosedRange<Date>) -> ClosedRange<Date> {
    guard let w = window else { return full }
    return Self.clamp(w, to: full)
  }

  /// 把窗口挪回整天范围内，宽度不变（超过整天就取整天）。
  static func clamp(_ w: ClosedRange<Date>, to full: ClosedRange<Date>) -> ClosedRange<Date> {
    let span = min(w.upperBound.timeIntervalSince(w.lowerBound), full.upperBound.timeIntervalSince(full.lowerBound))
    var lo = max(w.lowerBound, full.lowerBound)
    if lo.addingTimeInterval(span) > full.upperBound { lo = full.upperBound.addingTimeInterval(-span) }
    return lo...lo.addingTimeInterval(span)
  }

  /// 以 anchor（0…1，在可见窗口里的位置）为中心缩放；factor < 1 放大。
  func zoom(by factor: Double, anchor: Double) {
    let v = visible(full)
    let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
    let span = v.upperBound.timeIntervalSince(v.lowerBound)
    let next = min(fullSpan, max(Self.minSpan, span * factor))
    if next >= fullSpan { window = nil; return }
    let pivot = v.lowerBound.addingTimeInterval(span * anchor)
    let lo = pivot.addingTimeInterval(-next * anchor)
    window = Self.clamp(lo...lo.addingTimeInterval(next), to: full)
  }

  func pan(by seconds: TimeInterval) {
    guard window != nil else { return }
    let v = visible(full)
    window = Self.clamp(v.lowerBound.addingTimeInterval(seconds)...v.upperBound.addingTimeInterval(seconds), to: full)
  }

  func show(_ range: ClosedRange<Date>) {
    let span = max(Self.minSpan, range.upperBound.timeIntervalSince(range.lowerBound))
    let mid = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
    window = Self.clamp(mid.addingTimeInterval(-span / 2)...mid.addingTimeInterval(span / 2), to: full)
    if window.map({ $0.upperBound.timeIntervalSince($0.lowerBound) }) ?? 0 >= full.upperBound.timeIntervalSince(full.lowerBound) { window = nil }
  }

  /// 只在光标停在条带图上时接管：双指捏合、⌘ 滚轮缩放，横向滑动平移；竖向滚动照常交给页面。
  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
      guard let self, let hx = self.hoverX, self.plot.width > 0, hx >= self.plot.minX else { return event }
      let anchor = Double(min(1, max(0, (hx - self.plot.minX) / self.plot.width)))
      if event.type == .magnify {
        self.zoom(by: exp(-Double(event.magnification) * 1.6), anchor: anchor)
        return nil
      }
      let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
      let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 10
      if event.modifierFlags.contains(.command), dy != 0 {
        self.zoom(by: exp(-Double(dy) * scale * 0.01), anchor: anchor)
        return nil
      }
      if self.window != nil, abs(dx) > abs(dy) {
        let v = self.visible(self.full)
        self.pan(by: -Double(dx) * scale / Double(self.plot.width) * v.upperBound.timeIntervalSince(v.lowerBound))
        return nil
      }
      return event
    }
  }

  func uninstall() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
