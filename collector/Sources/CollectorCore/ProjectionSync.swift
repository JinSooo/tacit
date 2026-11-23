import CryptoKit
import Foundation

// MARK: - 内存原文 LRU 缓存（6.9.6：上限 50 MiB 或 200 条、闲置 10 分钟过期、不落盘）

/// 按需读取原文（`records.get` 等）的内存 LRU 缓存，不落盘。
public final class RawReadMemoryCache: @unchecked Sendable {
  public static let defaultMaxBytes = 50 * 1024 * 1024
  public static let defaultMaxEntries = 200
  public static let defaultIdleTTL: TimeInterval = 10 * 60

  private final class Node {
    let key: String
    var data: Data
    var recordIDs: Set<String>
    var invalidateOnAnyRecordGone: Bool
    var lastAccessedAt: Date
    var prev: Node?
    var next: Node?

    init(
      key: String,
      data: Data,
      recordIDs: Set<String>,
      invalidateOnAnyRecordGone: Bool,
      lastAccessedAt: Date
    ) {
      self.key = key
      self.data = data
      self.recordIDs = recordIDs
      self.invalidateOnAnyRecordGone = invalidateOnAnyRecordGone
      self.lastAccessedAt = lastAccessedAt
    }
  }

  public let maxBytes: Int
  public let maxEntries: Int
  public let idleTTL: TimeInterval

  private let clock: @Sendable () -> Date
  private let lock = NSLock()
  private var map: [String: Node] = [:]
  private var head: Node? // MRU
  private var tail: Node? // LRU
  private var currentBytes: Int = 0

  public init(
    maxBytes: Int = RawReadMemoryCache.defaultMaxBytes,
    maxEntries: Int = RawReadMemoryCache.defaultMaxEntries,
    idleTTL: TimeInterval = RawReadMemoryCache.defaultIdleTTL,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.maxBytes = max(1, maxBytes)
    self.maxEntries = max(1, maxEntries)
    self.idleTTL = max(0, idleTTL)
    self.clock = clock
  }

  public var count: Int {
    lock.lock(); defer { lock.unlock() }
    purgeExpiredLocked(now: clock())
    return map.count
  }

  public var totalBytes: Int {
    lock.lock(); defer { lock.unlock() }
    purgeExpiredLocked(now: clock())
    return currentBytes
  }

  public func get(_ key: String) -> Data? {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    purgeExpiredLocked(now: now)
    guard let node = map[key] else { return nil }
    node.lastAccessedAt = now
    moveToHeadLocked(node)
    return node.data
  }

  /// 写入缓存。单条超过 `maxBytes` 时不写入（并移除旧值）。
  public func set(
    _ key: String,
    data: Data,
    recordIDs: Set<String> = [],
    invalidateOnAnyRecordGone: Bool = false
  ) {
    lock.lock(); defer { lock.unlock() }
    let now = clock()
    purgeExpiredLocked(now: now)

    if let existing = map[key] {
      removeNodeLocked(existing)
    }
    guard data.count <= maxBytes else { return }

    let node = Node(
      key: key,
      data: data,
      recordIDs: recordIDs,
      invalidateOnAnyRecordGone: invalidateOnAnyRecordGone,
      lastAccessedAt: now
    )
    insertAtHeadLocked(node)
    evictOverflowLocked()
  }

  /// 收到 `record_gone` 时清除受影响的缓存项（含对应单条记录及受影响的列表/查询）。
  public func evict(recordIDs goneIDs: [String]) {
    guard !goneIDs.isEmpty else { return }
    let goneSet = Set(goneIDs)
    lock.lock(); defer { lock.unlock() }
    let toRemove = map.values.filter { node in
      node.invalidateOnAnyRecordGone || goneSet.contains(node.key) || !node.recordIDs.isDisjoint(with: goneSet)
    }
    for node in toRemove {
      removeNodeLocked(node)
    }
  }

  /// 清空全部内存缓存（锁屏、关窗、设备移除或重置时调用）。
  public func clear() {
    lock.lock(); defer { lock.unlock() }
    map.removeAll()
    head = nil
    tail = nil
    currentBytes = 0
  }

  private func purgeExpiredLocked(now: Date) {
    while let node = tail {
      if now.timeIntervalSince(node.lastAccessedAt) >= idleTTL {
        removeNodeLocked(node)
      } else {
        break
      }
    }
  }

  private func evictOverflowLocked() {
    while map.count > maxEntries || currentBytes > maxBytes {
      guard let oldest = tail else { break }
      removeNodeLocked(oldest)
    }
  }

  private func insertAtHeadLocked(_ node: Node) {
    map[node.key] = node
    currentBytes += node.data.count
    node.prev = nil
    node.next = head
    head?.prev = node
    head = node
    if tail == nil { tail = node }
  }

  private func moveToHeadLocked(_ node: Node) {
    guard head !== node else { return }
    node.prev?.next = node.next
    node.next?.prev = node.prev
    if tail === node { tail = node.prev }
    node.prev = nil
    node.next = head
    head?.prev = node
    head = node
  }

  private func removeNodeLocked(_ node: Node) {
    map.removeValue(forKey: node.key)
    currentBytes -= node.data.count
    node.prev?.next = node.next
    node.next?.prev = node.prev
    if head === node { head = node.next }
    if tail === node { tail = node.prev }
    node.prev = nil
    node.next = nil
  }
}

// MARK: - 实时事件流（直连 `/v1/device/events`）

/// 中枢经 `/v1/device/events` 推送的轻量变更通知（6.9.5）。
public struct ProjectionEvent: Codable, Equatable, Sendable {
  public let seq: Int64
  public let epoch: Int64
  public let urgent: Bool

  public init(seq: Int64, epoch: Int64, urgent: Bool) {
    self.seq = seq
    self.epoch = epoch
    self.urgent = urgent
  }
}

/// 可注入的事件流传输层，便于在单测中模拟连接成功、断线降级与 1008 移除。
public protocol ProjectionEventStream: Sendable {
  /// 使用首帧鉴权信封建立订阅，返回推送事件流；连接断开或失败时流抛出错误结束。
  func subscribe(authEnvelope: Data) async throws -> AsyncThrowingStream<ProjectionEvent, Error>
}

/// 基于 `URLSessionWebSocketTask` 的直连事件流（`GET /v1/device/events`）。
public struct URLSessionProjectionEventStream: ProjectionEventStream, Sendable {
  public let origin: URL
  private let session: URLSession

  private static let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    return URLSession(configuration: config)
  }()

  public init(origin: URL, session: URLSession? = nil) throws {
    guard let normalized = DevicePairingInvitation.normalizeOrigin(origin.absoluteString) else {
      throw DeviceClientError.invalidRequest("中枢直连地址无效")
    }
    self.origin = normalized
    self.session = session ?? Self.sharedSession
  }

  public func subscribe(authEnvelope: Data) async throws -> AsyncThrowingStream<ProjectionEvent, Error> {
    guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
      throw DeviceClientError.invalidRequest("无法构造事件流地址")
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/device/events"
    guard let wsURL = components.url,
          let authText = String(data: authEnvelope, encoding: .utf8) else {
      throw DeviceClientError.invalidRequest("事件流鉴权帧无效")
    }

    let task = session.webSocketTask(with: wsURL)
    task.resume()
    do {
      try await task.send(.string(authText))
    } catch {
      task.cancel(with: .goingAway, reason: nil)
      throw DeviceClientError.transportError("事件流鉴权发送失败：\(error.localizedDescription)")
    }

    return AsyncThrowingStream { continuation in
      let reader = Task {
        let decoder = JSONDecoder()
        do {
          while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let text):
              data = Data(text.utf8)
            case .data(let raw):
              data = raw
            @unknown default:
              continue
            }
            if let event = try? decoder.decode(ProjectionEvent.self, from: data) {
              continuation.yield(event)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        reader.cancel()
        task.cancel(with: .normalClosure, reason: nil)
      }
    }
  }
}

// MARK: - 中转信箱 `down` 下推消息与传输（6.8 / 6.9.5）

/// 中转信箱 `down` 中的 `projection.delta` 明文。
public struct ProjectionRelayDelta: Codable, Equatable, Sendable {
  public let epoch: Int64
  public let fromSeq: Int64
  public let toSeq: Int64
  public let changes: [ProjectionChange]
  public let more: Bool

  private enum CodingKeys: String, CodingKey {
    case epoch
    case fromSeq = "from_seq"
    case toSeq = "to_seq"
    case changes
    case more
  }

  public init(epoch: Int64, fromSeq: Int64, toSeq: Int64, changes: [ProjectionChange], more: Bool) {
    self.epoch = epoch
    self.fromSeq = fromSeq
    self.toSeq = toSeq
    self.changes = changes
    self.more = more
  }
}

/// 中转信箱 `down` 中的 `projection.invalidate` 明文。
public struct ProjectionRelayInvalidate: Codable, Equatable, Sendable {
  public let epoch: Int64
  public let toSeq: Int64
  public let items: [ProjectionInvalidateItem]

  private enum CodingKeys: String, CodingKey {
    case epoch
    case toSeq = "to_seq"
    case items
  }

  public init(epoch: Int64, toSeq: Int64, items: [ProjectionInvalidateItem]) {
    self.epoch = epoch
    self.toSeq = toSeq
    self.items = items
  }
}

/// 中转信箱 `down` 中的 `projection.hint` 明文。
public struct ProjectionRelayHint: Codable, Equatable, Sendable {
  public let epoch: Int64
  public let latestSeq: Int64

  private enum CodingKeys: String, CodingKey {
    case epoch
    case latestSeq = "latest_seq"
  }

  public init(epoch: Int64, latestSeq: Int64) {
    self.epoch = epoch
    self.latestSeq = latestSeq
  }
}

/// 信箱 `down` 里的中枢主动推送消息类型（6.8.7 / 6.9.5）。
public enum RelayPushMessage: Equatable, Sendable {
  case delta(ProjectionRelayDelta)
  case invalidate(ProjectionRelayInvalidate)
  case hint(ProjectionRelayHint)
  case reset(epoch: Int64)
  case relayMoved(DeviceRelayConfig?)
  case unknown(kind: String)

  private struct KindProbe: Decodable {
    let kind: String
  }

  private struct ResetWire: Decodable {
    let epoch: Int64
  }

  private struct MovedWire: Decodable {
    let relay: DeviceRelayConfig?
  }

  public static func decode(from plaintext: Data) throws -> RelayPushMessage {
    let decoder = JSONDecoder()
    let probe = try decoder.decode(KindProbe.self, from: plaintext)
    switch probe.kind {
    case "projection.delta":
      return .delta(try decoder.decode(ProjectionRelayDelta.self, from: plaintext))
    case "projection.invalidate":
      return .invalidate(try decoder.decode(ProjectionRelayInvalidate.self, from: plaintext))
    case "projection.hint":
      return .hint(try decoder.decode(ProjectionRelayHint.self, from: plaintext))
    case "projection.reset":
      let wire = try decoder.decode(ResetWire.self, from: plaintext)
      return .reset(epoch: wire.epoch)
    case "relay.moved":
      let wire = try decoder.decode(MovedWire.self, from: plaintext)
      return .relayMoved(wire.relay)
    default:
      return .unknown(kind: probe.kind)
    }
  }
}

/// 信箱单条消息摘要。
public struct RelayMessageMeta: Codable, Equatable, Sendable {
  public let id: String
  public let size: Int
  public let cursor: String?

  public init(id: String, size: Int, cursor: String? = nil) {
    self.id = id
    self.size = size
    self.cursor = cursor
  }
}

public enum RelayMailboxError: Error, Equatable, Sendable {
  case unauthorized(status: Int)
  case rateLimited(status: Int)
  case notFound
  case httpError(status: Int)
  case transportError(String)
  case invalidResponse
}

/// 可注入的中转信箱客户端协议（6.8.3）。
public protocol RelayMailboxClient: Sendable {
  func listDownMessages(after: String?, limit: Int) async throws -> (messages: [RelayMessageMeta], next: String?)
  func getDownMessage(id: String) async throws -> Data
  func deleteDownMessage(id: String) async throws
  func putUpMessage(id: String, data: Data) async throws
}

/// 标准 HTTP 中转信箱客户端（对应 6.8.3 接口）。
public struct HTTPRelayMailboxClient: RelayMailboxClient, Sendable {
  public let config: DeviceRelayConfig
  public let requestTimeout: TimeInterval
  private let session: URLSession

  private static let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    return URLSession(configuration: config)
  }()

  private struct ListResponse: Decodable {
    let messages: [RelayMessageMeta]
    let next: String?
  }

  public init(config: DeviceRelayConfig, session: URLSession? = nil, requestTimeout: TimeInterval = 20) {
    self.config = config
    self.session = session ?? Self.sharedSession
    self.requestTimeout = requestTimeout
  }

  public func listDownMessages(after: String? = nil, limit: Int = 100) async throws -> (messages: [RelayMessageMeta], next: String?) {
    let clamped = max(1, min(100, limit))
    var query = "limit=\(clamped)"
    if let after { query = "after=\(after)&\(query)" }
    guard let url = URL(string: "\(config.url)/v1/spaces/\(config.space)/boxes/\(config.down)/messages?\(query)") else {
      throw RelayMailboxError.invalidResponse
    }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    req.httpMethod = "GET"
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let (data, status) = try await perform(req)
    guard status == 200 else { throw classify(status) }
    do {
      let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
      return (decoded.messages, decoded.next)
    } catch {
      throw RelayMailboxError.invalidResponse
    }
  }

  public func getDownMessage(id: String) async throws -> Data {
    guard let url = URL(string: "\(config.url)/v1/spaces/\(config.space)/boxes/\(config.down)/messages/\(id)") else {
      throw RelayMailboxError.invalidResponse
    }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    req.httpMethod = "GET"
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let (data, status) = try await perform(req)
    guard status == 200 else { throw classify(status) }
    return data
  }

  public func deleteDownMessage(id: String) async throws {
    guard let url = URL(string: "\(config.url)/v1/spaces/\(config.space)/boxes/\(config.down)/messages/\(id)") else {
      throw RelayMailboxError.invalidResponse
    }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let (_, status) = try await perform(req)
    guard status == 200 || status == 204 || status == 404 else { throw classify(status) }
  }

  public func putUpMessage(id: String, data: Data) async throws {
    guard let url = URL(string: "\(config.url)/v1/spaces/\(config.space)/boxes/\(config.up)/messages/\(id)") else {
      throw RelayMailboxError.invalidResponse
    }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    req.httpMethod = "PUT"
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    let (_, status) = try await perform(req)
    guard status == 200 || status == 201 else { throw classify(status) }
  }

  private func perform(_ request: URLRequest) async throws -> (Data, Int) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw RelayMailboxError.transportError(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw RelayMailboxError.invalidResponse
    }
    return (data, http.statusCode)
  }

  private func classify(_ status: Int) -> RelayMailboxError {
    switch status {
    case 401, 403: return .unauthorized(status: status)
    case 404: return .notFound
    case 429, 507: return .rateLimited(status: status)
    default: return .httpError(status: status)
    }
  }
}

/// 经中转信箱收发的 `DeviceTransport` 实现（6.8.5 / 6.9.3，单条上限 1 MiB，默认等待回复 20 秒）。
public struct RelayDeviceTransport: DeviceTransport, Sendable {
  public static let maxRelayEnvelopeBytes = 1024 * 1024

  public let maxEnvelopeBytes: Int
  public let replyTimeout: TimeInterval
  public let pollInterval: TimeInterval
  private let mailbox: any RelayMailboxClient

  public init(
    mailbox: any RelayMailboxClient,
    replyTimeout: TimeInterval = 20,
    pollInterval: TimeInterval = 0.25,
    maxEnvelopeBytes: Int = RelayDeviceTransport.maxRelayEnvelopeBytes
  ) {
    self.mailbox = mailbox
    self.replyTimeout = replyTimeout
    self.pollInterval = pollInterval
    self.maxEnvelopeBytes = maxEnvelopeBytes
  }

  public func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
    if request.wireData.count > maxEnvelopeBytes {
      throw DeviceClientError.envelopeTooLarge(message: nil)
    }
    do {
      try await mailbox.putUpMessage(id: request.nonce, data: request.wireData)
    } catch {
      throw DeviceClientError.transportError("信箱发送失败：\(error)")
    }
    let deadline = Date().addingTimeInterval(replyTimeout)
    while Date() < deadline {
      do {
        let data = try await mailbox.getDownMessage(id: request.nonce)
        try? await mailbox.deleteDownMessage(id: request.nonce)
        return DeviceTransportResponse(statusCode: 200, body: data)
      } catch RelayMailboxError.notFound {
        try await Task.sleep(nanoseconds: UInt64(max(0.02, pollInterval) * 1_000_000_000))
      } catch {
        throw DeviceClientError.transportError("信箱等待回复失败：\(error)")
      }
    }
    throw DeviceClientError.transportError("等待信箱回复超时")
  }
}

// MARK: - 6.10.2 连接选择顺序

/// 6.10.2 规定的连接端点选择结果。
public enum SelectedHubEndpoint: Equatable, Sendable {
  case localFastPath(URL)
  case direct(URL)
  case relay(DeviceRelayConfig)
}

/// 按 6.10.2 顺序挑选可达的中枢连接：本机快路 → 上次成功地址 → 邀请地址 → Bonjour 地址 → 手填地址 → 信箱。
public enum ProjectionEndpointSelector {
  public static func select(
    localPort: Int?,
    lastSuccessful: URL? = nil,
    inviteAddresses: [URL] = [],
    bonjourAddresses: [URL] = [],
    manualAddresses: [URL] = [],
    relay: DeviceRelayConfig? = nil,
    expectedHubID: String,
    probe: @Sendable (URL, String) async -> Bool
  ) async -> SelectedHubEndpoint? {
    if let localPort, (1...65535).contains(localPort),
       let loopback = URL(string: "http://127.0.0.1:\(localPort)") {
      if await probe(loopback, expectedHubID) {
        return .localFastPath(loopback)
      }
    }
    var seen = Set<String>()
    var candidates: [URL] = []
    for raw in [lastSuccessful].compactMap({ $0 }) + inviteAddresses + bonjourAddresses + manualAddresses {
      if let normalized = DevicePairingInvitation.normalizeOrigin(raw.absoluteString),
         seen.insert(normalized.absoluteString).inserted {
        candidates.append(normalized)
      }
    }
    for candidate in candidates {
      if await probe(candidate, expectedHubID) {
        return .direct(candidate)
      }
    }
    if let relay {
      return .relay(relay)
    }
    return nil
  }
}

// MARK: - 同步引擎（ProjectionSync）

/// 前后台状态（由调用方通知）：前台 30 秒轮询，后台 5 分钟轮询。
public enum ProjectionSyncAppState: Equatable, Sendable {
  case foreground
  case background
}

/// 一次拉取循环的汇总结果。
public struct ProjectionSyncResult: Equatable, Sendable {
  public let pagesFetched: Int
  public let upsertedCount: Int
  public let deletedCount: Int
  public let goneRecordIDs: [String]
  public let cursor: ProjectionCursor
  public let didReset: Bool

  public init(
    pagesFetched: Int,
    upsertedCount: Int,
    deletedCount: Int,
    goneRecordIDs: [String],
    cursor: ProjectionCursor,
    didReset: Bool
  ) {
    self.pagesFetched = pagesFetched
    self.upsertedCount = upsertedCount
    self.deletedCount = deletedCount
    self.goneRecordIDs = goneRecordIDs
    self.cursor = cursor
    self.didReset = didReset
  }
}

/// 单条信箱推送消息的处理结果。
public enum RelayPushOutcome: Equatable, Sendable {
  case appliedDelta(ProjectionApplyResult, followedUpPull: ProjectionSyncResult?)
  case pulledForGap(ProjectionSyncResult)
  case invalidated(ProjectionApplyResult, followedUpPull: ProjectionSyncResult?)
  case pulledFromHint(ProjectionSyncResult?)
  case resetAndPulled(ProjectionSyncResult)
  case relayMoved(DeviceRelayConfig?)
  case ignored
}

/// 一轮信箱 `down` 扫描结果。
public struct RelayDownPollResult: Equatable, Sendable {
  public let processedMessages: Int
  public let outcomes: [RelayPushOutcome]
  public let relayDisabled: Bool

  public init(processedMessages: Int, outcomes: [RelayPushOutcome], relayDisabled: Bool) {
    self.processedMessages = processedMessages
    self.outcomes = outcomes
    self.relayDisabled = relayDisabled
  }
}

/// `records.get` 拼接多页后的结果。
public struct RawRecordsGetResult: Equatable, Sendable {
  public let records: [String: DeviceJSON]
  public let missing: [String]

  public init(records: [String: DeviceJSON], missing: [String]) {
    self.records = records
    self.missing = missing
  }
}

/// 同步触发清空时的原因。
public enum ProjectionWipeReason: Equatable, Sendable {
  case deviceRemoved
  case roleDowngraded
  case hubChanged(expected: String, actual: String)
  case serverReset(newEpoch: Int64)
}

private struct AckReply: Decodable {
  let ok: Bool
}

private struct RecordsGetPageWire: Decodable {
  let records: [DeviceJSON]
  let missing: [String]
  let next_cursor: String?
}

/// Mac 查看端同步引擎：驱动 `projection.pull` / `projection.ack`、`/v1/device/events` 订阅、轮询退避、信箱 `down` 处理与按需原文内存 LRU。
public actor ProjectionSync {
  public static let defaultForegroundPollInterval: TimeInterval = 30
  public static let defaultBackgroundPollInterval: TimeInterval = 5 * 60

  public nonisolated let client: DeviceClient
  public nonisolated let cache: ProjectionCache
  public nonisolated let rawCache: RawReadMemoryCache
  public nonisolated let foregroundPollInterval: TimeInterval
  public nonisolated let backgroundPollInterval: TimeInterval
  public nonisolated let pullLimit: Int
  public nonisolated let windowDays: Int

  public private(set) var appState: ProjectionSyncAppState = .foreground
  public private(set) var isUsingEventStream: Bool = false
  public private(set) var isRelayDisabled: Bool = false

  private let eventStream: (any ProjectionEventStream)?
  private let relayMailbox: (any RelayMailboxClient)?
  private let clock: @Sendable () -> Date
  private let onWipe: (@Sendable (ProjectionWipeReason) async -> Void)?
  private let onRelayMoved: (@Sendable (DeviceRelayConfig?) async -> Void)?
  private var loopTask: Task<Void, Never>?
  private var sleepWakeTask: Task<Void, Never>?
  private var sleepContinuation: CheckedContinuation<Void, Never>?

  public init(
    client: DeviceClient,
    cache: ProjectionCache,
    rawCache: RawReadMemoryCache = RawReadMemoryCache(),
    eventStream: (any ProjectionEventStream)? = nil,
    relayMailbox: (any RelayMailboxClient)? = nil,
    foregroundPollInterval: TimeInterval = ProjectionSync.defaultForegroundPollInterval,
    backgroundPollInterval: TimeInterval = ProjectionSync.defaultBackgroundPollInterval,
    pullLimit: Int = 50,
    windowDays: Int = 90,
    clock: @escaping @Sendable () -> Date = { Date() },
    onWipe: (@Sendable (ProjectionWipeReason) async -> Void)? = nil,
    onRelayMoved: (@Sendable (DeviceRelayConfig?) async -> Void)? = nil
  ) {
    self.client = client
    self.cache = cache
    self.rawCache = rawCache
    self.eventStream = eventStream
    self.relayMailbox = relayMailbox
    self.foregroundPollInterval = max(0.05, foregroundPollInterval)
    self.backgroundPollInterval = max(0.05, backgroundPollInterval)
    self.pullLimit = max(1, min(200, pullLimit))
    self.windowDays = max(1, min(365, windowDays))
    self.clock = clock
    self.onWipe = onWipe
    self.onRelayMoved = onRelayMoved
  }

  /// 当前有效的轮询间隔（前台 30 秒，后台 5 分钟）。
  public var currentPollInterval: TimeInterval {
    appState == .foreground ? foregroundPollInterval : backgroundPollInterval
  }

  /// 调用方告知前后台切换；切回前台时立即唤醒等待中的轮询定时器。
  public func setAppState(_ newState: ProjectionSyncAppState) {
    let previous = appState
    appState = newState
    if previous != newState && newState == .foreground {
      wakeSleep()
    }
  }

  /// 清空按需原文内存 LRU（锁屏或关闭窗口时调用）。
  public func clearMemory() {
    rawCache.clear()
  }

  /// 核对当前中枢 `hub_id`；若检测到变化则整库 `wipe()` 并清空内存缓存。
  @discardableResult
  public func verifyHubIdentity(_ observedHubID: String? = nil) async throws -> Bool {
    if let observedHubID, observedHubID != client.hubID {
      try await wipeAll(reason: .hubChanged(expected: client.hubID, actual: observedHubID))
      return true
    }
    let wiped = try cache.ensureHubID(client.hubID)
    if wiped {
      rawCache.clear()
      await onWipe?(.hubChanged(expected: client.hubID, actual: client.hubID))
    }
    return wiped
  }

  // MARK: - 拉取循环（projection.pull -> 写缓存 -> projection.ack）

  /// 执行一轮完整拉取直到 `more == false`，每页落盘后立即确认 `projection.ack`。
  @discardableResult
  public func pullToLatest(maxPages: Int = 500) async throws -> ProjectionSyncResult {
    _ = try await verifyHubIdentity()

    var pagesFetched = 0
    var totalUpserted = 0
    var totalDeleted = 0
    var allGone: [String] = []
    var didReset = false
    var resetRetries = 0
    var conflictRetries = 0

    while pagesFetched < maxPages {
      let current = try cache.cursor()
      var body: [String: DeviceJSON] = [
        "cursor": .int(current.seq),
        "limit": .int(Int64(pullLimit)),
      ]
      if current.epoch > 0 {
        body["epoch"] = .int(current.epoch)
      }
      if current.seq == 0 {
        body["window_days"] = .int(Int64(windowDays))
      }

      let page: ProjectionPage
      do {
        page = try await client.send(op: "projection.pull", body: body, as: ProjectionPage.self)
      } catch let error as DeviceClientError {
        if try await handleClientError(error, conflictRetries: &conflictRetries) {
          continue
        }
        throw error
      }
      conflictRetries = 0

      if page.reset {
        didReset = true
        resetRetries += 1
        guard resetRetries <= 3 else {
          throw DeviceClientError.operationError(op: "projection.pull", status: 409, message: "同步窗口连续重置")
        }
        try await wipeForReset(newEpoch: page.epoch)
        continue
      }

      let applied = try cache.applyPage(page, hubID: client.hubID, now: clock())
      if applied.wasReset {
        didReset = true
        rawCache.clear()
        resetRetries += 1
        guard resetRetries <= 3 else {
          throw DeviceClientError.operationError(op: "projection.pull", status: 409, message: "同步世代连续变化")
        }
        continue
      }

      pagesFetched += 1
      totalUpserted += applied.upsertedCount
      totalDeleted += applied.deletedCount
      if !applied.goneRecordIDs.isEmpty {
        rawCache.evict(recordIDs: applied.goneRecordIDs)
        allGone.append(contentsOf: applied.goneRecordIDs)
      }

      // 落盘后再发送 projection.ack。
      do {
        _ = try await client.send(
          op: "projection.ack",
          body: [
            "epoch": .int(applied.cursor.epoch),
            "cursor": .int(applied.cursor.seq),
          ],
          as: AckReply.self
        )
      } catch let error as DeviceClientError {
        if case .deviceRemoved = error {
          try await wipeAll(reason: .deviceRemoved)
          throw error
        }
        if case .operationError(_, status: 403, _) = error {
          try await wipeAll(reason: .roleDowngraded)
          throw error
        }
        if case .operationError(_, status: 409, _) = error {
          // 确认期间世代已切换，重跑拉取拿到 reset。
          conflictRetries += 1
          if conflictRetries <= 3 { continue }
        }
        throw error
      }

      if !page.more {
        break
      }
    }

    _ = try cache.prune(now: clock())
    let finalCursor = try cache.cursor()
    return ProjectionSyncResult(
      pagesFetched: pagesFetched,
      upsertedCount: totalUpserted,
      deletedCount: totalDeleted,
      goneRecordIDs: allGone,
      cursor: finalCursor,
      didReset: didReset
    )
  }

  /// 处理单条 WebSocket 推送事件：若世代变化、序号推进或标记紧急，立即触发拉取。
  @discardableResult
  public func handleEvent(_ event: ProjectionEvent) async throws -> ProjectionSyncResult? {
    let current = try cache.cursor()
    if event.urgent || event.epoch != current.epoch || event.seq > current.seq {
      return try await pullToLatest()
    }
    return nil
  }

  // MARK: - 信箱 `down` 处理（6.9.5）

  /// 读取并处理中转信箱 `down` 中全部待处理的主动推送消息，处理后逐条删除。
  @discardableResult
  public func pollRelayDown() async throws -> RelayDownPollResult {
    guard let relayMailbox, !isRelayDisabled else {
      return RelayDownPollResult(processedMessages: 0, outcomes: [], relayDisabled: isRelayDisabled)
    }
    _ = try await verifyHubIdentity()

    var after: String? = nil
    var processed = 0
    var outcomes: [RelayPushOutcome] = []

    while true {
      let page: (messages: [RelayMessageMeta], next: String?)
      do {
        page = try await relayMailbox.listDownMessages(after: after, limit: 100)
      } catch RelayMailboxError.unauthorized {
        // 6.8.6：信箱返回 401/403 时停用信箱。
        isRelayDisabled = true
        return RelayDownPollResult(processedMessages: processed, outcomes: outcomes, relayDisabled: true)
      }

      for message in page.messages {
        let wireData: Data
        do {
          wireData = try await relayMailbox.getDownMessage(id: message.id)
        } catch RelayMailboxError.notFound {
          continue
        } catch RelayMailboxError.unauthorized {
          isRelayDisabled = true
          return RelayDownPollResult(processedMessages: processed, outcomes: outcomes, relayDisabled: true)
        }

        var outcome: RelayPushOutcome = .ignored
        if let plaintext = try? await client.openPushEnvelope(wireData: wireData, messageID: message.id),
           let push = try? RelayPushMessage.decode(from: plaintext) {
          outcome = try await handleRelayPush(push)
        }
        outcomes.append(outcome)
        processed += 1
        try? await relayMailbox.deleteDownMessage(id: message.id)
      }

      guard let next = page.next, !page.messages.isEmpty else { break }
      after = next
    }

    return RelayDownPollResult(processedMessages: processed, outcomes: outcomes, relayDisabled: isRelayDisabled)
  }

  /// 按 6.9.5 处理单条已解密的信箱主动推送消息。
  @discardableResult
  public func handleRelayPush(_ push: RelayPushMessage) async throws -> RelayPushOutcome {
    _ = try await verifyHubIdentity()

    switch push {
    case .delta(let delta):
      let current = try cache.cursor()
      if current.epoch != 0 && delta.epoch != current.epoch {
        try await wipeForReset(newEpoch: delta.epoch)
        let pulled = try await pullToLatest()
        return .resetAndPulled(pulled)
      }
      if delta.toSeq <= current.seq && current.epoch == delta.epoch {
        return .ignored
      }
      if delta.fromSeq > current.seq {
        // 中间有缺口，不跳游标，主动从原游标拉取补齐。
        let pulled = try await pullToLatest()
        return .pulledForGap(pulled)
      }
      let filtered = delta.changes.filter { $0.seq > current.seq }
      let applied = try cache.applyChanges(
        filtered,
        epoch: delta.epoch,
        cursorSeq: delta.toSeq,
        hubID: client.hubID,
        now: clock()
      )
      if !applied.goneRecordIDs.isEmpty {
        rawCache.evict(recordIDs: applied.goneRecordIDs)
      }
      do {
        _ = try await client.send(
          op: "projection.ack",
          body: [
            "epoch": .int(delta.epoch),
            "cursor": .int(delta.toSeq),
          ],
          as: AckReply.self
        )
      } catch let error as DeviceClientError {
        if case .deviceRemoved = error {
          try await wipeAll(reason: .deviceRemoved)
          throw error
        }
        if case .operationError(_, status: 403, _) = error {
          try await wipeAll(reason: .roleDowngraded)
          throw error
        }
      }
      var followUp: ProjectionSyncResult? = nil
      if delta.more {
        followUp = try await pullToLatest()
      } else {
        _ = try cache.prune(now: clock())
      }
      return .appliedDelta(applied, followedUpPull: followUp)

    case .invalidate(let inv):
      let applied = try cache.applyInvalidate(epoch: inv.epoch, items: inv.items, now: clock())
      if applied.wasReset {
        rawCache.clear()
        let pulled = try await pullToLatest()
        return .resetAndPulled(pulled)
      }
      if !applied.goneRecordIDs.isEmpty {
        rawCache.evict(recordIDs: applied.goneRecordIDs)
      }
      // 6.9.4：按列表清除缓存后，以原拉取游标续拉。
      let followUp = try await pullToLatest()
      return .invalidated(applied, followedUpPull: followUp)

    case .hint(let hint):
      let current = try cache.cursor()
      if current.epoch != 0 && hint.epoch != current.epoch {
        try await wipeForReset(newEpoch: hint.epoch)
        let pulled = try await pullToLatest()
        return .resetAndPulled(pulled)
      }
      if hint.latestSeq > current.seq || current.epoch == 0 {
        let pulled = try await pullToLatest()
        return .pulledFromHint(pulled)
      }
      return .pulledFromHint(nil)

    case .reset(let epoch):
      try await wipeForReset(newEpoch: epoch)
      let pulled = try await pullToLatest()
      return .resetAndPulled(pulled)

    case .relayMoved(let newConfig):
      await onRelayMoved?(newConfig)
      return .relayMoved(newConfig)

    case .unknown:
      return .ignored
    }
  }

  // MARK: - 后台运行循环（直连订阅 + 断线退回前后台轮询）

  public func start() {
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop()
    }
  }

  public func stop() {
    loopTask?.cancel()
    loopTask = nil
    isUsingEventStream = false
    wakeSleep()
  }

  private func runLoop() async {
    while !Task.isCancelled {
      if await client.isRemoved {
        isUsingEventStream = false
        return
      }

      // 若配置了直连事件流，优先尝试订阅 `/v1/device/events`。
      if let eventStream {
        do {
          let auth = try await client.makeSealedRequest(op: "events.subscribe", body: [:])
          let stream = try await eventStream.subscribe(authEnvelope: auth.wireData)
          isUsingEventStream = true
          for try await event in stream {
            if Task.isCancelled { break }
            _ = try? await handleEvent(event)
            if await client.isRemoved {
              isUsingEventStream = false
              return
            }
          }
          isUsingEventStream = false
        } catch {
          isUsingEventStream = false
        }
      }

      if Task.isCancelled { return }
      if await client.isRemoved { return }

      // 事件流不可用或处于信箱模式：退回轮询（前台 30 秒，后台 5 分钟）。
      if relayMailbox != nil && !isRelayDisabled {
        _ = try? await pollRelayDown()
      } else {
        _ = try? await pullToLatest()
      }

      if Task.isCancelled { return }
      if await client.isRemoved { return }
      await interruptibleSleep(seconds: currentPollInterval)
    }
  }

  private func interruptibleSleep(seconds: TimeInterval) async {
    let nanos = UInt64(max(0.01, seconds) * 1_000_000_000)
    await withCheckedContinuation { continuation in
      sleepContinuation = continuation
      sleepWakeTask?.cancel()
      sleepWakeTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: nanos)
        await self?.wakeSleep()
      }
    }
  }

  private func wakeSleep() {
    sleepWakeTask?.cancel()
    sleepWakeTask = nil
    if let continuation = sleepContinuation {
      sleepContinuation = nil
      continuation.resume()
    }
  }

  // MARK: - 按需原文读取（6.9.3，结果仅入内存 LRU，不落盘）

  /// 读取 1–50 条原文；自动命中内存 LRU，未命中时自动处理 `records.get` 码点分页与 409 重试。
  public func getRecords(ids: [String], includeCorrections: Bool = false) async throws -> RawRecordsGetResult {
    _ = try await verifyHubIdentity()
    let uniqueIDs = Array(NSOrderedSet(array: ids).compactMap { $0 as? String })
    guard !uniqueIDs.isEmpty, uniqueIDs.count <= 50 else {
      throw DeviceClientError.invalidRequest("ids 必须是 1–50 个记录 ID")
    }

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]

    var resolved: [String: DeviceJSON] = [:]
    var toFetch: [String] = []
    for id in uniqueIDs {
      let cacheKey = Self.recordCacheKey(id: id, includeCorrections: includeCorrections)
      if let cachedData = rawCache.get(cacheKey),
         let decoded = try? decoder.decode(DeviceJSON.self, from: cachedData) {
        resolved[id] = decoded
      } else {
        toFetch.append(id)
      }
    }

    if toFetch.isEmpty {
      return RawRecordsGetResult(records: resolved, missing: [])
    }

    var fetched: [String: DeviceJSON] = [:]
    var missing: Set<String> = []
    var retries = 0

    while true {
      fetched.removeAll()
      missing.removeAll()
      var assembled: [String: [String: DeviceJSON]] = [:]
      var assembledCorrections: [String: [[String: DeviceJSON]]] = [:]
      var cursor: String? = nil
      var restartForConflict = false

      while true {
        var reqBody: [String: DeviceJSON] = [
          "ids": .array(toFetch.map { .string($0) }),
        ]
        if includeCorrections {
          reqBody["include_corrections"] = .bool(true)
        }
        if let cursor {
          reqBody["cursor"] = .string(cursor)
        }

        let page: RecordsGetPageWire
        do {
          page = try await client.send(op: "records.get", body: reqBody, as: RecordsGetPageWire.self)
        } catch let error as DeviceClientError {
          if case .deviceRemoved = error {
            try await wipeAll(reason: .deviceRemoved)
            throw error
          }
          if case .operationError(_, status: 403, _) = error {
            try await wipeAll(reason: .roleDowngraded)
            throw error
          }
          if case .operationError(_, status: 409, _) = error, retries < 2 {
            retries += 1
            restartForConflict = true
            break
          }
          throw error
        }

        for id in page.missing { missing.insert(id) }
        for item in page.records {
          guard var obj = item.objectValue, let id = obj["id"]?.stringValue else { continue }
          if let corrections = obj["corrections"]?.arrayValue {
            var list = assembledCorrections[id] ?? []
            for rawCorr in corrections {
              guard let corrObj = rawCorr.objectValue else { continue }
              if let corrID = corrObj["id"]?.stringValue,
                 let idx = list.firstIndex(where: { $0["id"]?.stringValue == corrID }),
                 let prevBody = list[idx]["body"]?.stringValue,
                 let chunk = corrObj["body"]?.stringValue {
                var merged = list[idx]
                merged["body"] = .string(prevBody + chunk)
                list[idx] = merged
              } else {
                list.append(corrObj)
              }
            }
            assembledCorrections[id] = list
          } else if var existing = assembled[id] {
            if let prevBody = existing["body"]?.stringValue, let chunk = obj["body"]?.stringValue {
              existing["body"] = .string(prevBody + chunk)
            }
            if let range = obj["body_range"] { existing["body_range"] = range }
            assembled[id] = existing
          } else {
            obj.removeValue(forKey: "body_range")
            assembled[id] = obj
          }
        }

        cursor = page.next_cursor
        if cursor == nil { break }
      }

      if restartForConflict { continue }

      for (id, var obj) in assembled {
        obj.removeValue(forKey: "body_range")
        if let corrs = assembledCorrections[id], !corrs.isEmpty {
          obj["corrections"] = .array(corrs.map { .object($0) })
        }
        let value = DeviceJSON.object(obj)
        fetched[id] = value
        if let encoded = try? encoder.encode(value) {
          rawCache.set(
            Self.recordCacheKey(id: id, includeCorrections: includeCorrections),
            data: encoded,
            recordIDs: [id],
            invalidateOnAnyRecordGone: false
          )
        }
      }
      break
    }

    for (id, value) in fetched { resolved[id] = value }
    return RawRecordsGetResult(records: resolved, missing: Array(missing).sorted())
  }

  /// 按需调用 `records.list`，结果缓存在内存 LRU（任一 `record_gone` 到达时失效）。
  public func listRecords(_ params: [String: DeviceJSON] = [:]) async throws -> DeviceResponsePayload {
    try await cachedRead(op: "records.list", body: params, invalidateOnAnyRecordGone: true)
  }

  /// 按需调用 `history.segments`，结果缓存在内存 LRU。
  public func historySegments(from: String, to: String, device: String? = nil) async throws -> DeviceResponsePayload {
    var body: [String: DeviceJSON] = ["from": .string(from), "to": .string(to)]
    if let device { body["device"] = .string(device) }
    return try await cachedRead(op: "history.segments", body: body, invalidateOnAnyRecordGone: true)
  }

  /// 按需调用 `conversations.detail`，结果缓存在内存 LRU 并绑定涉及的 `record_ids`。
  public func conversationDetail(recordID: String) async throws -> DeviceResponsePayload {
    try await cachedRead(
      op: "conversations.detail",
      body: ["record_id": .string(recordID)],
      extraRecordIDs: [recordID],
      invalidateOnAnyRecordGone: false
    )
  }

  /// 按需调用 `timeline.query`，结果缓存在内存 LRU。
  public func timelineQuery(_ params: [String: DeviceJSON]) async throws -> DeviceResponsePayload {
    try await cachedRead(op: "timeline.query", body: params, invalidateOnAnyRecordGone: true)
  }

  /// 按需调用 `timeline.locate`，结果缓存在内存 LRU 并绑定目标 `record_id`。
  public func timelineLocate(recordID: String) async throws -> DeviceResponsePayload {
    try await cachedRead(
      op: "timeline.locate",
      body: ["record_id": .string(recordID)],
      extraRecordIDs: [recordID],
      invalidateOnAnyRecordGone: false
    )
  }

  // MARK: - 内部辅助

  private static func recordCacheKey(id: String, includeCorrections: Bool) -> String {
    includeCorrections ? "record:\(id):corr" : "record:\(id)"
  }

  private func cachedRead(
    op: String,
    body: [String: DeviceJSON],
    extraRecordIDs: Set<String> = [],
    invalidateOnAnyRecordGone: Bool
  ) async throws -> DeviceResponsePayload {
    _ = try await verifyHubIdentity()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let keyBytes = (try? encoder.encode(DeviceJSON.object(body))) ?? Data()
    let cacheKey = "\(op):\(String(decoding: keyBytes, as: UTF8.self))"

    if let cachedData = rawCache.get(cacheKey),
       let decoded = try? JSONDecoder().decode([String: DeviceJSON].self, from: cachedData) {
      return DeviceResponsePayload(status: 200, body: decoded, bodyData: cachedData)
    }

    let payload: DeviceResponsePayload
    do {
      payload = try await client.send(op: op, body: body)
    } catch let error as DeviceClientError {
      if case .deviceRemoved = error {
        try await wipeAll(reason: .deviceRemoved)
      } else if case .operationError(_, status: 403, _) = error {
        try await wipeAll(reason: .roleDowngraded)
      }
      throw error
    }

    var recordIDs = extraRecordIDs
    if let ids = payload.body["record_ids"]?.arrayValue {
      for item in ids {
        if let id = item.stringValue { recordIDs.insert(id) }
      }
    }
    rawCache.set(
      cacheKey,
      data: payload.bodyData,
      recordIDs: recordIDs,
      invalidateOnAnyRecordGone: invalidateOnAnyRecordGone
    )
    return payload
  }

  private func handleClientError(_ error: DeviceClientError, conflictRetries: inout Int) async throws -> Bool {
    switch error {
    case .deviceRemoved:
      try await wipeAll(reason: .deviceRemoved)
      return false
    case .operationError(_, status: 403, _):
      try await wipeAll(reason: .roleDowngraded)
      return false
    case .operationError(_, status: 409, _):
      conflictRetries += 1
      return conflictRetries <= 3
    default:
      return false
    }
  }

  private func wipeForReset(newEpoch: Int64) async throws {
    try cache.wipe()
    rawCache.clear()
    try cache.reset(toEpoch: newEpoch, hubID: client.hubID)
    await onWipe?(.serverReset(newEpoch: newEpoch))
  }

  private func wipeAll(reason: ProjectionWipeReason) async throws {
    try cache.wipe()
    rawCache.clear()
    stop()
    await onWipe?(reason)
  }
}
