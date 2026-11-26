import AppKit
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
      case "/v1/audio/settings":
        #expect(request.httpMethod == "PUT")
        return (200, Data(#"{"retention_days":9}"#.utf8))
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

    #expect(await adaptive.activateIfLinked() == false)
    #expect(adaptive.isUsingCache == false)

    let projects = try await adaptive.projects()
    let now = try await adaptive.now()
    let actions = HubAPI(base: { origin }, token: { "test-token" }, configuration: sessionConfig,
                         deviceAction: adaptive.sendAction)
    try await actions.setRetentionDays(9)

    #expect(projects.map(\.name) == ["风帆日志"])
    #expect(now?.brief == "正在整理航线脚本")
    #expect(paths.snapshot == ["/v1/projects", "/v1/now", "/v1/audio/settings"])
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("viewer-cache.db").path))
  }

  // MARK: 2. 401 时调 wipe 并退回 HTTP

  @Test(arguments: [false, true]) func unauthorized401WipesCacheAndFallsBackToHTTP(usingAction: Bool) async throws {
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
    let sampleBytes = WorkerLogic.wav(Array(repeating: 0.2, count: 1_600))

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
        case "audio.sample.get":
          #expect(req.body == ["id": .string("sample-fixture")])
          let body = #"{"mime":"audio/wav","data_base64":"\#(sampleBytes.base64EncodedString())"}"#
          return (200, try sealReply(bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        case "settings.general.get":
          return (200, try sealReply(status: 403, bodyJSON: #"{"error":"当前设备权限不足"}"#,
                                     nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        case "segment.delete":
          let body = #"{"error":"这段记录已更新，请刷新后再确认删除"}"#
          return (200, try sealReply(status: 409, bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        case "delete":
          let body = #"{"error":"删除已达限额，请稍后重试"}"#
          return (200, try sealReply(status: 429, bodyJSON: body, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        default:
          return (200, try sealReply(status: 400, bodyJSON: #"{"error":"unexpected"}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        }
      case "/v1/records/01JAA000000000000000000099":
        let body = """
          {"id":"01JAA000000000000000000099","device":"mac","source":"manual.note","kind":"event",
           "t_start":"2026-11-23T09:15:00+09:00","title":"HTTP回退记录","body":"通过HTTP读取成功","corrections":[]}
          """
        return (200, Data(body.utf8))
      case "/v1/audio/settings":
        #expect(request.httpMethod == "PUT")
        return (200, Data(#"{"retention_days":9}"#.utf8))
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

    #expect(await adaptive.activateIfLinked() == true)
    #expect(adaptive.isUsingCache == true)

    // 先从缓存读一次，确认 viewer-cache.db 与小组件快照均存在。
    let cachedProjects = try await adaptive.projects()
    #expect(cachedProjects.map(\.name) == ["缓存项目"])
    let dbPath = dir.appendingPathComponent(ProjectionCache.databaseFileName).path
    #expect(FileManager.default.fileExists(atPath: dbPath))
    #expect(FileManager.default.fileExists(atPath: widgetFile.path))

    if usingAction {
      let actions = HubAPI(base: { origin }, token: { "test-token" }, configuration: sessionConfig,
                           busyRetryDelays: [], deviceAction: adaptive.sendAction)
      let day = try #require(TimelineDay.date("2026-11-23"))
      for (status, message) in [
        (403, "当前设备权限不足"), (409, "这段记录已更新，请刷新后再确认删除"), (429, "删除已达限额，请稍后重试"),
      ] {
        do {
          switch status {
          case 403: _ = try await actions.generalSettings()
          case 409: try await actions.deleteSegment(day: day, id: "segment-fixture", recordIds: ["record-fixture"])
          default: try await actions.deleteRecord("01JAA000000000000000000099")
          }
          Issue.record("应返回 \(status)")
        } catch let error as HubError {
          #expect(error.status == status)
          #expect(error.localizedDescription == message)
        }
      }
      let contents = try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
      let bytes = try await actions.sample("sample-fixture")
      #expect(bytes == sampleBytes)
      let playable = await MainActor.run { NSSound(data: bytes) != nil }
      #expect(playable)
      #expect(try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted() == contents)
      #expect(!paths.snapshot.contains { $0 != "/v1/device" })

      removedFlag.set(true)
      try await actions.setRetentionDays(9)
      #expect(paths.snapshot.last == "/v1/audio/settings")
    } else {
      removedFlag.set(true)
      let fallbackRecord = try await adaptive.record("01JAA000000000000000000099")
      #expect(fallbackRecord.record.title == "HTTP回退记录")
      #expect(fallbackRecord.record.body == "通过HTTP读取成功")
    }

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

    #expect(await adaptive.activateIfLinked() == true)
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
      func activeDays(inMonth month: String) async throws -> ActiveDaysResult {
        ActiveDaysResult(dates: Set(diaries.keys.filter { $0.hasPrefix("\(month)-") }), authoritative: true)
      }
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

    // Switching the host language republishes the same diary and refreshes the widget.
    let reloadsBeforeLanguageChange = reloadCount.get()
    publisher.languageChanged(to: .zh)
    await publisher.refreshNow()
    #expect(WidgetSnapshot.readLanguage(for: widgetFile) == .zh)
    #expect(WidgetSnapshot.readToday(from: widgetFile, now: day1, calendar: calendar)?.language == .zh)
    publisher.languageChanged(to: .en)
    await publisher.refreshNow()
    let english = try #require(WidgetSnapshot.readToday(from: widgetFile, now: day1, calendar: calendar))
    #expect(english.language == .en)
    #expect(english.summary == snapDay1.summary)
    #expect(english.segments == snapDay1.segments)
    #expect(reloadCount.get() > reloadsBeforeLanguageChange)

    // 跨到 Day 2（尚无 Day 2 数据）：旧快照必须被立即删除。
    let reloadsBefore = reloadCount.get()
    nowBox.set(day2)
    await publisher.refreshNow()
    #expect(!FileManager.default.fileExists(atPath: widgetFile.path))
    #expect(WidgetSnapshot.readLanguage(for: widgetFile) == .en)
    #expect(reloadCount.get() > reloadsBefore)
  }

  // MARK: 5. 真实中枢等价性与删除联动测试（sealed-file + local-bootstrap + 合成数据）

  @Test(ChineseUITrait()) func liveHubEquivalenceAndDeletion() async throws {
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
      import { writeHubPort } from "\(repoRoot.path)/hub/src/hub-json.ts";
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
        pendingA: "01JAE000000000000000000401",
        pendingB: "01JAE000000000000000000402",
        sample: "01JAE000000000000000000501",
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

      // 两份相同的段，记录来自旧版 Mac 身份，和当前登记的本机设备不同。
      const actionsDates = ["http", "device"].map((channel, channelIndex) => {
        const date = localDateString(now - (3 + channelIndex) * 24 * 3600_000);
        const actionStart = startOf(date, 10, 0);
        const records = Array.from({ length: 201 }, (_, i) => ({
          id: "01JAE" + String(10000 + channelIndex * 1000 + i).padStart(21, "0"),
          schema: 1, device: "mac", source: "manual.note", kind: "event",
          t_start: toLocalIso(actionStart + i * 1000), title: "合成潮汐观测", body: "记录合成潮位。",
          capture: { method: "manual" }, sensitivity: "normal",
        }));
        const result = db.ingest(records);
        if (result.accepted !== 201) throw new Error("action fixture ingestion failed: " + JSON.stringify(result.rejected[0] ?? result));
        const item = {
          id: "seg:" + channel, title: "合成潮汐观测", description: "整理合成潮位数据。",
          t_start: toLocalIso(actionStart), t_end: toLocalIso(actionStart + 201_000), active_seconds: 201,
          sources: ["manual.note"], apps: [], evidence: [], record_ids: records.map(record => record.id),
        };
        store.upsertDay({ date, detail: { items: [item] } });
        return date;
      });
      for (const [pending, project] of [[ids.pendingA, ids.projA], [ids.pendingB, ids.projB]]) {
        store.createPending({ id: pending, kind: "project", payload: { project_id: project }, created_at: updatedAt });
      }
      db.db.prepare("INSERT INTO voice_samples VALUES (?,?,?,?,?,?)")
        .run(ids.sample, ids.recT1, ids.factADecision, "audio/wav", Buffer.from("synthetic-wave-bytes"), updatedAt);

      const listener = (port: number) => Bun.listen({ hostname: "127.0.0.1", port, socket: { data() {} } });
      const firstPort = listener(Number(process.env.TACIT_SWIFT_TEST_HUB_PORT ?? "0"));
      const secondPort = listener(Number(process.env.TACIT_SWIFT_TEST_HUB_RESTART_PORT ?? "0"));
      const restartPort = secondPort.port;
      writeHubPort(config.dataDir, firstPort.port);
      firstPort.stop();
      secondPort.stop();
      console.log(JSON.stringify({ todayDate, yesterdayDate, actionsDates, ids, token: config.token, restartPort }));
      db.close();
      """
    try Data(seedSource.utf8).write(to: seedScript)

    var env = ProcessInfo.processInfo.environment
    env["RA_DATA_DIR"] = dataDir.path
    env["RA_SECRET_BACKEND"] = "sealed-file"
    env["RA_MASTER_KEY_FILE"] = masterKeyFile.path
    env.removeValue(forKey: "RA_PORT")
    env["RA_HUB_MODE"] = "mac"
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
        let factAOpen: String
        let pendingA: String
        let pendingB: String
        let sample: String
      }
      let todayDate: String
      let yesterdayDate: String
      let actionsDates: [String]
      let ids: IDs
      let token: String
      let restartPort: Int
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
    let config = Config(dataDir: dataDir, bun: bunPath)
    let api = HubAPI(base: { config.hubURL }, token: { seeded.token }, busyRetryDelays: [0.2, 0.5])
    let httpSource = HTTPViewerDataSource(api: api)
    let widgetFile = dataDir.appendingPathComponent("widget/today.json")
    let adaptiveSource = AdaptiveViewerDataSource(
      http: httpSource,
      dataDir: dataDir,
      originProvider: { config.hubURL },
      widgetSnapshotURL: widgetFile,
      files: files,
      keys: tempKeys,
      cacheKeyProvider: InMemoryProjectionCacheKeyProvider()
    )
    defer { adaptiveSource.stop() }

    #expect(await adaptiveSource.activateIfLinked() == true)
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

    // 本机管理设备单独调用，故意不给 HTTP token，设备操作误走 HTTP 时测试会失败。
    let actions = HubAPI(base: { config.hubURL }, token: { nil }, deviceAction: adaptiveSource.sendAction)
    let ids = seeded.ids
    let expectedSample = Data("synthetic-wave-bytes".utf8)
    #expect(try await api.sample(ids.sample) == expectedSample)
    #expect(try await actions.sample(ids.sample) == expectedSample)
    #expect(try await actions.pending() == (try await api.pending()))
    try await api.resolve(ids.pendingA, action: "rename", name: "合成港口")
    try await actions.resolve(ids.pendingB, action: "rename", name: "合成港口")
    let pendingAfter = try await actions.pending()
    #expect(!pendingAfter.contains { $0.id == ids.pendingA || $0.id == ids.pendingB })
    #expect(try await api.project(ids.projA, level: "brief").name == "合成港口")
    #expect(try await api.project(ids.projB, level: "brief").name == "合成港口")

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

    let httpDay = try #require(TimelineDay.date(seeded.actionsDates[0]))
    let deviceDay = try #require(TimelineDay.date(seeded.actionsDates[1]))
    let httpSegment = try #require(try await api.diary(httpDay)?.detail?.items?.first)
    let deviceSegment = try #require(try await api.diary(deviceDay)?.detail?.items?.first)
    let httpRecordIDs = try #require(httpSegment.recordIds)
    let deviceRecordIDs = try #require(deviceSegment.recordIds)
    #expect(httpRecordIDs.count == 201)
    #expect(deviceRecordIDs.count == 201)
    let description = "复核 201 条合成潮位记录。"
    try await api.correctSegment(day: httpDay, id: httpSegment.id, description: description)
    try await actions.correctSegment(day: deviceDay, id: deviceSegment.id, description: description)
    #expect(try await api.diary(httpDay)?.detail?.items?.first?.description == description)
    #expect(try await api.diary(deviceDay)?.detail?.items?.first?.description == description)

    let factA = try #require(try await api.thread(ids.threadA, level: "detail").facts?.first { $0.id == ids.factAOpen })
    // 删掉 seg-t2 的记录会清理旧事实，另用仍然存在的证据建立一份等价事实。
    let factB = try await api.call(Fact.self, "POST", "/v1/facts", [
      "kind": factA.kind, "text": factA.text, "evidence": [ids.recY2], "thread_id": ids.threadB, "project_id": ids.projB,
    ])
    let factText = "确认改用每秒一次采样。"
    try await api.correct(factA, text: factText)
    try await actions.correct(factB, text: factText)
    for fact in [factA, factB] {
      let threadID = try #require(fact.threadId)
      let facts = try #require(try await api.thread(threadID, level: "detail").facts)
      #expect(!facts.contains { $0.id == fact.id })
      let replacement = try #require(facts.first { $0.text == factText })
      #expect(replacement.origin == "user")
      #expect(replacement.kind == fact.kind && replacement.evidence == fact.evidence && replacement.projectId == fact.projectId)
    }

    // 原文修正的写入、删除与未找到，都通过 UI 使用的 API 比较。
    func correction(for recordID: String, id: String) -> [String: Any] {
      [
        "id": id, "schema": 1, "device": "mac", "source": "manual.correction", "kind": "event",
        "t_start": "2026-11-01T09:00:00Z", "title": "合成潮位", "body": "确认潮位 15 厘米。",
        "corrects": recordID, "capture": ["method": "manual"], "sensitivity": "normal",
      ]
    }
    let httpCorrectionID = ULID.make(), deviceCorrectionID = ULID.make()
    var malformed = correction(for: ids.recY2, id: ULID.make())
    malformed["body"] = 42
    let rejected = try await api.call([String: DeviceJSON].self, "POST", "/v1/records", malformed)
    #expect(rejected["accepted"] == .int(0) && rejected["rejected"]?.arrayValue?.count == 1)
    // 两条通道都由中枢 ingest 校验，报出同样的逐字段原因（不再是设备协议独有的一句 400）。
    func saveError(_ client: HubAPI) async -> HubError? {
      do { try await client.saveManual(malformed); return nil } catch let error as HubError { return error } catch { return nil }
    }
    let httpError = await saveError(api), deviceError = await saveError(actions)
    #expect(httpError != nil && httpError?.localizedDescription == deviceError?.localizedDescription && deviceError?.status == httpError?.status)
    try await api.saveManual(correction(for: ids.recY1, id: httpCorrectionID))
    try await actions.saveManual(correction(for: ids.recY2, id: deviceCorrectionID))
    #expect(try await api.record(ids.recY1).current.body == "确认潮位 15 厘米。")
    #expect(try await api.record(ids.recY2).current.body == "确认潮位 15 厘米。")
    try await api.deleteRecord(httpCorrectionID)
    try await actions.deleteRecord(deviceCorrectionID)
    for (client, deletedID) in [(api, httpCorrectionID), (actions, deviceCorrectionID)] {
      do {
        try await client.deleteRecord(deletedID)
        Issue.record("重复删除应返回 404")
      } catch let error as HubError {
        #expect(error.status == 404 && error.localizedDescription == "记录不存在")
      }
    }

    try await api.deleteSegment(day: httpDay, id: httpSegment.id, recordIds: httpRecordIDs)
    try await actions.deleteSegment(day: deviceDay, id: deviceSegment.id, recordIds: deviceRecordIDs)
    for day in [httpDay, deviceDay] {
      #expect(try await api.day(day).isEmpty)
      #expect((try await api.diary(day)?.detail?.items ?? []).isEmpty)
    }
    try await api.removeProject(ids.projA)
    try await actions.removeProject(ids.projB)
    #expect(try await api.projects().isEmpty)
    #expect(try await api.thread(ids.threadA, level: "brief").projectId == nil)
    #expect(try await api.thread(ids.threadB, level: "brief").projectId == nil)

    let httpSettings = try await api.modelSettings()
    let model = ModelTierConfig(provider: "openai-compatible", model: "synthetic-tide-model", reasoningEffort: "low")
    let tiers = httpSettings.tiers.mapValues { _ in model }
    let savedHTTP = try await api.saveModels(tiers)
    #expect(savedHTTP.tiers == tiers)
    #expect(try await actions.modelSettings().tiers == savedHTTP.tiers)
    _ = try await api.saveModels(httpSettings.tiers)
    let savedDevice = try await actions.saveModels(tiers)
    #expect(savedDevice.tiers == savedHTTP.tiers && savedDevice.keys == savedHTTP.keys)
    #expect(try await api.modelSettings().tiers == savedDevice.tiers)
    #expect(try await actions.generalSettings() == (try await api.generalSettings()))
    let originalGeneral = try await api.generalSettings()
    let savedGeneral = try await api.saveGeneral(["archive_days": 15])
    _ = try await api.saveGeneral(["archive_days": originalGeneral.archiveDays])
    #expect(try await actions.saveGeneral(["archive_days": 15]) == savedGeneral)
    #expect(try await api.generalSettings().archiveDays == 15)
    struct HubLanguage: Decodable { let language: AppLanguage }
    _ = try await actions.saveGeneral(["language": "en"])
    #expect(try await api.call(HubLanguage.self, "GET", "/v1/settings/general", nil).language == .en)
    _ = try await api.saveGeneral(["language": "zh"])
    #expect(try await api.call(HubLanguage.self, "GET", "/v1/settings/general", nil).language == .zh)
    #expect(try await api.generalSettings().archiveDays == 15)

    let provider = "openai-compatible"
    for client in [api, actions] {
      try await client.setKey(provider: provider, key: "synthetic-model-key-0123456789")
      #expect(try await api.modelSettings().keys[provider] == .some(true))
      try await client.deleteKey(provider: provider)
      #expect(try await api.modelSettings().keys[provider] == .some(false))
    }
    let originalRetention = try await api.retentionDays()
    try await api.setRetentionDays(12)
    #expect(try await actions.retentionDays() == 12)
    try await api.setRetentionDays(originalRetention)
    try await actions.setRetentionDays(12)
    #expect(try await api.retentionDays() == 12)
    var previousPurge: Date?
    for client in [api, actions] {
      try await client.purgeAudio()
      struct AudioSync: Decodable { let purgeBefore: String }
      let audioSync = try await api.get(AudioSync.self, "/v1/audio/sync", ["device": "mac"])
      let purgeDate = try #require(ViewerTime.parse(audioSync.purgeBefore))
      if let previousPurge { #expect(purgeDate >= previousPurge) }
      previousPurge = purgeDate
    }

    #expect(try await api.disableRelay().mode == .off)
    #expect(try await actions.disableRelay().mode == .off)
    #expect(try await actions.relaySettings().mode == (try await api.relaySettings().mode))
    #expect(try await actions.hubSettings() == (try await api.hubSettings()))
    let httpDevices = try #require(try await api.deviceSettings())
    let deviceDevices = try #require(try await actions.deviceSettings())
    #expect(httpDevices.hubId == deviceDevices.hubId && deviceDevices.hubId == link.hub_id)
    #expect(httpDevices.devices.map(\.id).sorted() == deviceDevices.devices.map(\.id).sorted())
    #expect(deviceDevices.devices.contains { $0.id == link.device_id })
    #expect(httpDevices.lan.addrs == deviceDevices.lan.addrs && httpDevices.lan.port == deviceDevices.lan.port)
    for client in [api, actions] {
      let invitation = try await client.createDeviceInvitation(role: "view")
      let parsed = try DevicePairingInvitation.parse(invitation.uri)
      #expect(parsed.hubID == link.hub_id && parsed.role == "view")
      #expect(try await api.deviceSettings()?.pairing?.expiresAt == invitation.expiresAt)
      try await client.cancelDeviceInvitation()
      #expect(try await api.deviceSettings()?.pairing == nil)

      let nextInvitation = try await client.createDeviceInvitation(role: "view")
      let pair = try DevicePairingInvitation.parse(nextInvitation.uri)
      let peer = try DeviceClient(hubPublicKeyBase64URL: link.hub_pk, keyStore: InMemoryDeviceKeyStore(),
                                  transport: DirectDeviceTransport(origin: origin))
      let device = try await peer.pair(invitation: pair, deviceName: "合成查看端")
      try await client.updateDeviceRole(device.deviceID, role: "collect")
      let status = try await api.get([String: DeviceJSON].self, "/v1/settings/devices")
      let row = try #require(status["devices"]?.arrayValue?.first { $0.objectValue?["id"] == .string(device.deviceID) })
      #expect(row.objectValue?["role"] == .string("collect"))
      try await client.removeDevice(device.deviceID)
      #expect(try await api.deviceSettings()?.devices.contains { $0.id == device.deviceID } == false)
    }
    let created = try await actions.requestDistill(kind: "round")  // 设备回复 202
    #expect(try await api.requestDistill(kind: "round") == created)  // 重复请求返回 200
    #expect(try await actions.distillRequests().contains(created))

    print("""
    [ACTIONS EQUIVALENCE OK]
    - segment correction: 2 descriptions matched; deletion: HTTP=201, device=201, remaining=0
    - record correction and deletion: both channels stored the correction, then returned the same 404 on repeated deletion
    - pending: 2 renamed projects; fact correction: 2 replacements retained their original evidence; project removal: 2 detached threads
    - model and general settings, keys, audio retention and purge, hub settings, relay off: matched
    - device list, invitation create and cancel, role update and device removal: matched
    - audio sample: \(expectedSample.count) bytes matched; distill request: new 202, duplicate 200 matched
    - malformed manual record: HTTP returned rejected entries; device returned 400 without field details
    """)

    let portAPI = HubAPI(base: { config.hubURL }, token: { seeded.token }, deviceAction: adaptiveSource.sendAction)
    #expect(try await portAPI.setHubPort(seeded.restartPort))
    for _ in 0..<50 {
      if !hubProc.isRunning { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try #require(!hubProc.isRunning, "端口修改后中枢未退出")
    #expect(hubProc.terminationStatus == 0)

    // 用相同参数手动拉起子进程，等同于 launchd 使用新 hub.json 重启。
    let restarted = Process()
    restarted.executableURL = hubProc.executableURL
    restarted.arguments = hubProc.arguments
    restarted.environment = env
    restarted.standardOutput = FileHandle.nullDevice
    restarted.standardError = FileHandle.nullDevice
    try restarted.run()
    defer {
      if restarted.isRunning {
        restarted.terminate()
        restarted.waitUntilExit()
      }
    }
    var ready = false
    for _ in 0..<50 {
      if await api.isReachable() { ready = true; break }
      if !restarted.isRunning { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try #require(ready, "中枢未在新端口启动")
    #expect(try await actions.hubSettings().port == seeded.restartPort)
    #expect(try files.collector()?.addrs == [origin.absoluteString])
    #expect(config.hubURL != origin)
    print("[PORT RESTART OK] device requests followed hub.json; collector-link.json addrs stayed at the original port")
  }

  @Test func activeDaysUsesProjectionCacheAndFallsBackWhenOffline() async throws {
    let dir = try makeTempDir("tacit-active-days-")
    defer { try? FileManager.default.removeItem(at: dir) }

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15))!

    let origin = URL(string: "http://127.0.0.1:47909")!
    let hubKey = Curve25519.KeyAgreement.PrivateKey()
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let deviceID = "mac-abcd2345"

    let offline = LockedValue(false)
    let seenOps = LockedList<String>()

    StubURLProtocol.handler = { request in
      let body = try readBody(request)
      let envelope = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: body)
      let opened = try DeviceEnvelope.openRequestEnvelope(envelope, recipientPrivateKey: hubKey, senderPublicKey: macKey.publicKey)
      let req = try JSONDecoder().decode(DecodedDeviceRequest.self, from: opened)
      seenOps.append(req.op)

      switch req.op {
      case "projection.pull":
        let dayWithItem = #"{"date":"2026-11-10","detail":{"summary":"整理了航标清单","items":[{"id":"s1","title":"核对航标","description":"完成核对","t_start":"2026-11-10T10:00:00+08:00","t_end":"2026-11-10T10:30:00+08:00","active_seconds":1800,"sources":["manual.note"],"evidence":[],"record_ids":["01JAA000000000000000000010"]}]}}"#
        let emptyDay = #"{"date":"2026-11-11","detail":{"summary":null,"items":[]}}"#
        let todayDraft = #"{"date":"2026-11-26","detail":null,"drafts":[{"id":"d1","title":"一场对话","excerpt":"刚记下一条","t_start":"2026-11-26T14:00:00+08:00","t_end":"2026-11-26T14:05:00+08:00","active_seconds":300,"sources":["mac.audio"],"apps":[],"record_ids":["01JAA000000000000000000026"]}]}"#
        let reply = """
          {"epoch":1,"reset":false,"cursor":3,"more":false,"server_time":"2026-11-26T07:00:00Z","changes":[
            {"seq":1,"rev":1,"op":"upsert","kind":"day","id":"2026-11-10","data":\(dayWithItem)},
            {"seq":2,"rev":1,"op":"upsert","kind":"day","id":"2026-11-11","data":\(emptyDay)},
            {"seq":3,"rev":1,"op":"upsert","kind":"day","id":"2026-11-26","data":\(todayDraft)}
          ]}
          """
        return (200, try sealReply(bodyJSON: reply, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      case "projection.ack":
        return (200, try sealReply(bodyJSON: #"{"ok":true}"#, nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      case "days.active":
        if offline.get() { throw URLError(.cannotConnectToHost) }
        let month = req.body["month"]?.stringValue ?? ""
        #expect(req.body["include_private"]?.boolValue == true)
        if month == "2026-11" {
          return (200, try sealReply(bodyJSON: #"{"month":"2026-11","dates":["2026-11-02","2026-11-10","2026-11-26"]}"#,
                                     nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
        }
        return (200, try sealReply(bodyJSON: #"{"month":"\#(month)","dates":["2025-09-15"]}"#,
                                   nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      default:
        return (400, try sealReply(status: 400, bodyJSON: #"{"error":"unexpected op"}"#,
                                   nonce: req.nonce, hubKey: hubKey, devicePublicKey: macKey.publicKey))
      }
    }
    defer { StubURLProtocol.handler = nil }

    let cache = try ProjectionCache(
      dataDirectory: dir,
      keyProvider: InMemoryProjectionCacheKeyProvider(),
      clock: { now },
      calendar: cal
    )
    let client = try DeviceClient(
      hubPublicKeyBase64URL: DeviceEnvelope.publicKeyBase64URL(hubKey.publicKey),
      deviceID: deviceID,
      keyStore: InMemoryDeviceKeyStore(rawRepresentation: macKey.rawRepresentation),
      transport: DirectDeviceTransport(origin: origin, session: makeStubSession()),
      clock: { now }
    )
    let sync = ProjectionSync(client: client, cache: cache, eventStream: nil, clock: { now })
    let source = CachedViewerDataSource(sync: sync, includePrivate: true, calendar: cal, clock: { now })

    // 拉取 90 天投影后，cachedActiveDays 同步即刻返回有内容或今日草稿的日期，排除空日。
    _ = try await sync.pullToLatest()
    #expect(source.cachedActiveDays(inMonth: "2026-11") == ["2026-11-10", "2026-11-26"])

    // 在线调用补齐仅有原始记录的 2026-11-02 与 90 天之外的历史月份，且标为 authoritative。
    #expect(try await source.activeDays(inMonth: "2026-11") == ActiveDaysResult(dates: ["2026-11-02", "2026-11-10", "2026-11-26"], authoritative: true))
    #expect(try await source.activeDays(inMonth: "2025-09") == ActiveDaysResult(dates: ["2025-09-15"], authoritative: true))

    // 离线时当月跳过内存 LRU，回退到已缓存的 .day 集合并标为非 authoritative，方便恢复连接后重拉。
    offline.set(true)
    #expect(try await source.activeDays(inMonth: "2026-11") == ActiveDaysResult(dates: ["2026-11-10", "2026-11-26"], authoritative: false))
    // 历史月份命中内存 LRU 时仍可读到先前接口结果；未命中内存 LRU 的历史月回退为空且标为非 authoritative。
    #expect(try await source.activeDays(inMonth: "2025-09") == ActiveDaysResult(dates: ["2025-09-15"], authoritative: true))
    #expect(try await source.activeDays(inMonth: "2025-08") == ActiveDaysResult(dates: [], authoritative: false))
    #expect(seenOps.snapshot.contains("days.active"))
  }

  @Test @MainActor func activeDaysCacheDistinguishesFallbackExpiresTTLAndBoundsSize() {
    let base = Date(timeIntervalSince1970: 1_764_000_000)
    let cache = ActiveDaysCache(maxEntries: 2, pastMonthTTL: 300)
    #expect(cache.dates(for: "2026-11", fallback: ["2026-11-10"]) == ["2026-11-10"])
    cache.seedIfEmpty(month: "2026-11", dates: ["2026-11-10"], now: base)
    #expect(cache.needsLoad(month: "2026-11", revision: 1, isCurrentMonth: false, now: base) == true)

    // 离线回退结果不视为权威结果，重新打开时仍需重新读取。
    cache.store(month: "2026-09", dates: [], revision: 1, authoritative: false, now: base)
    #expect(cache.needsLoad(month: "2026-09", revision: 1, isCurrentMonth: false, now: base) == true)

    // 在线权威结果在 TTL 内复用，revision 变化或超时后刷新；离线回退不能覆盖已有的在线结果。
    cache.store(month: "2026-10", dates: ["2026-10-03", "2026-10-18"], revision: 1, authoritative: true, now: base)
    #expect(cache.dates(for: "2026-10", fallback: []) == ["2026-10-03", "2026-10-18"])
    #expect(cache.needsLoad(month: "2026-10", revision: 1, isCurrentMonth: false, now: base.addingTimeInterval(60)) == false)
    #expect(cache.needsLoad(month: "2026-10", revision: 1, isCurrentMonth: false, now: base.addingTimeInterval(300)) == true)
    #expect(cache.needsLoad(month: "2026-10", revision: 2, isCurrentMonth: false, now: base) == true)
    cache.store(month: "2026-10", dates: [], revision: 1, authoritative: false, now: base.addingTimeInterval(10))
    #expect(cache.dates(for: "2026-10", fallback: []) == ["2026-10-03", "2026-10-18"])

    // 容量上限淘汰最久未访问月份。
    cache.store(month: "2026-11", dates: ["2026-11-01", "2026-11-10"], revision: 1, authoritative: true, now: base.addingTimeInterval(20))
    #expect(cache.count == 2)
    #expect(cache.needsLoad(month: "2026-11", revision: 1, isCurrentMonth: true, now: base.addingTimeInterval(20)) == true)

    cache.clear()
    #expect(cache.count == 0)
    #expect(cache.dates(for: "2026-10", fallback: []) == [])
    #expect(cache.needsLoad(month: "2026-10", revision: 1, isCurrentMonth: false, now: base) == true)
  }
}
