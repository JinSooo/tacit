import Foundation
import CollectorCore

/// 客户端只通过 hub 的本机 HTTP 接口读写，和网页用同一套接口与同一个 token。
struct HubError: LocalizedError {
  let message: String
  let status: Int
  var errorDescription: String? { message }
}

final class HubAPI: @unchecked Sendable {
  private let baseURL: () -> URL
  var base: URL { baseURL() }
  private let tokenProvider: () -> String?
  private let session: URLSession

  init(base: @escaping () -> URL, token: @escaping () -> String?) {
    self.baseURL = base
    self.tokenProvider = token
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: c)
  }

  private func request(_ path: String, query: [String: String?] = [:], method: String = "GET", body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Data {
    guard let token = tokenProvider() else { throw HubError(message: "找不到后台服务的访问令牌，后台服务可能还没启动过", status: 0) }
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
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let data: Data, response: URLResponse
    do { (data, response) = try await session.data(for: r) }
    catch let e as URLError where e.code == .cancelled { throw CancellationError() }
    catch { throw HubError(message: "连不上后台服务：\(error.localizedDescription)", status: 0) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw HubError(message: msg ?? "请求失败（\(status)）", status: status)
    }
    return data
  }

  /// 中枢网页的状态页地址，和 `bun hub/src/cli.ts open` 一样把 token 放在 hash 里（不会发给服务器）。
  func statusPageURL() -> URL? {
    guard let token = tokenProvider(), !token.isEmpty,
          let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return URL(string: "\(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/#token=\(encoded)&status")
  }

  func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:]) async throws -> T {
    let data = try await request(path, query: query)
    do { return try HubJSON.decoder().decode(T.self, from: data) }
    catch { throw HubError(message: "后台服务返回的数据读不出来：\(error)", status: 0) }
  }

  private func send(_ method: String, _ path: String, _ json: Any? = nil) async throws {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    _ = try await request(path, method: method, body: body)
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

  /// 一天的活动段（hub 按线程或应用聚合，不调用模型）。
  /// 同时返回这一天的对话分场：被静音切开的几条对话记录在列表里合成一行。
  func segments(_ day: Date, device: String? = nil) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    struct R: Decodable { let segments: [HistorySegment]; let conversations: [ConversationRef]? }
    let bounds = ViewerTime.dayQuery(day)
    let r = try await get(R.self, "/v1/history/segments", ["from": bounds.from, "to": bounds.to, "device": device])
    return (r.segments, r.conversations ?? [])
  }
  func conversation(_ recordID: String) async throws -> ConversationDetail { try await get(ConversationDetail.self, "/v1/conversations/\(recordID)") }
  func deleteRecord(_ id: String) async throws { try await send("DELETE", "/v1/records/\(id)") }

  func saveManual(_ record: [String: Any]) async throws {
    let body = try JSONSerialization.data(withJSONObject: record)
    let data = try await request("/v1/records", method: "POST", body: body)
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
    try await send("PATCH", "/v1/days/\(TimelineDay.key(day))/segments/\(id)", ["description": description])
  }

  func deleteSegment(day: Date, id: String, recordIds: [String]) async throws {
    try await send("DELETE", "/v1/days/\(TimelineDay.key(day))/segments/\(id)", ["record_ids": recordIds])
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

  func pending() async throws -> [PendingItem] {
    struct R: Decodable { let pending: [PendingItem] }
    return try await get(R.self, "/v1/pending").pending
  }

  func resolve(_ id: String, action: String, name: String? = nil, target: String? = nil) async throws {
    var body: [String: Any] = ["action": action]
    if let name { body["name"] = name }
    if let target { body["target"] = target }
    try await send("POST", "/v1/pending/\(id)", body)
  }

  /// 这条事实不属于它的线程：证据所在片段退回未分配，下一轮由模型重新归属（见 contracts.md）。
  func detachFact(_ id: String) async throws { try await send("POST", "/v1/facts/\(id)/detach") }

  func correct(_ fact: Fact, text: String) async throws {
    var body: [String: Any] = ["kind": fact.kind, "text": text, "evidence": fact.evidence, "supersedes": fact.id]
    if let t = fact.threadId { body["thread_id"] = t }
    if let p = fact.projectId { body["project_id"] = p }
    try await send("POST", "/v1/facts", body)
  }

  // MARK: 提炼请求（由常驻提炼进程领取执行，见 docs/contracts.md 4.8）

  @discardableResult
  func requestDistill(kind: String, range: DistillDateRange? = nil) async throws -> DistillRequestInfo {
    var body: [String: Any] = ["kind": kind]
    if let range { body["from"] = range.from; body["to"] = range.to }
    let data = try await request("/v1/distill/requests", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    do { return try HubJSON.decoder().decode(DistillRequestInfo.self, from: data) }
    catch { throw HubError(message: "后台服务返回的数据读不出来：\(error)", status: 0) }
  }

  func distillRequests() async throws -> [DistillRequestInfo] {
    struct R: Decodable { let requests: [DistillRequestInfo] }
    return try await get(R.self, "/v1/distill/requests").requests
  }

  // MARK: 音频

  func speakers() async throws -> [Speaker] {
    struct R: Decodable { let speakers: [Speaker] }
    return try await get(R.self, "/v1/speakers").speakers
  }
  func sample(_ id: String) async throws -> Data { try await request("/v1/audio/samples/\(id)") }
  func retentionDays() async throws -> Int {
    struct R: Decodable { let retentionDays: Int }
    return try await get(R.self, "/v1/audio/settings").retentionDays
  }
  func setRetentionDays(_ days: Int) async throws { try await send("PUT", "/v1/audio/settings", ["retention_days": days]) }
  func purgeAudio() async throws { try await send("POST", "/v1/audio/purge") }

  func modelCalls(cursor: String?) async throws -> ModelCallPage {
    try await get(ModelCallPage.self, "/v1/runtime/models", ["limit":"30", "cursor":cursor])
  }
  func callSnapshot(_ id: String) async throws -> CallSnapshot {
    try await get(CallSnapshot.self, "/v1/runtime/calls/" + id)
  }
  func backgroundLog(_ source: String) async throws -> BackgroundLogPage {
    try await get(BackgroundLogPage.self, "/v1/runtime/background", ["source":source])
  }

  // MARK: 读取记录

  func audit(tool: String?, cursor: String?) async throws -> (reads: [AuditRead], next: String?) {
    struct R: Decodable { let reads: [AuditRead]; let nextCursor: String? }
    let r = try await get(R.self, "/v1/audit", ["limit": "100", "tool": tool, "cursor": cursor])
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
  var injectTokens: Int
  var askDoneDays: Int
  var archiveDays: Int
  let ranges: [String: [Int]]
}
struct ModelTestResult: Decodable { let ok: Bool; let ms: Double?; let error: String? }

extension HubAPI {
  func call<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ json: Any?, timeout: TimeInterval? = nil) async throws -> T {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    let data = try await request(path, method: method, body: body, timeout: timeout)
    do { return try HubJSON.decoder().decode(T.self, from: data) }
    catch { throw HubError(message: "后台服务返回的数据读不出来：\(error)", status: 0) }
  }
  static func tierJSON(_ t: ModelTierConfig) -> [String: Any] {
    var d: [String: Any] = ["provider": t.provider, "model": t.model]
    if let b = t.baseUrl, !b.isEmpty { d["base_url"] = b }
    if let r = t.reasoningEffort, !r.isEmpty { d["reasoning_effort"] = r }
    return d
  }

  func hubSettings() async throws -> HubPortSettings { try await get(HubPortSettings.self, "/v1/settings/hub") }
  func setHubPort(_ port: Int) async throws -> Bool {
    struct R: Decodable { let restarting: Bool }
    return try await call(R.self, "PUT", "/v1/settings/hub", ["port": port]).restarting
  }
  func modelSettings() async throws -> ModelSettingsInfo { try await get(ModelSettingsInfo.self, "/v1/settings/models") }
  func saveModels(_ tiers: [String: ModelTierConfig]) async throws -> ModelSettingsInfo {
    try await call(ModelSettingsInfo.self, "PUT", "/v1/settings/models", ["tiers": tiers.mapValues(Self.tierJSON)])
  }
  func testModel(tier: String, config: ModelTierConfig) async throws -> ModelTestResult {
    try await call(ModelTestResult.self, "POST", "/v1/settings/models/test", ["tier": tier, "config": Self.tierJSON(config)], timeout: 75)
  }
  func setKey(provider: String, key: String) async throws { try await send("PUT", "/v1/settings/keys/\(provider)", ["key": key]) }
  func deleteKey(provider: String) async throws { try await send("DELETE", "/v1/settings/keys/\(provider)") }
  func generalSettings() async throws -> GeneralSettingsInfo { try await get(GeneralSettingsInfo.self, "/v1/settings/general") }
  func saveGeneral(_ values: [String: Int]) async throws -> GeneralSettingsInfo {
    try await call(GeneralSettingsInfo.self, "PUT", "/v1/settings/general", values)
  }

  func localModels(baseURL: String) async throws -> [String] {
    struct R: Decodable { let models: [String] }
    return try await call(R.self, "POST", "/v1/settings/models/local", ["base_url": baseURL], timeout: 8).models
  }
}
