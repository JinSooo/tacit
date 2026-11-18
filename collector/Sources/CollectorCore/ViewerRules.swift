import Foundation

/// 读取记录页的一行：相邻、完全相同的读取（同一工具、同一动作、同样参数、同样成败）合成一行。
public struct AuditGroup: Identifiable, Hashable, Sendable {
  /// 按列表顺序（新的在前），第一条就是最近的一次。
  public let reads: [AuditRead]
  public var id: String { reads[0].id }
  public var latest: AuditRead { reads[0] }
}

public enum AuditGrouping {
  public static func group(_ reads: [AuditRead]) -> [AuditGroup] {
    var groups: [[AuditRead]] = []
    for r in reads {
      if let first = groups.last?.first, same(first, r) { groups[groups.count - 1].append(r) }
      else { groups.append([r]) }
    }
    return groups.map(AuditGroup.init)
  }

  static func same(_ a: AuditRead, _ b: AuditRead) -> Bool {
    a.tool == b.tool && a.kind == b.kind && a.args == b.args && a.ok.value == b.ok.value
  }
}

/// 使用天数由后台按所有设备的历史记录计算，客户端不按日历时间推算倒计时。
public enum PendingArchive {
  public static func notice(createdAt: String?) -> String? {
    guard let createdAt, ViewerTime.parse(createdAt) != nil else { return nil }
    return "继续使用后会自动归档"
  }
}

/// 回顾的活动条跟随实时采集开关；历史记录仍显示已经采集的内容。
public enum ReviewActivity {
  public static func segmentRecords(_ records: [HistoryRecord]) -> (visible: [HistoryRecord], collapsed: [HistoryRecord]) {
    var visible: [HistoryRecord] = [], collapsed: [HistoryRecord] = []
    for record in records {
      switch Lane.of(record.source) {
      case .screen, .browser: collapsed.append(record)
      default: visible.append(record)
      }
    }
    return visible.isEmpty ? (collapsed, []) : (visible, collapsed)
  }

  public static func visibleRecords(_ records: [HistoryRecord], sources: [DataSourceStatus]) -> [HistoryRecord] {
    let enabled = Set(sources.lazy.filter(\.enabled).map(\.id))
    return records.filter { record in
      if let id = collectorID[record.source] {
        return DataSourceCatalog.isVisible(id) && enabled.contains(id)
      }
      // 已安装的插件与旧记录用 plugin.ext_... 命名，开关用 ext-...。
      if record.source.hasPrefix("plugin.ext_") {
        let id = record.source.dropFirst("plugin.".count).replacingOccurrences(of: "_", with: "-")
        return enabled.contains(id)
      }
      return true
    }
  }

  // 来源名是记录协议，开关是采集器 ID。截图识字与辅助功能共用屏幕记录，两种 AI 会话共用一个开关。
  private static let collectorID = [
    "mac.screen": "screen", "mac.app": "screen", "mac.browser": "browser",
    "claude_code.session": "agent-sessions", "codex.session": "agent-sessions",
    "mac.audio": "audio", "mac.calendar": "calendar", "mac.wechat": "wechat",
    "mac.shell": "shell", "mac.git": "git", "mac.file": "files", "mac.clipboard": "clipboard",
  ]
}

/// 项目页先读最近进展，展开后沿用每段各自的时间和原文。
public struct ProjectUpdate: Identifiable, Sendable {
  public let day: String
  public let item: DayDiary.Item
  public var id: String { "\(day)/\(item.id)" }
  public init(day: String, item: DayDiary.Item) { self.day = day; self.item = item }
}

public struct ProjectStory: Identifiable, Sendable {
  public let id: String
  public let updates: [ProjectUpdate]
  public var latest: ProjectUpdate { updates[0] }
}

public enum ProjectReading {
  public static func stories(_ updates: [ProjectUpdate]) -> [ProjectStory] {
    let ordered = updates.sorted {
      let a = $0.item.start ?? .distantPast, b = $1.item.start ?? .distantPast
      return a == b ? $0.id < $1.id : a > b
    }
    var groups: [String: [ProjectUpdate]] = [:]
    for update in ordered {
      let key = update.item.threadId.map { "\(update.item.projectId ?? "")/thread:\($0)" }
        ?? "segment:\(update.id)"
      groups[key, default: []].append(update)
    }
    return groups.map { ProjectStory(id: $0.key, updates: $0.value) }.sorted {
      let a = $0.latest.item.start ?? .distantPast, b = $1.latest.item.start ?? .distantPast
      return a == b ? $0.id < $1.id : a > b
    }
  }
}
