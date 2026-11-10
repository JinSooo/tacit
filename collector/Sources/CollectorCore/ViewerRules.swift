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

/// "做完了吗"放进待确认 7 天没人处理，线程自动归档（hub/src/distill/run.ts 的 archiveAfter）。
public enum PendingArchive {
  public static let after: TimeInterval = 7 * 86400

  public static func notice(createdAt: String?, now: Date = Date()) -> String? {
    guard let createdAt, let created = ViewerTime.parse(createdAt) else { return nil }
    let left = created.addingTimeInterval(after).timeIntervalSince(now)
    if left <= 0 { return "即将自动归档" }
    return "\(Int((left / 86400).rounded(.up))) 天后自动归档"
  }
}
