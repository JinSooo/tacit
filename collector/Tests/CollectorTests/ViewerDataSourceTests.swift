import CollectorCore
import CryptoKit
import Foundation
import Testing
@testable import Collector

// MARK: - 测试辅助

private func makeTempDir(_ prefix: String = "tacit-viewer-test-") throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return dir
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      guard let handler = Self.handler else { throw URLError(.badServerResponse) }
      let (status, body) = try handler(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func readBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buf = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = stream.read(&buf, maxLength: buf.count)
    if n == 0 { return data }
    if n < 0 { throw URLError(.cannotDecodeContentData) }
    data.append(contentsOf: buf.prefix(n))
  }
}

private func makeStubSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: config)
}

private final class LockedList<Element>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Element] = []
  func append(_ item: Element) { lock.lock(); items.append(item); lock.unlock() }
  var snapshot: [Element] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LockedValue<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ value: T) { self.value = value }
  func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

private func sealReply(
  status: Int = 200,
  bodyJSON: String,
  nonce: String,
  hubKey: Curve25519.KeyAgreement.PrivateKey,
  devicePublicKey: Curve25519.KeyAgreement.PublicKey
) throws -> Data {
  let plaintext = Data("{\"status\":\(status),\"body\":\(bodyJSON)}".utf8)
  let sealed = try DeviceEnvelope.sealResponsePlaintext(
    plaintext,
    requestNonce: nonce,
    senderPrivateKey: hubKey,
    recipientPublicKey: devicePublicKey
  )
  return try JSONEncoder().encode(sealed)
}

private struct DecodedDeviceRequest: Decodable {
  let op: String
  let nonce: String
  let body: [String: DeviceJSON]
}

private func locateRepoRoot() -> URL? {
  var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<8 {
    let cli = dir.appendingPathComponent("hub/src/cli.ts")
    if FileManager.default.fileExists(atPath: cli.path) { return dir }
    dir.deleteLastPathComponent()
  }
  return nil
}

private func locateBun() -> String? {
  let candidates = [
    ProcessInfo.processInfo.environment["BUN_PATH"],
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path,
    "/opt/homebrew/bin/bun",
    "/usr/local/bin/bun",
  ].compactMap { $0 }
  return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - 单测与等价性测试

@Suite(.serialized) struct ViewerDataSourceTests {

  // MARK: 1. 没有连接文件时走 HTTP

  @Test func noLinkFileUsesHTTP() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let origin = URL(string: "http://127.0.0.1:47901")!
    let paths = LockedList<String>()
    StubURLProtocol.handler = { request in
      let path = request.url?.path ?? ""
      paths.append(path)
      switch path {
      case "/v1/projects":
        return (200, Data(#"{"projects":[{"id":"01JAA000000000000000000001","name":"风帆日志","brief":"测试项目","confirmed":1,"last_ms":1763890000000,"thread_count":1}]}"#.utf8))
      case "/v1/now":
        return (200, Data(#"{"now":{"brief":"正在整理航线脚本","updated_at":"2026-11-23T09:30:00Z","feedback":null}}"#.utf8))
      default:
        return (404, Data(#"{"error":"not found"}"#.utf8))
      }
    }
    defer { StubURLProtocol.handler = nil }

    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [StubURLProtocol.self]
    let api = HubAPI(base: { origin }, token: { "test-token" }, configuration: sessionConfig, busyRetryDelays: [])
    let adaptive = AdaptiveViewerDataSource(
      http: HTTPViewerDataSource(api: api),
      dataDir: dir,
      originProvider: { origin },
      cacheKeyProvider: InMemoryProjectionCacheKeyProvider(),
      urlSession: makeStubSession()
    )

    #expect(adaptive.activateIfLinked() == false)
    #expect(adaptive.isUsingCache == false)

    let projects = try await adaptive.projects()
    let now = try await adaptive.now()

    #expect(projects.map(\.name) == ["风帆日志"])
    #expect(now?.brief == "正在整理航线脚本")
    #expect(paths.snapshot == ["/v1/projects", "/v1/now"])
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("viewer-cache.db").path))
  }

  // MARK: 2. 401 时调 wipe 并退回 HTTP

  @Test func unauthorized401WipesCacheAndFallsBackToHTTP() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let origin = URL(string: "http://127.0.0.1:47902")!
    let hubKey = Curve25519.KeyAgreement.PrivateKey()
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let deviceID = "mac-abcd2345"
    let hubID = DeviceProtocol.hubID(for: hubKey.publicKey)

    let files = LocalDeviceLink.Files(directory: dir)
    let linkPayload = try JSONSerialization.data(withJSONObject: [
      "hub_id": hubID,
      "hub_pk": DeviceEnvelope.publicKeyBase64URL(hubKey.publicKey),
      "device_id": deviceID,
      "mode": "local",
      "addrs": [origin.absoluteString],
      "relay": NSNull(),
    ])
    try files.write(.collector, linkPayload)

    let widgetFile = dir.appendingPathComponent("widget/today.json")
    try FileManager.default.createDirectory(at: widgetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PrivateFile.write(JSONEncoder().encode(WidgetSnapshot(day: "2026-11-23", summary: "旧快照")), to: widgetFile)

    let keys = LocalDeviceLink.Keys(
      read: { $0 == .mac ? macKey.rawRepresentation : nil },
      create: { _, _ in Issue.record("不应新建私钥") }
    )

    let removedFlag = LockedValue(false)
    let paths = LockedList<String>()
    let wipedReasons = LockedList<ProjectionWipeReason>()

    StubURLProtocol.handler = { request in
      let path = request.url?.path ?? ""
      paths.append(path)
      switch path {
      case "/v1/device":
        let envelope = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: readBody(request))
        let plain = try DeviceEnvelope.openRequestEnvelope(envelope, recipientPrivateKey: hubKey, senderPublicKey: macKey.publicKey)
        let req = try JSONDecoder().decode(DecodedDeviceRequest.self, from: plain)
        if removedFlag.get() {
          return (401, Data(#"{"error":"设备未配对或已被移除"}"#.utf8))
        }
        switch req.op {
        case "projection.pull":
          let body = """
            {"epoch":1,"reset":false,"cursor":1,"more":false,"server_time":"2026-11-23T10:00:00Z","changes":[
              {"seq":1,"op":"upsert","kind":"project","id":"01JAA000000000000000000001","rev":1,
               "data":{"id":"01JAA000000000000000000001","name":"缓存项目","confirmed":1,"brief":"来自缓存","last_ms":1763890000000,"thread_count":1,"needs_regen":0,"updated_at":"2026-11-23T10:00:00Z","facts":[]}}
            ]}
            """
          return (200, try sealReply(bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        case "projection.ack":
          return (200, try sealReply(bodyJSON: #"{"ok":true}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        default:
          return (200, try sealReply(status: 400, bodyJSON: #"{"error":"unexpected"}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        }
      case "/v1/records/01JAA000000000000000000099":
        let body = """
          {"id":"01JAA000000000000000000099","device":"mac","source":"manual.note","kind":"event",
           "t_start":"2026-11-23T09:15:00+09:00","title":"HTTP回退记录","body":"通过HTTP读取成功","corrections":[]}
          """
        return (200, Data(body.utf8))
      case "/v1/projects":
        return (200, Data(#"{"projects":[{"id":"01JAA000000000000000000002","name":"HTTP项目","brief":"来自HTTP","confirmed":1,"last_ms":1763890000000,"thread_count":1}]}"#.utf8))
      default:
        return (404, Data(#"{"error":"not found"}"#.utf8))
      }
    }
    defer { StubURLProtocol.handler = nil }

    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [StubURLProtocol.self]
    let stubSession = makeStubSession()
    defer { stubSession.invalidateAndCancel() }
    let api = HubAPI(base: { origin }, token: { "test-token" }, configuration: sessionConfig, busyRetryDelays: [])

    let adaptive = AdaptiveViewerDataSource(
      http: HTTPViewerDataSource(api: api),
      dataDir: dir,
      originProvider: { origin },
      widgetSnapshotURL: widgetFile,
      files: files,
      keys: keys,
      cacheKeyProvider: InMemoryProjectionCacheKeyProvider(),
      urlSession: stubSession,
      foregroundPollInterval: 600,
      backgroundPollInterval: 600,
      onWipe: { reason in wipedReasons.append(reason) },
      sessionFactory: { link, resolvedOrigin, onWipe, onUpdate in
        let transport = try DirectDeviceTransport(origin: resolvedOrigin, session: stubSession)
        let client = try DeviceClient(
          hubPublicKeyBase64URL: link.hub_pk,
          deviceID: link.device_id,
          keyStore: InMemoryDeviceKeyStore(rawRepresentation: macKey.rawRepresentation),
          transport: transport
        )
        let cache = try ProjectionCache(
          dataDirectory: dir,
          widgetSnapshotURL: widgetFile,
          keyProvider: InMemoryProjectionCacheKeyProvider()
        )
        return ProjectionSync(
          client: client,
          cache: cache,
          eventStream: nil,
          foregroundPollInterval: 600,
          backgroundPollInterval: 600,
          onWipe: onWipe,
          onUpdate: onUpdate
        )
      }
    )
    defer { adaptive.stop() }

    #expect(adaptive.activateIfLinked() == true)
    #expect(adaptive.isUsingCache == true)

    // 先从缓存读一次，确认 viewer-cache.db 与小组件快照均存在。
    let cachedProjects = try await adaptive.projects()
    #expect(cachedProjects.map(\.name) == ["缓存项目"])
    let dbPath = dir.appendingPathComponent(ProjectionCache.databaseFileName).path
    #expect(FileManager.default.fileExists(atPath: dbPath))
    #expect(FileManager.default.fileExists(atPath: widgetFile.path))

    // 模拟设备被移除 -> 下一次设备请求返回 401。
    removedFlag.set(true)
    let fallbackRecord = try await adaptive.record("01JAA000000000000000000099")
    #expect(fallbackRecord.record.title == "HTTP回退记录")
    #expect(fallbackRecord.record.body == "通过HTTP读取成功")

    // 验证 wipe 已执行：viewer-cache.db、小组件快照、collector-link.json 均已删除，并已切回 HTTP。
    #expect(adaptive.isUsingCache == false)
    #expect(!FileManager.default.fileExists(atPath: dbPath))
    #expect(!FileManager.default.fileExists(atPath: widgetFile.path))
    #expect(try files.collector() == nil)
    #expect(wipedReasons.snapshot.contains(.deviceRemoved))

    // 后续读取直接走 HTTP，不再访问 /v1/device。
    let beforeCount = paths.snapshot.filter { $0 == "/v1/device" }.count
    let httpProjects = try await adaptive.projects()
    #expect(httpProjects.map(\.name) == ["HTTP项目"])
    #expect(paths.snapshot.filter { $0 == "/v1/device" }.count == beforeCount)
  }

  // MARK: 3. clearMemory 后，内存里的原文清空

  @Test func clearMemoryEmptiesRawRecordLRU() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let origin = URL(string: "http://127.0.0.1:47903")!
    let hubKey = Curve25519.KeyAgreement.PrivateKey()
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let deviceID = "mac-bcde2345"
    let hubID = DeviceProtocol.hubID(for: hubKey.publicKey)

    let files = LocalDeviceLink.Files(directory: dir)
    try files.write(.collector, try JSONSerialization.data(withJSONObject: [
      "hub_id": hubID,
      "hub_pk": DeviceEnvelope.publicKeyBase64URL(hubKey.publicKey),
      "device_id": deviceID,
      "mode": "local",
      "addrs": [origin.absoluteString],
      "relay": NSNull(),
    ]))

    let getCalls = LockedValue(0)
    let targetID = "01JAA000000000000000000088"
    StubURLProtocol.handler = { request in
      let envelope = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: readBody(request))
      let plain = try DeviceEnvelope.openRequestEnvelope(envelope, recipientPrivateKey: hubKey, senderPublicKey: macKey.publicKey)
      let req = try JSONDecoder().decode(DecodedDeviceRequest.self, from: plain)
      switch req.op {
      case "projection.pull":
        let body = #"{"epoch":1,"reset":false,"cursor":1,"more":false,"server_time":"2026-11-23T10:00:00Z","changes":[]}"#
        return (200, try sealReply(bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      case "projection.ack":
        return (200, try sealReply(bodyJSON: #"{"ok":true}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      case "records.get":
        getCalls.set(getCalls.get() + 1)
        let body = """
          {"records":[{"id":"\(targetID)","device":"\(deviceID)","source":"manual.note","kind":"event",
           "t_start":"2026-11-23T08:00:00+09:00","title":"私密原文","body":"仅留内存的敏感正文",
           "sensitivity":"private","body_range":{"start":0,"end":10,"total":10}}],"missing":[],"next_cursor":null}
          """
        return (200, try sealReply(bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      default:
        return (200, try sealReply(status: 400, bodyJSON: #"{"error":"unexpected"}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      }
    }
    defer { StubURLProtocol.handler = nil }

    let stubSession = makeStubSession()
    defer { stubSession.invalidateAndCancel() }
    let api = HubAPI(base: { origin }, token: { "test-token" }, busyRetryDelays: [])

    let adaptive = AdaptiveViewerDataSource(
      http: HTTPViewerDataSource(api: api),
      dataDir: dir,
      originProvider: { origin },
      files: files,
      cacheKeyProvider: InMemoryProjectionCacheKeyProvider(),
      sessionFactory: { link, resolvedOrigin, onWipe, onUpdate in
        let transport = try DirectDeviceTransport(origin: resolvedOrigin, session: stubSession)
        let client = try DeviceClient(
          hubPublicKeyBase64URL: link.hub_pk,
          deviceID: link.device_id,
          keyStore: InMemoryDeviceKeyStore(rawRepresentation: macKey.rawRepresentation),
          transport: transport
        )
        let cache = try ProjectionCache(
          dataDirectory: dir,
          keyProvider: InMemoryProjectionCacheKeyProvider()
        )
        return ProjectionSync(
          client: client,
          cache: cache,
          eventStream: nil,
          foregroundPollInterval: 600,
          backgroundPollInterval: 600,
          onWipe: onWipe,
          onUpdate: onUpdate
        )
      }
    )
    defer { adaptive.stop() }

    #expect(adaptive.activateIfLinked() == true)
    let sync = try #require(adaptive.activeSync)

    // 首次读取命中中枢，写入内存 LRU；第二次直接命中内存。
    let first = try await adaptive.record(targetID)
    #expect(first.record.body == "仅留内存的敏感正文")
    #expect(getCalls.get() == 1)
    #expect(sync.rawCache.count == 1)
    #expect(sync.rawCache.totalBytes > 0)

    let second = try await adaptive.record(targetID)
    #expect(second == first)
    #expect(getCalls.get() == 1)

    // 锁屏/关窗调用 clearMemory() -> 内存 LRU 立即清空。
    adaptive.clearMemory()
    #expect(sync.rawCache.count == 0)
    #expect(sync.rawCache.totalBytes == 0)

    // 清空后再次读取必须重新请求中枢。
    _ = try await adaptive.record(targetID)
    #expect(getCalls.get() == 2)
  }

  // MARK: 4. 跨天时小组件快照删除

  @Test @MainActor func widgetSnapshotDeletedOnDayRollover() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15, minute: 0))!
    let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 0, minute: 5))!

    let nowBox = LockedValue(day1)
    let reloadCount = LockedValue(0)
    let widgetFile = dir.appendingPathComponent("widget/today.json")

    let day1DiaryJSON = """
      {
        "date": "2026-11-22",
        "detail": {
          "summary": "完成了灯塔巡检排班表重构。",
          "items": [
            {
              "id": "seg-1",
              "title": "灯塔排班表",
              "description": "重构了排班算法。",
              "t_start": "2026-11-22T10:00:00+09:00",
              "t_end": "2026-11-22T11:00:00+09:00",
              "active_seconds": 3600,
              "sources": ["claude_code.session"],
              "evidence": [],
              "record_ids": ["01JAA000000000000000000011"]
            }
          ]
        }
      }
      """
    let day1Diary = try HubJSON.decoder().decode(DayDiary.self, from: Data(day1DiaryJSON.utf8))

    struct StaticDiarySource: ViewerDataSource {
      let diaries: [String: DayDiary]
      let calendar: Calendar
      func diary(_ day: Date) async throws -> DayDiary? { diaries[TimelineDay.key(day, calendar: calendar)] }
      func now() async throws -> NowState? { nil }
      func projects() async throws -> [Project] { [] }
      func project(_ id: String, level: String) async throws -> EntityDetail { throw HubError(message: "404", status: 404) }
      func projectContext(_ id: String) async throws -> [HubThread] { [] }
      func thread(_ id: String, level: String) async throws -> EntityDetail { throw HubError(message: "404", status: 404) }
      func timeline(projectId: String?, threadId: String?, query: String?, before: String?) async throws -> HubAPI.TimelineResult {
        HubAPI.TimelineResult(days: [], nextCursor: nil)
      }
      func timelineLocation(record id: String) async throws -> HubAPI.TimelineLocation {
        HubAPI.TimelineLocation(date: "2026-11-22", segmentId: nil)
      }
      func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage { RecordPage(records: [], nextCursor: nil) }
      func day(_ day: Date) async throws -> [HistoryRecord] { [] }
      func record(_ id: String) async throws -> RecordDetail { throw HubError(message: "404", status: 404) }
      func recordsByIDs(_ ids: [String]) async throws -> [HistoryRecord] { [] }
      func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord] { [] }
      func segments(_ day: Date, device: String?) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) { ([], []) }
      func conversation(_ recordID: String) async throws -> ConversationDetail { throw HubError(message: "404", status: 404) }
    }

    let source = StaticDiarySource(diaries: ["2026-11-22": day1Diary], calendar: calendar)
    let publisher = WidgetSnapshotPublisher(
      dataSource: source,
      file: widgetFile,
      clock: { nowBox.get() },
      calendar: calendar,
      reloadTimelines: { reloadCount.set(reloadCount.get() + 1) },
      stopStaleExtension: false
    )
    defer { publisher.stop() }

    // Day 1：生成今日快照。
    await publisher.refreshNow()
    #expect(FileManager.default.fileExists(atPath: widgetFile.path))
    let snapDay1 = try #require(WidgetSnapshot.readToday(from: widgetFile, now: day1, calendar: calendar))
    #expect(snapDay1.day == "2026-11-22")
    #expect(snapDay1.summary == "完成了灯塔巡检排班表重构。")
    #expect(snapDay1.segments.count == 1)

    // 跨到 Day 2（尚无 Day 2 数据）：旧快照必须被立即删除。
    let reloadsBefore = reloadCount.get()
    nowBox.set(day2)
    await publisher.refreshNow()
    #expect(!FileManager.default.fileExists(atPath: widgetFile.path))
    #expect(reloadCount.get() > reloadsBefore)
  }

  // MARK: 5. 真实中枢等价性与删除联动测试（sealed-file + local-bootstrap + 合成数据）

  @Test func liveHubEquivalenceAndDeletion() async throws {
    let repoRoot = try #require(locateRepoRoot(), "找不到仓库根目录 hub/src/cli.ts")
    let bunPath = try #require(locateBun(), "找不到 bun 可执行文件")

    let workDir = try makeTempDir("tacit-equiv-")
    defer { try? FileManager.default.removeItem(at: workDir) }
    let dataDir = workDir.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    // 根密钥文件放在数据目录之外，权限 0600（符合 sealed-file 契约 6.11.3）。
    let masterKeyFile = workDir.appendingPathComponent("master.key")
    var masterBytes = [UInt8](repeating: 0, count: 32)
    for i in masterBytes.indices { masterBytes[i] = UInt8((i * 17 + 41) & 0xff) }
    let masterHex = masterBytes.map { String(format: "%02x", $0) }.joined()
    try PrivateFile.write(Data((masterHex + "\n").utf8), to: masterKeyFile)

    // 用独立 Bun 脚本写入合成虚构数据：多天、多项目、含私密记录、含纠错过的段和记录修正、含事项和此刻。
    let seedScript = workDir.appendingPathComponent("seed.ts")
    let seedSource = """
      import { join } from "node:path";
      import { loadConfig } from "\(repoRoot.path)/hub/src/config.ts";
      import { HubDB } from "\(repoRoot.path)/hub/src/db.ts";
      import { DistillStore } from "\(repoRoot.path)/hub/src/distill/store.ts";
      import { incrementalReview } from "\(repoRoot.path)/hub/src/distill/day-review.ts";
      import { localDateString, localDayStart } from "\(repoRoot.path)/hub/src/distill/requests.ts";
      import { nowSummary } from "\(repoRoot.path)/hub/src/now-status.ts";
      import { correctTimelineSegment } from "\(repoRoot.path)/hub/src/timeline.ts";
      import { toLocalIso } from "\(repoRoot.path)/packages/record/index.ts";

      const config = loadConfig();
      const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
      const store = new DistillStore(db);

      const now = Date.now();
      const todayDate = localDateString(now);
      const yesterdayMs = now - 24 * 3600_000;
      const yesterdayDate = localDateString(yesterdayMs);

      const startOf = (dateStr: string, hour: number, minute: number) => {
        const [y, m, d] = dateStr.split("-").map(Number);
        return new Date(y!, m! - 1, d!, hour, minute, 0, 0).getTime();
      };

      // 确保记录时刻不超过当前时刻，便于 nowSummary 和今日展示。
      const baseToday = Math.min(startOf(todayDate, 9, 0), now - 90 * 60_000);
      const y1Start = startOf(yesterdayDate, 10, 0);
      const y1End = y1Start + 35 * 60_000;
      const y2Start = y1Start + 5 * 60_000;
      const y2End = y1Start + 25 * 60_000;

      const t1Start = baseToday;
      const t1End = t1Start + 25 * 60_000;
      const t2Start = t1End + 10 * 60_000;
      const t2End = t2Start + 20 * 60_000;
      const t3Start = t2Start + 5 * 60_000;
      const t3End = t2Start + 15 * 60_000;
      const privStart = t2End + 5 * 60_000;
      const privEnd = privStart + 5 * 60_000;
      const corrStart = t1End + 60_000;

      const ids = {
        recY1: "01JAE000000000000000000001",
        recY2: "01JAE000000000000000000002",
        recT1: "01JAE000000000000000000003",
        recT2: "01JAE000000000000000000004",
        recT3: "01JAE000000000000000000005",
        recPriv: "01JAE000000000000000000006",
        recCorr: "01JAE000000000000000000007",
        projA: "01JAE000000000000000000101",
        projB: "01JAE000000000000000000102",
        threadA: "01JAE000000000000000000201",
        threadB: "01JAE000000000000000000202",
        factAOpen: "01JAE000000000000000000301",
        factADecision: "01JAE000000000000000000302",
        factBOpen: "01JAE000000000000000000303",
      };

      const ingestRes = db.ingest([
        {
          id: ids.recY1, schema: 1, device: "mac", source: "claude_code.session", kind: "span",
          t_start: toLocalIso(y1Start), t_end: toLocalIso(y1End),
          title: "风向平滑算法讨论", body: "[我] 先按三点滑动平均做风向平滑。\\n\\n[AI] 已写入 WindCalibrator.swift。",
          source_ref: "sess-y1#1", context: { app: "com.anthropic.claudefordesktop", repo: "/tmp/synthetic-sailing" },
          capture: { method: "file" }, sensitivity: "normal",
        },
        {
          id: ids.recY2, schema: 1, device: "mac", source: "mac.screen", kind: "span",
          t_start: toLocalIso(y2Start), t_end: toLocalIso(y2End),
          title: "Xcode · WindCalibrator.swift", body: "func smoothWind(samples: [Double]) -> Double",
          context: { app: "com.apple.dt.Xcode", window: "WindCalibrator.swift" },
          capture: { method: "ax" }, sensitivity: "normal",
        },
        {
          id: ids.recT1, schema: 1, device: "mac", source: "codex.session", kind: "span",
          t_start: toLocalIso(t1Start), t_end: toLocalIso(t1End),
          title: "风速计边界测试", body: "[我] 补齐高风速边界单测。\\n\\n[AI] 原始测试输出。",
          source_ref: "sess-t1#1", context: { app: "com.openai.codex", repo: "/tmp/synthetic-sailing" },
          capture: { method: "file" }, sensitivity: "normal",
        },
        {
          id: ids.recT2, schema: 1, device: "mac", source: "claude_code.session", kind: "span",
          t_start: toLocalIso(t2Start), t_end: toLocalIso(t2End),
          title: "雾号排班页面改版", body: "[我] 重构灯塔夜间雾号排班视图。\\n\\n[AI] 已完成排班列表改版。",
          source_ref: "sess-t2#1", context: { app: "com.anthropic.claudefordesktop", repo: "/tmp/synthetic-lighthouse" },
          capture: { method: "file" }, sensitivity: "normal",
        },
        {
          id: ids.recT3, schema: 1, device: "mac", source: "mac.wechat", kind: "span",
          t_start: toLocalIso(t3Start), t_end: toLocalIso(t3End),
          title: "港口值班群", body: "我：今晚雾号换班时间还是 22:00 吗？\\n值班长：提前到 21:00 了。",
          context: { app: "com.tencent.xinWeChat", chat: "港口值班群", extra: { from_me: 1 } },
          capture: { method: "ocr" }, sensitivity: "normal",
        },
        {
          id: ids.recPriv, schema: 1, device: "mac", source: "mac.screen", kind: "span",
          t_start: toLocalIso(privStart), t_end: toLocalIso(privEnd),
          title: "私密健康备忘 · 体检摘要", body: "合成私密记录正文：PRIVATE_SYNTHETIC_MARKER_9981",
          context: { app: "com.apple.Notes", window: "私密健康备忘" },
          capture: { method: "ax" }, sensitivity: "private",
        },
        {
          id: ids.recCorr, schema: 1, device: "mac", source: "manual.correction", kind: "event",
          t_start: toLocalIso(corrStart), title: "风速计边界测试",
          body: "修正后的记录正文：高风速边界 12 组用例全部通过。",
          corrects: ids.recT1, capture: { method: "manual" }, sensitivity: "normal",
        },
      ]);
      if (ingestRes.accepted !== 7) throw new Error("ingest failed: " + JSON.stringify(ingestRes));

      const updatedAt = new Date(t2End).toISOString();
      store.upsertProject({
        id: ids.projA, name: "风帆航海志", confirmed: 1,
        keys: { repos: ["/tmp/synthetic-sailing"], hosts: [], chats: [] },
        brief: "整理航线规划与风向校准脚本。",
        detail: { goal: "完成风速风向校准模块", status: "测试通过，待合入主分支", people: ["林船长"] },
        salience: 0.9, last_ms: t1End, needs_regen: 0, updated_at: updatedAt,
      });
      store.upsertProject({
        id: ids.projB, name: "灯塔信号站", confirmed: 1,
        keys: { repos: ["/tmp/synthetic-lighthouse"], hosts: [], chats: ["港口值班群"] },
        brief: "重构灯塔雾号排班和巡检记录。",
        detail: { goal: "上线新版夜间排班表", status: "界面改版已完成", people: ["值班长"] },
        salience: 0.8, last_ms: t2End, needs_regen: 0, updated_at: updatedAt,
      });

      store.upsertThread({
        id: ids.threadA, project_id: ids.projA, status: "active", domain: "work",
        title: "风向校准与边界测试", brief: "完成风向平滑算法与高风速边界单测。",
        detail: {
          goal: "保证风速计高风速区间稳定读数",
          progress: "昨日完成平滑算法，今日补齐边界测试。",
          artifacts: { files: ["/tmp/synthetic-sailing/WindCalibrator.swift"], urls: [], commands: ["swift test"], people: ["林船长"] },
          quotes: [{ record_id: ids.recT1, text: "补齐高风速边界单测" }],
        },
        first_ms: y1Start, last_ms: t1End, active_minutes: 60, sessions: 2, needs_regen: 0, updated_at: updatedAt,
      });
      store.upsertThread({
        id: ids.threadB, project_id: ids.projB, status: "active", domain: "work",
        title: "雾号排班界面改版", brief: "重构夜间雾号排班表并与值班群核对换班时间。",
        detail: {
          goal: "明确夜间换班时间展示",
          progress: "已改版页面并确认换班提前到 21:00。",
          artifacts: { files: ["/tmp/synthetic-lighthouse/ScheduleView.swift"], urls: [], commands: [], people: ["值班长"] },
          quotes: [{ record_id: ids.recT2, text: "重构灯塔夜间雾号排班视图" }],
        },
        first_ms: t2Start, last_ms: t2End, active_minutes: 20, sessions: 1, needs_regen: 0, updated_at: updatedAt,
      });

      // 建立 frames / frame_records / assignments 关联（供 threadAccess / readingItems / historySegments 使用）。
      const insertFrame = db.db.prepare("INSERT INTO frames(id,t_start_ms,t_end_ms,key,record_ids,chars,private,status) VALUES(?,?,?,?,?,?,?,?)");
      const insertFR = db.db.prepare("INSERT INTO frame_records(frame_id,record_id) VALUES(?,?)");
      const insertAssign = db.db.prepare("INSERT INTO assignments(frame_id,thread_id,method,confidence) VALUES(?,?,?,?)");

      const frames: [string, string, number, number, string[], string][] = [
        ["frame-y1", "repo:/tmp/synthetic-sailing", y1Start, y1End, [ids.recY1, ids.recY2], ids.threadA],
        ["frame-t1", "repo:/tmp/synthetic-sailing", t1Start, t1End, [ids.recT1], ids.threadA],
        ["frame-t2", "repo:/tmp/synthetic-lighthouse", t2Start, t2End, [ids.recT2, ids.recT3], ids.threadB],
      ];
      for (const [fid, key, s, e, rids, tid] of frames) {
        insertFrame.run(fid, s, e, key, JSON.stringify(rids), 100, 0, "assigned");
        for (const rid of rids) insertFR.run(fid, rid);
        insertAssign.run(fid, tid, "model", 0.95);
      }

      store.writeFact({
        id: ids.factAOpen, thread_id: ids.threadA, project_id: ids.projA, kind: "open",
        text: "确认极端阵风条件下的采样频率上限", evidence: [ids.recT1],
        origin: "auto", valid_at: updatedAt, created_at: updatedAt,
      });
      store.writeFact({
        id: ids.factADecision, thread_id: ids.threadA, project_id: ids.projA, kind: "decision",
        text: "风向平滑固定采用三点滑动平均", evidence: [ids.recY1],
        origin: "user", valid_at: updatedAt, created_at: updatedAt,
      });
      store.writeFact({
        id: ids.factBOpen, thread_id: ids.threadB, project_id: ids.projB, kind: "open",
        text: "核对冬令时切换当晚的排班边界", evidence: [ids.recT2],
        origin: "auto", valid_at: updatedAt, created_at: updatedAt,
      });

      const yesterdayDetail = {
        summary: "在风帆航海志完成了风向平滑算法实现，并在 Xcode 中核对代码。",
        timeline: [],
        items: [
          {
            id: "seg-y1", title: "实现风向平滑算法", description: "按三点滑动平均实现风向平滑逻辑。",
            t_start: toLocalIso(y1Start), t_end: toLocalIso(y1End), active_seconds: 2100,
            sources: ["claude_code.session"],
            apps: [{ source: "claude_code.session", app: "com.anthropic.claudefordesktop" }],
            evidence: [{ id: ids.recY1, at: toLocalIso(y1Start), source: "claude_code.session", title: "风向平滑算法讨论" }],
            record_ids: [ids.recY1, ids.recY2], project_id: ids.projA,
          },
        ],
        cutoff: toLocalIso(y1End),
        record_ids: [ids.recY1, ids.recY2],
        omitted_record_ids: [],
      };
      store.upsertDay({ date: yesterdayDate, brief: yesterdayDetail.summary, detail: yesterdayDetail, needs_regen: 0, updated_at: updatedAt });

      // 按中枢真实 incrementalReview 生成的候选边界构造今日已润色段，确保与真实提炼产物完全一致。
      const plan = incrementalReview(db, localDayStart(todayDate)!, Date.now(), null);
      const findPlan = (recId: string) => {
        const hit = plan.pending.find(entry => entry.snapshot.record_ids.includes(recId));
        if (!hit) throw new Error("missing candidate for " + recId + " in " + JSON.stringify(plan.pending.map(p => p.snapshot)));
        return hit.snapshot;
      };
      const snapT1 = findPlan(ids.recT1);
      const snapT2 = findPlan(ids.recT2);

      const todayDetail = {
        summary: "在风帆航海志完成风速计边界测试，并在灯塔信号站更新了雾号排班页面。",
        timeline: [],
        items: [
          {
            id: "seg-t1", title: "风速计边界测试", description: "原描述：跑通部分风速计测试。",
            t_start: toLocalIso(snapT1.start), t_end: toLocalIso(snapT1.end), active_seconds: 1500,
            sources: ["codex.session"],
            apps: [{ source: "codex.session", app: "com.openai.codex" }],
            evidence: [{ id: ids.recT1, at: toLocalIso(t1Start), source: "codex.session", title: "风速计边界测试" }],
            record_ids: snapT1.record_ids, project_id: ids.projA,
          },
          {
            id: "seg-t2", title: "更新雾号排班界面", description: "重构灯塔夜间雾号排班表，并与港口值班群确认换班提前至 21:00。",
            t_start: toLocalIso(snapT2.start), t_end: toLocalIso(snapT2.end), active_seconds: 1200,
            sources: ["claude_code.session", "mac.wechat"],
            apps: [
              { source: "claude_code.session", app: "com.anthropic.claudefordesktop" },
              { source: "mac.wechat", app: "com.tencent.xinWeChat" },
            ],
            evidence: [
              { id: ids.recT2, at: toLocalIso(t2Start), source: "claude_code.session", title: "雾号排班页面改版" },
              { id: ids.recT3, at: toLocalIso(t3Start), source: "mac.wechat", title: "港口值班群" },
            ],
            record_ids: snapT2.record_ids, project_id: ids.projB,
          },
        ],
        polished_segments: [
          { ...snapT1, id: "seg-t1", model_dependencies: snapT1.dependencies },
          { ...snapT2, id: "seg-t2", model_dependencies: snapT2.dependencies },
        ],
        cutoff: toLocalIso(privEnd + 60_000),
        record_ids: [...new Set([...snapT1.record_ids, ...snapT2.record_ids])],
        omitted_record_ids: [],
      };
      store.upsertDay({ date: todayDate, brief: todayDetail.summary, detail: todayDetail, needs_regen: 0, updated_at: updatedAt });

      // 对今日第一段做一次用户纠错。
      const corrected = correctTimelineSegment(store, todayDate, "seg-t1", {
        description: "已纠错：完成风速计全部 12 组高风速边界测试并确认通过。",
      });
      if (!corrected) throw new Error("segment correction failed");

      // 写入此刻状态。
      store.setState("now", nowSummary(store, Date.now()));

      console.log(JSON.stringify({ todayDate, yesterdayDate, ids, token: config.token }));
      db.close();
      """
    try Data(seedSource.utf8).write(to: seedScript)

    var env = ProcessInfo.processInfo.environment
    env["RA_DATA_DIR"] = dataDir.path
    env["RA_SECRET_BACKEND"] = "sealed-file"
    env["RA_MASTER_KEY_FILE"] = masterKeyFile.path
    env["RA_PORT"] = "0"
    env["RA_LAN_PORT"] = "0"

    let seedProc = Process()
    seedProc.executableURL = URL(fileURLWithPath: bunPath)
    seedProc.arguments = [seedScript.path]
    seedProc.environment = env
    let seedOut = Pipe()
    let seedErr = Pipe()
    seedProc.standardOutput = seedOut
    seedProc.standardError = seedErr
    try seedProc.run()
    seedProc.waitUntilExit()
    let seedStdout = seedOut.fileHandleForReading.readDataToEndOfFile()
    let seedStderr = seedErr.fileHandleForReading.readDataToEndOfFile()
    guard seedProc.terminationStatus == 0 else {
      Issue.record("seed script failed (\(seedProc.terminationStatus)): \(String(decoding: seedStderr, as: UTF8.self))")
      return
    }

    struct SeedOutput: Decodable {
      struct IDs: Decodable {
        let recY1: String
        let recY2: String
        let recT1: String
        let recT2: String
        let recT3: String
        let recPriv: String
        let recCorr: String
        let projA: String
        let projB: String
        let threadA: String
        let threadB: String
      }
      let todayDate: String
      let yesterdayDate: String
      let ids: IDs
      let token: String
    }
    let seeded = try JSONDecoder().decode(SeedOutput.self, from: seedStdout)

    // 启动真实中枢子进程 `bun hub/src/cli.ts serve`。
    let hubProc = Process()
    hubProc.executableURL = URL(fileURLWithPath: bunPath)
    hubProc.arguments = [repoRoot.appendingPathComponent("hub/src/cli.ts").path, "serve"]
    hubProc.environment = env
    let hubOut = Pipe()
    let hubErr = Pipe()
    hubProc.standardOutput = hubOut
    hubProc.standardError = hubErr
    try hubProc.run()
    defer {
      if hubProc.isRunning {
        hubProc.terminate()
        hubProc.waitUntilExit()
      }
    }

    // 解析中枢实际监听的本机端口（`Hub 已启动：http://127.0.0.1:<port>`）。
    let origin: URL = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let handle = hubOut.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
          let chunk = handle.availableData
          if chunk.isEmpty { break }
          buffer.append(chunk)
          let text = String(decoding: buffer, as: UTF8.self)
          if let range = text.range(of: #"http://127\.0\.0\.1:\d+"#, options: .regularExpression),
             let url = URL(string: String(text[range])) {
            continuation.resume(returning: url)
            return
          }
        }
        let errText = String(decoding: hubErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        continuation.resume(throwing: HubError(message: "中枢未能启动：\(errText)", status: 0))
      }
    }

    // 用 local-bootstrap 将 Swift 端登记为本机 admin 设备（私钥仅存于临时目录，不碰真实钥匙串）。
    let files = LocalDeviceLink.Files(directory: dataDir)
    let keysDir = workDir.appendingPathComponent("keys")
    try FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tempKeys = LocalDeviceLink.Keys(
      read: { account in
        let file = keysDir.appendingPathComponent(account.rawValue)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return DeviceProtocol.hexDecode(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
      },
      create: { account, data in
        let file = keysDir.appendingPathComponent(account.rawValue)
        try PrivateFile.write(Data(DeviceProtocol.hexEncode(data).utf8), to: file)
      }
    )

    let link = try #require(try await LocalDeviceLink.bootstrap(
      origin: origin,
      token: seeded.token,
      files: files,
      keys: tempKeys
    ))
    #expect(link.device_id.hasPrefix("mac-"))

    // 分别构造 HTTP 数据源与缓存数据源。
    let api = HubAPI(base: { origin }, token: { seeded.token }, busyRetryDelays: [0.2, 0.5])
    let httpSource = HTTPViewerDataSource(api: api)
    let widgetFile = dataDir.appendingPathComponent("widget/today.json")
    let adaptiveSource = AdaptiveViewerDataSource(
      http: httpSource,
      dataDir: dataDir,
      originProvider: { origin },
      widgetSnapshotURL: widgetFile,
      files: files,
      keys: tempKeys,
      cacheKeyProvider: InMemoryProjectionCacheKeyProvider()
    )
    defer { adaptiveSource.stop() }

    #expect(adaptiveSource.activateIfLinked() == true)
    #expect(adaptiveSource.isUsingCache == true)
    let sync = try #require(adaptiveSource.activeSync)
    let initialSync = try await sync.pullToLatest()
    #expect(initialSync.cursor.epoch >= 1)
    #expect(initialSync.upsertedCount > 0)

    let today = try #require(TimelineDay.date(seeded.todayDate))
    let yesterday = try #require(TimelineDay.date(seeded.yesterdayDate))

    // 1. 时间线与当天概述（含纠错过的段）
    let httpTodayDiary = try #require(try await httpSource.diary(today))
    let cacheTodayDiary = try #require(try await adaptiveSource.diary(today))
    let httpYesterdayDiary = try #require(try await httpSource.diary(yesterday))
    let cacheYesterdayDiary = try #require(try await adaptiveSource.diary(yesterday))

    // 校验展示字段完全相等（注：projection 下推 omitted_count 而非 omitted_record_ids）。
    #expect(cacheTodayDiary.date == httpTodayDiary.date)
    #expect(cacheTodayDiary.summary == httpTodayDiary.summary)
    #expect(cacheTodayDiary.detail?.items == httpTodayDiary.detail?.items)
    #expect(cacheTodayDiary.detail?.timeline == httpTodayDiary.detail?.timeline)
    #expect(cacheTodayDiary.detail?.cutoff == httpTodayDiary.detail?.cutoff)
    #expect(cacheTodayDiary.drafts == httpTodayDiary.drafts)
    #expect(cacheTodayDiary.failed == httpTodayDiary.failed)
    // 验证纠错后的段描述在两边都生效。
    let correctedItem = try #require(cacheTodayDiary.detail?.items?.first { $0.id == "seg-t1" })
    #expect(correctedItem.description == "已纠错：完成风速计全部 12 组高风速边界测试并确认通过。")

    #expect(cacheYesterdayDiary.date == httpYesterdayDiary.date)
    #expect(cacheYesterdayDiary.summary == httpYesterdayDiary.summary)
    #expect(cacheYesterdayDiary.detail?.items == httpYesterdayDiary.detail?.items)
    #expect(cacheYesterdayDiary.detail?.timeline == httpYesterdayDiary.detail?.timeline)
    #expect(cacheYesterdayDiary.detail?.cutoff == httpYesterdayDiary.detail?.cutoff)

    // 2. 项目列表与项目页（一句话概况、正在推进的事、最近的进展）
    let httpProjects = try await httpSource.projects()
    let cacheProjects = try await adaptiveSource.projects()
    #expect(cacheProjects == httpProjects)
    #expect(cacheProjects.count == 2)

    for projID in [seeded.ids.projA, seeded.ids.projB] {
      let httpProjDetail = try await httpSource.project(projID, level: "detail")
      let cacheProjDetail = try await adaptiveSource.project(projID, level: "detail")
      #expect(cacheProjDetail == httpProjDetail)

      let httpContext = try await httpSource.projectContext(projID)
      let cacheContext = try await adaptiveSource.projectContext(projID)
      #expect(cacheContext == httpContext)
      #expect(!cacheContext.isEmpty)
      #expect(cacheContext.first?.open?.isEmpty == false)

      let httpProjTimeline = try await httpSource.timeline(projectId: projID)
      let cacheProjTimeline = try await adaptiveSource.timeline(projectId: projID)
      #expect(cacheProjTimeline == httpProjTimeline)
    }

    // 3. 事项经过（跨天事项标题、详情、经过时间线）
    let httpThreadBrief = try await httpSource.thread(seeded.ids.threadA, level: "brief")
    let cacheThreadBrief = try await adaptiveSource.thread(seeded.ids.threadA, level: "brief")
    #expect(cacheThreadBrief.id == httpThreadBrief.id)
    #expect(cacheThreadBrief.title == httpThreadBrief.title)
    #expect(cacheThreadBrief.brief == httpThreadBrief.brief)
    #expect(cacheThreadBrief.status == httpThreadBrief.status)
    #expect(cacheThreadBrief.projectId == httpThreadBrief.projectId)

    let httpThreadDetail = try await httpSource.thread(seeded.ids.threadA, level: "detail")
    let cacheThreadDetail = try await adaptiveSource.thread(seeded.ids.threadA, level: "detail")
    #expect(cacheThreadDetail == httpThreadDetail)

    let httpThreadStory = try await httpSource.timeline(threadId: seeded.ids.threadA)
    let cacheThreadStory = try await adaptiveSource.timeline(threadId: seeded.ids.threadA)
    #expect(cacheThreadStory == httpThreadStory)
    #expect(cacheThreadStory.days.count == 2)

    // 4. 此刻（now）
    let httpNow = try await httpSource.now()
    let cacheNow = try await adaptiveSource.now()
    #expect(cacheNow == httpNow)
    #expect(cacheNow?.brief != nil)

    // 5. 小组件快照（两边相等，且都不含私密内容）
    let snapshotTime = Date()
    let httpWidget = WidgetSnapshot(diary: httpTodayDiary, now: snapshotTime)
    let cacheWidget = WidgetSnapshot(diary: cacheTodayDiary, now: snapshotTime)
    #expect(cacheWidget == httpWidget)
    #expect(cacheWidget.segments.count == 2)
    #expect(!cacheWidget.segments.contains { $0.title.contains("私密") || $0.description.contains("PRIVATE_SYNTHETIC_MARKER") })
    #expect(!(cacheWidget.summary ?? "").contains("PRIVATE_SYNTHETIC_MARKER"))

    // 确认私密内容未落盘到下推缓存任何实体中。
    for kind in ProjectionEntityKind.allCases {
      for entity in try sync.cache.list(kind: kind) {
        let text = String(decoding: entity.payloadData, as: UTF8.self)
        #expect(!text.contains("PRIVATE_SYNTHETIC_MARKER_9981"))
        #expect(!text.contains("私密健康备忘"))
      }
    }

    // 6. 详细档记录与原文（两边相等，且私密记录在详细档两边都在！）
    let httpTodayRecords = try await httpSource.day(today)
    let cacheTodayRecords = try await adaptiveSource.day(today)
    #expect(cacheTodayRecords == httpTodayRecords)
    #expect(httpTodayRecords.contains { $0.id == seeded.ids.recPriv && $0.sensitivity == "private" })
    #expect(cacheTodayRecords.contains { $0.id == seeded.ids.recPriv && $0.sensitivity == "private" })

    let httpYesterdayRecords = try await httpSource.day(yesterday)
    let cacheYesterdayRecords = try await adaptiveSource.day(yesterday)
    #expect(cacheYesterdayRecords == httpYesterdayRecords)

    // 含修正的普通记录原文（records.get include_corrections: true）
    let httpCorrectedRec = try await httpSource.record(seeded.ids.recT1)
    let cacheCorrectedRec = try await adaptiveSource.record(seeded.ids.recT1)
    #expect(cacheCorrectedRec == httpCorrectedRec)
    #expect(cacheCorrectedRec.current.body == "修正后的记录正文：高风速边界 12 组用例全部通过。")

    // 私密记录原文（records.get include_private: true，仅放内存）
    let httpPrivRec = try await httpSource.record(seeded.ids.recPriv)
    let cachePrivRec = try await adaptiveSource.record(seeded.ids.recPriv)
    #expect(cachePrivRec == httpPrivRec)
    #expect(cachePrivRec.record.body == "合成私密记录正文：PRIVATE_SYNTHETIC_MARKER_9981")

    // 详细档活动段：本机 admin 经设备协议带 include_private 按需读，私密记录不丢、与 HTTP 相同。
    let httpSegments = try await httpSource.segments(today)
    let cacheSegments = try await adaptiveSource.segments(today)
    #expect(cacheSegments.segments == httpSegments.segments)
    #expect(cacheSegments.conversations == httpSegments.conversations)
    #expect(cacheSegments.segments.contains { $0.recordIds.contains(seeded.ids.recPriv) && $0.privateCount == 1 })
    // 定位私密记录同样走设备协议，与 HTTP 一致。
    #expect(try await adaptiveSource.timelineLocation(record: seeded.ids.recPriv) == (try await httpSource.timelineLocation(record: seeded.ids.recPriv)))

    // 7. 演示删除：先发布今日小组件快照，再在中枢删除 recT2（属于 seg-t2），验证缓存段消失且小组件更新。
    let publisher = await MainActor.run {
      WidgetSnapshotPublisher(
        dataSource: adaptiveSource,
        file: widgetFile,
        reloadTimelines: {},
        stopStaleExtension: false
      )
    }
    await publisher.refreshNow()
    let widgetBeforeDelete = try #require(WidgetSnapshot.readToday(from: widgetFile))
    #expect(widgetBeforeDelete.segments.contains { $0.title == "更新雾号排班界面" })

    // 在中枢删除 seg-t2 的记录（recT2、recT3），验证缓存段消失且小组件快照同步更新。
    try await api.deleteRecord(seeded.ids.recT2)
    try await api.deleteRecord(seeded.ids.recT3)
    let afterDeleteSync = try await sync.pullToLatest()
    #expect(afterDeleteSync.goneRecordIDs.contains(seeded.ids.recT2))
    #expect(afterDeleteSync.goneRecordIDs.contains(seeded.ids.recT3))

    // 缓存数据源中的今日段 seg-t2 消失（与 HTTP 一致）。
    let httpAfterDelete = try await httpSource.diary(today)
    let cacheAfterDelete = try await adaptiveSource.diary(today)
    #expect(cacheAfterDelete?.detail?.items == httpAfterDelete?.detail?.items)
    #expect((cacheAfterDelete?.detail?.items ?? []).contains { $0.id == "seg-t2" } == false)

    // 刷新小组件快照：seg-t2 从小组件快照中消失，仅剩 seg-t1。
    await publisher.refreshNow(invalidate: true)
    let widgetAfterDelete = try #require(WidgetSnapshot.readToday(from: widgetFile))
    #expect(widgetAfterDelete.segments.count == 1)
    #expect(widgetAfterDelete.segments.first?.title == "风速计边界测试")
    #expect(!widgetAfterDelete.segments.contains { $0.title == "更新雾号排班界面" })

    print("""
    [EQUIVALENCE OK] device=\(link.device_id) origin=\(origin.absoluteString)
    - days: yesterday=\(seeded.yesterdayDate) (items=\(cacheYesterdayDiary.detail?.items?.count ?? 0)), today=\(seeded.todayDate) (items=\(cacheTodayDiary.detail?.items?.count ?? 0), corrected seg-t1 matched)
    - projects=\(cacheProjects.count), threadA_story_days=\(cacheThreadStory.days.count), now_brief=\(cacheNow?.brief ?? "nil")
    - detailed today records=\(cacheTodayRecords.count) (private record present in both HTTP & cache; absent from widget & viewer-cache.db)
    - after deleting \(seeded.ids.recT2) & \(seeded.ids.recT3): gone=\(afterDeleteSync.goneRecordIDs), today_items_after=\(cacheAfterDelete?.detail?.items?.count ?? 0), widget_segments_before=\(widgetBeforeDelete.segments.count) -> after=\(widgetAfterDelete.segments.count)
    """)
  }
}
