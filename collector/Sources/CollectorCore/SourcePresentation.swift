import Foundation

public enum SourceCategory: String, CaseIterable, Codable, Sendable {
  // 按来源角色分两组（2026-11-25）：对话是整理的主体，电脑上的活动只当时间骨架。
  // development 不再有来源归入，保留是为了旧数据能解码；空组不显示。
  case communication, activity, development, extensions
  public var title: String {
    switch self {
    case .communication: return "对话"
    case .activity: return "电脑上的活动"
    case .development: return "开发活动"
    case .extensions: return "扩展数据源"
    }
  }
  public static func forID(_ id: String) -> SourceCategory {
    switch id {
    case "screen", "ocr", "browser": return .activity
    case "audio", "wechat", "agent-sessions": return .communication
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
