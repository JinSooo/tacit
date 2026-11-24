import Foundation

public enum SourceCategory: String, CaseIterable, Codable, Sendable {
  case activity, communication, development, extensions
  public var title: String {
    switch self {
    case .activity: return "日常活动"
    case .communication: return "沟通与会议"
    case .development: return "开发活动"
    case .extensions: return "扩展数据源"
    }
  }
  public static func forID(_ id: String) -> SourceCategory {
    switch id {
    case "screen", "ocr", "browser": return .activity
    case "audio", "wechat": return .communication
    case "agent-sessions": return .development
    default: return .extensions
    }
  }
}

public enum SourceFilter: String, CaseIterable {
  case all, enabled, attention
  public var title: String {
    switch self { case .all: return "全部"; case .enabled: return "已启用"; case .attention: return "需要处理" }
  }
  public func includes(_ source: DataSourceStatus) -> Bool {
    switch self { case .all: return true; case .enabled: return source.enabled; case .attention: return source.needsAttention }
  }
}

extension DataSourceStatus {
  public var category: SourceCategory { SourceCategory.forID(id) }
  public var needsAttention: Bool { enabled && (!ok || needsPermission) }
  /// 开关已经说明启用与否，这里只写开关说明不了的：缺权限、出错、暂停和来源自己的进度。
  public func overviewStatus(paused: Bool) -> String {
    if !enabled { return "" }
    if needsPermission { return "需要\(permissionName ?? "系统")权限" }
    if !ok { return detail.isEmpty ? "运行失败" : detail }
    if paused { return "记录暂停中" }
    if running { return "正在运行" }
    return detail
  }
}
