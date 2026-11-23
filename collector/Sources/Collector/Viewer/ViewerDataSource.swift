import Foundation
import CollectorCore

/// 查看窗口与桌面小组件的统一读数据源抽象。
/// 写操作、设置页、待确认与排障接口仍直接走 HubAPI（HTTP）。
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
}

extension ViewerDataSource {
  func timeline(projectId: String? = nil, threadId: String? = nil, query: String? = nil, before: String? = nil) async throws -> HubAPI.TimelineResult {
    try await timeline(projectId: projectId, threadId: threadId, query: query, before: before)
  }

  func segments(_ day: Date) async throws -> (segments: [HistorySegment], conversations: [ConversationRef]) {
    try await segments(day, device: nil)
  }
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
}

// MARK: - 下推缓存 + 设备协议按需读路径实现

final class CachedViewerDataSource: ViewerDataSource, @unchecked Sendable {
  let sync: ProjectionSync
  private let httpFallback: HTTPViewerDataSource?
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
      let decoded = try HubJSON.decoder().decode(DayDiary.self, from: entity.payloadData)
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
    if level == "evidence", let httpFallback {
      return try await httpFallback.project(id, level: level)
    }
    try await ensureReady()
    guard let entity = try sync.cache.get(kind: .project, id: id) else {
      throw HubError(message: "内容不存在", status: 404)
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
    throw HubError(message: "内容不存在", status: 404)
  }

  func thread(_ id: String, level: String) async throws -> EntityDetail {
    if level == "evidence", let httpFallback {
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
    throw HubError(message: "内容不存在", status: 404)
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
    do {
      let payload = try await sync.timelineLocate(recordID: id)
      return try HubJSON.decoder().decode(HubAPI.TimelineLocation.self, from: payload.bodyData)
    } catch let error as DeviceClientError {
      // 中枢 timeline.locate 目前不支持 include_private，私密记录返回 404 时退回 HTTP。
      if case .operationError(_, 404, _) = error, includePrivate, let httpFallback {
        return try await httpFallback.timelineLocation(record: id)
      }
      throw error
    }
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
    if includePrivate { params["include_private"] = .bool(true) }

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
    let result = try await sync.getRecords(ids: [id], includeCorrections: true, includePrivate: includePrivate)
    guard let json = result.records[id] else {
      throw HubError(message: "记录不存在", status: 404)
    }
    if json.objectValue?["redacted_private"]?.boolValue == true {
      throw HubError(message: "记录不存在", status: 404)
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
      let batch = try await sync.getRecords(ids: chunk, includeCorrections: false, includePrivate: includePrivate)
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
    // 中枢 history.segments 设备操作目前硬编码过滤私密记录与私密对话，尚未支持 admin 的 include_private；
    // 为保证详细档不丢失私密内容，有本机 HTTP 回退时暂走 HTTP。
    if includePrivate, let httpFallback {
      return try await httpFallback.segments(day, device: device)
    }
    struct Wire: Decodable { let segments: [HistorySegment]; let conversations: [ConversationRef]? }
    let bounds = ViewerTime.dayQuery(day)
    let payload = try await sync.historySegments(from: bounds.from, to: bounds.to, device: device)
    let decoded = try HubJSON.decoder().decode(Wire.self, from: payload.bodyData)
    return (decoded.segments, decoded.conversations ?? [])
  }

  func conversation(_ recordID: String) async throws -> ConversationDetail {
    do {
      let payload = try await sync.conversationDetail(recordID: recordID)
      return try HubJSON.decoder().decode(ConversationDetail.self, from: payload.bodyData)
    } catch let error as DeviceClientError {
      // 中枢 conversations.detail 目前不支持 include_private，私密对话返回 404 时退回 HTTP。
      if case .operationError(_, 404, _) = error, includePrivate, let httpFallback {
        return try await httpFallback.conversation(recordID)
      }
      throw error
    }
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
    return false
  }
}

// MARK: - 自适应数据源路由器与同步生命周期

/// 有有效 collector-link.json 时自动启用本地下推缓存与设备协议，否则（或 401/被移除后）静默退回 HTTP。
final class AdaptiveViewerDataSource: ViewerDataSource, @unchecked Sendable {
  struct Session {
    let link: LocalDeviceLink
    let origin: URL
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
  private let originProvider: @Sendable () -> URL
  private let sessionFactory: SessionFactory
  private let calendar: Calendar
  private let clock: @Sendable () -> Date
  private let onUpdateCallback: (@Sendable (ProjectionSyncResult) async -> Void)?
  private let onWipeCallback: (@Sendable (ProjectionWipeReason) async -> Void)?

  private let lock = NSLock()
  private var active: Session?
  private var foreground = false
  private var disabledByRemoval = false

  var isUsingCache: Bool {
    lock.lock(); defer { lock.unlock() }
    return active != nil
  }

  var activeSync: ProjectionSync? {
    lock.lock(); defer { lock.unlock() }
    return active?.sync
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
    sessionFactory: SessionFactory? = nil
  ) {
    self.http = http
    let resolvedFiles = files ?? LocalDeviceLink.Files(directory: dataDir)
    self.files = resolvedFiles
    self.originProvider = originProvider
    self.calendar = calendar
    self.clock = clock
    self.onUpdateCallback = onUpdate
    self.onWipeCallback = onWipe
    self.sessionFactory = sessionFactory ?? { link, origin, handleWipe, handleUpdate in
      guard let rawKey = try keys.read(.mac) else {
        throw LocalDeviceLink.Failure.keyUnavailable
      }
      let transport = try DirectDeviceTransport(origin: origin, session: urlSession)
      let eventStream = try URLSessionProjectionEventStream(origin: origin, session: urlSession)
      let client = try DeviceClient(
        hubPublicKeyBase64URL: link.hub_pk,
        deviceID: link.device_id,
        keyStore: InMemoryDeviceKeyStore(rawRepresentation: rawKey),
        transport: transport,
        clock: clock
      )
      let cache = try ProjectionCache(
        dataDirectory: dataDir,
        widgetSnapshotURL: widgetSnapshotURL,
        keyProvider: cacheKeyProvider,
        clock: clock,
        calendar: calendar
      )
      return ProjectionSync(
        client: client,
        cache: cache,
        eventStream: eventStream,
        foregroundPollInterval: foregroundPollInterval,
        backgroundPollInterval: backgroundPollInterval,
        clock: clock,
        onWipe: handleWipe,
        onUpdate: handleUpdate
      )
    }
  }

  /// 本机登记完成后或应用启动时调用：读取 collector-link.json 并启动同步引擎。
  @discardableResult
  func activateIfLinked() -> Bool {
    let origin = originProvider()
    let link: LocalDeviceLink?
    do {
      link = try files.collector()
    } catch {
      return false
    }
    guard let link else { return false }

    let existingToStop: ProjectionSync?
    let newSync: ProjectionSync
    let isForeground: Bool
    do {
      lock.lock()
      if disabledByRemoval {
        lock.unlock()
        return false
      }
      if let current = active, current.link == link, current.origin == origin {
        lock.unlock()
        return true
      }
      isForeground = foreground
      existingToStop = active?.sync
      lock.unlock()

      newSync = try sessionFactory(
        link,
        origin,
        { [weak self] reason in await self?.handleWipe(reason) },
        { [weak self] result in await self?.onUpdateCallback?(result) }
      )
      let cached = CachedViewerDataSource(
        sync: newSync,
        httpFallback: http,
        includePrivate: true,
        calendar: calendar,
        clock: clock
      )
      let session = Session(link: link, origin: origin, sync: newSync, cached: cached)

      lock.lock()
      if disabledByRemoval {
        lock.unlock()
        return false
      }
      active = session
      lock.unlock()
    } catch {
      return false
    }

    Task {
      if let existingToStop { await existingToStop.stop() }
      await newSync.setAppState(isForeground ? .foreground : .background)
      await newSync.start()
    }
    return true
  }

  func setForeground(_ isForeground: Bool) {
    lock.lock()
    foreground = isForeground
    let sync = active?.sync
    lock.unlock()
    if let sync {
      Task { await sync.setAppState(isForeground ? .foreground : .background) }
    }
  }

  /// 锁屏、关窗时立即清空内存中的原文 LRU（同步执行，无竞态）。
  func clearMemory() {
    lock.lock()
    let sync = active?.sync
    lock.unlock()
    sync?.rawCache.clear()
  }

  /// 本地写操作完成后清空查询内存缓存并主动拉取最新投影。
  func notifyLocalWrite() {
    lock.lock()
    let sync = active?.sync
    lock.unlock()
    guard let sync else { return }
    sync.rawCache.clear()
    Task { _ = try? await sync.pullToLatest() }
  }

  func stop() {
    lock.lock()
    let sync = active?.sync
    active = nil
    lock.unlock()
    if let sync {
      sync.rawCache.clear()
      Task { await sync.stop() }
    }
  }

  private func deactivateForRemoval() {
    lock.lock()
    disabledByRemoval = true
    active = nil
    lock.unlock()
  }

  private func handleWipe(_ reason: ProjectionWipeReason) async {
    switch reason {
    case .deviceRemoved, .roleDowngraded:
      deactivateForRemoval()
      if reason == .deviceRemoved {
        try? files.removeCollector()
      }
    case .hubChanged, .serverReset:
      break
    }
    await onWipeCallback?(reason)
  }

  private func currentSession() -> Session? {
    let origin = originProvider()
    lock.lock()
    let current = active
    let disabled = disabledByRemoval
    lock.unlock()
    if disabled { return nil }
    if let current, current.origin == origin {
      return current
    }
    if current != nil {
      _ = activateIfLinked()
      lock.lock()
      defer { lock.unlock() }
      return active
    }
    return nil
  }

  private func route<T>(
    _ cacheOp: (CachedViewerDataSource) async throws -> T,
    fallback httpOp: (HTTPViewerDataSource) async throws -> T
  ) async throws -> T {
    guard let session = currentSession() else {
      return try await httpOp(http)
    }
    do {
      return try await cacheOp(session.cached)
    } catch let error as DeviceClientError {
      switch error {
      case .deviceRemoved:
        await handleWipe(.deviceRemoved)
        return try await httpOp(http)
      case .operationError(_, 403, _):
        await handleWipe(.roleDowngraded)
        return try await httpOp(http)
      default:
        // 冷缓存首次同步失败时（如旧版中枢或设备端口不可用），退回 HTTP。
        if (try? session.sync.cache.cursor().epoch) == 0 {
          return try await httpOp(http)
        }
        throw Self.mapDeviceError(error)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HubError {
      throw error
    } catch {
      if (try? session.sync.cache.cursor().epoch) == 0 {
        return try await httpOp(http)
      }
      throw HubError(message: error.localizedDescription, status: 0)
    }
  }

  static func mapDeviceError(_ error: DeviceClientError) -> HubError {
    switch error {
    case .transportError(let msg):
      return HubError(message: "连不上后台服务：\(msg)", status: 0)
    case .hubBusy(let msg):
      return HubError(message: msg ?? "数据库忙，稍后再试", status: 503)
    case .operationError(_, let status, let msg), .plaintextError(let status, let msg):
      return HubError(message: msg ?? "请求失败（\(status)）", status: status)
    case .envelopeTooLarge(let msg):
      return HubError(message: msg ?? "响应过大，请缩小查询范围", status: 413)
    case .deviceRemoved(let msg):
      return HubError(message: msg ?? "请求失败（401）", status: 401)
    default:
      return HubError(message: "后台服务返回的数据读不出来", status: 0)
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
    try await route({ try await $0.timelineLocation(record: id) }, fallback: { try await $0.timelineLocation(record: id) })
  }

  func records(_ query: HubAPI.RecordQuery, cursor: String?) async throws -> RecordPage {
    try await route({ try await $0.records(query, cursor: cursor) }, fallback: { try await $0.records(query, cursor: cursor) })
  }

  func day(_ day: Date) async throws -> [HistoryRecord] {
    try await route({ try await $0.day(day) }, fallback: { try await $0.day(day) })
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
    try await route({ try await $0.segments(day, device: device) }, fallback: { try await $0.segments(day, device: device) })
  }

  func conversation(_ recordID: String) async throws -> ConversationDetail {
    try await route({ try await $0.conversation(recordID) }, fallback: { try await $0.conversation(recordID) })
  }
}
