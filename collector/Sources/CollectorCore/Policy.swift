import CoreGraphics
import Foundation

/// 采集前的黑名单：命中的应用和窗口完全不采，只是结束当前段。
public enum CapturePolicy {
  public static let blockedBundles: Set<String> = [
    "com.apple.keychainaccess", "com.apple.Passwords",
    "me.proton.pass.electron", "com.1password.1password", "com.agilebits.onepassword7",
    "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
  ]

  /// 浏览器隐私窗口的标题特征（各浏览器的写法不同）。
  public static let privateTitleMarkers = [
    "Private Browsing", "Private Window", "Incognito", "InPrivate",
    "隐私浏览", "无痕", "私密浏览", "隐身",
  ]

  public static func shouldSkip(bundleID: String, window: String, extraBlocked: Set<String> = []) -> Bool {
    if blockedBundles.contains(bundleID) || extraBlocked.contains(bundleID) { return true }
    return privateTitleMarkers.contains { window.localizedCaseInsensitiveContains($0) }
  }
}

/// 有界发送窗口。HubClient 用加密 outbox 保存窗口以外的记录；存储失效时内存退路超限会计数。
public final class OutboundQueue {
  public let capacity: Int
  public private(set) var items: [Record] = []
  private var dropCount = 0
  public var dropped: Int { lock.lock(); defer { lock.unlock() }; return dropCount }
  private var peak = 0
  private let lock = NSLock()

  public init(capacity: Int = 5000) { self.capacity = capacity }

  public func push(_ records: [Record]) {
    lock.lock(); defer { lock.unlock() }
    items += records
    if items.count > capacity {
      let n = items.count - capacity
      dropCount += n
      items.removeFirst(n)
    }
    peak = max(peak, items.count)
  }

  public func peek(_ n: Int) -> [Record] {
    lock.lock(); defer { lock.unlock() }
    return Array(items.prefix(n))
  }

  /// 只移除确实是开头这几条的记录（发送期间可能有新记录进来）。
  public func remove(ids: Set<String>) {
    lock.lock(); defer { lock.unlock() }
    items.removeAll { ids.contains($0.id) }
  }

  public var queuePeak: Int { lock.lock(); defer { lock.unlock() }; return peak }

  public var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// 屏幕文字里哪些不该读。
public enum ScreenTextPolicy {
  private static let dedicatedSources: Set<String> = [
    "com.anthropic.claudefordesktop", "com.openai.codex", "com.tencent.xinwechat",
  ]

  public static func keepsText(bundleID: String) -> Bool { !dedicatedSources.contains(bundleID.lowercased()) }

  /// OCR 行中心是窗口内的点，辅助功能编辑区是全局坐标。已读到的编辑区由 AX 保留最后一个版本。
  public static func isEditableOCRPoint(_ point: CGPoint, window: CGSize, frame: CGRect?,
                                       editableFrames: [CGRect]) -> Bool {
    guard !editableFrames.isEmpty, let frame, !frame.isEmpty, window.width > 0, window.height > 0 else { return false }
    let global = CGPoint(x: frame.minX + point.x * frame.width / window.width,
                         y: frame.minY + point.y * frame.height / window.height)
    return editableFrames.contains { $0.contains(global) }
  }
}

/// 截图识字的节奏：同一窗口至少隔 15 秒再识别；识别结果和上次一样就把间隔加倍，最长 2 分钟，
/// 文字一变回到 15 秒。停在读不到正文的窗口上时，每 15 秒重识别一次曾让采集端多耗单核 1–2%（2026-11-21 实测）。
public struct OCRSchedule {
  public static let base: TimeInterval = 15
  public static let longest: TimeInterval = 120
  private var entries: [String: (last: Date, interval: TimeInterval, text: String?)] = [:]
  public init() {}

  public func due(_ key: String, now: Date) -> Bool {
    guard let e = entries[key] else { return true }
    return now.timeIntervalSince(e.last) > e.interval
  }

  public mutating func started(_ key: String, now: Date) {
    entries[key, default: (now, Self.base, nil)].last = now
    if entries.count > 500 { entries = entries.filter { now.timeIntervalSince($0.value.last) < 600 } }
  }

  public mutating func finished(_ key: String, lines: [String]) {
    guard var e = entries[key] else { return }
    let text = lines.joined(separator: "\n")
    e.interval = e.text == text ? min(e.interval * 2, Self.longest) : Self.base
    e.text = text
    entries[key] = e
  }
}
