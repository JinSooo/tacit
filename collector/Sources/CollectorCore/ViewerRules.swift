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
