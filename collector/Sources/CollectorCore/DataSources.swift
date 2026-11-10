import Foundation

// 数据源注册表的纯逻辑：哪些数据源、开关存在哪、维护任务的回溯起点和提炼日期范围。
// 读取系统权限和启动采集的部分在 Collector 里（DataSource 协议）。

/// 数据源所需系统权限的当前状态。只是查询结果，查询本身不弹授权框。
public enum SourcePermission: Equatable, Sendable {
  case notNeeded, granted, notDetermined, denied
  public var satisfied: Bool { self == .notNeeded || self == .granted }
}

public struct DataSourceDescriptor: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case builtin, plugin }
  public let id: String
  public let title: String
  /// 设置存储里的开关键；OCR 和录音沿用原来的键，升级后用户的选择不丢。
  public let defaultsKey: String
  public let defaultEnabled: Bool
  public let kind: Kind
  public init(id: String, title: String, defaultsKey: String? = nil, defaultEnabled: Bool = true, kind: Kind = .builtin) {
    self.id = id; self.title = title; self.defaultsKey = defaultsKey ?? "source.\(id).enabled"
    self.defaultEnabled = defaultEnabled; self.kind = kind
  }
}

public enum DataSourceCatalog {
  /// 注册顺序即菜单和设置页的显示顺序。
  public static let all: [DataSourceDescriptor] = [
    .init(id: "screen", title: "屏幕文字"),
    .init(id: "ocr", title: "OCR 兜底", defaultsKey: "ocrEnabled", defaultEnabled: false),
    .init(id: "clipboard", title: "剪贴板"),
    .init(id: "audio", title: "录音", defaultsKey: "recordingEnabled"),
    .init(id: "files", title: "文件"),
    .init(id: "calendar", title: "日历"),
    // 读微信窗口的聊天区拆成消息，默认关闭（AGENTS.md 2026-11-10）。
    .init(id: "wechat", title: "微信对话", defaultEnabled: false),
    .init(id: "agent-sessions", title: "AI 会话", kind: .plugin),
    .init(id: "browser", title: "浏览器", kind: .plugin),
    .init(id: "shell", title: "终端命令", kind: .plugin),
    .init(id: "git", title: "Git 提交", kind: .plugin),
  ]
  public static var plugins: [DataSourceDescriptor] { all.filter { $0.kind == .plugin } }
  public static func descriptor(_ id: String) -> DataSourceDescriptor? { all.first { $0.id == id } }
}

/// 开关存储的最小接口；采集端用 UserDefaults，测试用内存字典。
public protocol SettingsStore: AnyObject {
  func object(forKey defaultName: String) -> Any?
  func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: SettingsStore {}

public final class MemorySettings: SettingsStore {
  public private(set) var values: [String: Any] = [:]
  public init(_ values: [String: Any] = [:]) { self.values = values }
  public func object(forKey defaultName: String) -> Any? { values[defaultName] }
  public func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

public struct SourceToggles {
  public let store: SettingsStore
  public init(store: SettingsStore) { self.store = store }
  public func isEnabled(_ id: String) -> Bool {
    guard let d = DataSourceCatalog.descriptor(id) else { return false }
    return store.object(forKey: d.defaultsKey) as? Bool ?? d.defaultEnabled
  }
  public func setEnabled(_ id: String, _ on: Bool) {
    guard let d = DataSourceCatalog.descriptor(id) else { return }
    store.set(on, forKey: d.defaultsKey)
  }
}

/// 设置页和菜单显示的一行。只含状态，不含任何采集内容。
public struct DataSourceStatus: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let kind: DataSourceDescriptor.Kind
  public var enabled: Bool
  public var permission: SourcePermission
  /// 需要的系统权限名称（例如"辅助功能"）；不需要权限时为 nil。
  public var permissionName: String?
  public var lastRun: Date?
  public var detail: String
  public var ok: Bool
  public var canRunNow: Bool
  public var running: Bool
  public init(id: String, title: String, kind: DataSourceDescriptor.Kind, enabled: Bool, permission: SourcePermission, permissionName: String?,
              lastRun: Date?, detail: String, ok: Bool, canRunNow: Bool, running: Bool = false) {
    self.id = id; self.title = title; self.kind = kind; self.enabled = enabled; self.permission = permission
    self.permissionName = permissionName; self.lastRun = lastRun; self.detail = detail; self.ok = ok
    self.canRunNow = canRunNow; self.running = running
  }
  /// 启用了但缺权限时才提示授权；停用的数据源不申请权限。
  public var needsPermission: Bool { enabled && !permission.satisfied && permissionName != nil }
}

// MARK: 维护

public enum MaintenanceTask: String, CaseIterable, Sendable {
  case syncAll, reimportRecent, importAll, backfill
  public var title: String {
    switch self {
    case .syncAll: return "立即同步全部"
    case .reimportRecent: return "重新导入最近 7 天"
    case .importAll: return "导入全部历史"
    case .backfill: return "整理启用前的历史"
    }
  }
}

public enum PluginImport {
  public static let recentDays = 7
  /// "全部历史"的起点：早于任何浏览器、AI 会话和 git 的可能记录，又不会被 git 当成无效时间。
  public static let allHistorySince = Date(timeIntervalSince1970: 631_152_000)  // 1990-01-01T00:00:00Z

  public static func since(_ task: MaintenanceTask, now: Date = Date()) -> Date? {
    switch task {
    case .reimportRecent: return now.addingTimeInterval(-Double(recentDays) * 86_400)
    case .importAll: return allHistorySince
    case .syncAll, .backfill: return nil
    }
  }

  /// 插件额外参数。shell 插件只读缓冲文件、没有可回溯的历史，传 --since 反而会把缓冲里更早的命令丢掉，所以不传。
  public static func arguments(plugin: String, since: Date?) -> [String] {
    guard let since, plugin != "shell" else { return [] }
    return ["--since", rfc3339(since)]
  }

  public static func rfc3339(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
  }

  /// 常规增量 3 分钟；导入可能要读很多年的日志，放宽到 30 分钟。
  public static func timeout(since: Date?) -> TimeInterval { since == nil ? 180 : 1800 }

  /// 一次运行的状态文字，例如"成功 · 新增 3 · 2 秒"。不到 1 秒不写耗时。
  public static func outcomeText(ok: Bool, exitStatus: Int32, accepted: Int?, elapsed: TimeInterval) -> String {
    var parts = [ok ? "成功" : "失败（\(exitStatus)）"]
    if let accepted { parts.append("新增 \(accepted)") }
    let s = Int(elapsed)
    if s >= 60 { parts.append(s % 60 == 0 ? "\(s / 60) 分钟" : "\(s / 60) 分 \(s % 60) 秒") }
    else if s >= 1 { parts.append("\(s) 秒") }
    return parts.joined(separator: " · ")
  }
}

/// 提炼的本地日期闭区间（YYYY-MM-DD）。
public struct DistillDateRange: Equatable, Sendable {
  public var from: String
  public var to: String
  public init(from: String, to: String) { self.from = from; self.to = to }

  public static let defaultDays = 30
  /// 含今天在内的最近 days 天。
  public static func last(_ days: Int = defaultDays, now: Date = Date(), calendar: Calendar = .current) -> DistillDateRange {
    let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
    return DistillDateRange(from: format(start, calendar: calendar), to: format(now, calendar: calendar))
  }
  public init(start: Date, end: Date, calendar: Calendar = .current) {
    let (a, b) = start <= end ? (start, end) : (end, start)
    self.init(from: Self.format(a, calendar: calendar), to: Self.format(b, calendar: calendar))
  }
  public static func format(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}

/// hub 的提炼请求（docs/contracts.md 4.8）。
public struct DistillRequestInfo: Decodable, Equatable, Identifiable, Sendable {
  public struct Progress: Decodable, Equatable, Sendable { public let done: Int; public let total: Int }
  public let id: String
  public let kind: String
  public let from: String?
  public let to: String?
  public let status: String
  public let createdAt: String
  public let startedAt: String?
  public let finishedAt: String?
  public let error: String?
  public let progress: Progress?

  public var finished: Bool { status == "done" || status == "failed" }
  /// 界面上的一行状态。常驻提炼进程没在跑时请求会一直排队，如实显示。
  public var statusText: String {
    let range = from.flatMap { f in to.map { "\(f) 至 \($0)" } }
    let prefix = range.map { "\($0) · " } ?? ""
    switch status {
    case "queued": return prefix + "排队中，等待提炼进程领取"
    case "running":
      if let p = progress, p.total > 0, p.done < p.total { return prefix + "切片中 \(p.done)/\(p.total) 天" }
      return prefix + (kind == "backfill" ? "整理中（归线程、写日记）" : "提炼中")
    case "done":
      if kind == "backfill", let p = progress { return prefix + (p.total == 0 ? "完成，范围内没有需要整理的记录" : "完成，整理了 \(p.total) 天") }
      return prefix + "完成"
    case "failed": return prefix + "失败：\(error ?? "未知原因")"
    default: return prefix + status
    }
  }
}
