import Foundation

struct DeviceAdvertisement: Equatable {
  let hubId: String
  let port: Int
}

@MainActor protocol DeviceAdvertising: AnyObject {
  var advertisement: DeviceAdvertisement? { get }
  func publish(_ advertisement: DeviceAdvertisement)
  func stop()
}

/// 只发布 DNS-SD 记录。HTTP 端口由后台服务持有。
final class BonjourDeviceAdvertiser: NSObject, DeviceAdvertising, NetServiceDelegate {
  private var service: NetService?
  private(set) var advertisement: DeviceAdvertisement?

  func publish(_ advertisement: DeviceAdvertisement) {
    let service = NetService(domain: "local.", type: "_tacit._tcp.", name: "", port: Int32(advertisement.port))
    service.delegate = self
    service.setTXTRecord(NetService.data(fromTXTRecord: ["hub": Data(advertisement.hubId.utf8)]))
    self.service = service
    self.advertisement = advertisement
    service.publish()
  }

  func stop() {
    service?.delegate = nil
    service?.stop()
    service = nil
    advertisement = nil
  }

  nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    // NetService 的委托回调由启动发布的主 run loop 送达。
    MainActor.assumeIsolated {
      if service === sender { stop() }
    }
  }
}

@MainActor final class DeviceDiscovery {
  private let advertiser: DeviceAdvertising
  private var lastPoll: TimeInterval = -.infinity
  private var poll: Task<Void, Never>?

  init(advertiser: DeviceAdvertising) { self.advertiser = advertiser }

  func refreshIfDue(api: HubAPI, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard poll == nil, uptime - lastPoll >= 60 else { return }
    lastPoll = uptime
    poll = Task {
      let settings = try? await api.deviceSettings()
      guard !Task.isCancelled else { return }
      poll = nil
      apply(settings)
    }
  }

  /// 设置页主动变更配对状态时，用刚读到的状态登记，避免等下一轮维护。
  func update(_ settings: DeviceSettings?, invitationHubId: String? = nil) {
    poll?.cancel()
    poll = nil
    apply(settings, invitationHubId: invitationHubId)
  }

  private func apply(_ settings: DeviceSettings?, invitationHubId: String? = nil) {
    let next: DeviceAdvertisement?
    if let settings, settings.lan.open, (1...65535).contains(settings.lan.port),
       let hubId = invitationHubId ?? settings.hubId, !hubId.isEmpty {
      next = DeviceAdvertisement(hubId: hubId, port: settings.lan.port)
    } else {
      next = nil
    }
    guard next != advertiser.advertisement else { return }
    if advertiser.advertisement != nil { advertiser.stop() }
    if let next { advertiser.publish(next) }
  }
}
