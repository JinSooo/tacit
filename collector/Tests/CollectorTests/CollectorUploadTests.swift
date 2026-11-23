import CollectorCore
import CryptoKit
import Foundation
import Testing
@testable import Collector

private let fixtureDevice = "mac-abcd2345"

private func fixtureRecord(source: String = "mac.screen", body: String = "合成读数") -> Record {
  Record(device: "mac", source: source, kind: "event", start: Date(), context: nil,
         title: "虚构风速计样本", body: body, capture: .init(method: "ax"), sourceRef: UUID().uuidString)
}

private func temporaryData() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  try Data("synthetic-token".utf8).write(to: dir.appendingPathComponent("token"))
  return dir
}

private final class UploadProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard let respond = Self.respond else { throw URLError(.badServerResponse) }
      let (status, body) = try respond(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = stream.read(&chunk, maxLength: chunk.count)
    if count == 0 { return data }
    if count < 0 { throw URLError(.cannotDecodeContentData) }
    data.append(contentsOf: chunk.prefix(count))
  }
}

@Suite(.serialized) struct CollectorUploadTests {
  @Test func legacyConflictAndRemovalFallback() async throws {
    let dir = try temporaryData()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = Config(dataDir: dir, bun: "")
    let files = LocalDeviceLink.Files(directory: dir)
    let hub = Curve25519.KeyAgreement.PrivateKey()
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let agent = Curve25519.KeyAgreement.PrivateKey()
    let keys = LocalDeviceLink.Keys(read: { $0 == .mac ? mac.rawRepresentation : agent.rawRepresentation },
                                   create: { _, _ in Issue.record("已经存在的私钥不应重建") })
    let record = fixtureRecord()
    let receipt = Data(#"{"accepted":1,"duplicates":0,"rejected":[]}"#.utf8)
    let response = try JSONEncoder().encode([
      "hub_id": DeviceProtocol.hubID(for: hub.publicKey), "hub_pk": DeviceEnvelope.publicKeyBase64URL(hub.publicKey),
      "mac_device_id": fixtureDevice, "agent_device_id": "agent-abcd2345", "endpoint": config.hubURL.absoluteString + "/v1/device",
    ])
    var paths: [String] = []
    var registrationStatus = 409, removed = false
    UploadProtocol.respond = { request in
      let path = try #require(request.url?.path)
      paths.append(path)
      switch path {
      case "/v1/health":
        return (200, Data(#"{"ok":true}"#.utf8))
      case "/v1/settings/devices/local-bootstrap":
        let keys = try JSONDecoder().decode([String: String].self, from: requestBody(request))
        #expect(keys == ["mac_pk": DeviceEnvelope.publicKeyBase64URL(mac.publicKey),
                         "agent_pk": DeviceEnvelope.publicKeyBase64URL(agent.publicKey)])
        return (registrationStatus, response)
      case "/v1/ingest":
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        let body = try JSONDecoder().decode(LegacyRequest.self, from: requestBody(request))
        #expect(body.device == "mac" && body.records == [record])
        return (200, receipt)
      case "/v1/device":
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let envelope = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: requestBody(request))
        #expect(envelope.device == fixtureDevice)
        let data = try DeviceEnvelope.openRequestEnvelope(envelope, recipientPrivateKey: hub, senderPublicKey: mac.publicKey)
        let plaintext = try JSONDecoder().decode(DeviceRequest.self, from: data)
        #expect(plaintext.op == "ingest")
        #expect(plaintext.body.records.map(\.device) == [fixtureDevice])
        #expect(plaintext.body.records.map(\.id) == [record.id])
        if removed { return (401, Data()) }
        let body = Data(#"{"status":200,"body":{"accepted":1,"duplicates":0,"rejected":[]}}"#.utf8)
        let reply = try DeviceEnvelope.sealResponsePlaintext(body, requestNonce: plaintext.nonce,
          senderPrivateKey: hub, recipientPublicKey: mac.publicKey)
        return (200, try JSONEncoder().encode(reply))
      default: throw URLError(.unsupportedURL)
      }
    }
    defer { UploadProtocol.respond = nil }
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [UploadProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    defer { session.invalidateAndCancel() }
    var logs: [String] = []
    let old = CollectorUpload(config: config, files: files, keys: keys, session: session, log: { logs.append($0) })
    await old.prepare()
    await old.prepare()
    #expect(try files.collector() == nil && files.read(.agent) == nil)
    #expect(logs == ["local-bootstrap: key_conflict"])
    let legacy = try await old.send([record])
    #expect(legacy.records == [record])

    registrationStatus = 200
    let upgraded = CollectorUpload(config: config, files: files, keys: keys, session: session)
    await upgraded.prepare()
    let linked = try await upgraded.send([record])
    #expect(linked.records.map(\.device) == [fixtureDevice])
    #expect(DeliveryReceipt.decode(linked.body, batchCount: 1)?.accepted == 1)

    removed = true
    let fallback = try await upgraded.send([record])
    #expect(fallback.records == [record])
    #expect(try files.collector() == nil && files.read(.agent) != nil)
    await upgraded.prepare()
    _ = try await upgraded.send([record])
    #expect(paths == ["/v1/health", "/v1/settings/devices/local-bootstrap", "/v1/ingest",
                      "/v1/health", "/v1/settings/devices/local-bootstrap", "/v1/device",
                      "/v1/device", "/v1/ingest", "/v1/ingest"])
  }

  private struct LegacyRequest: Decodable { let device: String; let records: [Record] }
  private struct DeviceRequest: Decodable {
    struct Body: Decodable { let records: [Record] }
    let op: String
    let nonce: String
    let body: Body
  }

  @Test func splitsAtRecordAndByteLimits() throws {
    let small = Array(repeating: fixtureRecord(), count: 201)
    let large = Array(repeating: fixtureRecord(body: String(repeating: "🌱", count: 150_000)), count: 10)
    #expect(try CollectorUpload.batch(small, legacyDevice: "mac", assignedDevice: nil).count == 200)
    let deviceBatch = try CollectorUpload.batch(large, legacyDevice: nil, assignedDevice: fixtureDevice)
    let encoder = JSONEncoder()
    #expect(deviceBatch.count == 6 && deviceBatch.allSatisfy { $0.device == fixtureDevice })
    #expect(try encoder.encode(["records": deviceBatch]).count <= 4 * 1024 * 1024)
    #expect(try encoder.encode(["records": deviceBatch + [large[6]]]).count > 4 * 1024 * 1024)
  }
}

@Test func localCollectorLiveHubProbe() async throws {
  // 由 scripts/e2e-local-collector.ts 在临时目录启动真实中枢后注入。常规测试跳过探针。
  let env = ProcessInfo.processInfo.environment
  guard let dir = env["TACIT_E2E_COLLECTOR_DIR"], let port = env["TACIT_E2E_COLLECTOR_PORT"] else { return }
  let config = Config(dataDir: URL(fileURLWithPath: dir), fixedPort: port, bun: "")
  let files = LocalDeviceLink.Files(directory: config.dataDir)
  let keys = LocalDeviceLink.Keys(read: { account in
    let url = config.dataDir.appendingPathComponent(account.rawValue)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return DeviceProtocol.hexDecode(try String(contentsOf: url, encoding: .utf8))
  }, create: { account, data in
    let hex = DeviceProtocol.hexEncode(data)
    try PrivateFile.write(Data(hex.utf8), to: config.dataDir.appendingPathComponent(account.rawValue))
  })
  let upload = CollectorUpload(config: config, files: files, keys: keys)
  await upload.prepare()
  let link = try #require(try files.collector())
  if env["TACIT_E2E_COLLECTOR_INGEST"] == "1" {
    let records = ["mac.screen", "mac.wechat", "mac.app", "claude_code.session", "codex.session", "plugin.ext_fixture"]
      .map { fixtureRecord(source: $0) }
    let delivery = try await upload.send(records)
    let receipt = try #require(DeliveryReceipt.decode(delivery.body, batchCount: records.count))
    try #require(receipt.accepted == records.count)
    try #require(delivery.records.allSatisfy { $0.device == link.device_id })
    print("Swift ingest accepted=\(receipt.accepted) duplicates=\(receipt.duplicates) rejected=\(receipt.rejected.count) device=\(link.device_id)")
  }
}
