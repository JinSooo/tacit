import CryptoKit
import Foundation
import Testing
@testable import CollectorCore

private let origin = URL(string: "http://127.0.0.1:47823")!
private let collectorID = "mac-abcd2345"
private let agentID = "agent-abcd2345"

@Test func localBootstrapReusesConfirmedKeysAfterPartialWrite() async throws {
  let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey
  let reply = try JSONEncoder().encode([
    "hub_id": DeviceProtocol.hubID(for: publicKey),
    "hub_pk": DeviceEnvelope.publicKeyBase64URL(publicKey),
    "mac_device_id": collectorID,
    "agent_device_id": agentID,
    "endpoint": origin.absoluteString + "/v1/device",
  ])
  var stored: [LocalDeviceLink.Account: Data] = [:]
  var confirmed = Set<LocalDeviceLink.Account>()
  let keys = LocalDeviceLink.Keys(read: { account in
    if stored[account] != nil { confirmed.insert(account) }
    return stored[account]
  }, create: { account, raw in
    #expect(stored[account] == nil)
    stored[account] = raw
  })
  var disk: [LocalDeviceLink.File: Data] = [:]
  var failWrite = true
  let files = LocalDeviceLink.Files(read: { disk[$0] }, write: { file, data in
    if file == .collector && failWrite { throw LocalDeviceLink.Failure.fileIO }
    disk[file] = data
  }, removeCollector: { disk.removeValue(forKey: .collector) })
  var posts: [[String: String]] = []
  let http: LocalDeviceLink.HTTP = { request in
    if request.url?.path == "/v1/health" { return .init(statusCode: 200, body: Data(#"{"ok":true}"#.utf8)) }
    #expect(request.url?.path == "/v1/settings/devices/local-bootstrap")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    #expect(confirmed == [.mac, .agent])
    posts.append(try JSONDecoder().decode([String: String].self, from: #require(request.httpBody)))
    return .init(statusCode: 200, body: reply)
  }
  await #expect(throws: LocalDeviceLink.Failure.fileIO) {
    try await LocalDeviceLink.bootstrap(origin: origin, token: "synthetic", files: files, keys: keys, http: http)
  }
  let firstAgent = try #require(disk[.agent])
  #expect(disk[.collector] == nil)
  failWrite = false
  let link = try await LocalDeviceLink.bootstrap(origin: origin, token: "synthetic", files: files, keys: keys, http: http)
  #expect(link?.device_id == collectorID)
  #expect(posts.count == 2 && posts.first == posts.last)
  #expect(try JSONDecoder().decode([String: String].self, from: firstAgent) ==
    JSONDecoder().decode([String: String].self, from: #require(disk[.agent])))
  #expect(try JSONDecoder().decode([String: String].self, from: firstAgent)["device_id"] == agentID)
  #expect(try await LocalDeviceLink.bootstrap(origin: origin, token: "synthetic", files: files, keys: keys, http: http) == link)
  #expect(posts.count == 2)
}

@Test func localLinkFilesArePrivateAndRejectSymlinks() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: dir) }
  let files = LocalDeviceLink.Files(directory: dir)
  let bytes = Data("fixture".utf8)
  let absent = dir.appendingPathComponent("absent")
  for file in [LocalDeviceLink.File.agent, .collector] {
    try files.write(file, bytes)
    let path = dir.appendingPathComponent(file.rawValue)
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(try files.read(file) == bytes)
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: absent)
    #expect(throws: LocalDeviceLink.Failure.unsafeFile) { try files.read(file) }
    #expect(throws: LocalDeviceLink.Failure.unsafeFile) { try files.write(file, bytes) }
  }
  #expect(throws: LocalDeviceLink.Failure.unsafeFile) { try files.removeCollector() }
  #expect(!FileManager.default.fileExists(atPath: absent.path))
}

@Test func localBootstrapDefersKeyAccessUntilHubIsHealthy() async throws {
  let keys = LocalDeviceLink.Keys(read: { _ in
    Issue.record("中枢未就绪时不应读取钥匙串")
    return nil
  }, create: { _, _ in Issue.record("中枢未就绪时不应写入钥匙串") })
  let files = LocalDeviceLink.Files(read: { _ in nil }, write: { _, _ in Issue.record("未成功登记时不应写文件") },
                                   removeCollector: { Issue.record("未成功登记时不应删除文件") })
  let health: LocalDeviceLink.HTTP = { request in
    #expect(request.url?.path == "/v1/health")
    return .init(statusCode: 503)
  }
  await #expect(throws: LocalDeviceLink.Failure.busy) {
    try await LocalDeviceLink.bootstrap(origin: origin, token: "synthetic", files: files, keys: keys, http: health)
  }
  await #expect(throws: LocalDeviceLink.Failure.offline) {
    try await LocalDeviceLink.bootstrap(origin: origin, token: "synthetic", files: files, keys: keys) { _ in
      throw LocalDeviceLink.Failure.offline
    }
  }
  let noToken = try await LocalDeviceLink.bootstrap(origin: origin, token: nil, files: files, keys: keys) { _ in
    Issue.record("没有管理令牌时不应向中枢发请求")
    return .init(statusCode: 200)
  }
  #expect(noToken == nil)
}
