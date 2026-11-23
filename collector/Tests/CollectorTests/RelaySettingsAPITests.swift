import Foundation
import Testing
@testable import Collector

@Test func relaySettingsUseAuthenticatedLocalRequests() async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [RelaySettingsStub.self]
  let api = HubAPI(base: { URL(string: "http://hub.test")! }, token: { "fixture-token" }, configuration: configuration)
  let address = "https://relay.example"

  #expect(try await api.relaySettings().mode == .off)
  let tested = try await api.testRelay(address: address)
  #expect(tested.tacitRelay == 1)
  #expect(tested.limits.retentionDays == 30)
  #expect(try await api.saveRelay(address: address, code: "").url == address)
  #expect(try await api.saveRelay(address: "https://locked.relay.example", code: "fixture-code").mode == .custom)
  #expect(try await api.disableRelay().mode == .off)
}

private final class RelaySettingsStub: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let status: Int
    let response: String
    let root = "/v1/settings/relay"
    let body = bodyData().flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] }
    let address = "https://relay.example"
    let off = #"{"mode":"off","url":null,"connected":false,"last_fetch_at":null,"used_bytes":null,"unprocessable":0,"devices":[],"retiring":[]}"#
    let custom = #"{"mode":"custom","url":"https://relay.example","connected":true,"last_fetch_at":null,"used_bytes":null,"unprocessable":0,"devices":[],"retiring":[]}"#
    switch (url.host, request.value(forHTTPHeaderField: "Authorization"), request.httpMethod, url.path) {
    case ("hub.test", "Bearer fixture-token", "GET", root) where body == nil,
         ("hub.test", "Bearer fixture-token", "PUT", root) where body == ["mode": "off"]:
      (status, response) = (200, off)
    case ("hub.test", "Bearer fixture-token", "PUT", root) where body == ["mode": "custom", "url": address],
         ("hub.test", "Bearer fixture-token", "PUT", root)
           where body == ["mode": "custom", "url": "https://locked.relay.example", "code": "fixture-code"]:
      (status, response) = (200, custom)
    case ("hub.test", "Bearer fixture-token", "POST", root + "/test") where body == ["url": address]:
      (status, response) = (200, #"{"tacit_relay":1,"limits":{"space_bytes":100,"message_bytes":10,"retention_days":30}}"#)
    default:
      Issue.record("Unexpected relay settings request: \(request.httpMethod ?? "") \(url.path), body keys \(body?.keys.sorted() ?? [])")
      (status, response) = (400, #"{"error":"unexpected relay settings request"}"#)
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                        cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(response.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  private func bodyData() -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { return nil }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  override func stopLoading() {}
}
