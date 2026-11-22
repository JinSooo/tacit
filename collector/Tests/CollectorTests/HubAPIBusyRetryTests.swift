import Foundation
import Testing
@testable import Collector

// 回归（2026-11-22）：整理进程正在写库时，Mac 上删除记录直接报“数据库忙”失败。
@Test func busyHubIsRetriedBeforeFailing() async throws {
  BusyStub.reset(busyResponses: 1)
  try await busyAPI().deleteRecord("01M80JKPMFC0HCJGB4WNR30G2K")
  #expect(BusyStub.requests == 2)

  BusyStub.reset(busyResponses: 5)
  await #expect(throws: HubError.self) { try await busyAPI().deleteRecord("01M80JKPMFC0HCJGB4WNR30G2K") }
  #expect(BusyStub.requests == 3)
}

private func busyAPI() -> HubAPI {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [BusyStub.self]
  return HubAPI(base: { URL(string: "http://busy.test")! }, token: { "fixture-token" }, configuration: configuration,
                busyRetryDelays: [0, 0])
}

private final class BusyStub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var remainingBusy = 0
  nonisolated(unsafe) private static var count = 0
  static var requests: Int { lock.withLock { count } }
  static func reset(busyResponses: Int) { lock.withLock { remainingBusy = busyResponses; count = 0 } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let busy = Self.lock.withLock { () -> Bool in
      Self.count += 1
      guard Self.remainingBusy > 0 else { return false }
      Self.remainingBusy -= 1
      return true
    }
    let status = busy ? 503 : 200
    let body = busy ? #"{"error":"数据库忙，稍后再试"}"# : #"{"deleted":true}"#
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
