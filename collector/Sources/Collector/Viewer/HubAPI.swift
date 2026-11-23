import Foundation
import CollectorCore

struct HubError: LocalizedError {
  let message: String
  let status: Int
  var errorDescription: String? { message }
  var actionMessage: String? { [403, 409, 429].contains(status) ? message : nil }
}

final class HubAPI: @unchecked Sendable {
  typealias DeviceAction = (String, [String: DeviceJSON], TimeInterval?) async throws -> DeviceResponsePayload?

  struct DeviceOperation {
    let name: String
    let parameters: [String: DeviceJSON]
    let responseData: (DeviceResponsePayload) throws -> Data

    init(_ name: String, _ parameters: [String: DeviceJSON] = [:],
         responseData: @escaping (DeviceResponsePayload) throws -> Data = { $0.bodyData }) {
      self.name = name
      self.parameters = parameters
      self.responseData = responseData
    }
  }

  private let baseURL: () -> URL
  var base: URL { baseURL() }
  private let tokenProvider: () -> String?
  private let session: URLSession
  private let busyRetryDelays: [TimeInterval]
  private let deviceAction: DeviceAction?

  init(base: @escaping () -> URL, token: @escaping () -> String?, configuration: URLSessionConfiguration = .ephemeral,
       busyRetryDelays: [TimeInterval] = [1, 2], deviceAction: DeviceAction? = nil) {
    self.baseURL = base
    self.tokenProvider = token
    self.busyRetryDelays = busyRetryDelays
    self.deviceAction = deviceAction
    configuration.timeoutIntervalForRequest = 20
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: configuration)
  }

  private func request(
    _ path: String, query: [String: String?] = [:], method: String = "GET", body: Data? = nil,
    timeout: TimeInterval? = nil, authenticated: Bool = true, device: DeviceOperation? = nil
  ) async throws -> Data {
    if let device, let deviceAction {
      let fields = try body.map { try JSONDecoder().decode([String: DeviceJSON].self, from: $0) } ?? [:]
      let parameters = fields.merging(device.parameters) { _, parameter in parameter }
      for wait in busyRetryDelays.map(Optional.some) + [nil] {
        do {
          if let reply = try await deviceAction(device.name, parameters, timeout) {
            return try device.responseData(reply)
          }
          break
        } catch let error as HubError where error.status == 503 {
          guard let wait else { throw error }
          try await Task.sleep(for: .seconds(wait))
        }
      }
    }
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.path = path
    let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
    if !items.isEmpty {
      c.queryItems = items.sorted { $0.name < $1.name }
      // URLComponents 不转义 "+"，hub 会把它当空格；时间里的时区偏移必须转义。
      c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    var r = URLRequest(url: c.url!)
    r.httpMethod = method
    if let timeout { r.timeoutInterval = timeout }
    if authenticated {
      guard let token = tokenProvider() else { throw HubError(message: "找不到后台服务的访问令牌，后台服务可能还没启动过", status: 0) }
      r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    var data = Data(), status = 0
    // 503 表示撞上整理进程的写锁、整笔已回滚，重试不会重复写入；稍等再试，不让删除这类操作直接失败。
    for wait in busyRetryDelays.map(Optional.some) + [nil] {
      let response: URLResponse
      do { (data, response) = try await session.data(for: r) }
      catch let e as URLError where e.code == .cancelled { throw CancellationError() }
      catch { throw HubError(message: "连不上后台服务：\(error.localizedDescription)", status: 0) }
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 503, let wait else { break }
      try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }
    guard (200..<300).contains(status) else {
      let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw HubError(message: msg ?? "请求失败（\(status)）", status: status)
    }
    return data
  }

  func isReachable() async -> Bool {
    struct Health: Decodable { let ok: Bool }
    guard let data = try? await request("/v1/health", timeout: 3, authenticated: false),
          let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
    return health.ok
  }

  func diagnosticStatus() async -> (reachable: Bool, status: Data?) {
    guard await isReachable(), !Task.isCancelled else { return (false, nil) }
    return (true, try? await request("/v1/status", timeout: 3, device: .init("status.get")))
  }

  /// 中枢网页的状态页地址，和 `bun hub/src/cli.ts open` 一样把 token 放在 hash 里（不会发给服务器）。
  func statusPageURL() -> URL? {
    guard let token = tokenProvider(), !token.isEmpty,
          let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return URL(string: "\(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/#token=\(encoded)&status")
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try HubJSON.decoder().decode(T.self, from: data) }
    catch { throw HubError(message: "后台服务返回的数据读不出来：\(error)", status: 0) }
  }

  func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:], device: DeviceOperation? = nil) async throws -> T {
    try decode(type, from: await request(path, query: query, device: device))
  }

  private func send(_ method: String, _ path: String, _ json: Any? = nil, device: DeviceOperation? = nil) async throws {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    _ = try await request(path, method: method, body: body, device: device)
  }

  // MARK: History

  struct RecordQuery: Sendable {
    var q: String?
    var source: String?
    var device: String?
    var from: String?
    var to: String?
    var limit = 200
    /// 带上正文（搜索结果要显示命中片段）。
    var body = false
  }

  func records(_ query: RecordQuery, cursor: String?) async throws -> RecordPage {
    try await get(RecordPage.self, "/v1/records", [
      "limit": String(query.limit), "q": query.q, "source": query.source, "device": query.device,
      "from": query.from, "to": query.to, "cursor": cursor, "body": query.body ? "1" : nil,
    ])
  }

  /// 读完一整天（一天几百条，分页拉全）。
  func day(_ day: Date) async throws -> [HistoryRecord] {
    let bounds = ViewerTime.dayQuery(day)
    var query = RecordQuery(); query.from = bounds.from; query.to = bounds.to; query.limit = 500
    var all: [HistoryRecord] = [], cursor: String? = nil, pages = 0
    repeat {
      let page = try await records(query, cursor: cursor)
      all += page.records
      cursor = page.nextCursor
      pages += 1
    } while cursor != nil && pages < 20
    return all
  }

  func record(_ id: String) async throws -> RecordDetail { try await get(RecordDetail.self, "/v1/records/\(id)") }

  /// 列表按开始日期读取；结束于次日的成员需要按编号补齐。
  func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord] {
    let needed = Set(ids).subtracting(available.map(\.id))
    var missing: [HistoryRecord] = []
    for id in needed {
      do { missing.append(try await record(id).record) }
      catch let error as HubError where error.status == 404 { continue }
    }
    return missing
  }

  /// 一天的活动段（hub 按线程或应用聚合，不调用模型）。
  /// 同时返回这一天的对话分场：被静音切开的几条对话记录在列表里合成一行。
  func segments(_ day: Date, device: String? = nil) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    struct R: Decodable { let segments: [HistorySegment]; let conversations: [ConversationRef]? }
    let bounds = ViewerTime.dayQuery(day)
    let r = try await get(R.self, "/v1/history/segments", ["from": bounds.from, "to": bounds.to, "device": device])
    return (r.segments, r.conversations ?? [])
  }
  func conversation(_ recordID: String) async throws -> ConversationDetail { try await get(ConversationDetail.self, "/v1/conversations/\(recordID)") }
  func deleteRecord(_ id: String) async throws {
    let device = DeviceOperation("delete", ["ids": .array([.string(id)])]) { reply in
      struct Result: Decodable { let deleted: Int }
      if try self.decode(Result.self, from: reply.bodyData).deleted == 0 {
        throw HubError(message: "记录不存在", status: 404)
      }
      return reply.bodyData
    }
    try await send("DELETE", "/v1/records/\(id)", device: device)
  }

  func saveManual(_ record: [String: Any]) async throws {
    let body = try JSONSerialization.data(withJSONObject: record)
    let data = try await request("/v1/records", method: "POST", body: body, device: .init("records.create"))
    let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if (j?["accepted"] as? Int) != 1 {
      let errors = ((j?["rejected"] as? [[String: Any]]) ?? []).flatMap { ($0["errors"] as? [String]) ?? [] }
      throw HubError(message: errors.isEmpty ? "记录未写入，请重试" : errors.joined(separator: "；"), status: 0)
    }
  }

  func diary(_ day: Date) async throws -> DayDiary? {
    do { return try await get(DayDiary.self, "/v1/days/\(TimelineDay.key(day))") }
    catch let e as HubError where e.status == 404 { return nil }
  }

  func correctSegment(day: Date, id: String, description: String) async throws {
    let date = TimelineDay.key(day)
    try await send("PATCH", "/v1/days/\(date)/segments/\(id)", ["description": description],
                   device: .init("segment.correct", ["date": .string(date), "id": .string(id)]))
  }

  func deleteSegment(day: Date, id: String, recordIds: [String]) async throws {
    let date = TimelineDay.key(day)
    try await send("DELETE", "/v1/days/\(date)/segments/\(id)", ["record_ids": recordIds],
                   device: .init("segment.delete", ["date": .string(date), "id": .string(id)]))
  }

  struct TimelineResult: Decodable, Equatable, Sendable {
    struct Day: Decodable, Identifiable, Equatable, Sendable {
      let date: String
      let items: [DayDiary.Item]
      var id: String { date }
    }
    let days: [Day]
    let nextCursor: String?
  }

  func timeline(projectId: String? = nil, threadId: String? = nil, query: String? = nil, before: String? = nil) async throws -> TimelineResult {
    try await get(TimelineResult.self, "/v1/timeline", ["project_id": projectId, "thread_id": threadId, "q": query, "before": before])
  }

  struct TimelineLocation: Decodable, Equatable, Sendable {
    let date: String
    let segmentId: String?
  }

  func timelineLocation(record id: String) async throws -> TimelineLocation {
    try await get(TimelineLocation.self, "/v1/timeline/record/\(id)")
  }

  // MARK: 提炼

  func now() async throws -> NowState? {
    struct R: Decodable { let now: NowState? }
    return try await get(R.self, "/v1/now").now
  }

  func projects() async throws -> [Project] {
    struct R: Decodable { let projects: [Project] }
    return try await get(R.self, "/v1/projects").projects
  }

  func removeProject(_ id: String) async throws { try await send("DELETE", "/v1/projects/\(id)", device: .init("project.remove", ["id": .string(id)])) }

  func threads(project: String? = nil, status: String? = nil) async throws -> [HubThread] {
    struct R: Decodable { let threads: [HubThread]; let nextCursor: String? }
    var rows: [HubThread] = [], cursor: String? = nil, seen = Set<String>()
    repeat {
      let page = try await get(R.self, "/v1/threads", ["project": project, "status": status, "cursor": cursor, "limit": "200"])
      rows += page.threads
      cursor = page.nextCursor
      if let c = cursor { if seen.contains(c) { break }; seen.insert(c) }
    } while cursor != nil
    var ids = Set<String>()
    return rows.filter { ids.insert($0.id).inserted }
  }

  func thread(_ id: String, level: String) async throws -> EntityDetail { try await get(EntityDetail.self, "/v1/threads/\(id)", ["level": level]) }
  func project(_ id: String, level: String) async throws -> EntityDetail { try await get(EntityDetail.self, "/v1/projects/\(id)", ["level": level]) }

  func projectContext(_ id: String) async throws -> [HubThread] {
    struct Result: Decodable { let threads: [HubThread] }
    return try await get(Result.self, "/v1/projects/\(id)/context").threads
  }

  func pending() async throws -> [PendingItem] {
    struct R: Decodable { let pending: [PendingItem] }
    return try await get(R.self, "/v1/pending", device: .init("pending.list")).pending
  }

  func resolve(_ id: String, action: String, name: String? = nil, target: String? = nil) async throws {
    var body: [String: Any] = ["action": action]
    if let name { body["name"] = name }
    if let target { body["target"] = target }
    try await send("POST", "/v1/pending/\(id)", body, device: .init("pending.resolve", ["id": .string(id)]))
  }

  /// 这条事实不属于它的线程：证据所在片段退回未分配，下一轮由模型重新归属（见 contracts.md）。
  func detachFact(_ id: String) async throws { try await send("POST", "/v1/facts/\(id)/detach", device: .init("facts.detach", ["id": .string(id)])) }

  func correct(_ fact: Fact, text: String) async throws {
    var body: [String: Any] = ["kind": fact.kind, "text": text, "evidence": fact.evidence, "supersedes": fact.id]
    if let t = fact.threadId { body["thread_id"] = t }
    if let p = fact.projectId { body["project_id"] = p }
    try await send("POST", "/v1/facts", body, device: .init("facts.create"))
  }

  // MARK: 提炼请求（由常驻提炼进程领取执行，见 docs/contracts.md 4.8）

  @discardableResult
  func requestDistill(kind: String, range: DistillDateRange? = nil) async throws -> DistillRequestInfo {
    var body: [String: Any] = ["kind": kind]
    if let range { body["from"] = range.from; body["to"] = range.to }
    return try await call(DistillRequestInfo.self, "POST", "/v1/distill/requests", body, device: .init("distill.request"))
  }

  func distillRequests() async throws -> [DistillRequestInfo] {
    struct R: Decodable { let requests: [DistillRequestInfo] }
    return try await get(R.self, "/v1/distill/requests", device: .init("distill.list")).requests
  }

  // MARK: 音频

  func speakers() async throws -> [Speaker] {
    struct R: Decodable { let speakers: [Speaker] }
    return try await get(R.self, "/v1/speakers", device: .init("speakers.list")).speakers
  }
  func sample(_ id: String) async throws -> Data {
    struct Sample: Decodable { let dataBase64: Data }
    let device = DeviceOperation("audio.sample.get", ["id": .string(id)]) {
      try self.decode(Sample.self, from: $0.bodyData).dataBase64
    }
    return try await request("/v1/audio/samples/\(id)", device: device)
  }
  func retentionDays() async throws -> Int {
    struct R: Decodable { let retentionDays: Int }
    return try await get(R.self, "/v1/audio/settings", device: .init("audio.settings.get")).retentionDays
  }
  func setRetentionDays(_ days: Int) async throws { try await send("PUT", "/v1/audio/settings", ["retention_days": days], device: .init("audio.settings.put")) }
  func purgeAudio() async throws { try await send("POST", "/v1/audio/purge", device: .init("audio.purge")) }

  func modelCalls(cursor: String?) async throws -> ModelCallPage {
    var parameters: [String: DeviceJSON] = ["limit": .int(30)]
    if let cursor { parameters["cursor"] = .string(cursor) }
    return try await get(ModelCallPage.self, "/v1/runtime/models", ["limit": "30", "cursor": cursor],
                         device: .init("runtime.models", parameters))
  }
  func callSnapshot(_ id: String) async throws -> CallSnapshot {
    try await get(CallSnapshot.self, "/v1/runtime/calls/" + id, device: .init("runtime.call", ["id": .string(id)]))
  }
  func backgroundLog(_ source: String) async throws -> BackgroundLogPage {
    let device = source == "hub" ? DeviceOperation("diagnostics.get") : .init("runtime.background", ["source": .string(source)])
    return try await get(BackgroundLogPage.self, "/v1/runtime/background", ["source": source], device: device)
  }

  // MARK: 读取记录

  func audit(tool: String?, cursor: String?) async throws -> (reads: [AuditRead], next: String?) {
    struct R: Decodable { let reads: [AuditRead]; let nextCursor: String? }
    var parameters: [String: DeviceJSON] = ["limit": .int(100)]
    if let tool { parameters["tool"] = .string(tool) }
    if let cursor { parameters["cursor"] = .string(cursor) }
    let r = try await get(R.self, "/v1/audit", ["limit": "100", "tool": tool, "cursor": cursor],
                          device: .init("audit.list", parameters))
    return (r.reads, r.nextCursor)
  }

  /// 读取记录里的 id 可能是线程、项目或记录；只有 404 表示"不是这一类"。
  func resolveTarget(_ id: String) async throws -> (kind: String, title: String)? {
    if let t = try await existing({ try await self.thread(id, level: "brief") }) { return ("thread", t.title ?? id) }
    if let p = try await existing({ try await self.project(id, level: "brief") }) { return ("project", p.name ?? id) }
    if let r = try await existing({ try await self.record(id) }) { return ("record", RecordTitles.display(r.record.title, source: r.record.source) ?? id) }
    return nil
  }
  private func existing<T>(_ load: () async throws -> T) async throws -> T? {
    do { return try await load() } catch let e as HubError where e.status == 404 || e.status == 400 { return nil }
  }
}

// MARK: 设置（契约见 docs/contracts.md 3.1）

struct HubPortSettings: Decodable, Equatable { let port: Int; let listen: String; let lan: Bool; let locked: Bool }
struct ModelTierConfig: Codable, Equatable {
  var provider: String
  var model: String
  var baseUrl: String?
  var reasoningEffort: String?
}
struct ModelSettingsInfo: Decodable {
  struct ProviderInfo: Decodable, Hashable { let id: String; let label: String; let needsKey: Bool; let baseUrl: Bool }
  struct TierInfo: Decodable { let label: String; let description: String }
  let tiers: [String: ModelTierConfig]
  let configError: String?
  let keys: [String: Bool?]
  let providers: [ProviderInfo]
  let tierInfo: [String: TierInfo]
}
struct GeneralSettingsInfo: Decodable, Equatable {
  enum PolishTiming: String, Decodable { case afterSegment = "after_segment", hourly, nightly }
  enum OverviewTiming: String, Decodable { case hourly, everyThreeHours = "every_3h", nightly }

  var injectTokens: Int
  var askDoneDays: Int
  var archiveDays: Int
  let timelinePolish: PolishTiming
  let timelineOverview: OverviewTiming
  let dailyTokenLimit: Int?
  let modelUsage: ModelUsageSummary
  let ranges: [String: [Int]]
}
struct ModelTestResult: Decodable { let ok: Bool; let ms: Double?; let error: String? }

extension HubAPI {
  func call<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ json: Any?, timeout: TimeInterval? = nil, device: DeviceOperation? = nil) async throws -> T {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    return try decode(type, from: await request(path, method: method, body: body, timeout: timeout, device: device))
  }
  static func tierJSON(_ t: ModelTierConfig) -> [String: Any] {
    var d: [String: Any] = ["provider": t.provider, "model": t.model]
    if let b = t.baseUrl, !b.isEmpty { d["base_url"] = b }
    if let r = t.reasoningEffort, !r.isEmpty { d["reasoning_effort"] = r }
    return d
  }

  func hubSettings() async throws -> HubPortSettings { try await get(HubPortSettings.self, "/v1/settings/hub", device: .init("settings.hub.get")) }
  /// nil 表示后台服务版本还没有设备管理接口。
  func deviceSettings() async throws -> DeviceSettings? {
    do { return try await call(DeviceSettings.self, "GET", "/v1/settings/devices", nil, timeout: 5, device: .init("devices.list")) }
    catch let error as HubError where error.status == 404 { return nil }
  }
  func createDeviceInvitation(role: String? = nil) async throws -> DeviceInvitation {
    try await call(DeviceInvitation.self, "POST", "/v1/settings/devices/pairing", role.map { ["role": $0] },
                   device: .init("devices.pairing.create"))
  }
  func cancelDeviceInvitation() async throws {
    try await send("DELETE", "/v1/settings/devices/pairing", device: .init("devices.pairing.cancel"))
  }
  func removeDevice(_ id: String) async throws {
    try await send("DELETE", "/v1/settings/devices/\(id)", device: .init("devices.remove", ["id": .string(id)]))
  }
  func updateDeviceRole(_ id: String, role: String) async throws {
    try await send("PUT", "/v1/settings/devices/\(id)/role", ["role": role],
                   device: .init("devices.role.update", ["id": .string(id)]))
  }
  func pendingSecurityEvents() async throws -> [TimelineSecurityEvent] {
    struct Reply: Decodable { let events: [TimelineSecurityEvent] }
    return try await call(Reply.self, "GET", "/v1/settings/security-events", nil, timeout: 5,
                          device: .init("settings.security-events.list")).events
  }

  func acknowledgeSecurityEvent(_ id: String) async throws {
    try await send("POST", "/v1/settings/security-events/\(id)/ack",
                   device: .init("settings.security-events.ack", ["id": .string(id)]))
  }

  func relaySettings() async throws -> RelaySettings {
    try await call(RelaySettings.self, "GET", "/v1/settings/relay", nil, timeout: 5, device: .init("settings.relay.get"))
  }
  func saveRelay(address: String, code: String) async throws -> RelaySettings {
    var body = ["mode": RelaySettings.Mode.custom.rawValue, "url": address]
    if !code.isEmpty { body["code"] = code }
    return try await call(RelaySettings.self, "PUT", "/v1/settings/relay", body, timeout: 75, device: .init("settings.relay.put"))
  }
  func disableRelay() async throws -> RelaySettings {
    try await call(RelaySettings.self, "PUT", "/v1/settings/relay", ["mode": RelaySettings.Mode.off.rawValue], timeout: 75, device: .init("settings.relay.put"))
  }
  func testRelay(address: String) async throws -> RelayTestResult {
    try await call(RelayTestResult.self, "POST", "/v1/settings/relay/test", ["url": address], device: .init("settings.relay.test"))
  }
  // hub.json 会随重启切换端口，collector-link.json 的 addrs 尚不会改写。
  func setHubPort(_ port: Int) async throws -> Bool {
    struct R: Decodable { let restarting: Bool }
    return try await call(R.self, "PUT", "/v1/settings/hub", ["port": port]).restarting
  }
  func modelSettings() async throws -> ModelSettingsInfo { try await get(ModelSettingsInfo.self, "/v1/settings/models", device: .init("settings.models.get")) }
  func saveModels(_ tiers: [String: ModelTierConfig]) async throws -> ModelSettingsInfo {
    try await call(ModelSettingsInfo.self, "PUT", "/v1/settings/models", ["tiers": tiers.mapValues(Self.tierJSON)],
                   device: .init("settings.models.put"))
  }
  func testModel(tier: String, config: ModelTierConfig) async throws -> ModelTestResult {
    try await call(ModelTestResult.self, "POST", "/v1/settings/models/test", ["tier": tier, "config": Self.tierJSON(config)], timeout: 75,
                   device: .init("settings.models.test"))
  }
  func setKey(provider: String, key: String) async throws { try await send("PUT", "/v1/settings/keys/\(provider)", ["key": key],
                   device: .init("settings.keys.put", ["provider": .string(provider)])) }
  func deleteKey(provider: String) async throws { try await send("DELETE", "/v1/settings/keys/\(provider)",
                   device: .init("settings.keys.delete", ["provider": .string(provider)])) }
  func generalSettings() async throws -> GeneralSettingsInfo { try await get(GeneralSettingsInfo.self, "/v1/settings/general", device: .init("settings.general.get")) }
  func saveGeneral(_ values: [String: Any]) async throws -> GeneralSettingsInfo {
    try await call(GeneralSettingsInfo.self, "PUT", "/v1/settings/general", values, device: .init("settings.general.put"))
  }

  func localModels(baseURL: String) async throws -> [String] {
    struct R: Decodable { let models: [String] }
    return try await call(R.self, "POST", "/v1/settings/models/local", ["base_url": baseURL], timeout: 8,
                          device: .init("settings.models.local")).models
  }
}

struct RelayTestResult: Decodable {
  struct Limits: Decodable {
    let spaceBytes: Int
    let messageBytes: Int
    let retentionDays: Int
  }
  let tacitRelay: Int
  let limits: Limits
}
