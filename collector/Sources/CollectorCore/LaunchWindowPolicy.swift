import Darwin
import Foundation

/// 启动时要不要把主窗口拿出来。
/// macOS 开机“重新打开窗口”恢复 Tacit 时，和用户在访达里双击走同一条 LaunchServices 路径，启动事件也一样
/// （2026-11-25 在 SIP 开着的虚拟机里实测）。准备完的 Mac 用登录时间区分；仍需准备时让用户看到清单。
public enum LaunchWindowPolicy {
  public static let loginQuietPeriod: TimeInterval = 90

  public static func opensWindow(source: DiagnosticLog.LaunchSource, loginAt: Date?,
                                 setupIncomplete: Bool = false, now: Date = Date()) -> Bool {
    guard source == .finder else { return false }
    if setupIncomplete { return true }
    guard let loginAt else { return true }
    return now.timeIntervalSince(loginAt) >= loginQuietPeriod
  }
}

/// 当前用户这次控制台登录的时间，取自 utmpx（`who` 显示的同一份记录）。读不到时返回 nil。
public enum LoginSession {
  public static func consoleLoginDate(user: String = NSUserName()) -> Date? {
    setutxent()
    defer { endutxent() }
    var latest: Date?
    while let entry = getutxent() {
      guard entry.pointee.ut_type == USER_PROCESS else { continue }
      let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      let name = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      guard line == "console", name == user else { continue }
      let tv = entry.pointee.ut_tv
      let date = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
      if latest.map({ date > $0 }) ?? true { latest = date }
    }
    return latest
  }
}
