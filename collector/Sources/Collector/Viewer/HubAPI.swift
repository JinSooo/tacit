import Foundation
import CollectorCore

/// 客户端只通过 hub 的本机 HTTP 接口读写，和网页用同一套接口与同一个 token。
struct HubError: LocalizedError {
  let message: String
  let status: Int
  var errorDescription: String? { message }
}

final class HubAPI: @unchecked Sendable {
  let base: URL
  private let tokenProvider: () -> String?
  private let session: URLSession

  init(base: URL, token: @escaping () -> String?) {
    self.base = base
    self.tokenProvider = token
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: c)
  }

  private func request(_ path: String, query: [String: String?] = [:], method: String = "GET", body: Data? = nil) async throws -> Data {
    guard let token = tokenProvider() else { throw HubError(message: "找不到 hub 的 token，hub 是否启动过？", status: 0) }
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
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let data: Data, response: URLResponse
    do { (data, response) = try await session.data(for: r) }
    catch let e as URLError where e.code == .cancelled { throw CancellationError() }
    catch { throw HubError(message: "hub 连不上：\(error.localizedDescription)", status: 0) }
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

  private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:]) async throws -> T {
    let data = try await request(path, query: query)
    do { return try HubJSON.decoder().decode(T.self, from: data) }
    catch { throw HubError(message: "hub 返回的数据无法解析：\(error)", status: 0) }
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
  func segments(_ day: Date, device: String? = nil) async throws -> [HistorySegment] {
    struct R: Decodable { let segments: [HistorySegment] }
    let bounds = ViewerTime.dayQuery(day)
    return try await get(R.self, "/v1/history/segments", ["from": bounds.from, "to": bounds.to, "device": device]).segments
  }
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
    let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    do { return try await get(DayDiary.self, "/v1/days/\(key)") }
    catch let e as HubError where e.status == 404 { return nil }
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

  func correct(_ fact: Fact, text: String) async throws {
    var body: [String: Any] = ["kind": fact.kind, "text": text, "evidence": fact.evidence, "supersedes": fact.id]
    if let t = fact.threadId { body["thread_id"] = t }
    if let p = fact.projectId { body["project_id"] = p }
    try await send("POST", "/v1/facts", body)
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
    if let r = try await existing({ try await self.record(id) }) { return ("record", r.record.title) }
    return nil
  }
  private func existing<T>(_ load: () async throws -> T) async throws -> T? {
    do { return try await load() } catch let e as HubError where e.status == 404 || e.status == 400 { return nil }
  }
}
