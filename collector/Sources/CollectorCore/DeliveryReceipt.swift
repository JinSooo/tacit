import Foundation

/// 只有完整、明确的入库确认才能删除待发送副本；HTTP 200 本身不代表记录已保存。
public struct DeliveryReceipt: Decodable {
  public struct Rejection: Decodable { public let index: Int; public let errors: [String] }
  public let accepted: Int
  public let duplicates: Int
  public let rejected: [Rejection]
  public static func decode(_ data: Data, batchCount: Int) -> DeliveryReceipt? {
    guard let r = try? JSONDecoder().decode(Self.self, from: data), r.accepted >= 0, r.duplicates >= 0,
          r.accepted <= batchCount, r.duplicates <= batchCount,
          r.accepted + r.duplicates + r.rejected.count == batchCount,
          Set(r.rejected.map(\.index)).count == r.rejected.count,
          r.rejected.allSatisfy({ (0..<batchCount).contains($0.index) && !$0.errors.isEmpty }) else { return nil }
    return r
  }
}
