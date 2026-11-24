import Foundation

/// Bonjour only supplies candidates. The pairing receipt authenticates the chosen backend.
@MainActor final class RemotePairingBonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private let browser = NetServiceBrowser()
  private let hubID: String
  private var services: [NetService] = []
  private var endpoints: [RemotePairing.BonjourAddress] = []
  private var result: CheckedContinuation<[RemotePairing.BonjourAddress], Never>?

  private init(hubID: String) { self.hubID = hubID }

  static func lookup(hubID: String) async -> [RemotePairing.BonjourAddress] {
    let search = RemotePairingBonjour(hubID: hubID)
    return await withCheckedContinuation { result in
      search.result = result
      search.browser.delegate = search
      search.browser.searchForServices(ofType: "_tacit._tcp.", inDomain: "local.")
      // Keep the discovery and in-flight resolutions alive until the short probe window ends.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { search.finish() }
    }
  }

  private func finish() {
    browser.stop()
    browser.delegate = nil
    for service in services {
      service.stop()
      service.delegate = nil
    }
    result?.resume(returning: endpoints)
    result = nil
  }

  nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    MainActor.assumeIsolated {
      guard result != nil else { return }
      services.append(service)
      service.delegate = self
      service.resolve(withTimeout: 2)
    }
  }

  nonisolated func netServiceDidResolveAddress(_ service: NetService) {
    MainActor.assumeIsolated {
      guard result != nil, let data = service.txtRecordData(),
            let advertised = NetService.dictionary(fromTXTRecord: data)["hub"],
            String(data: advertised, encoding: .utf8) == hubID,
            let host = service.hostName, (1...65535).contains(service.port),
            let origin = DevicePairingInvitation.normalizeOrigin("http://\(host):\(service.port)") else { return }
      endpoints.append(RemotePairing.BonjourAddress(hubID: hubID, address: origin))
    }
  }
}
