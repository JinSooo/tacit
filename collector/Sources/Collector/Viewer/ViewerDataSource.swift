import Foundation
import CollectorCore

struct ActiveDaysResult: Equatable, Sendable {
  let dates: Set<String>
  let authoritative: Bool
}

/// 查看窗口与桌面小组件的统一读数据源抽象。
/// 写操作及管理接口由 HubAPI 复用 AdaptiveViewerDataSource 的设备会话。
protocol ViewerDataSource: Sendable {
  func diary(_ day: Date) async throws -> DayDiary?
  func now() async throws -> NowState?
  func projects() async throws -> [Project]
  func project(_ id: String, level: String) async throws -> EntityDetail
  func projectContext(_ id: String) async throws -> [HubThread]
  func thread(_ id: String, level: String) async throws -> EntityDetail
  func timeline(projectId: String?, threadId: String?, query: String?, before: String?) async throws -> HubAPI.TimelineResult
  func timelineLocation(record id: String) async throws -> HubAPI.TimelineLocation
  func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage
  func day(_ day: Date) async throws -> [HistoryRecord]
  func record(_ id: String) async throws -> RecordDetail
  func recordsByIDs(_ ids: [String]) async throws -> [HistoryRecord]
  func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord]
  func segments(_ day: Date, device: String?) async throws -> (segments: [HistorySegment], conversations: [ConversationRef])
  func conversation(_ recordID: String) async throws -> ConversationDetail
  func activeDays(inMonth month: String, bypassCache: Bool) async throws -> ActiveDaysResult
  func cachedActiveDays(inMonth month: String) -> Set<String>
}

extension ViewerDataSource {
  func timeline(projectId: String? = nil, threadId: String? = nil, query: String? = nil, before: String? = nil) async throws -> HubAPI.TimelineResult {
    try await timeline(projectId: projectId, threadId: threadId, query: query, before: before)
  }

  func segments(_ day: Date) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    try await segments(day, device: nil)
  }

  func activeDays(inMonth month: String) async throws -> ActiveDaysResult {
    try await activeDays(inMonth: month, bypassCache: false)
  }

  func cachedActiveDays(inMonth month: String) -> Set<String> { [] }
}

// MARK: - HTTP 读路径实现

final class HTTPViewerDataSource: ViewerDataSource, @unchecked Sendable {
  let api: HubAPI

  init(api: HubAPI) {
    self.api = api
  }

  func diary(_ day: Date) async throws -> DayDiary? { try await api.diary(day) }
  func now() async throws -> NowState? { try await api.now() }
  func projects() async throws -> [Project] { try await api.projects() }
  func project(_ id: String, level: String) async throws -> EntityDetail { try await api.project(id, level: level) }
  func projectContext(_ id: String) async throws -> [HubThread] { try await api.projectContext(id) }
  func thread(_ id: String, level: String) async throws -> EntityDetail { try await api.thread(id, level: level) }
  func timeline(projectId: String?, threadId: String?, query: String?, before: String?) async throws -> HubAPI.TimelineResult {
    try await api.timeline(projectId: projectId, threadId: threadId, query: query, before: before)
  }
  func timelineLocation(record id: String) async throws -> HubAPI.TimelineLocation { try await api.timelineLocation(record: id) }
  func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage { try await api.records(query, cursor: cursor) }
  func day(_ day: Date) async throws -> [HistoryRecord] { try await api.day(day) }
  func record(_ id: String) async throws -> RecordDetail { try await api.record(id) }
  func recordsByIDs(_ ids: [String]) async throws -> [HistoryRecord] { try await api.missingRecords(ids, from: []) }
  func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord] {
    try await api.missingRecords(ids, from: available)
  }
  func segments(_ day: Date, device: String?) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    try await api.segments(day, device: device)
  }
  func conversation(_ recordID: String) async throws -> ConversationDetail { try await api.conversation(recordID) }
  func activeDays(inMonth month: String, bypassCache: Bool) async throws -> ActiveDaysResult {
    ActiveDaysResult(dates: Set(try await api.activeDays(inMonth: month).dates), authoritative: true)
  }
}

// MARK: - 下推缓存 + 设备协议按需读路径实现

final class CachedViewerDataSource: ViewerDataSource, @unchecked Sendable {
  let sync: ProjectionSync
  private let httpFallback: HTTPViewerDataSource?
  private func privateReadAllowed() async -> Bool {
    guard includePrivate else { return false }
    return await sync.canReadPrivate()
  }

  private let includePrivate: Bool
  private let calendar: Calendar
  private let clock: @Sendable () -> Date

  init(
    sync: ProjectionSync,
    httpFallback: HTTPViewerDataSource? = nil,
    includePrivate: Bool = true,
    calendar: Calendar = .current,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sync = sync
    self.httpFallback = httpFallback
    self.includePrivate = includePrivate
    self.calendar = calendar
    self.clock = clock
  }

  private func ensureReady() async throws {
    try await sync.ensureInitialSync()
  }

  private func retentionCutoffDayKey() -> String {
    let today = clock()
    let cutoffDate = calendar.date(byAdding: .day, value: -(sync.cache.policy.dayRetentionDays - 1), to: today) ?? today
    return TimelineDay.key(cutoffDate, calendar: calendar)
  }

  func diary(_ day: Date) async throws -> DayDiary? {
    try await ensureReady()
    let key = TimelineDay.key(day, calendar: calendar)
    if let entity = try sync.cache.get(kind: .day, id: key) {
      let decoded = try HubAPI.decodeDiary(entity.payloadData)
      return normalizeDayDiary(decoded)
    }
    if key < retentionCutoffDayKey(), let httpFallback {
      return try await httpFallback.diary(day)
    }
    return nil
  }

  func now() async throws -> NowState? {
    try await ensureReady()
    guard let entity = try sync.cache.get(kind: .now, id: "current") else { return nil }
    return try HubJSON.decoder().decode(NowState.self, from: entity.payloadData)
  }

  func projects() async throws -> [Project] {
    try await ensureReady()
    let decoder = HubJSON.decoder()
    let list = try sync.cache.list(kind: .project).map { try decoder.decode(Project.self, from: $0.payloadData) }
    // 与中枢 SQLite `ORDER BY p.last_ms DESC, p.id DESC` 保持一致（NULL 排在最后）。
    return list.sorted { a, b in
      switch (a.lastMs, b.lastMs) {
      case let (la?, lb?) where la != lb: return la > lb
      case (_?, nil): return true
      case (nil, _?): return false
      default: return a.id > b.id
      }
    }
  }

  func project(_ id: String, level: String) async throws -> EntityDetail {
    if level == "evidence" {
      guard let httpFallback else { throw HubError.needsLocalHub }
      return try await httpFallback.project(id, level: level)
    }
    try await ensureReady()
    guard let entity = try sync.cache.get(kind: .project, id: id) else {
      throw HubError(message: L10n.contentNotFound, status: 404)
    }
    return try HubJSON.decoder().decode(EntityDetail.self, from: entity.payloadData)
  }

  func projectContext(_ id: String) async throws -> [HubThread] {
    try await ensureReady()
    if let entity = try sync.cache.get(kind: .projectContext, id: id) {
      struct ContextWire: Decodable { let threads: [HubThread] }
      return try HubJSON.decoder().decode(ContextWire.self, from: entity.payloadData).threads
    }
    if try sync.cache.get(kind: .project, id: id) != nil {
      return []
    }
    throw HubError(message: L10n.contentNotFound, status: 404)
  }

  func thread(_ id: String, level: String) async throws -> EntityDetail {
    if level == "evidence" {
      guard let httpFallback else { throw HubError.needsLocalHub }
      // 下推 thread 不含全部关联的 frame_records 依据列表，evidence 层沿用 HTTP。
      return try await httpFallback.thread(id, level: level)
    }
    try await ensureReady()
    if let entity = try sync.cache.get(kind: .thread, id: id) {
      return try HubJSON.decoder().decode(EntityDetail.self, from: entity.payloadData)
    }
    // 超过 30 天的已归档事项已从本地缓存清理，按需退回 HTTP。
    if let httpFallback {
      return try await httpFallback.thread(id, level: level)
    }
    throw HubError(message: L10n.contentNotFound, status: 404)
  }

  func timeline(projectId: String?, threadId: String?, query: String?, before: String?) async throws -> HubAPI.TimelineResult {
    if let query {
      return try await remoteTimeline(projectId: nil, threadId: nil, query: query, before: before, limit: nil)
    }
    try await ensureReady()
    let pageLimit = 15
    let cutoffKey = retentionCutoffDayKey()
    if let before, before <= cutoffKey {
      return try await remoteTimeline(projectId: projectId, threadId: threadId, query: nil, before: before, limit: pageLimit)
    }

    let decoder = HubJSON.decoder()
    let cachedDays = try sync.cache.list(kind: .day).reversed()
    var matched: [HubAPI.TimelineResult.Day] = []
    var hasMoreInCache = false

    for entity in cachedDays {
      if let before, entity.id >= before { continue }
      let diary = try decoder.decode(DayDiary.self, from: entity.payloadData)
      guard let rawItems = diary.detail?.items else { continue }
      let filtered = rawItems.filter { item in
        guard item.recordIds != nil else { return false }
        if let projectId { return item.projectId == projectId }
        if let threadId { return item.threadId == threadId }
        return false
      }
      guard !filtered.isEmpty else { continue }
      if matched.count == pageLimit {
        hasMoreInCache = true
        break
      }
      // 与 hub/src/timeline.ts 一致：按 t_start 降序、id 升序排列。
      let sorted = filtered.sorted { a, b in
        let ta = ViewerTime.parse(a.tStart)?.timeIntervalSince1970 ?? 0
        let tb = ViewerTime.parse(b.tStart)?.timeIntervalSince1970 ?? 0
        if ta != tb { return ta > tb }
        return a.id < b.id
      }
      matched.append(HubAPI.TimelineResult.Day(date: diary.date, items: sorted))
    }

    if hasMoreInCache {
      return HubAPI.TimelineResult(days: matched, nextCursor: matched.last?.date)
    }

    // 检查 90 天窗口之外是否还有更早的日期；离线时优雅返回本地缓存结果。
    let olderBefore = before.map { min($0, cutoffKey) } ?? cutoffKey
    let remaining = matched.count == pageLimit ? 1 : (pageLimit - matched.count)
    do {
      let remote = try await remoteTimeline(projectId: projectId, threadId: threadId, query: nil, before: olderBefore, limit: remaining)
      if matched.count == pageLimit {
        return HubAPI.TimelineResult(days: matched, nextCursor: remote.days.isEmpty ? nil : matched.last?.date)
      }
      let seen = Set(matched.map(\.date))
      let combined = matched + remote.days.filter { !seen.contains($0.date) }
      return HubAPI.TimelineResult(days: combined, nextCursor: remote.nextCursor)
    } catch let error as DeviceClientError {
      if isRemovalOrForbidden(error) { throw error }
      return HubAPI.TimelineResult(days: matched, nextCursor: nil)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return HubAPI.TimelineResult(days: matched, nextCursor: nil)
    }
  }

  func timelineLocation(record id: String) async throws -> HubAPI.TimelineLocation {
    let payload = try await sync.timelineLocate(recordID: id, includePrivate: await privateReadAllowed())
    return try HubJSON.decoder().decode(HubAPI.TimelineLocation.self, from: payload.bodyData)
  }

  func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage {
    var params: [String: DeviceJSON] = ["limit": .int(Int64(query.limit))]
    if let q = query.q { params["q"] = .string(q) }
    if let source = query.source { params["source"] = .string(source) }
    if let device = query.device { params["device"] = .string(device) }
    if let from = query.from { params["from"] = .string(from) }
    if let to = query.to { params["to"] = .string(to) }
    if let cursor { params["cursor"] = .string(cursor) }
    if query.body { params["body"] = .bool(true) }
    if await privateReadAllowed() { params["include_private"] = .bool(true) }

    // 开放区间（无上界）或覆盖当前时刻的查询不走 10 分钟 LRU，避免菜单栏和当天详细档滞后。
    let useCache: Bool
    if let to = query.to, let toDate = ViewerTime.parse(to), toDate < clock() {
      useCache = true
    } else {
      useCache = false
    }

    let payload = try await sync.listRecords(params, useCache: useCache)
    return try HubJSON.decoder().decode(RecordPage.self, from: payload.bodyData)
  }

  func day(_ day: Date) async throws -> [HistoryRecord] {
    let bounds = ViewerTime.dayQuery(day)
    var query = HubAPI.RecordQuery()
    query.from = bounds.from
    query.to = bounds.to
    query.limit = 500
    var all: [HistoryRecord] = []
    var cursor: String? = nil
    var pages = 0
    repeat {
      let page = try await records(query, cursor: cursor)
      all += page.records
      cursor = page.nextCursor
      pages += 1
    } while cursor != nil && pages < 20
    return all
  }

  func record(_ id: String) async throws -> RecordDetail {
    let result = try await sync.getRecords(ids: [id], includeCorrections: true, includePrivate: await privateReadAllowed())
    guard let json = result.records[id] else {
      throw HubError(message: L10n.recordNotFound, status: 404)
    }
    if json.objectValue?["redacted_private"]?.boolValue == true {
      throw HubError(message: L10n.recordNotFound, status: 404)
    }
    let data = try JSONEncoder().encode(json)
    return try HubJSON.decoder().decode(RecordDetail.self, from: data)
  }

  func recordsByIDs(_ ids: [String]) async throws -> [HistoryRecord] {
    let unique = Array(NSOrderedSet(array: ids).compactMap { $0 as? String })
    guard !unique.isEmpty else { return [] }
    let encoder = JSONEncoder()
    let decoder = HubJSON.decoder()
    var resolved: [HistoryRecord] = []
    var start = 0
    while start < unique.count {
      let end = min(start + 50, unique.count)
      let chunk = Array(unique[start..<end])
      let batch = try await sync.getRecords(ids: chunk, includeCorrections: false, includePrivate: await privateReadAllowed())
      for id in chunk {
        guard let json = batch.records[id],
              json.objectValue?["redacted_private"]?.boolValue != true else { continue }
        let data = try encoder.encode(json)
        resolved.append(try decoder.decode(HistoryRecord.self, from: data))
      }
      start = end
    }
    return resolved
  }

  func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord] {
    let availableSet = Set(available.map(\.id))
    let needed = ids.filter { !availableSet.contains($0) }
    return try await recordsByIDs(needed)
  }

  func segments(_ day: Date, device: String?) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    struct Wire: Decodable { let segments: [HistorySegment]; let conversations: [ConversationRef]? }
    let bounds = ViewerTime.dayQuery(day)
    let payload = try await sync.historySegments(from: bounds.from, to: bounds.to, device: device, includePrivate: await privateReadAllowed())
    let decoded = try HubJSON.decoder().decode(Wire.self, from: payload.bodyData)
    return (decoded.segments, decoded.conversations ?? [])
  }

  func conversation(_ recordID: String) async throws -> ConversationDetail {
    let payload = try await sync.conversationDetail(recordID: recordID, includePrivate: await privateReadAllowed())
    return try HubJSON.decoder().decode(ConversationDetail.self, from: payload.bodyData)
  }

  func cachedActiveDays(inMonth month: String) -> Set<String> {
    let prefix = "\(month)-"
    guard let entities = try? sync.cache.list(kind: .day) else { return [] }
    let decoder = HubJSON.decoder()
    let protoCalendar = TimelineCalendar.protocolCalendar(from: calendar)
    let todayKey = TimelineDay.key(clock(), calendar: protoCalendar)
    var dates: Set<String> = []
    for entity in entities where entity.id.hasPrefix(prefix) {
      guard let diary = try? decoder.decode(DayDiary.self, from: entity.payloadData) else { continue }
      if Self.diaryHasContent(diary, todayKey: todayKey) {
        dates.insert(entity.id)
      }
    }
    return dates
  }

  func activeDays(inMonth month: String, bypassCache: Bool) async throws -> ActiveDaysResult {
    try await ensureReady()
    let currentMonth = TimelineCalendar.Month(containing: clock(), calendar: calendar).key
    let useCache = !bypassCache && month < currentMonth
    do {
      let payload = try await sync.activeDays(month: month, includePrivate: await privateReadAllowed(), useCache: useCache)
      let decoded = try HubJSON.decoder().decode(ActiveDaysResponse.self, from: payload.bodyData)
      return ActiveDaysResult(dates: Set(decoded.dates), authoritative: true)
    } catch let error as DeviceClientError {
      if isRemovalOrForbidden(error) { throw error }
      return ActiveDaysResult(dates: cachedActiveDays(inMonth: month), authoritative: false)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return ActiveDaysResult(dates: cachedActiveDays(inMonth: month), authoritative: false)
    }
  }

  static func diaryHasContent(_ diary: DayDiary, todayKey: String) -> Bool {
    if let items = diary.detail?.items, !items.isEmpty { return true }
    if let summary = diary.detail?.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty { return true }
    if diary.date == todayKey, let drafts = diary.drafts, !drafts.isEmpty { return true }
    return false
  }

  // MARK: - 内部辅助

  private func remoteTimeline(
    projectId: String?,
    threadId: String?,
    query: String?,
    before: String?,
    limit: Int?
  ) async throws -> HubAPI.TimelineResult {
    var params: [String: DeviceJSON] = [:]
    if let projectId { params["project_id"] = .string(projectId) }
    if let threadId { params["thread_id"] = .string(threadId) }
    if let query { params["q"] = .string(query) }
    if let before { params["before"] = .string(before) }
    if let limit { params["limit"] = .int(Int64(limit)) }
    let payload = try await sync.timelineQuery(params)
    return try HubJSON.decoder().decode(HubAPI.TimelineResult.self, from: payload.bodyData)
  }

  private func normalizeDayDiary(_ raw: DayDiary) -> DayDiary {
    let todayKey = TimelineDay.key(clock(), calendar: calendar)
    let normalizedDrafts = raw.date == todayKey ? raw.drafts : nil
    let normalizedFailed: FlexBool? = raw.failed?.value == true ? FlexBool(true) : nil
    guard let body = raw.detail else {
      return DayDiary(date: raw.date, detail: nil, drafts: normalizedDrafts, needsRegen: raw.needsRegen, failed: normalizedFailed)
    }
    let chapters: [DayDiary.Chapter]?
    if let existing = body.timeline {
      chapters = existing
    } else if let items = body.items, items.allSatisfy({ $0.recordIds != nil }) {
      chapters = Self.synthesizeChapters(items: items, date: raw.date)
    } else {
      chapters = nil
    }
    let normalizedBody = DayDiary.Body(
      summary: body.summary,
      timeline: chapters,
      items: body.items,
      omittedRecordIds: body.omittedRecordIds,
      cutoff: body.cutoff
    )
    return DayDiary(
      date: raw.date,
      detail: normalizedBody,
      drafts: normalizedDrafts,
      needsRegen: raw.needsRegen,
      failed: normalizedFailed
    )
  }

  static func synthesizeChapters(items: [DayDiary.Item], date: String) -> [DayDiary.Chapter] {
    items.compactMap { item in
      guard item.tStart.count >= 16, item.tEnd.count >= 16 else { return nil }
      let start = String(item.tStart.dropFirst(11).prefix(5))
      let endDate = String(item.tEnd.prefix(10))
      let end = endDate > date ? "24:00" : String(item.tEnd.dropFirst(11).prefix(5))
      guard start != end else { return nil }
      return DayDiary.Chapter(start: start, end: end, text: item.title)
    }
  }

  private func isRemovalOrForbidden(_ error: DeviceClientError) -> Bool {
    if case .deviceRemoved = error { return true }
    if case .operationError(_, 403, _) = error { return true }
    if case .plaintextError(403, _) = error { return true }
    return false
  }
}

// MARK: - 自适应数据源路由器与同步生命周期

/// Routes the viewer through the active binding. The local route can also use legacy HTTP.
final class AdaptiveViewerDataSource: ViewerDataSource, @unchecked Sendable {
  struct Session: Sendable {
    let id: UUID
    let route: HubBinding.Route
    let localLink: LocalDeviceLink?
    let remoteLink: RemoteDeviceLink?
    let origin: URL
    let credentialRevision: UUID?
    let sync: ProjectionSync
    let cached: CachedViewerDataSource
  }

  typealias SessionFactory = @Sendable (
    LocalDeviceLink,
    URL,
    @escaping @Sendable (ProjectionWipeReason) async -> Void,
    @escaping @Sendable (ProjectionSyncResult) async -> Void
  ) throws -> ProjectionSync

  let http: HTTPViewerDataSource
  private let files: LocalDeviceLink.Files
  private let remoteAccess: RemoteDeviceAccess
  private let widgetSnapshotURL: URL?
  private let remoteSessionFactory: @Sendable (HubBinding.Route, RemoteDeviceLink, URL,
    @escaping @Sendable (ProjectionWipeReason) async -> Void,
    @escaping @Sendable (ProjectionSyncResult) async -> Void) throws -> ProjectionSync
  private let onBindingChanged: (@Sendable () async -> Void)?
  private let originProvider: @Sendable () -> URL
  private let sessionFactory: SessionFactory
  private let calendar: Calendar
  private let clock: @Sendable () -> Date
  private let onUpdateCallback: (@Sendable (ProjectionSyncResult) async -> Void)?
  private let onWipeCallback: (@Sendable (ProjectionWipeReason) async -> Void)?

  private let bindingQueue = DispatchQueue(label: "record-anything.viewer-binding", qos: .utility)
  private let displayLock = NSLock()
  private let refreshGate = NSLock()
  private var refreshQueued = false // Protected by refreshGate.
  private var displayedSync: ProjectionSync?
  private var displayedCached: CachedViewerDataSource?
  private var active: Session?
  private var lastRoute: HubBinding.Route?
  private var bindingReady = false
  private var bindingTransition: Task<Void, Never>?
  private var foreground = false // Protected by displayLock.
  private var disabledReason: ProjectionWipeReason?
  private var disabledCredentialRevision: UUID?
  private var remoteCacheNeedsDiscard = false

  var isUsingCache: Bool { activeSync != nil }

  var activeSync: ProjectionSync? { displayLock.withLock { displayedSync } }

  private func publishSync() {
    displayLock.withLock {
      let ready = disabledReason == nil && bindingReady
      displayedSync = ready ? active?.sync : nil
      displayedCached = ready ? active?.cached : nil
    }
  }

  private func onBindingQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      bindingQueue.async { continuation.resume(returning: work()) }
    }
  }

  init(
    http: HTTPViewerDataSource,
    dataDir: URL,
    originProvider: @escaping @Sendable () -> URL,
    widgetSnapshotURL: URL? = nil,
    files: LocalDeviceLink.Files? = nil,
    keys: LocalDeviceLink.Keys = .keychain,
    cacheKeyProvider: any ProjectionCacheKeyProvider = KeychainProjectionCacheKeyProvider(),
    urlSession: URLSession? = nil,
    foregroundPollInterval: TimeInterval = ProjectionSync.defaultForegroundPollInterval,
    backgroundPollInterval: TimeInterval = ProjectionSync.defaultBackgroundPollInterval,
    calendar: Calendar = .current,
    clock: @escaping @Sendable () -> Date = { Date() },
    onUpdate: (@Sendable (ProjectionSyncResult) async -> Void)? = nil,
    onWipe: (@Sendable (ProjectionWipeReason) async -> Void)? = nil,
    remoteAccess: RemoteDeviceAccess? = nil,
    remoteTransport: RemoteDeviceAccess.TransportFactory? = nil,
    onBindingChanged: (@Sendable () async -> Void)? = nil,
    sessionFactory: SessionFactory? = nil
  ) {
    self.http = http
    let access = remoteAccess ?? RemoteDeviceAccess(dataDirectory: dataDir)
    self.remoteAccess = access
    self.widgetSnapshotURL = widgetSnapshotURL
    self.onBindingChanged = onBindingChanged
    let resolvedFiles = files ?? LocalDeviceLink.Files(directory: dataDir)
    self.files = resolvedFiles
    self.originProvider = originProvider
    self.calendar = calendar
    self.clock = clock
    self.onUpdateCallback = onUpdate
    self.onWipeCallback = onWipe
    let makeSync: @Sendable (DeviceClient, URL, RemoteDeviceSession?,
      @escaping @Sendable (ProjectionWipeReason) async -> Void,
      @escaping @Sendable (ProjectionSyncResult) async -> Void) throws -> ProjectionSync = { client, origin, remote, wipe, update in
      let eventStream: (any ProjectionEventStream)?
      if let remote {
        eventStream = remoteTransport == nil ? RemoteProjectionEventStream(deviceSession: remote, session: urlSession) : nil
      } else {
        eventStream = try URLSessionProjectionEventStream(origin: origin, session: urlSession)
      }
      let cache = try ProjectionCache(dataDirectory: dataDir, widgetSnapshotURL: widgetSnapshotURL,
                                      keyProvider: cacheKeyProvider, clock: clock, calendar: calendar)
      return ProjectionSync(client: client, cache: cache, eventStream: eventStream, deviceSession: remote,
                            foregroundPollInterval: foregroundPollInterval, backgroundPollInterval: backgroundPollInterval,
                            clock: clock, retireOnAccessLoss: remote != nil, onWipe: wipe, onUpdate: update)
    }
    self.sessionFactory = sessionFactory ?? { link, origin, wipe, update in
      guard let rawKey = try keys.read(.mac) else { throw LocalDeviceLink.Failure.keyUnavailable }
      let capturedRoute = try access.route()
      guard capturedRoute.remote == nil else { throw HubBinding.Failure.changed }
      let client = try DeviceClient(
        hubPublicKeyBase64URL: link.hub_pk, deviceID: link.device_id,
        keyStore: InMemoryDeviceKeyStore(rawRepresentation: rawKey),
        transport: DirectDeviceTransport(origin: origin, session: urlSession), clock: clock,
        validateRequest: { guard try access.route() == capturedRoute else { throw HubBinding.Failure.changed } }
      )
      return try makeSync(client, origin, nil, wipe, update)
    }
    self.remoteSessionFactory = { route, link, origin, wipe, update in
      let deviceSession = try access.session(for: route, link: link, transport: remoteTransport ?? {
        try DirectDeviceTransport(origin: $0, session: urlSession)
      })
      return try makeSync(deviceSession.client(), origin, deviceSession, wipe, update)
    }
  }

  /// Called at startup and when a local device is first registered.
  @discardableResult
  func activateIfLinked() async -> Bool {
    await onBindingQueue { [self] in
      defer { publishSync() }
      guard let route = refreshBindingLocked() else { return false }
      return activateLocked(route, forActions: false)
    }
  }

  /// The cutover must wait even when a periodic refresh was already queued.
  func refreshBindingAfterSwitch() async {
    _ = await activateIfLinked()
    let transition = await onBindingQueue { [self] in bindingTransition }
    await transition?.value
  }

  /// Observe a binding change even while the window is closed.
  func refreshBinding() async {
    // 定时刷新最多排一次：钥匙串慢时不在串行队列里越积越多。
    let skip = refreshGate.withLock { () -> Bool in
      if refreshQueued { return true }
      refreshQueued = true
      return false
    }
    if skip { return }
    await onBindingQueue { [self] in
      refreshGate.withLock { refreshQueued = false }
      defer { publishSync() }
      guard let route = refreshBindingLocked() else { return }
      if active != nil || route != .local { _ = activateLocked(route, forActions: false) }
    }
  }

  private func refreshBindingLocked() -> HubBinding.Route? {
    let observed = try? remoteAccess.route()
    if bindingReady, observed == lastRoute { return observed }

    let previous = active?.sync
    active = nil
    disabledReason = nil
    disabledCredentialRevision = nil
    publishSync()
    previous?.cache.retire()
    previous?.rawCache.retire()
    let pending = bindingTransition
    let changed = lastRoute != nil && observed != lastRoute
    lastRoute = observed
    bindingReady = false
    let cleared = observed.flatMap { route in
      try? ProjectionCache.prepareBinding(route, in: remoteAccess.dataDirectory, widgetSnapshotURL: widgetSnapshotURL)
    }
    if changed || cleared == true || previous != nil {
      bindingTransition = Task { [onBindingChanged] in
        await pending?.value
        await previous?.stop()
        await onBindingChanged?()
      }
    }
    bindingReady = cleared != nil
    return bindingReady ? observed : nil
  }

  private func activateLocked(_ route: HubBinding.Route, forActions: Bool) -> Bool {
    do {
      let localLink: LocalDeviceLink?
      let remoteLink: RemoteDeviceLink?
      let origin: URL
      let stamp: UUID?
      if remoteCacheNeedsDiscard { try discardRemoteCacheLocked() }
      if let identity = route.remote {
        do { stamp = try remoteAccess.credentialRevision(for: route) }
        catch RemoteDeviceAccess.Failure.frozen {
          if disabledReason != .deviceRemoved {
            try retireRemoteLocked(.deviceRemoved)
          }
          return false
        }
        if disabledReason == .deviceRemoved ||
            (disabledReason == .roleDowngraded && disabledCredentialRevision != stamp) {
          disabledReason = nil
          disabledCredentialRevision = nil
        }
        if disabledReason != nil { return false }
        if let active, active.credentialRevision != stamp {
          try retireRemoteLocked(.deviceRemoved)
          disabledReason = nil
        }
        localLink = nil
        let link = try RemoteDeviceLink.read(from: remoteAccess.dataDirectory, identity: identity)
        remoteLink = link
        origin = link.addresses.first ?? originProvider()
      } else {
        stamp = nil
        if disabledReason == .deviceRemoved || (!forActions && disabledReason != nil) { return false }
        guard let link = try files.collector() else { return false }
        localLink = link
        remoteLink = nil
        origin = originProvider()
      }
      if let current = active, current.localLink == localLink, current.remoteLink == remoteLink,
         current.origin == origin { return true }

      let id = UUID()
      let onWipe: @Sendable (ProjectionWipeReason) async -> Void = { [weak self] reason in
        await self?.handleWipe(reason, sessionID: id, route: route)
      }
      let onUpdate: @Sendable (ProjectionSyncResult) async -> Void = { [weak self] result in
        guard let self, await self.isCurrent(id, route: route) else { return }
        await self.onUpdateCallback?(result)
      }
      let newSync: ProjectionSync
      if let remoteLink {
        newSync = try remoteSessionFactory(route, remoteLink, origin, onWipe, onUpdate)
      } else if let localLink {
        newSync = try sessionFactory(localLink, origin, onWipe, onUpdate)
      } else {
        return false
      }
      let cached = CachedViewerDataSource(sync: newSync, httpFallback: route.remote == nil ? http : nil,
                                          includePrivate: true, calendar: calendar, clock: clock)
      let previous = active?.sync
      previous?.cache.retire()
      previous?.rawCache.retire()
      active = Session(id: id, route: route, localLink: localLink, remoteLink: remoteLink,
                       origin: origin, credentialRevision: stamp, sync: newSync, cached: cached)
      if disabledReason == nil {
        let pending = bindingTransition
        Task {
          await pending?.value
          await previous?.stop()
          let state: ProjectionSyncAppState = displayLock.withLock { foreground ? .foreground : .background }
          await newSync.setAppState(state)
          if await isCurrent(id, route: route) { await newSync.start() }
        }
      }
      return true
    } catch {
      return false
    }
  }

  private func isCurrent(_ id: UUID, route: HubBinding.Route) async -> Bool {
    await onBindingQueue { [self] in
      guard let active, active.id == id, (try? remoteAccess.route()) == route else { return false }
      if let stamp = active.credentialRevision {
        return (try? remoteAccess.credentialRevision(for: route)) == stamp
      }
      return true
    }
  }

  func setForeground(_ isForeground: Bool) {
    let sync = displayLock.withLock {
      foreground = isForeground
      return displayedSync
    }
    if let sync {
      Task { await sync.setAppState(isForeground ? .foreground : .background) }
    }
  }

  /// 锁屏、关窗时立即清空内存中的原文 LRU。
  func clearMemory() { activeSync?.rawCache.clear() }

  /// 本地写操作完成后清空查询内存缓存并主动拉取最新投影。
  func notifyLocalWrite() {
    guard let sync = activeSync else { return }
    sync.rawCache.clear()
    Task { _ = try? await sync.pullToLatest() }
  }

  func stop() {
    clearMemory()
    bindingQueue.async { [self] in
      let sync = active?.sync
      active = nil
      publishSync()
      if let sync {
        sync.rawCache.retire()
        sync.cache.retire()
        Task { await sync.stop() }
      }
    }
  }

  private func retireRemoteLocked(_ reason: ProjectionWipeReason) throws {
    let rejected = active?.sync
    disabledCredentialRevision = active?.credentialRevision
    disabledReason = reason
    remoteCacheNeedsDiscard = true
    active = nil
    rejected?.rawCache.retire()
    rejected?.cache.retire()
    publishSync()
    let pending = bindingTransition
    bindingTransition = Task { [onWipeCallback] in
      await pending?.value
      await rejected?.stop()
      await onWipeCallback?(reason)
    }
    try discardRemoteCacheLocked()
  }

  private func discardRemoteCacheLocked() throws {
    try ProjectionCache.discardPersisted(in: remoteAccess.dataDirectory, widgetSnapshotURL: widgetSnapshotURL)
    remoteCacheNeedsDiscard = false
  }

  private func handleWipe(_ reason: ProjectionWipeReason, sessionID: UUID, route: HubBinding.Route) async {
    let (notify, transition) = await onBindingQueue { [self] in
      defer { publishSync() }
      guard active?.id == sessionID, (try? remoteAccess.route()) == route else { return (false, nil as Task<Void, Never>?) }
      switch reason {
      case .deviceRemoved, .roleDowngraded:
        if route.remote != nil {
          try? retireRemoteLocked(reason)
          return (false, bindingTransition)
        }
        disabledReason = reason
        if reason == .deviceRemoved {
          active = nil
          try? files.removeCollector()
        }
      case .hubChanged, .serverReset:
        break
      }
      return (true, nil)
    }
    await transition?.value
    if notify { await onWipeCallback?(reason) }
  }

  private func resolve(forActions: Bool = false, on expected: HubBinding.Route? = nil) async throws -> (HubBinding.Route, Session?) {
    let (route, session, transition) = await onBindingQueue { [self] in
      defer { publishSync() }
      let route = refreshBindingLocked()
      var session: Session?
      if let route, active != nil || forActions || route != .local, activateLocked(route, forActions: forActions) {
        session = active
      }
      return (route, session, bindingTransition)
    }
    await transition?.value
    guard let route else { throw HubError.invalidBinding }
    if let expected, expected != route { throw CancellationError() }
    try check(route)
    return (route, session)
  }

  private func check(_ route: HubBinding.Route) throws {
    guard (try? remoteAccess.route()) == route else { throw CancellationError() }
  }

  func sendAction(op: String, body: [String: DeviceJSON], timeout: TimeInterval?,
                  on expected: HubBinding.Route? = nil) async throws -> DeviceResponsePayload? {
    let (route, session) = try await resolve(forActions: true, on: expected)
    guard let session else {
      if route.remote != nil { throw HubError.remoteUnavailable }
      do {
        let unavailable: Result<Bool, Error> = await onBindingQueue { [self] in
          Result { try files.collector() == nil || disabledReason == .deviceRemoved }
        }
        if try unavailable.get() { return nil }
      } catch {
        throw HubError(message: L10n.unreadableDeviceConnection, status: 0, kind: .deviceLink)
      }
      throw HubError(message: L10n.deviceConnectionUnavailable, status: 0, kind: .deviceLink)
    }
    do {
      let reply = try await session.sync.client.send(op: op, body: body, timeout: timeout)
      try check(route)
      guard await isCurrent(session.id, route: route) else { throw CancellationError() }
      return reply
    } catch let error as DeviceClientError {
      try check(route)
      switch error {
      case .deviceRemoved:
        do { try await session.sync.discardRemovedDevice() }
        catch {
          await session.sync.stop()
          session.sync.rawCache.clear()
          await handleWipe(.deviceRemoved, sessionID: session.id, route: route)
        }
        if route.remote == nil { return nil }
      default: break
      }
      throw Self.mapDeviceError(error)
    } catch RemoteDeviceAccess.Failure.frozen {
      throw HubError.remoteUnavailable
    }
  }

  private func discardRemoteSession(_ session: Session) async {
    do { try await session.sync.discardRemovedDevice() }
    catch { await handleWipe(.deviceRemoved, sessionID: session.id, route: session.route) }
  }

  private func route<T>(
    _ cacheOp: (CachedViewerDataSource) async throws -> T,
    fallback httpOp: (HTTPViewerDataSource) async throws -> T, requiresDirect: Bool = false
  ) async throws -> T {
    let (route, session) = try await resolve()
    func localFallback() async throws -> T {
      try check(route)
      guard route.remote == nil else { throw requiresDirect ? HubError.needsDirectHub : HubError.remoteUnavailable }
      let value = try await httpOp(http)
      try check(route)
      return value
    }
    guard let session else { return try await localFallback() }
    do {
      let value = try await cacheOp(session.cached)
      try check(route)
      guard await isCurrent(session.id, route: route) else { throw CancellationError() }
      return value
    } catch let error as DeviceClientError {
      try check(route)
      if route.remote != nil {
        switch error {
        case .deviceRemoved:
          await discardRemoteSession(session)
        case .transportError, .invalidKey, .keyStoreError:
          if requiresDirect { throw HubError.needsDirectHub }
        default: break
        }
        throw Self.mapDeviceError(error)
      }
      switch error {
      case .deviceRemoved:
        await handleWipe(.deviceRemoved, sessionID: session.id, route: route)
        return try await localFallback()
      case .operationError(_, 403, _):
        await handleWipe(.roleDowngraded, sessionID: session.id, route: route)
        return try await localFallback()
      default:
        if (try? session.sync.cache.cursor().epoch) == 0 { return try await localFallback() }
        throw Self.mapDeviceError(error)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HubError {
      throw error
    } catch RemoteDeviceAccess.Failure.frozen {
      throw HubError.remoteUnavailable
    } catch {
      try check(route)
      if route.remote == nil, (try? session.sync.cache.cursor().epoch) == 0 {
        return try await localFallback()
      }
      throw HubError(message: error.localizedDescription, status: 0)
    }
  }

  static func mapDeviceError(_ error: DeviceClientError) -> HubError {
    switch error {
    case .transportError(let msg):
      return HubError(message: L10n.unreachableService(msg), status: 0, kind: .unreachable)
    case .hubBusy(let msg):
      return HubError(message: msg ?? L10n.databaseBusyTryAgainShortly, status: 503)
    case .operationError(_, 403, let msg), .plaintextError(403, let msg):
      return HubError(message: msg ?? L10n.devicePermissionDenied, status: 403)
    case .operationError(_, let status, let msg), .plaintextError(let status, let msg):
      return HubError(message: msg ?? L10n.requestFailed(status), status: status)
    case .envelopeTooLarge(let msg):
      return HubError(message: msg ?? L10n.responseTooLarge, status: 413)
    case .deviceRemoved(let msg):
      return HubError(message: msg ?? L10n.requestFailed401, status: 401)
    default:
      return HubError(message: L10n.unreadableResponse, status: 0, kind: .badResponse)
    }
  }

  // MARK: - ViewerDataSource

  func diary(_ day: Date) async throws -> DayDiary? {
    try await route({ try await $0.diary(day) }, fallback: { try await $0.diary(day) })
  }

  func now() async throws -> NowState? {
    try await route({ try await $0.now() }, fallback: { try await $0.now() })
  }

  func projects() async throws -> [Project] {
    try await route({ try await $0.projects() }, fallback: { try await $0.projects() })
  }

  func project(_ id: String, level: String) async throws -> EntityDetail {
    try await route({ try await $0.project(id, level: level) }, fallback: { try await $0.project(id, level: level) })
  }

  func projectContext(_ id: String) async throws -> [HubThread] {
    try await route({ try await $0.projectContext(id) }, fallback: { try await $0.projectContext(id) })
  }

  func thread(_ id: String, level: String) async throws -> EntityDetail {
    try await route({ try await $0.thread(id, level: level) }, fallback: { try await $0.thread(id, level: level) })
  }

  func timeline(projectId: String?, threadId: String?, query: String?, before: String?) async throws -> HubAPI.TimelineResult {
    try await route(
      { try await $0.timeline(projectId: projectId, threadId: threadId, query: query, before: before) },
      fallback: { try await $0.timeline(projectId: projectId, threadId: threadId, query: query, before: before) }
    )
  }

  func timelineLocation(record id: String) async throws -> HubAPI.TimelineLocation {
    try await route({ try await $0.timelineLocation(record: id) }, fallback: { try await $0.timelineLocation(record: id) }, requiresDirect: true)
  }

  func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage {
    try await route({ try await $0.records(query, cursor: cursor) }, fallback: { try await $0.records(query, cursor: cursor) })
  }

  func day(_ day: Date) async throws -> [HistoryRecord] {
    try await route({ try await $0.day(day) }, fallback: { try await $0.day(day) }, requiresDirect: true)
  }

  func record(_ id: String) async throws -> RecordDetail {
    try await route({ try await $0.record(id) }, fallback: { try await $0.record(id) })
  }

  func recordsByIDs(_ ids: [String]) async throws -> [HistoryRecord] {
    try await route({ try await $0.recordsByIDs(ids) }, fallback: { try await $0.recordsByIDs(ids) })
  }

  func missingRecords(_ ids: [String], from available: [HistoryRecord]) async throws -> [HistoryRecord] {
    try await route(
      { try await $0.missingRecords(ids, from: available) },
      fallback: { try await $0.missingRecords(ids, from: available) }
    )
  }

  func segments(_ day: Date, device: String?) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    try await route({ try await $0.segments(day, device: device) }, fallback: { try await $0.segments(day, device: device) }, requiresDirect: true)
  }

  func conversation(_ recordID: String) async throws -> ConversationDetail {
    try await route({ try await $0.conversation(recordID) }, fallback: { try await $0.conversation(recordID) }, requiresDirect: true)
  }

  func cachedActiveDays(inMonth month: String) -> Set<String> {
    displayLock.withLock { displayedCached }?.cachedActiveDays(inMonth: month) ?? []
  }

  func activeDays(inMonth month: String, bypassCache: Bool) async throws -> ActiveDaysResult {
    try await route(
      { try await $0.activeDays(inMonth: month, bypassCache: bypassCache) },
      fallback: { try await $0.activeDays(inMonth: month, bypassCache: bypassCache) }
    )
  }
}
