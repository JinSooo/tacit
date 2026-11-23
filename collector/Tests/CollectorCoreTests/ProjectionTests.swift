import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CollectorCore

// MARK: - 测试辅助桩

private actor ProjectionStubTransport: DeviceTransport {
  let maxEnvelopeBytes: Int
  private let handler: @Sendable (SealedDeviceRequest) async throws -> DeviceTransportResponse
  private(set) var requests: [SealedDeviceRequest] = []

  init(
    maxEnvelopeBytes: Int = DeviceProtocol.maxEnvelopeBytes,
    handler: @escaping @Sendable (SealedDeviceRequest) async throws -> DeviceTransportResponse
  ) {
    self.maxEnvelopeBytes = maxEnvelopeBytes
    self.handler = handler
  }

  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
    requests.append(request)
    return try await handler(request)
  }
}

private final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ date: Date) {
    self.current = date
  }

  func now() -> Date {
    lock.lock(); defer { lock.unlock() }
    return current
  }

  func advance(by seconds: TimeInterval) {
    lock.lock(); defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

private actor MockRelayMailbox: RelayMailboxClient {
  private var downMessages: [(id: String, data: Data)] = []
  private(set) var deletedDownIDs: [String] = []
  private(set) var upMessages: [(id: String, data: Data)] = []
  private var failListError: RelayMailboxError?

  func enqueueDown(id: String, data: Data) {
    downMessages.append((id: id, data: data))
  }

  func setListFailure(_ error: RelayMailboxError?) {
    failListError = error
  }

  func listDownMessages(after: String?, limit: Int) async throws -> (messages: [RelayMessageMeta], next: String?) {
    if let failListError { throw failListError }
    let metas = downMessages.map { RelayMessageMeta(id: $0.id, size: $0.data.count, cursor: nil) }
    return (metas, nil)
  }

  func getDownMessage(id: String) async throws -> Data {
    guard let found = downMessages.first(where: { $0.id == id }) else {
      throw RelayMailboxError.notFound
    }
    return found.data
  }

  func deleteDownMessage(id: String) async throws {
    deletedDownIDs.append(id)
    downMessages.removeAll { $0.id == id }
  }

  func putUpMessage(id: String, data: Data) async throws {
    upMessages.append((id: id, data: data))
  }
}

private actor MockEventStream: ProjectionEventStream {
  private var shouldFailSubscribe: Bool
  private(set) var receivedAuthEnvelopes: [Data] = []
  private var eventsToEmit: [ProjectionEvent]

  init(events: [ProjectionEvent] = [], failSubscribe: Bool = false) {
    self.eventsToEmit = events
    self.shouldFailSubscribe = failSubscribe
  }

  func subscribe(authEnvelope: Data) async throws -> AsyncThrowingStream<ProjectionEvent, Error> {
    receivedAuthEnvelopes.append(authEnvelope)
    if shouldFailSubscribe {
      throw DeviceClientError.transportError("模拟 WebSocket 不可用")
    }
    let snapshot = eventsToEmit
    return AsyncThrowingStream { continuation in
      for event in snapshot {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

private func makeTempDirectory() throws -> URL {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("tacit-projection-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  return base
}

private func sealHubReply(
  status: Int = 200,
  body: DeviceJSON,
  requestNonce: String,
  hubKey: Curve25519.KeyAgreement.PrivateKey,
  devicePublicKey: Curve25519.KeyAgreement.PublicKey
) throws -> DeviceTransportResponse {
  let plain = try JSONEncoder().encode(DeviceJSON.object([
    "status": .int(Int64(status)),
    "body": body,
  ]))
  let env = try DeviceEnvelope.sealResponsePlaintext(
    plain,
    requestNonce: requestNonce,
    senderPrivateKey: hubKey,
    recipientPublicKey: devicePublicKey
  )
  return DeviceTransportResponse(statusCode: 200, body: try JSONEncoder().encode(env))
}

private func sealRelayPush(
  payload: DeviceJSON,
  messageID: String,
  hubKey: Curve25519.KeyAgreement.PrivateKey,
  devicePublicKey: Curve25519.KeyAgreement.PublicKey
) throws -> Data {
  let plain = try JSONEncoder().encode(payload)
  let env = try DeviceEnvelope.sealResponsePlaintext(
    plain,
    requestNonce: messageID,
    senderPrivateKey: hubKey,
    recipientPublicKey: devicePublicKey
  )
  return try JSONEncoder().encode(env)
}

private func decodeClientRequest(
  _ sealed: SealedDeviceRequest,
  hubKey: Curve25519.KeyAgreement.PrivateKey,
  devicePublicKey: Curve25519.KeyAgreement.PublicKey
) throws -> (op: String, body: [String: DeviceJSON]) {
  let plaintext = try DeviceEnvelope.openRequestEnvelope(
    sealed.envelope,
    recipientPrivateKey: hubKey,
    senderPublicKey: devicePublicKey
  )
  let json = try JSONDecoder().decode(DeviceJSON.self, from: plaintext)
  let op = try #require(json["op"]?.stringValue)
  let body = json["body"]?.objectValue ?? [:]
  return (op, body)
}

// MARK: - 1. 加密往返、AAD 绑定、权限与符号链接检查、钥匙串提供者

@Test func projectionCacheCryptoRoundtripAndAADBinding() throws {
  let key = SymmetricKey(size: .bits256)
  let plaintext = Data(#"{"date":"2026-11-23","brief":"校准风速仪与气压计"}"#.utf8)

  let sealed = try ProjectionCacheCrypto.seal(plaintext, kind: .day, entityID: "2026-11-23", using: key)
  let opened = try ProjectionCacheCrypto.open(sealed, kind: .day, entityID: "2026-11-23", using: key)
  #expect(opened == plaintext)

  // 换 entity_id 后解密必须失败。
  #expect(throws: ProjectionCacheError.self) {
    _ = try ProjectionCacheCrypto.open(sealed, kind: .day, entityID: "2026-11-22", using: key)
  }
  // 换 kind 后解密必须失败。
  #expect(throws: ProjectionCacheError.self) {
    _ = try ProjectionCacheCrypto.open(sealed, kind: .project, entityID: "2026-11-23", using: key)
  }
  // 换密钥后解密必须失败。
  let otherKey = SymmetricKey(size: .bits256)
  #expect(throws: ProjectionCacheError.self) {
    _ = try ProjectionCacheCrypto.open(sealed, kind: .day, entityID: "2026-11-23", using: otherKey)
  }

  // 在真实 SQLite 中验证：磁盘密文不含明文，且调换两行密文会被 AAD 拦住。
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  let cache = try ProjectionCache(
    dataDirectory: dir,
    keyProvider: InMemoryProjectionCacheKeyProvider(key: key)
  )
  let secretText = "虚构观测站独有敏感正文-ALPHA-9876"
  let page = ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(
        seq: 1,
        op: .upsert,
        kind: .day,
        id: "2026-11-22",
        rev: 1,
        data: .object(["date": .string("2026-11-22"), "brief": .string(secretText)])
      ),
      ProjectionChange(
        seq: 2,
        op: .upsert,
        kind: .day,
        id: "2026-11-23",
        rev: 2,
        data: .object(["date": .string("2026-11-23"), "brief": .string("第二天记录")])
      ),
    ],
    cursor: 2,
    more: false,
    serverTime: "2026-11-23T08:00:00Z"
  )
  _ = try cache.applyPage(page)

  // 权限、PRAGMA 与落盘加密核验。
  let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
  let filePerms = try FileManager.default.attributesOfItem(atPath: cache.databaseURL.path)[.posixPermissions] as? Int
  #expect(dirPerms == 0o700)
  #expect(filePerms == 0o600)
  #expect(try cache.pragmaInt("secure_delete") == 1)
  #expect(try cache.pragmaInt("auto_vacuum") == 2) // INCREMENTAL

  let rawDiskData = try Data(contentsOf: cache.databaseURL)
  #expect(rawDiskData.range(of: Data(secretText.utf8)) == nil)

  // 直接改 SQLite，把 2026-11-22 的密文挪到 2026-11-23，读 2026-11-23 时 AAD 不匹配必须失败。
  var rawDB: OpaquePointer?
  #expect(sqlite3_open(cache.databaseURL.path, &rawDB) == SQLITE_OK)
  defer { sqlite3_close(rawDB) }
  let swapSQL = """
    UPDATE projection_entities
    SET payload = (SELECT payload FROM projection_entities WHERE kind = 'day' AND entity_id = '2026-11-22')
    WHERE kind = 'day' AND entity_id = '2026-11-23';
    """
  #expect(sqlite3_exec(rawDB, swapSQL, nil, nil, nil) == SQLITE_OK)

  #expect(throws: ProjectionCacheError.self) {
    _ = try cache.get(kind: .day, id: "2026-11-23")
  }
}

@Test func projectionCacheRejectsSymlinksAndKeychainProviderUsesSecurityCLI() throws {
  let root = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: root) }

  let realDir = root.appendingPathComponent("real", isDirectory: true)
  try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
  let linkDir = root.appendingPathComponent("link-dir", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

  #expect(throws: ProjectionCacheError.self) {
    _ = try ProjectionCache(dataDirectory: linkDir, keyProvider: InMemoryProjectionCacheKeyProvider())
  }

  let dataDir = root.appendingPathComponent("data", isDirectory: true)
  try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
  let decoyFile = root.appendingPathComponent("decoy.db")
  try Data().write(to: decoyFile)
  try FileManager.default.createSymbolicLink(
    at: dataDir.appendingPathComponent("viewer-cache.db"),
    withDestinationURL: decoyFile
  )
  #expect(throws: ProjectionCacheError.self) {
    _ = try ProjectionCache(dataDirectory: dataDir, keyProvider: InMemoryProjectionCacheKeyProvider())
  }

  // 验证 KeychainProjectionCacheKeyProvider 仅通过注入的 /usr/bin/security 回调读写，不碰真实钥匙串。
  final class FakeSecurityBox: @unchecked Sendable {
    var storedHex: String?
    var calls: [[String]] = []
  }
  let box = FakeSecurityBox()
  let provider = KeychainProjectionCacheKeyProvider { args, stdin in
    box.calls.append(args)
    if args.first == "find-generic-password" {
      #expect(args.contains("record-anything"))
      #expect(args.contains("viewer-cache-key"))
      if let hex = box.storedHex { return (0, hex) }
      return (44, "")
    }
    if args == ["-i"] {
      // 写入经标准输入：密钥不能出现在进程参数里。
      let line = String(decoding: stdin ?? Data(), as: UTF8.self)
      #expect(line.hasPrefix("add-generic-password -s record-anything -a viewer-cache-key -w "))
      #expect(!line.contains("-U"))
      box.storedHex = line.split(separator: " ").last.map { $0.trimmingCharacters(in: .newlines) }
      return (0, "")
    }
    return (1, "")
  }
  let first = try provider.loadOrCreateKey()
  let second = try provider.loadOrCreateKey()
  let firstBytes = first.withUnsafeBytes { Data($0) }
  let secondBytes = second.withUnsafeBytes { Data($0) }
  #expect(firstBytes.count == 32)
  #expect(firstBytes == secondBytes)
  #expect(box.calls.count == 4) // find(44) -> add(0) -> find(0) -> find(0)
}

// MARK: - 2. 游标推进与 epoch 变化清空

@Test func cursorAdvancesAcrossPagesAndClearsOnEpochChange() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let snapshotURL = dir.appendingPathComponent("widget-today.json")
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)

  let cache = try ProjectionCache(
    dataDirectory: dir,
    widgetSnapshotURL: snapshotURL,
    keyProvider: InMemoryProjectionCacheKeyProvider()
  )
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()

  final class ServerState: @unchecked Sendable {
    var epoch: Int64 = 1
    var acked: [(epoch: Int64, cursor: Int64)] = []
  }
  let state = ServerState()

  let transport = ProjectionStubTransport { sealed in
    let (op, body) = try decodeClientRequest(sealed, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    if op == "projection.ack" {
      let epoch = try #require(body["epoch"]?.intValue)
      let cursor = try #require(body["cursor"]?.intValue)
      state.acked.append((epoch, cursor))
      return try sealHubReply(body: .object(["ok": .bool(true)]), requestNonce: sealed.nonce, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    }
    #expect(op == "projection.pull")
    let cursor = try #require(body["cursor"]?.intValue)
    let reqEpoch = body["epoch"]?.intValue

    if state.epoch == 2 && reqEpoch == 1 {
      // 返回 reset: true
      return try sealHubReply(
        body: .object([
          "epoch": .int(2),
          "reset": .bool(true),
          "changes": .array([]),
          "cursor": .int(0),
          "more": .bool(true),
          "server_time": .string("2026-11-23T09:00:00Z"),
        ]),
        requestNonce: sealed.nonce,
        hubKey: hubKey,
        devicePublicKey: deviceKey.publicKey
      )
    }

    if state.epoch == 1 && cursor == 0 {
      return try sealHubReply(
        body: .object([
          "epoch": .int(1),
          "reset": .bool(false),
          "changes": .array([
            .object([
              "seq": .int(1), "op": .string("upsert"), "kind": .string("project"),
              "id": .string("proj-starport"), "rev": .int(1),
              "data": .object(["id": .string("proj-starport"), "name": .string("星港气象站")]),
            ]),
          ]),
          "cursor": .int(1),
          "more": .bool(true),
          "server_time": .string("2026-11-23T08:00:00Z"),
        ]),
        requestNonce: sealed.nonce,
        hubKey: hubKey,
        devicePublicKey: deviceKey.publicKey
      )
    } else if state.epoch == 1 && cursor == 1 {
      return try sealHubReply(
        body: .object([
          "epoch": .int(1),
          "reset": .bool(false),
          "changes": .array([
            .object([
              "seq": .int(2), "op": .string("upsert"), "kind": .string("day"),
              "id": .string("2026-11-23"), "rev": .int(2),
              "data": .object(["date": .string("2026-11-23"), "brief": .string("调试风速传感器")]),
            ]),
          ]),
          "cursor": .int(2),
          "more": .bool(false),
          "server_time": .string("2026-11-23T08:01:00Z"),
        ]),
        requestNonce: sealed.nonce,
        hubKey: hubKey,
        devicePublicKey: deviceKey.publicKey
      )
    } else {
      // epoch 2 重拉后的最新状态（不含旧项目 proj-starport）
      return try sealHubReply(
        body: .object([
          "epoch": .int(2),
          "reset": .bool(false),
          "changes": .array([
            .object([
              "seq": .int(5), "op": .string("upsert"), "kind": .string("now"),
              "id": .string("current"), "rev": .int(5),
              "data": .object(["brief": .string("世代 2 新状态")]),
            ]),
          ]),
          "cursor": .int(5),
          "more": .bool(false),
          "server_time": .string("2026-11-23T09:00:01Z"),
        ]),
        requestNonce: sealed.nonce,
        hubKey: hubKey,
        devicePublicKey: deviceKey.publicKey
      )
    }
  }

  let client = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: transport
  )
  let sync = ProjectionSync(client: client, cache: cache, clock: {
    DeviceProtocol.parseRFC3339("2026-11-23T09:00:00Z")!
  })

  // 第一轮：翻两页并逐页确认。
  let first = try await sync.pullToLatest()
  #expect(first.pagesFetched == 2)
  #expect(first.upsertedCount == 2)
  #expect(first.cursor == ProjectionCursor(epoch: 1, seq: 2))
  #expect(first.didReset == false)
  #expect(try cache.get(kind: .project, id: "proj-starport") != nil)
  #expect(try cache.get(kind: .day, id: "2026-11-23") != nil)
  #expect(state.acked.count == 2)
  #expect(state.acked[0] == (1, 1))
  #expect(state.acked[1] == (1, 2))

  // 第二轮：服务端 epoch 切到 2 -> 触发清空并从 0 重拉。
  state.epoch = 2
  let second = try await sync.pullToLatest()
  #expect(second.didReset == true)
  #expect(second.cursor == ProjectionCursor(epoch: 2, seq: 5))
  #expect(try cache.get(kind: .project, id: "proj-starport") == nil)
  #expect(try cache.get(kind: .day, id: "2026-11-23") == nil)
  #expect(try cache.get(kind: .now, id: "current") != nil)
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
}

// MARK: - 3. invalidate 与 record_gone

@Test func invalidateDeletesEntitiesWithoutAdvancingCursorAndRecordGoneEvictsMemoryLRU() throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let snapshotURL = dir.appendingPathComponent("today.json")
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)

  let now = try #require(DeviceProtocol.parseRFC3339("2026-11-23T12:00:00Z"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(secondsFromGMT: 0)!

  let cache = try ProjectionCache(
    dataDirectory: dir,
    widgetSnapshotURL: snapshotURL,
    keyProvider: InMemoryProjectionCacheKeyProvider(),
    clock: { now },
    calendar: utc
  )

  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 1, op: .upsert, kind: .day, id: "2026-11-23", rev: 1, data: .object(["brief": .string("今天")])),
      ProjectionChange(seq: 2, op: .upsert, kind: .thread, id: "th-1", rev: 2, data: .object(["title": .string("风速仪")])),
      ProjectionChange(seq: 3, op: .upsert, kind: .project, id: "p-1", rev: 3, data: .object(["name": .string("星港")])),
    ],
    cursor: 3,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))

  let lru = RawReadMemoryCache()
  lru.set("record:01TESTREC00000000000000001", data: Data("原文A".utf8), recordIDs: ["01TESTREC00000000000000001"])
  lru.set("record:01TESTREC00000000000000002", data: Data("原文B".utf8), recordIDs: ["01TESTREC00000000000000002"])
  lru.set("records.list:q=foo", data: Data("列表结果".utf8), invalidateOnAnyRecordGone: true)

  // 收到 invalidate：删 day 和 thread，游标保持 (1, 3) 不变，返回 record_gone。
  let invResult = try cache.applyInvalidate(
    epoch: 1,
    items: [
      ProjectionInvalidateItem(kind: .day, id: "2026-11-23"),
      ProjectionInvalidateItem(kind: .thread, id: "th-1"),
      ProjectionInvalidateItem(kind: .recordGone, id: "01TESTREC00000000000000001"),
    ],
    now: now
  )
  #expect(invResult.cursor == ProjectionCursor(epoch: 1, seq: 3))
  #expect(invResult.deletedCount == 2)
  #expect(invResult.goneRecordIDs == ["01TESTREC00000000000000001"])
  #expect(invResult.invalidatedWidget == true)
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(try cache.get(kind: .day, id: "2026-11-23") == nil)
  #expect(try cache.get(kind: .thread, id: "th-1") == nil)
  #expect(try cache.get(kind: .project, id: "p-1") != nil)

  lru.evict(recordIDs: invResult.goneRecordIDs)
  #expect(lru.get("record:01TESTREC00000000000000001") == nil)
  #expect(lru.get("records.list:q=foo") == nil)
  #expect(lru.get("record:01TESTREC00000000000000002") == Data("原文B".utf8))

  // record_gone 经由常规变更流到达时，不落盘为实体且返回 goneRecordIDs。
  let applyGone = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 4, op: .delete, kind: .recordGone, id: "01TESTREC00000000000000002", rev: 4),
    ],
    cursor: 4,
    more: false,
    serverTime: "2026-11-23T12:01:00Z"
  ))
  #expect(applyGone.goneRecordIDs == ["01TESTREC00000000000000002"])
  #expect(try cache.count() == 1) // 仅剩 p-1
  lru.evict(recordIDs: applyGone.goneRecordIDs)
  #expect(lru.get("record:01TESTREC00000000000000002") == nil)
}

// MARK: - 4. 90 天 day 清理与 thread 保留规则

@Test func prunesDaysOlderThan90DaysAndOldArchivedThreads() throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  let now = try #require(DeviceProtocol.parseRFC3339("2026-11-23T12:00:00Z"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(secondsFromGMT: 0)!

  let cache = try ProjectionCache(
    dataDirectory: dir,
    keyProvider: InMemoryProjectionCacheKeyProvider(),
    policy: ProjectionCachePolicy(dayRetentionDays: 90, archivedThreadRetentionDays: 30),
    clock: { now },
    calendar: utc
  )

  func dayKey(_ daysAgo: Int) -> String {
    let date = utc.date(byAdding: .day, value: -daysAgo, to: now)!
    return TimelineDay.key(date, calendar: utc)
  }

  let dayRecent = dayKey(10)
  let dayEdgeKeep = dayKey(89) // 含今天共 90 天内
  let dayExpired90 = dayKey(90)
  let dayExpired120 = dayKey(120)

  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 1, op: .upsert, kind: .day, id: dayRecent, rev: 1, data: .object(["date": .string(dayRecent)])),
      ProjectionChange(seq: 2, op: .upsert, kind: .day, id: dayEdgeKeep, rev: 2, data: .object(["date": .string(dayEdgeKeep)])),
      ProjectionChange(seq: 3, op: .upsert, kind: .day, id: dayExpired90, rev: 3, data: .object(["date": .string(dayExpired90)])),
      ProjectionChange(seq: 4, op: .upsert, kind: .day, id: dayExpired120, rev: 4, data: .object(["date": .string(dayExpired120)])),
      // active / paused / 近期 archived 保留；超过 30 天的 archived 清理。
      ProjectionChange(seq: 5, op: .upsert, kind: .thread, id: "th-active", rev: 5, data: .object([
        "status": .string("active"), "updated_at": .string("2026-01-01T00:00:00Z"),
      ])),
      ProjectionChange(seq: 6, op: .upsert, kind: .thread, id: "th-paused", rev: 6, data: .object([
        "status": .string("paused"), "updated_at": .string("2026-01-01T00:00:00Z"),
      ])),
      ProjectionChange(seq: 7, op: .upsert, kind: .thread, id: "th-arch-recent", rev: 7, data: .object([
        "status": .string("archived"), "updated_at": .string("2026-11-05T00:00:00Z"),
      ])),
      ProjectionChange(seq: 8, op: .upsert, kind: .thread, id: "th-arch-old", rev: 8, data: .object([
        "status": .string("archived"), "updated_at": .string("2026-10-01T00:00:00Z"),
      ])),
      ProjectionChange(seq: 9, op: .upsert, kind: .project, id: "proj-1", rev: 9, data: .object(["name": .string("气象站")])),
      ProjectionChange(seq: 10, op: .upsert, kind: .projectContext, id: "proj-1", rev: 10, data: .object(["text": .string("概况")])),
      ProjectionChange(seq: 11, op: .upsert, kind: .now, id: "current", rev: 11, data: .object(["brief": .string("此刻")])),
    ],
    cursor: 11,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))

  let pruned = try cache.prune(now: now)
  #expect(pruned.expiredDaysDeleted == 2)
  #expect(pruned.expiredArchivedThreadsDeleted == 1)

  #expect(try cache.get(kind: .day, id: dayRecent) != nil)
  #expect(try cache.get(kind: .day, id: dayEdgeKeep) != nil)
  #expect(try cache.get(kind: .day, id: dayExpired90) == nil)
  #expect(try cache.get(kind: .day, id: dayExpired120) == nil)

  #expect(try cache.get(kind: .thread, id: "th-active") != nil)
  #expect(try cache.get(kind: .thread, id: "th-paused") != nil)
  #expect(try cache.get(kind: .thread, id: "th-arch-recent") != nil)
  #expect(try cache.get(kind: .thread, id: "th-arch-old") == nil)

  #expect(try cache.get(kind: .project, id: "proj-1") != nil)
  #expect(try cache.get(kind: .projectContext, id: "proj-1") != nil)
  #expect(try cache.get(kind: .now, id: "current") != nil)
}

// MARK: - 5. 128 MiB 磁盘硬上限清理（测试中调小上限）

@Test func enforcesDiskLimitByTrimmingDaysOlderThan30DaysAndIncrementalVacuum() throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  let now = try #require(DeviceProtocol.parseRFC3339("2026-11-23T12:00:00Z"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(secondsFromGMT: 0)!

  let smallLimit: Int64 = 64 * 1024 // 64 KiB 上限，代替 128 MiB 做快速验证
  let cache = try ProjectionCache(
    dataDirectory: dir,
    keyProvider: InMemoryProjectionCacheKeyProvider(),
    policy: ProjectionCachePolicy(dayRetentionDays: 90, archivedThreadRetentionDays: 30, maxDiskBytes: smallLimit, diskTrimDayAgeDays: 30),
    clock: { now },
    calendar: utc
  )

  func dayKey(_ daysAgo: Int) -> String {
    TimelineDay.key(utc.date(byAdding: .day, value: -daysAgo, to: now)!, calendar: utc)
  }

  // 写入 10 条 35–80 天前的大体积 day（约 150 KiB），以及 2 条近 30 天内的 day 和 1 个 project。
  let bigText = String(repeating: "观测数据风向标读数", count: 600)
  var changes: [ProjectionChange] = []
  var seq: Int64 = 1
  for daysAgo in stride(from: 80, through: 35, by: -5) {
    let key = dayKey(daysAgo)
    changes.append(ProjectionChange(
      seq: seq,
      op: .upsert,
      kind: .day,
      id: key,
      rev: seq,
      data: .object(["date": .string(key), "brief": .string(bigText)])
    ))
    seq += 1
  }
  let recentDay1 = dayKey(5)
  let recentDay2 = dayKey(15)
  changes.append(ProjectionChange(seq: seq, op: .upsert, kind: .day, id: recentDay1, rev: seq, data: .object(["date": .string(recentDay1), "brief": .string("近期1")])))
  seq += 1
  changes.append(ProjectionChange(seq: seq, op: .upsert, kind: .day, id: recentDay2, rev: seq, data: .object(["date": .string(recentDay2), "brief": .string("近期2")])))
  seq += 1
  changes.append(ProjectionChange(seq: seq, op: .upsert, kind: .project, id: "proj-keep", rev: seq, data: .object(["name": .string("保留项目")])))

  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: changes,
    cursor: seq,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))

  let beforeBytes = cache.databaseFileSize()
  #expect(beforeBytes > smallLimit)

  let pruned = try cache.prune(now: now)
  #expect(pruned.diskTrimDaysDeleted > 0)
  #expect(pruned.finalDatabaseBytes <= smallLimit)
  #expect(cache.databaseFileSize() <= smallLimit)

  // 近 30 天的 day 与 project 必须保留。
  #expect(try cache.get(kind: .day, id: recentDay1) != nil)
  #expect(try cache.get(kind: .day, id: recentDay2) != nil)
  #expect(try cache.get(kind: .project, id: "proj-keep") != nil)
}

// MARK: - 6. wipe、401 移除与 hub_id 变化清空

@Test func wipeRemovesDatabaseAndWidgetSnapshotAndTriggersOn401OrHubChange() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let snapshotURL = dir.appendingPathComponent("widget/today.json")
  try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)

  let cache = try ProjectionCache(
    dataDirectory: dir,
    widgetSnapshotURL: snapshotURL,
    keyProvider: InMemoryProjectionCacheKeyProvider()
  )
  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 1, op: .upsert, kind: .now, id: "current", rev: 1, data: .object(["brief": .string("工作中")])),
    ],
    cursor: 1,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))
  #expect(FileManager.default.fileExists(atPath: cache.databaseURL.path))
  #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

  // 直接 wipe()：删除数据库文件与小组件快照。
  try cache.wipe()
  #expect(!FileManager.default.fileExists(atPath: cache.databaseURL.path))
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(try cache.cursor() == .zero)

  // 重新写入后验证 401（设备被移除）触发 wipe + 清理内存 LRU。
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)
  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 1, op: .upsert, kind: .now, id: "current", rev: 1, data: .object(["brief": .string("工作中")])),
    ],
    cursor: 1,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))
  let hubA = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()
  let hubAID = DeviceProtocol.hubID(for: hubA.publicKey)
  _ = try cache.ensureHubID(hubAID)

  let rawLRU = RawReadMemoryCache()
  rawLRU.set("record:01REC000000000000000000000", data: Data("敏感原文".utf8))

  let removedClient = try DeviceClient(
    hubPublicKey: hubA.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: ProjectionStubTransport { _ in
      DeviceTransportResponse(statusCode: 401, body: Data(#"{"error":"设备未配对或已移除"}"#.utf8))
    }
  )
  let sync = ProjectionSync(client: removedClient, cache: cache, rawCache: rawLRU)
  await #expect(throws: DeviceClientError.deviceRemoved(message: "设备未配对或已移除")) {
    _ = try await sync.pullToLatest()
  }
  #expect(!FileManager.default.fileExists(atPath: cache.databaseURL.path))
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(rawLRU.count == 0)

  // 切换绑定中枢（hub_id 变化）触发 wipe + 清理内存 LRU。
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)
  _ = try cache.ensureHubID(hubAID)
  _ = try cache.applyPage(ProjectionPage(
    epoch: 1,
    reset: false,
    changes: [
      ProjectionChange(seq: 1, op: .upsert, kind: .project, id: "p-old", rev: 1, data: .object(["name": .string("旧中枢项目")])),
    ],
    cursor: 1,
    more: false,
    serverTime: "2026-11-23T12:00:00Z"
  ))
  rawLRU.set("record:01REC000000000000000000001", data: Data("旧原文".utf8))

  let hubB = Curve25519.KeyAgreement.PrivateKey()
  let hubBClient = try DeviceClient(
    hubPublicKey: hubB.publicKey,
    deviceID: "mac-zzzz2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: ProjectionStubTransport { _ in DeviceTransportResponse(statusCode: 503) }
  )
  let syncB = ProjectionSync(client: hubBClient, cache: cache, rawCache: rawLRU)
  let didWipe = try await syncB.verifyHubIdentity()
  #expect(didWipe == true)
  #expect(try cache.get(kind: .project, id: "p-old") == nil)
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(rawLRU.count == 0)
  #expect(try cache.storedHubID() == DeviceProtocol.hubID(for: hubB.publicKey))
}

// MARK: - 7. 内存 LRU 的条数、字节、过期与 clearMemory

@Test func rawReadMemoryCacheEnforcesCountBytesTTLAndClear() {
  let start = DeviceProtocol.parseRFC3339("2026-11-23T10:00:00Z")!
  let clock = MutableClock(start)

  // 条数上限与 LRU 淘汰顺序。
  let countLRU = RawReadMemoryCache(maxBytes: 1024, maxEntries: 3, idleTTL: 600, clock: { clock.now() })
  countLRU.set("k1", data: Data("aaa".utf8))
  countLRU.set("k2", data: Data("bbb".utf8))
  countLRU.set("k3", data: Data("ccc".utf8))
  #expect(countLRU.count == 3)
  // 刷新 k1 为最新访问，再插入 k4，应淘汰 k2。
  #expect(countLRU.get("k1") == Data("aaa".utf8))
  countLRU.set("k4", data: Data("ddd".utf8))
  #expect(countLRU.count == 3)
  #expect(countLRU.get("k2") == nil)
  #expect(countLRU.get("k1") == Data("aaa".utf8))
  #expect(countLRU.get("k3") == Data("ccc".utf8))
  #expect(countLRU.get("k4") == Data("ddd".utf8))

  // 字节上限与单条超限拒绝。
  let byteLRU = RawReadMemoryCache(maxBytes: 10, maxEntries: 200, idleTTL: 600, clock: { clock.now() })
  byteLRU.set("a", data: Data(repeating: 1, count: 6))
  byteLRU.set("b", data: Data(repeating: 2, count: 4))
  #expect(byteLRU.totalBytes == 10)
  byteLRU.set("c", data: Data(repeating: 3, count: 5))
  #expect(byteLRU.get("a") == nil) // 淘汰 a（6 字节），保留 b(4) + c(5) = 9
  #expect(byteLRU.totalBytes == 9)
  byteLRU.set("too-big", data: Data(repeating: 9, count: 11))
  #expect(byteLRU.get("too-big") == nil)
  #expect(byteLRU.totalBytes == 9)

  // 闲置 10 分钟过期。
  let ttlLRU = RawReadMemoryCache(maxBytes: 1024, maxEntries: 10, idleTTL: 600, clock: { clock.now() })
  ttlLRU.set("x", data: Data("hello".utf8))
  clock.advance(by: 599)
  #expect(ttlLRU.get("x") == Data("hello".utf8)) // 访问后刷新闲置起点
  clock.advance(by: 599)
  #expect(ttlLRU.get("x") == Data("hello".utf8))
  clock.advance(by: 600)
  #expect(ttlLRU.get("x") == nil)
  #expect(ttlLRU.count == 0)
  #expect(ttlLRU.totalBytes == 0)

  // clear() 立即清空。
  ttlLRU.set("y", data: Data("world".utf8))
  #expect(ttlLRU.count == 1)
  ttlLRU.clear()
  #expect(ttlLRU.count == 0)
  #expect(ttlLRU.totalBytes == 0)
}

// MARK: - 8. 信箱 4 种 kind 处理 + 事件流/轮询切换

@Test func handlesAllFourRelayDownKindsAndDeletesMessages() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let snapshotURL = dir.appendingPathComponent("today.json")
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)

  let now = try #require(DeviceProtocol.parseRFC3339("2026-11-23T12:00:00Z"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(secondsFromGMT: 0)!

  let cache = try ProjectionCache(
    dataDirectory: dir,
    widgetSnapshotURL: snapshotURL,
    keyProvider: InMemoryProjectionCacheKeyProvider(),
    clock: { now },
    calendar: utc
  )
  let rawLRU = RawReadMemoryCache()
  rawLRU.set("record:01GONEREC00000000000000001", data: Data("待清除原文".utf8), recordIDs: ["01GONEREC00000000000000001"])

  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()

  final class MockHub: @unchecked Sendable {
    var epoch: Int64 = 1
    var nextPullChanges: [ProjectionChange] = []
    var nextPullCursor: Int64 = 0
    var pullCount = 0
    var ackCount = 0
  }
  let hub = MockHub()

  let transport = ProjectionStubTransport { sealed in
    let (op, _) = try decodeClientRequest(sealed, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    if op == "projection.ack" {
      hub.ackCount += 1
      return try sealHubReply(body: .object(["ok": .bool(true)]), requestNonce: sealed.nonce, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    }
    #expect(op == "projection.pull")
    hub.pullCount += 1
    let encodedChanges = try JSONDecoder().decode(DeviceJSON.self, from: JSONEncoder().encode(hub.nextPullChanges))
    return try sealHubReply(
      body: .object([
        "epoch": .int(hub.epoch),
        "reset": .bool(false),
        "changes": encodedChanges,
        "cursor": .int(hub.nextPullCursor),
        "more": .bool(false),
        "server_time": .string("2026-11-23T12:00:00Z"),
      ]),
      requestNonce: sealed.nonce,
      hubKey: hubKey,
      devicePublicKey: deviceKey.publicKey
    )
  }

  let client = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: transport
  )
  let mailbox = MockRelayMailbox()
  let sync = ProjectionSync(
    client: client,
    cache: cache,
    rawCache: rawLRU,
    relayMailbox: mailbox,
    clock: { now }
  )

  // 1) projection.delta（无缺口，直接应用并确认）。
  let msg1 = try DeviceEnvelope.randomNonce()
  let deltaWire = try sealRelayPush(
    payload: .object([
      "kind": .string("projection.delta"),
      "epoch": .int(1),
      "from_seq": .int(0),
      "to_seq": .int(2),
      "changes": .array([
        .object([
          "seq": .int(1), "op": .string("upsert"), "kind": .string("project"),
          "id": .string("p-alpha"), "rev": .int(1),
          "data": .object(["id": .string("p-alpha"), "name": .string("阿尔法观测站")]),
        ]),
        .object([
          "seq": .int(2), "op": .string("upsert"), "kind": .string("day"),
          "id": .string("2026-11-23"), "rev": .int(2),
          "data": .object(["date": .string("2026-11-23"), "brief": .string("初始日报")]),
        ]),
      ]),
      "more": .bool(false),
    ]),
    messageID: msg1,
    hubKey: hubKey,
    devicePublicKey: deviceKey.publicKey
  )
  await mailbox.enqueueDown(id: msg1, data: deltaWire)
  let r1 = try await sync.pollRelayDown()
  #expect(r1.processedMessages == 1)
  #expect(try cache.cursor() == ProjectionCursor(epoch: 1, seq: 2))
  #expect(try cache.get(kind: .project, id: "p-alpha") != nil)
  #expect(hub.ackCount == 1)
  #expect(hub.pullCount == 0)

  // 2) projection.invalidate（立即删本地缓存 + 清内存 LRU，再从原游标续拉）。
  hub.nextPullChanges = [
    ProjectionChange(seq: 3, op: .delete, kind: .day, id: "2026-11-23", rev: 3),
    ProjectionChange(seq: 4, op: .delete, kind: .recordGone, id: "01GONEREC00000000000000001", rev: 4),
  ]
  hub.nextPullCursor = 4
  let msg2 = try DeviceEnvelope.randomNonce()
  let invWire = try sealRelayPush(
    payload: .object([
      "kind": .string("projection.invalidate"),
      "epoch": .int(1),
      "to_seq": .int(4),
      "items": .array([
        .object(["kind": .string("day"), "id": .string("2026-11-23")]),
        .object(["kind": .string("record_gone"), "id": .string("01GONEREC00000000000000001")]),
      ]),
    ]),
    messageID: msg2,
    hubKey: hubKey,
    devicePublicKey: deviceKey.publicKey
  )
  await mailbox.enqueueDown(id: msg2, data: invWire)
  let r2 = try await sync.pollRelayDown()
  #expect(r2.processedMessages == 1)
  #expect(try cache.get(kind: .day, id: "2026-11-23") == nil)
  #expect(rawLRU.get("record:01GONEREC00000000000000001") == nil)
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(try cache.cursor() == ProjectionCursor(epoch: 1, seq: 4))
  #expect(hub.pullCount == 1)

  // 3) projection.hint（latest_seq > 当前 seq 时触发 pull；<= 时跳过）。
  hub.nextPullChanges = [
    ProjectionChange(seq: 5, op: .upsert, kind: .thread, id: "th-hint", rev: 5, data: .object(["title": .string("来自 hint 续拉")])),
  ]
  hub.nextPullCursor = 5
  let msg3 = try DeviceEnvelope.randomNonce()
  let hintWire = try sealRelayPush(
    payload: .object([
      "kind": .string("projection.hint"),
      "epoch": .int(1),
      "latest_seq": .int(5),
    ]),
    messageID: msg3,
    hubKey: hubKey,
    devicePublicKey: deviceKey.publicKey
  )
  await mailbox.enqueueDown(id: msg3, data: hintWire)
  let r3 = try await sync.pollRelayDown()
  #expect(r3.processedMessages == 1)
  #expect(try cache.get(kind: .thread, id: "th-hint") != nil)
  #expect(try cache.cursor() == ProjectionCursor(epoch: 1, seq: 5))
  #expect(hub.pullCount == 2)

  // 4) projection.reset（整库 wipe 并按新 epoch 从 0 重拉）。
  try Data(#"{"day":"2026-11-23"}"#.utf8).write(to: snapshotURL)
  hub.epoch = 2
  hub.nextPullChanges = [
    ProjectionChange(seq: 1, op: .upsert, kind: .now, id: "current", rev: 1, data: .object(["brief": .string("reset 后新状态")])),
  ]
  hub.nextPullCursor = 1
  let msg4 = try DeviceEnvelope.randomNonce()
  let resetWire = try sealRelayPush(
    payload: .object([
      "kind": .string("projection.reset"),
      "epoch": .int(2),
    ]),
    messageID: msg4,
    hubKey: hubKey,
    devicePublicKey: deviceKey.publicKey
  )
  await mailbox.enqueueDown(id: msg4, data: resetWire)
  let r4 = try await sync.pollRelayDown()
  #expect(r4.processedMessages == 1)
  #expect(try cache.get(kind: .project, id: "p-alpha") == nil)
  #expect(try cache.get(kind: .thread, id: "th-hint") == nil)
  #expect(try cache.get(kind: .now, id: "current") != nil)
  #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
  #expect(try cache.cursor() == ProjectionCursor(epoch: 2, seq: 1))

  // 确认 4 条 down 消息均已删除。
  #expect(await mailbox.deletedDownIDs == [msg1, msg2, msg3, msg4])

  // 前后台轮询间隔切换检查（前台 30s、后台 5 分钟）。
  #expect(await sync.currentPollInterval == 30)
  await sync.setAppState(.background)
  #expect(await sync.currentPollInterval == 300)
  await sync.setAppState(.foreground)
  #expect(await sync.currentPollInterval == 30)

  // clearMemory 生效。
  rawLRU.set("record:01KEEP", data: Data("abc".utf8))
  await sync.clearMemory()
  #expect(rawLRU.count == 0)
}

@Test func eventStreamTriggersPullAndFallsBackToPollingWhenUnavailable() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = try ProjectionCache(dataDirectory: dir, keyProvider: InMemoryProjectionCacheKeyProvider())

  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()

  final class Counter: @unchecked Sendable { var pulls = 0 }
  let counter = Counter()

  let transport = ProjectionStubTransport { sealed in
    let (op, _) = try decodeClientRequest(sealed, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    if op == "projection.ack" {
      return try sealHubReply(body: .object(["ok": .bool(true)]), requestNonce: sealed.nonce, hubKey: hubKey, devicePublicKey: deviceKey.publicKey)
    }
    counter.pulls += 1
    return try sealHubReply(
      body: .object([
        "epoch": .int(1),
        "reset": .bool(false),
        "changes": .array([
          .object([
            "seq": .int(1), "op": .string("upsert"), "kind": .string("now"),
            "id": .string("current"), "rev": .int(1),
            "data": .object(["brief": .string("实时同步完成")]),
          ]),
        ]),
        "cursor": .int(1),
        "more": .bool(false),
        "server_time": .string("2026-11-23T12:00:00Z"),
      ]),
      requestNonce: sealed.nonce,
      hubKey: hubKey,
      devicePublicKey: deviceKey.publicKey
    )
  }

  let client = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: transport
  )

  // WebSocket 不可用时退回轮询，仍能完成拉取。
  let failingStream = MockEventStream(failSubscribe: true)
  let sync = ProjectionSync(
    client: client,
    cache: cache,
    eventStream: failingStream,
    foregroundPollInterval: 0.05,
    backgroundPollInterval: 0.2
  )
  await sync.start()
  try await Task.sleep(nanoseconds: 150_000_000)
  await sync.stop()

  #expect(await failingStream.receivedAuthEnvelopes.count >= 1)
  #expect(counter.pulls >= 1)
  #expect(try cache.get(kind: .now, id: "current") != nil)

  // 校验首帧鉴权信封能被中枢解开且 op == events.subscribe。
  let firstAuth = try #require(await failingStream.receivedAuthEnvelopes.first)
  let env = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: firstAuth)
  let plain = try DeviceEnvelope.openRequestEnvelope(env, recipientPrivateKey: hubKey, senderPublicKey: deviceKey.publicKey)
  let json = try JSONDecoder().decode(DeviceJSON.self, from: plain)
  #expect(json["op"]?.stringValue == "events.subscribe")
}

// MARK: - 9. 真实中枢端到端测试（由 collector/scripts/e2e-projection.ts 驱动）

@Test func projectionLiveHubEndToEnd() async throws {
  let env = ProcessInfo.processInfo.environment
  guard let inviteURI = env["TACIT_PROJECTION_E2E_INVITE"],
        let originString = env["TACIT_PROJECTION_E2E_ORIGIN"],
        let adminBase = env["TACIT_PROJECTION_E2E_ADMIN"],
        let adminToken = env["TACIT_PROJECTION_E2E_TOKEN"],
        let deleteRecordID = env["TACIT_PROJECTION_E2E_DELETE_RECORD_ID"],
        let deletedThreadID = env["TACIT_PROJECTION_E2E_DELETED_THREAD_ID"],
        let deletedDayKey = env["TACIT_PROJECTION_E2E_DELETED_DAY"],
        let expectedJSON = env["TACIT_PROJECTION_E2E_EXPECT_COUNTS"] else {
    return
  }

  struct ExpectedCounts: Decodable {
    let day: Int
    let project: Int
    let thread: Int
    let project_context: Int
    let now: Int
  }
  let expected = try JSONDecoder().decode(ExpectedCounts.self, from: Data(expectedJSON.utf8))

  // 1. 解析 viewer 邀请并核对中枢 hello。
  let invitation = try DevicePairingInvitation.parse(inviteURI)
  #expect(invitation.role == "view")
  #expect(invitation.receivesProjection)
  let originURL = try #require(URL(string: originString))
  let transport = try DirectDeviceTransport(origin: originURL)
  #expect(await transport.matchesHub(hubID: invitation.hubID) == true)

  // 2. Swift 端以 platform: .mac 完成配对。
  let keyStore = InMemoryDeviceKeyStore()
  let client = DeviceClient(invitation: invitation, keyStore: keyStore, transport: transport)
  let paired = try await client.pair(invitation: invitation, deviceName: "E2E 查看端 Mac", platform: .mac)
  #expect(paired.hubID == invitation.hubID)
  #expect(paired.deviceID.hasPrefix("mac-"))

  // 3. 在临时目录建立 ProjectionCache（内存密钥，不碰真实钥匙串和数据目录）并全量拉取。
  let tempDir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: tempDir) }
  let widgetURL = tempDir.appendingPathComponent("widget-today.json")
  try Data(#"{"day":"\#(deletedDayKey)"}"#.utf8).write(to: widgetURL)

  let cache = try ProjectionCache(
    dataDirectory: tempDir,
    widgetSnapshotURL: widgetURL,
    keyProvider: InMemoryProjectionCacheKeyProvider()
  )
  let eventStream = try URLSessionProjectionEventStream(origin: originURL)
  let sync = ProjectionSync(client: client, cache: cache, eventStream: eventStream)

  let initialSync = try await sync.pullToLatest()
  #expect(initialSync.pagesFetched >= 1)
  #expect(initialSync.cursor.epoch >= 1)
  #expect(initialSync.cursor.seq > 0)

  let actualDays = try cache.count(kind: .day)
  let actualProjects = try cache.count(kind: .project)
  let actualThreads = try cache.count(kind: .thread)
  let actualContexts = try cache.count(kind: .projectContext)
  let actualNow = try cache.count(kind: .now)

  #expect(actualDays == expected.day)
  #expect(actualProjects == expected.project)
  #expect(actualThreads == expected.thread)
  #expect(actualContexts == expected.project_context)
  #expect(actualNow == expected.now)
  #expect(try cache.get(kind: .thread, id: deletedThreadID) != nil)
  #expect(try cache.get(kind: .day, id: deletedDayKey) != nil)

  // 验证按需原文读取写入内存 LRU。
  let rawBefore = try await sync.getRecords(ids: [deleteRecordID])
  #expect(rawBefore.records[deleteRecordID] != nil)
  #expect(sync.rawCache.count == 1)

  // 4. 经真实 WebSocket `/v1/device/events` 订阅，并在中枢删除记录。
  let auth = try await client.makeSealedRequest(op: "events.subscribe", body: [:])
  let stream = try await eventStream.subscribe(authEnvelope: auth.wireData)

  let eventTask = Task<ProjectionEvent?, Error> {
    var firstSeen = false
    for try await event in stream {
      if !firstSeen {
        firstSeen = true
        continue // 跳过订阅握手立即返回的当前游标
      }
      if event.urgent && event.seq > initialSync.cursor.seq {
        return event
      }
    }
    return nil
  }

  // 等待订阅完成再删除记录。
  try await Task.sleep(nanoseconds: 200_000_000)

  let deleteURL = try #require(URL(string: "\(adminBase)/v1/records/\(deleteRecordID)"))
  var delReq = URLRequest(url: deleteURL)
  delReq.httpMethod = "DELETE"
  delReq.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
  let (_, delResp) = try await URLSession.shared.data(for: delReq)
  #expect((delResp as? HTTPURLResponse)?.statusCode == 200)

  // 等到中枢推送 urgent 事件（或超时兜底）。
  let urgentEvent = try await withThrowingTaskGroup(of: ProjectionEvent?.self) { group in
    group.addTask { try await eventTask.value }
    group.addTask {
      try await Task.sleep(nanoseconds: 3_000_000_000)
      return nil
    }
    let first = try await group.next() ?? nil
    group.cancelAll()
    return first
  }
  #expect(urgentEvent?.urgent == true)

  // 5. 拉取删除后的增量，核对受影响实体和内存 LRU 被立即撤下。
  let afterDelete = try await sync.pullToLatest()
  #expect(afterDelete.goneRecordIDs.contains(deleteRecordID))
  #expect(try cache.get(kind: .thread, id: deletedThreadID) == nil)
  #expect(sync.rawCache.count == 0)

  // 校验该天的日报中不再包含被删记录。
  if let updatedDay = try cache.get(kind: .day, id: deletedDayKey) {
    let text = String(decoding: updatedDay.payloadData, as: UTF8.self)
    #expect(!text.contains(deleteRecordID))
  }

  print(
    "[E2E OK] device=\(paired.deviceID) hub=\(paired.hubID) "
      + "counts(day=\(actualDays),project=\(actualProjects),thread=\(actualThreads),project_context=\(actualContexts),now=\(actualNow)) "
      + "urgent_ws_seq=\(urgentEvent?.seq ?? -1) deleted_thread=\(deletedThreadID) gone=\(afterDelete.goneRecordIDs)"
  )
}
