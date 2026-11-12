/// 发送结果的纯计数逻辑；由 HubClient 在自己的锁内更新。
public struct HubDeliveryMetrics {
  public private(set) var hubBusy = 0
  public init() {}
  public mutating func received(status: Int) {
    if status == 503 { hubBusy += 1 }
  }
}
