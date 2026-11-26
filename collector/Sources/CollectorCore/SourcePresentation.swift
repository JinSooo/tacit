import Foundation

public enum SourceCategory: String, CaseIterable, Codable, Sendable {
  // 按来源角色分两组（2026-11-25）：对话是整理的主体，电脑上的活动只当时间骨架。
  // development 不再有来源归入，保留是为了旧数据能解码；空组不显示。
  case communication, activity, development, extensions
  public var title: String {
    switch self {
    case .communication: return L10n.text(zh: "对话", en: "Conversations")
    case .activity: return L10n.text(zh: "电脑上的活动", en: "Computer activity")
    case .development: return L10n.text(zh: "开发活动", en: "Development activity")
    case .extensions: return L10n.text(zh: "扩展数据源", en: "Extensions")
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
    switch self { case .all: return L10n.text(zh: "全部", en: "All"); case .enabled: return L10n.text(zh: "已启用", en: "Enabled"); case .attention: return L10n.text(zh: "需要处理", en: "Needs attention") }
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
    if needsPermission {
      return L10n.text(zh: "需要\(permissionName ?? "系统")权限",
                       en: permissionName.map { "\(L10n.permission($0)) permission required" } ?? "System permission required")
    }
    if !ok { return detail.isEmpty ? L10n.text(zh: "运行失败", en: "Couldn't run") : detail }
    if paused { return L10n.text(zh: "记录暂停中", en: "Recording paused") }
    if running { return L10n.text(zh: "正在运行", en: "Running") }
    return detail
  }
}
