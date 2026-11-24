import CryptoKit
import Foundation
import Network
import os

/// Routing and down-box ownership for one active Mac device generation.
public actor RemoteDeviceSession {
  public enum Failure: Error, Equatable {
    case unavailable, awaitingReceipt, invalidJournal, journalFull
  }

  public struct CaptureDelivery: Sendable {
    public let ids: [String]
    public let body: Data
    public let nonce: String?
    public let rejectedStatus: Int?

    init(ids: [String], body: Data, nonce: String?, rejectedStatus: Int? = nil) {
      self.ids = ids
      self.body = body
      self.nonce = nonce
      self.rejectedStatus = rejectedStatus
    }
  }

  public static let relayPlaintextLimit = 640 * 1024
  private static let mailboxRetention: TimeInterval = 30 * 86_400
  public nonisolated let route: HubBinding.Route
  public nonisolated let link: RemoteDeviceLink
  nonisolated let revision: UUID

  struct MailboxServices: Sendable {
    let open: @Sendable (DeviceRelayConfig) -> any RelayMailboxClient
    let limit: @Sendable (DeviceRelayConfig) async throws -> Int
    let automatic: Bool

    static let live = Self(open: { HTTPRelayMailboxClient(config: $0) },
                           limit: { try await HTTPRelayMailboxClient(config: $0).messageByteLimit() },
                           automatic: true)
  }

  private nonisolated(unsafe) weak var access: RemoteDeviceAccess?
  private let writeGate: RemoteSwitchWriteGate?
  private let mailboxServices: MailboxServices
  private let clock: @Sendable () -> Date
  private let transportFactory: RemoteDeviceAccess.TransportFactory
  private let directory: URL
  private let captureDirectory: URL
  private let journalName: String
  private var key: SymmetricKey?
  private var journal: RemoteRelayJournal?
  private var loading: Task<Void, Error>?
  private var installing: (id: UUID, task: Task<Void, Error>)?
  private var configs: [RemoteRelayMailbox: DeviceRelayConfig] = [:]
  private var direct: URL? { selectedDirect?.origin }
  private var checkedAt = Date.distantPast
  private var relayRefreshAt = Date.distantPast
  private struct DirectSelection: Sendable {
    let origin: URL
    let transport: any DeviceTransport
  }
  private var selectedDirect: DirectSelection?
  private var selectionTask: (id: UUID, job: Task<DirectSelection?, Never>)?

  private var monitor: NWPathMonitor?
  private var pump: Task<Void, Never>?
  private var pumping = false
  private var stopped = false
  private var wakeAgain = false
  private var submittedThisCycle = false
  private var retryAdvancedThisCycle: Set<String> = []
  private var succeededThisCycle: Set<String> = []
  private var foreground = false
  private var projection: (@Sendable (RelayPushMessage) async throws -> Void)?
  private var runningPushes: Set<String> = []
  private var limits: [RemoteRelayMailbox: Int] = [:]
  private var backoff: [RemoteRelayMailbox: (until: Date, seconds: TimeInterval)] = [:]
  private var inUse: Set<String> = []
  private var testingModelConnection = false
  private var checkingConnection = false
  private var oversizedReplies: Set<String> = []

  init(access: RemoteDeviceAccess, route: HubBinding.Route, link: RemoteDeviceLink, revision: UUID,
       transport: @escaping RemoteDeviceAccess.TransportFactory,
       mailboxServices: MailboxServices = .live,
       clock: @escaping @Sendable () -> Date = { Date() }) {
    self.access = access
    self.writeGate = access.writeGate
    self.route = route
    self.link = link
    self.revision = revision
    self.transportFactory = transport
    self.mailboxServices = mailboxServices
    self.clock = clock
    directory = access.dataDirectory.appendingPathComponent("remote-\(link.hub_id)", isDirectory: true)
    captureDirectory = access.dataDirectory
      .appendingPathComponent("outbox-\(route.generation)-\(link.hub_id)/outbox", isDirectory: true)
    journalName = Self.journalName(for: route)
  }

  deinit {
    monitor?.cancel()
    pump?.cancel()
  }

  private static func journalName(for route: HubBinding.Route) -> String {
    RemoteRelayJournal.name(for: route)
  }

  public static func hasJournal(in dataDirectory: URL, for route: HubBinding.Route) -> Bool {
    guard let remote = route.remote else { return false }
    return FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(remote.dir)
      .appendingPathComponent(journalName(for: route)).path)
  }

  /// Build an authenticated protocol client using the shared selector and pump.
  // The viewer builds its session on its GCD binding queue.
  public nonisolated func client() throws -> DeviceClient {
    guard let access else { throw Failure.unavailable }
    guard try access.credentialRevision(for: route) == revision else { throw HubBinding.Failure.changed }
    return try access.makeClient(for: route, link: link, transport: RoutedTransport(owner: self))
  }

  public nonisolated func clientInBackground() async throws -> DeviceClient {
    guard let access else { throw Failure.unavailable }
    guard try access.credentialRevision(for: route) == revision else { throw HubBinding.Failure.changed }
    let client = try await access.makeClientInBackground(for: route, link: link, transport: RoutedTransport(owner: self))
    guard try access.credentialRevision(for: route) == revision else { throw HubBinding.Failure.changed }
    return client
  }

  public func setProjectionConsumer(
    _ consumer: @escaping @Sendable (RelayPushMessage) async throws -> Void
  ) {
    projection = consumer
    wakeMailbox()
  }

  public func setForeground(_ value: Bool) {
    guard foreground != value else { return }
    foreground = value
    wakeMailbox()
  }

  public func networkChanged() {
    checkedAt = .distantPast
    wakeMailbox()
  }

  /// Importers may inspect the current target, but must send through the authenticated client.
  public func selectedEndpoint() async throws -> SelectedHubEndpoint? {
    try await load()
    if clock().timeIntervalSince(checkedAt) >= 30 { await selectDirect() }
    try validate()
    if let direct { return .direct(direct) }
    guard let active = journal?.active, journal?.disabled.contains(active) == false else { return nil }
    return .relay(try await config(for: active))
  }

  var isMailboxIdle: Bool { !pumping }

  public enum ConnectionState: Equatable, Sendable {
    public enum Channel: Equatable, Sendable { case direct, relay }
    case unavailable, unconfirmed(Channel), connected(Channel)
  }

  public func connectionState(timeout: TimeInterval = 5) async -> ConnectionState {
    let channel: ConnectionState.Channel
    switch try? await selectedEndpoint() {
    case .direct: channel = .direct
    case .relay: channel = .relay
    default: return .unavailable
    }
    guard !checkingConnection else { return .unconfirmed(channel) }
    checkingConnection = true
    defer { checkingConnection = false }
    do {
      // 以前的版本为每次探测保留一条随机请求；释放遗留的业务名额。
      let stale = journal?.deliveries.filter {
        $0.operation == "status.get" && $0.body?["read_nonce"] != nil && !inUse.contains($0.nonce)
      } ?? []
      for entry in stale { try discard(entry.nonce) }
      let client = try await clientInBackground()
      _ = try await client.send(op: "status.get", body: ["read_nonce": .string(UUID().uuidString)], timeout: timeout)
      switch (channel, try await selectedEndpoint()) {
      case (.direct, .direct), (.relay, .relay): return .connected(channel)
      default: return .unconfirmed(channel)
      }
    } catch {
      return .unconfirmed(channel)
    }
  }

  func stopMailbox() {
    stopped = true
    monitor?.cancel()
    monitor = nil
    pump?.cancel()
    pump = nil
    selectionTask?.job.cancel()
    selectionTask = nil
    selectedDirect = nil
    configs.removeAll()
  }

  public func wakeMailbox() {
    guard mailboxServices.automatic, (try? validate()) != nil else { return }
    if pumping { wakeAgain = true; return }
    pump?.cancel()
    schedule(after: 0)
  }

  public func unknownCaptureOutcomes() async throws -> Int {
    try await load()
    return journal?.unknownOutcomes ?? 0
  }

  /// IDs are reserved by the journal until a complete receipt is applied or a safe retry becomes due.
  public func reservedCaptureIDs() async throws -> Set<String> {
    try await load()
    try reconcileCapture()
    return Set(journal?.deliveries.filter { !$0.abandoned && !$0.queueConfirmed && ($0.capture || $0.reply == nil) }.flatMap(\.recordIDs) ?? [])
  }

  public func completedCapture() async throws -> CaptureDelivery? {
    try await load()
    guard let entry = journal?.deliveries.first(where: {
      $0.capture && !$0.queueConfirmed && !$0.abandoned && $0.reply != nil
    }), let wire = entry.reply else { return nil }
    let payload = try await codec().openResponseEnvelope(wireData: wire, requestNonce: entry.nonce)
    return CaptureDelivery(ids: entry.recordIDs, body: payload.bodyData, nonce: entry.nonce,
      rejectedStatus: payload.status == 200 ? nil : payload.status)
  }

  /// Call only after the generation's durable outbox has acknowledged the IDs.
  public func confirmCapture(nonce: String) throws {
    try update { state in
      guard let index = state.deliveries.firstIndex(where: { $0.nonce == nonce && $0.capture }),
            state.deliveries[index].reply != nil else { return }
      state.deliveries[index].queueConfirmed = true
    }
    wakeMailbox()
  }

  /// A request-level failure settles the mailbox message, leaving the outbox
  /// intact. A 413 can reflect the reply size, so retry smaller batches.
  public func releaseRejectedCapture(nonce: String, status: Int) throws {
    try update { state in
      guard let index = state.deliveries.firstIndex(where: { $0.nonce == nonce && $0.capture }),
            !state.deliveries[index].queueConfirmed, state.deliveries[index].reply != nil else { return }
      let ids = state.deliveries[index].recordIDs
      state.deliveries[index].queueConfirmed = true
      if status == 413 {
        if ids.count > 1 {
          state.captureBatchLimit = min(state.captureBatchLimit ?? 200, ids.count / 2)
        } else if let id = ids.first, captureExists(id) {
          var oversized = (state.relayOversizedCaptureIDs ?? []).filter(captureExists)
          oversized.insert(id)
          state.relayOversizedCaptureIDs = oversized
        }
      }
      advanceRetry("ingest", status: status, in: &state)
    }
    wakeMailbox()
  }

  public func captureBatchLimits() async throws -> (bytes: Int, count: Int, requiresDirect: Set<String>) {
    let endpoint = try await selectedEndpoint()
    let bytes = try await recordBatchBudget(on: endpoint)
    if case .relay = endpoint {
      return (bytes, journal?.captureBatchLimit ?? 200, journal?.relayOversizedCaptureIDs ?? [])
    }
    return (bytes, 200, [])
  }

  public func historyImportRecordBudget() async throws -> Int {
    // Historical batches include the session UUID and batch number in addition to the common headers.
    max(0, try await recordBatchBudget() - 128)
  }

  public func recordBatchBudget() async throws -> Int {
    try await recordBatchBudget(on: selectedEndpoint())
  }

  private func recordBatchBudget(on endpoint: SelectedHubEndpoint?) async throws -> Int {
    switch endpoint {
    case .direct:
      return Self.batchBudget(wireLimit: DeviceProtocol.maxEnvelopeBytes, plainLimit: 4 * 1024 * 1024)
    case .relay(let config):
      let limit = try await messageLimit(RemoteRelayMailbox(config))
      return Self.batchBudget(wireLimit: limit, plainLimit: Self.relayPlaintextLimit)
    default:
      throw Failure.unavailable
    }
  }

  public nonisolated func captureRecordFits(_ record: Record, budget: Int) -> Bool {
    var stamped = record
    stamped.device = link.device_id
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let bytes = try? encoder.encode(stamped) else { return false }
    return bytes.count + 1 <= budget
  }

  private static func batchBudget(wireLimit: Int, plainLimit: Int) -> Int {
    min(plainLimit, max(0, (wireLimit - 256) * 3 / 4)) - 128
  }

  /// Send one capture batch. The collector owns the underlying records until a complete receipt.
  public func sendCapture(_ input: [Record]) async throws -> CaptureDelivery {
    try await load()
    if let done = try await completedCapture() { return done }
    let excluded = try await reservedCaptureIDs()
    let records = try input.filter { !excluded.contains($0.id) }.map { record in
      var stamped = record
      stamped.device = link.device_id
      let data = try JSONEncoder().encode(stamped)
      return (record.id, try JSONDecoder().decode(DeviceJSON.self, from: data))
    }
    guard !records.isEmpty else { throw Failure.awaitingReceipt }
    let endpoint = try await selectedEndpoint()
    if case .direct(let url) = endpoint {
      let prepared = try await makeBatch(records, wireLimit: DeviceProtocol.maxEnvelopeBytes, plainLimit: 4 * 1024 * 1024)
      do {
        try markCaptureSubmitted(prepared.ids, requireDurable: false)
        let reply = try await sendDirect(prepared.request, to: url, timeout: 15)
        let payload = try await verified(reply, request: prepared.request)
        return CaptureDelivery(ids: prepared.ids, body: payload.bodyData, nonce: nil)
      } catch where Self.canRetryIngest(error) {
        await selectDirect(excluding: url)
        guard direct == nil else { throw error }
        // Use a fresh nonce on the other channel. Record IDs remain unchanged.
      }
    }
    guard case .relay(let config) = try await selectedEndpoint() else { throw Failure.unavailable }
    // Never create a recoverable second copy for records present only in the degraded memory buffer.
    let oversized = journal?.relayOversizedCaptureIDs ?? []
    let durable = records.filter { !oversized.contains($0.0) && captureExists($0.0) }
    guard !durable.isEmpty else { throw Failure.unavailable }
    let mailbox = RemoteRelayMailbox(config)
    let wireLimit = try await messageLimit(mailbox)
    let prepared = try await makeBatch(durable, wireLimit: wireLimit, plainLimit: Self.relayPlaintextLimit,
                                       countLimit: journal?.captureBatchLimit ?? 200)
    _ = try await enqueue(prepared.request, mailbox: mailbox, capture: true)
    throw Failure.awaitingReceipt
  }

  private func makeBatch(
    _ records: [(String, DeviceJSON)], wireLimit: Int, plainLimit: Int, countLimit: Int = 200
  ) async throws -> (ids: [String], request: SealedDeviceRequest) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    // Reserve room for the protocol headers. Check actual sealed bytes before sending.
    let budget = Self.batchBudget(wireLimit: wireLimit, plainLimit: plainLimit)
    var items: [DeviceJSON] = []
    var ids: [String] = []
    var bytes = 0
    for (id, record) in records {
      let size = try encoder.encode(record).count + 1
      if size > budget { continue }
      if bytes + size > budget || items.count >= countLimit { break }
      bytes += size
      items.append(record)
      ids.append(id)
    }
    guard !items.isEmpty else { throw DeviceClientError.envelopeTooLarge(message: "这条记录需直连上传") }
    let request = try await codec().makeSealedRequest(op: "ingest", body: ["records": .array(items)])
    guard request.wireData.count < wireLimit, request.plaintextBytes <= plainLimit else {
      throw DeviceClientError.envelopeTooLarge(message: nil)
    }
    return (ids, request)
  }

  public func sendIngest(_ body: [String: DeviceJSON]) async throws -> DeviceResponsePayload {
    let client = try await clientInBackground()
    if case .direct = try await selectedEndpoint() {
      do { return try await client.send(op: "ingest", body: body) }
      catch DeviceClientError.envelopeTooLarge {
        // A smaller batch is useful only if this request already switched to the mailbox.
        if case .relay = try await selectedEndpoint() {} else { throw DeviceClientError.envelopeTooLarge(message: nil) }
      }
    }
    guard case .relay(let config) = try await selectedEndpoint(),
          let records = body["records"]?.arrayValue, !records.isEmpty else { throw Failure.unavailable }
    let limit = try await messageLimit(RemoteRelayMailbox(config))
    let budget = Self.batchBudget(wireLimit: limit, plainLimit: Self.relayPlaintextLimit)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var batch: [(index: Int, value: DeviceJSON)] = []
    var bytes = 0
    var oversized = false
    var accepted = 0
    var duplicates = 0
    var rejected: [DeviceJSON] = []
    func upload() async throws {
      guard !batch.isEmpty else { return }
      var part = body
      part["records"] = .array(batch.map(\.value))
      let reply = try await client.send(op: "ingest", body: part)
      guard let receipt = DeliveryReceipt.decode(reply.bodyData, batchCount: batch.count) else {
        throw DeviceClientError.invalidEnvelope("入库回执不完整")
      }
      accepted += receipt.accepted
      duplicates += receipt.duplicates
      rejected += receipt.rejected.map { failure in
        .object(["index": .int(Int64(batch[failure.index].index)), "errors": .array(failure.errors.map(DeviceJSON.string))])
      }
      batch.removeAll(keepingCapacity: true)
      bytes = 0
    }
    for (i, record) in records.enumerated() {
      let size = try encoder.encode(record).count + 1
      if size > budget { oversized = true; continue }
      if bytes + size > budget || batch.count == 200 { try await upload() }
      batch.append((i, record))
      bytes += size
    }
    try await upload()
    guard !oversized else { throw DeviceClientError.envelopeTooLarge(message: "这条记录需直连上传") }
    let result: [String: DeviceJSON] = [
      "accepted": .int(Int64(accepted)), "duplicates": .int(Int64(duplicates)), "rejected": .array(rejected),
    ]
    return DeviceResponsePayload(status: 200, body: result, bodyData: try encoder.encode(result))
  }

  private func dispatch(_ request: SealedDeviceRequest, timeout: TimeInterval?) async throws -> DeviceTransportResponse {
    guard let op = request.operation, let body = request.body else { throw DeviceClientError.invalidRequest("缺少操作信息") }
    let testsModel = op == "settings.models.test"
    if testsModel {
      guard !testingModelConnection else {
        throw DeviceClientError.operationError(op: op, status: 409, message: "上一次测试还没结束")
      }
      testingModelConnection = true
    }
    defer { if testsModel { testingModelConnection = false } }
    try await load()
    let fingerprint = try Self.fingerprint(op, body)
    let ids = Self.recordIDs(body)
    var relayRequest = request
    if case .direct(let origin) = try await selectedEndpoint() {
      if op == "ingest", !ids.isEmpty {
        let overlap = Set(ids)
        let pending = journal?.deliveries.filter { !$0.abandoned && !$0.queueConfirmed && $0.reply == nil } ?? []
        guard !pending.contains(where: { !overlap.isDisjoint(with: $0.recordIDs) }) else {
          throw Failure.awaitingReceipt
        }
      }
      do {
        let reply = try await sendDirect(request, to: origin, timeout: timeout)
        if op == "ingest" {
          let status = reply.statusCode == 200
            ? (try? await codec().openResponseEnvelope(wireData: reply.body, requestNonce: request.nonce).status) ?? 200
            : reply.statusCode
          if (500...599).contains(status) { throw DeviceClientError.hubBusy(message: nil) }
        }
        return reply
      } catch where op == "ingest" && Self.canRetryIngest(error) {
        await selectDirect(excluding: origin)
        if self.direct != nil { throw error }
        relayRequest = try await codec().makeSealedRequest(op: op, body: body)
      } catch {
        if Self.canRetryIngest(error) { checkedAt = .distantPast }
        throw error
      }
    }
    guard Self.relayAllowed(op), case .relay(let config) = try await selectedEndpoint() else { throw Failure.unavailable }
    let mailbox = RemoteRelayMailbox(config)
    // Only a relay caller can resume an outstanding relay RPC.
    let freshRead = writeGate?.isPaused == true && Self.allowedDuringPause(op)
    let existing = journal?.deliveries.first {
      !freshRead && !$0.capture && !$0.abandoned && !$0.queueConfirmed && $0.operation == op &&
        ($0.fingerprint == fingerprint || op == "ingest" && !ids.isEmpty && ids == $0.recordIDs)
    }
    let nonce: String
    if let existing { nonce = existing.nonce }
    else { nonce = try await enqueue(relayRequest, mailbox: mailbox, capture: false, freshRead: freshRead) }
    do {
      let wire = try await reply(for: nonce, operation: op, timeout: timeout ?? 35)
      return DeviceTransportResponse(statusCode: 200, body: wire, authenticatedNonce: nonce)
    } catch {
      if op == "status.get", body["read_nonce"] != nil { try? discard(nonce) }
      throw error
    }
  }

  private func selectDirect(excluding failed: URL? = nil) async {
    let pending: (id: UUID, job: Task<DirectSelection?, Never>)
    if let selectionTask, failed == nil {
      pending = selectionTask
    } else {
      let factory = transportFactory
      let last = direct ?? journal?.lastSuccessfulOrigin
      let candidates = link.addresses.filter { $0 != failed }
      let hubID = link.hub_id
      pending = (UUID(), Task {
        // Retain the actual transport selected by the probe for subsequent operations.
        let found = OSAllocatedUnfairLock<DirectSelection?>(initialState: nil)
        _ = await ProjectionEndpointSelector.select(localPort: nil, lastSuccessful: last,
          inviteAddresses: candidates, expectedHubID: hubID) { url, hubID in
          guard url != failed, let transport = try? factory(url) else { return false }
          if let direct = transport as? DirectDeviceTransport, !(await direct.matchesHub(hubID: hubID)) { return false }
          found.withLock { $0 = DirectSelection(origin: url, transport: transport) }
          return true
        }
        return found.withLock { $0 }
      })
      selectionTask = pending
    }
    let chosen = await pending.job.value
    guard selectionTask?.id == pending.id else { return }
    selectedDirect = chosen
    checkedAt = clock()
    selectionTask = nil
  }

  private func sendDirect(_ request: SealedDeviceRequest, to origin: URL,
                          timeout: TimeInterval?) async throws -> DeviceTransportResponse {
    try validate()
    guard let target = selectedDirect, target.origin == origin else {
      throw DeviceClientError.transportError("直连地址已变化")
    }
    let transport = target.transport
    guard request.wireData.count <= transport.maxEnvelopeBytes else { throw DeviceClientError.envelopeTooLarge(message: nil) }
    let reply = try await transport.send(request, timeout: timeout ?? 30)
    try validate()
    // Authenticated success is the only event that can reset the retry
    // delay or re-enable/refresh the mailbox configuration.
    if let op = request.operation, op != "relay" {
      let shouldRefresh = clock().timeIntervalSince(relayRefreshAt) >= 30
      if shouldRefresh || journal?.retryDelays?[op] != nil,
         let payload = try? await verified(reply, request: request), (200..<300).contains(payload.status) {
        if journal?.retryDelays?[op] != nil { try? update { $0.retryDelays?.removeValue(forKey: op) } }
        if shouldRefresh {
          relayRefreshAt = clock()
          if journal?.lastSuccessfulOrigin != origin { try? update { $0.lastSuccessfulOrigin = origin } }
          Task { await self.refreshRelay(transport) }
        }
      }
    }
    return reply
  }

  private func verified(_ reply: DeviceTransportResponse, request: SealedDeviceRequest) async throws -> DeviceResponsePayload {
    guard reply.statusCode == 200 else {
      if reply.statusCode == 401 {
        access?.freeze(route)
        throw DeviceClientError.deviceRemoved(message: nil)
      }
      throw DeviceClientError.plaintextError(status: reply.statusCode, message: nil)
    }
    let payload = try await codec().openResponseEnvelope(wireData: reply.body, requestNonce: request.nonce)
    if payload.status == 401 {
      access?.freeze(route)
      throw DeviceClientError.deviceRemoved(message: payload.errorMessage)
    }
    guard (200..<300).contains(payload.status) else {
      throw DeviceClientError.operationError(op: request.operation ?? "", status: payload.status, message: payload.errorMessage)
    }
    return payload
  }

  private func refreshRelay(_ transport: any DeviceTransport) async {
    struct ConfigReply: Decodable { let relay: DeviceRelayConfig? }
    guard let access else { return }
    do {
      let client = try await access.makeClientInBackground(for: route, link: link, transport: transport)
      let reply = try await client.send(op: "relay", timeout: 5)
      guard reply.body["relay"] != nil else { return }
      try await install(reply.decodeBody(ConfigReply.self).relay, authenticatedDirect: true)
      wakeMailbox()
    } catch { /* Preserve the last authenticated configuration on a transient failure. */ }
  }

  private func validate() throws {
    guard !stopped, let access, try access.credentialRevision(for: route) == revision else {
      throw HubBinding.Failure.changed
    }
  }

  private func codec() async throws -> DeviceClient {
    try validate()
    guard let access else { throw Failure.unavailable }
    let client = try await access.makeClientInBackground(for: route, link: link, transport: UnusedTransport())
    try validate()
    return client
  }

  private func load() async throws {
    try validate()
    if let loading { try await loading.value; return }
    guard journal == nil else { return }
    let task = Task { try await self.initializeJournal() }
    loading = task
    defer { loading = nil }
    try await task.value
  }

  private func initializeJournal() async throws {
    guard let access else { throw Failure.unavailable }
    let key = try await access.withCredentials { [route, link, revision] in
      try access.relayJournalKey(for: route, link: link, revision: revision)
    }
    try validate()
    self.key = key
    journal = try RemoteRelayJournal.load(key: key, in: directory, name: journalName, route: route, deviceID: link.device_id)
    do {
      if journal?.configured == false, let bootstrap = try link.relay(in: access.dataDirectory) {
        let config = try await access.withCredentials { [link] in
          try bootstrap.config(deviceID: link.device_id, keys: access.keys)
        }
        try await install(config, authenticatedDirect: false)
      }
    } catch {
      journal = nil
      throw error
    }
    try validate()
    if mailboxServices.automatic {
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { [weak self] _ in Task { await self?.networkChanged() } }
      monitor.start(queue: DispatchQueue(label: "record-anything.remote-network"))
      self.monitor = monitor
    }
    wakeMailbox()
  }

  private func update(reserve: Int = 0, _ change: (inout RemoteRelayJournal) throws -> Void) throws {
    try validate()
    guard var next = journal, let key else { throw Failure.invalidJournal }
    try change(&next)
    try next.save(key: key, in: directory, name: journalName, reserve: reserve)
    journal = next
  }

  private func account(for mailbox: RemoteRelayMailbox) -> String {
    RemoteDeviceLink.Relay.account(deviceID: link.device_id) + "-" + mailbox.credentialSuffix
  }

  private func config(for mailbox: RemoteRelayMailbox) async throws -> DeviceRelayConfig {
    if let cached = configs[mailbox] { return cached }
    guard let access else { throw Failure.unavailable }
    let name = account(for: mailbox)
    let token = try await access.withCredentials {
      guard let data = try access.keys.read(name), let token = String(data: data, encoding: .utf8) else {
        throw LocalDeviceLink.Failure.keyUnavailable
      }
      return token
    }
    try validate()
    if let cached = configs[mailbox] { return cached }
    let config = try DeviceRelayConfig(url: mailbox.url, space: mailbox.space, up: mailbox.up, down: mailbox.down, token: token)
    configs[mailbox] = config
    return config
  }

  private func install(_ config: DeviceRelayConfig?, authenticatedDirect: Bool) async throws {
    let previous = installing?.task
    let id = UUID()
    let task = Task {
      _ = await previous?.result
      try await self.persistConfig(config, authenticatedDirect: authenticatedDirect)
    }
    installing = (id, task)
    defer { if installing?.id == id { installing = nil } }
    try await task.value
  }

  private func persistConfig(_ config: DeviceRelayConfig?, authenticatedDirect: Bool) async throws {
    guard let access else { throw Failure.unavailable }
    try validate()
    let next = config.map(RemoteRelayMailbox.init)
    // Publish the durable token before the journal points to its mailbox.
    if let next, let config, configs[next] != config {
      let name = account(for: next)
      let token = Data(config.token.utf8)
      try await access.withCredentials { [route, revision] in
        guard try access.credentialRevision(for: route) == revision else { throw HubBinding.Failure.changed }
        try Self.saveToken(token, account: name, keys: access.keys)
      }
    }
    try validate()
    let prior = journal?.active
    if let next, let config { configs[next] = config }
    if journal?.configured != true || prior != next || authenticatedDirect && next.map({ journal?.disabled.contains($0) == true }) == true {
      try update { state in
        if let prior, prior != next, !state.retired.contains(where: { $0.mailbox == prior }) {
          state.retired.append(.init(mailbox: prior, until: clock().addingTimeInterval(7 * 86_400)))
        }
        state.configured = true
        state.active = next
        state.retired.removeAll { $0.mailbox == next }
        if let next, authenticatedDirect { state.disabled.removeAll { $0 == next } }
      }
    }
    if authenticatedDirect, let next {
      backoff[next] = nil
      limits[next] = nil
    }

    // Retain the original credentials and metadata for setup tools. The
    // per-mailbox credential above is sufficient for journal recovery.
    let primary = RemoteDeviceLink.Relay.account(deviceID: link.device_id)
    try await access.withCredentials { [directory, link, route, revision] in
      guard try access.credentialRevision(for: route) == revision else { throw HubBinding.Failure.changed }
      if let config {
        try Self.saveToken(Data(config.token.utf8), account: primary, keys: access.keys)
        let metadata = RemoteDeviceLink.Relay(config)
        if try link.relay(in: access.dataDirectory) != metadata {
          try BindingFile.write(JSONEncoder().encode(metadata), named: RemoteDeviceLink.Relay.fileName, in: directory)
        }
      } else {
        try BindingFile.remove(RemoteDeviceLink.Relay.fileName, in: directory)
        try access.keys.remove(primary)
      }
    }
  }

  private static func saveToken(_ token: Data, account: String, keys: RemoteDeviceLink.Keys) throws {
    if try keys.read(account) != token {
      try keys.create(account, token)
      guard try keys.read(account) == token else { throw LocalDeviceLink.Failure.keyUnavailable }
    }
  }

  private func messageLimit(_ box: RemoteRelayMailbox) async throws -> Int {
    if let retry = backoff[box], retry.until > clock() { throw Failure.awaitingReceipt }
    if let limit = limits[box] { return limit }
    do {
      let limit = try await mailboxServices.limit(config(for: box))
      limits[box] = min(limit, DeviceProtocol.maxEnvelopeBytes)
      return min(limit, DeviceProtocol.maxEnvelopeBytes)
    } catch {
      try note(error, for: box)
      throw error
    }
  }

  private static func recordIDs(_ body: [String: DeviceJSON]) -> [String] {
    body["records"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
  }

  private static func fingerprint(_ operation: String, _ body: [String: DeviceJSON]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var stableBody = body
    if operation == "ingest", let records = body["records"]?.arrayValue {
      stableBody["records"] = .array(records.map {
        guard var record = $0.objectValue, record["source_ref"]?.stringValue?.isEmpty == false else { return $0 }
        record.removeValue(forKey: "id")
        return .object(record)
      })
    }
    let bytes = try encoder.encode(stableBody)
    return Data(SHA256.hash(data: Data(operation.utf8) + Data([0]) + bytes))
  }

  private static func canRetryIngest(_ error: Error) -> Bool {
    switch error {
    case DeviceClientError.transportError, DeviceClientError.hubBusy: return true
    case DeviceClientError.plaintextError(let status, _), DeviceClientError.operationError(_, let status, _):
      return (500...599).contains(status)
    default: return false
    }
  }

  private static func relayAllowed(_ op: String) -> Bool {
    ["ingest", "sync", "sync.ack", "audio.sync", "audio.sync.ack", "audio.embeddings", "audio.skipped",
     "audio.lines", "collector.status", "status.get", "agent.enroll", "records.get", "records.list", "history.segments",
     "conversations.detail", "timeline.query", "timeline.locate"].contains(op)
      || op.hasPrefix("projection.") || op.hasPrefix("history.import.")
  }

  private static func canReseal(_ op: String) -> Bool {
    op.hasPrefix("history.import.") || ["ingest", "sync", "sync.ack", "audio.sync", "audio.sync.ack", "collector.status",
     "records.get", "records.list", "history.segments", "conversations.detail", "timeline.query", "timeline.locate",
     "projection.pull", "projection.ack", "projection.status", "status.get"].contains(op)
  }


  private static func allowedDuringPause(_ op: String) -> Bool {
    ["history.import.changes", "history.import.verify", "history.import.status", "status.get"].contains(op)
  }

  private func mailboxOperationAllowed(_ op: String) -> Bool {
    writeGate?.isPaused != true || Self.allowedDuringPause(op)
  }

  private func hasPausedMailboxWork() -> Bool {
    journal?.deliveries.contains {
      inUse.contains($0.nonce) && Self.allowedDuringPause($0.operation) && $0.reply == nil
    } == true
  }

  private func enqueue(_ request: SealedDeviceRequest, mailbox: RemoteRelayMailbox, capture: Bool, freshRead: Bool = false) async throws -> String {
    guard let op = request.operation, let body = request.body else { throw Failure.invalidJournal }
    guard mailboxOperationAllowed(op) else { throw RemoteSwitchWriteGate.Paused() }
    if let backoff = backoff[mailbox], backoff.until > clock() { throw Failure.awaitingReceipt }
    if retryIsDelayed(op) {
      if capture, let status = journal?.retryDelays?[op]?.status {
        throw DeviceClientError.operationError(op: op, status: status, message: nil)
      }
      throw Failure.awaitingReceipt
    }
    let limit = try await messageLimit(mailbox)
    guard request.plaintextBytes <= Self.relayPlaintextLimit, request.wireData.count < limit else {
      throw DeviceClientError.envelopeTooLarge(message: "信箱请求太大，需直连")
    }
    let fingerprint = try Self.fingerprint(op, body)
    let ids = Self.recordIDs(body)
    if op == "ingest", ids.count != body["records"]?.arrayValue?.count || ids.isEmpty || Set(ids).count != ids.count {
      throw DeviceClientError.invalidRequest("入库批次缺记录编号")
    }
    if freshRead {
      // A cutover read must start after the write gate closed. Retire stale
      // matching reads but let the pump authenticate and remove late replies.
      let stale = journal?.deliveries.filter {
        Self.allowedDuringPause($0.operation) && !$0.capture && !inUse.contains($0.nonce)
      } ?? []
      for entry in stale { try discard(entry.nonce) }
    }
    if let existing = journal?.deliveries.first(where: {
      !freshRead && !$0.abandoned && !$0.queueConfirmed && $0.capture == capture && $0.fingerprint == fingerprint
    }) {
      return existing.nonce
    }
    let overlap = Set(ids)
    let pending = journal?.deliveries.filter { !$0.abandoned && !$0.queueConfirmed } ?? []
    let single = op == "sync" || op == "audio.sync" || op == "collector.status"
    guard !pending.contains(where: { $0.reply == nil && (single && $0.operation == op || !overlap.isDisjoint(with: $0.recordIDs)) }) else {
      throw Failure.awaitingReceipt
    }
    // Reserve slots for collection so bursts of reads/status cannot fill the sender.
    if freshRead {
      guard pending.filter({ Self.allowedDuringPause($0.operation) }).count < 5 else {
        throw Failure.journalFull
      }
    } else {
      guard pending.count < (capture ? 8 : 5) else { throw Failure.journalFull }
    }
    let entry = RemoteRelayJournal.Delivery(nonce: request.nonce, operation: op, recordIDs: ids,
      mailbox: mailbox, createdAt: clock(), capture: capture, fingerprint: fingerprint,
      body: capture ? nil : body, wire: request.wireData)
    let gate = Self.allowedDuringPause(op) ? nil : writeGate
    try gate?.begin()
    defer { gate?.end() }
    try update(reserve: freshRead ? 0 : 256 * 1024) { $0.deliveries.append(entry) }
    wakeMailbox()
    return entry.nonce
  }

  private func reply(for nonce: String, operation: String, timeout: TimeInterval) async throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    guard inUse.insert(nonce).inserted else { throw Failure.awaitingReceipt }
    defer { inUse.remove(nonce); oversizedReplies.remove(nonce) }
    if writeGate?.isPaused == true, Self.allowedDuringPause(operation) { wakeMailbox() }
    repeat {
      try validate()
      if oversizedReplies.contains(nonce) { throw DeviceClientError.envelopeTooLarge(message: "信箱请求太大，需重新分批") }
      guard mailboxOperationAllowed(operation) else { throw RemoteSwitchWriteGate.Paused() }
      guard let entry = journal?.deliveries.first(where: { $0.nonce == nonce }),
            !entry.abandoned, !entry.queueConfirmed else { throw Failure.awaitingReceipt }
      if let reply = entry.reply {
        if entry.removedFromMailbox {
          try discard(nonce)
        } else {
          // Keep only the authenticated nonce until the pump deletes the
          // downlink. Identical future requests no longer match this entry.
          try update { state in
            guard let i = state.deliveries.firstIndex(where: { $0.nonce == nonce }) else { return }
            state.deliveries[i].queueConfirmed = true
            state.deliveries[i].reply = nil
          }
          wakeMailbox()
        }
        return reply
      }
      if journal?.disabled.contains(entry.mailbox) == true { throw Failure.unavailable }
      try await Task.sleep(for: .milliseconds(250))
    } while Date() < deadline
    throw Failure.awaitingReceipt
  }

  private func discard(_ nonce: String) throws {
    try update { state in
      guard let i = state.deliveries.firstIndex(where: { $0.nonce == nonce }) else { return }
      Self.tombstone(state.deliveries.remove(at: i), in: &state)
    }
  }

  private func schedule(after delay: TimeInterval) {
    pump = Task { [weak self] in
      do {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        await self?.runPump()
      } catch { }
    }
  }

  /// Wake the shared consumer immediately. The background task otherwise uses
  /// 30 seconds in the foreground and 5 minutes in the background.
  func runPump() async {
    guard !pumping, !stopped else { return }
    if writeGate?.isPaused == true && !hasPausedMailboxWork() {
      if mailboxServices.automatic { schedule(after: 2) }
      return
    }
    pumping = true
    wakeAgain = false
    submittedThisCycle = false
    retryAdvancedThisCycle.removeAll()
    succeededThisCycle.removeAll()
    defer {
      pumping = false
      if mailboxServices.automatic, (try? validate()) != nil, journal?.active != nil || journal?.retired.isEmpty == false {
        let interval: TimeInterval = submittedThisCycle ? 2 : foreground ? 30 : 300
        let now = clock()
        let retryDate = journal?.retryDelays?.values.map(\.until).filter { $0 > now }.min()
        schedule(after: wakeAgain ? 0 : writeGate?.isPaused == true ? 2
          : min(interval, retryDate?.timeIntervalSince(now) ?? interval))
      }
    }
    guard (try? await load()) != nil else { return }
    if writeGate?.isPaused != true {
      if clock().timeIntervalSince(checkedAt) >= 30 { await selectDirect() }
      // Reconnect while idle, including when the most recent mailbox credential was rejected.
      if writeGate?.isPaused != true, journal?.active != nil, let selectedDirect,
         clock().timeIntervalSince(relayRefreshAt) >= 30 {
        relayRefreshAt = clock()
        await refreshRelay(selectedDirect.transport)
      }
      if writeGate?.isPaused != true {
        do { try await cleanup() } catch { return }
      }
    }
    guard (try? validate()) != nil else { return }
    let boxes = [journal?.active].compactMap { $0 } + (journal?.retired.map(\.mailbox) ?? [])
    var ready: [(RemoteRelayMailbox, any RelayMailboxClient)] = []
    for box in boxes {
      guard writeGate?.isPaused != true || hasPausedMailboxWork() else { return }
      guard journal?.disabled.contains(box) == false,
            backoff[box].map({ $0.until <= clock() }) ?? true else { continue }
      do {
        let client = try await mailboxServices.open(config(for: box))
        try await consume(box, client: client)
        try await finishMailboxDeletes(box, client: client)
        ready.append((box, client))
      } catch {
        try? note(error, for: box)
      }
    }
    let recovered = succeededThisCycle.subtracting(retryAdvancedThisCycle)
    if !recovered.isEmpty {
      do { try update { state in
        for op in recovered { state.retryDelays?.removeValue(forKey: op) }
      } } catch { return }
    }
    // A receipt already waiting in a retired box takes precedence over a retry.
    if writeGate?.isPaused != true {
      do { try reconcileCapture() } catch { return }
    }
    try? await renewSafeRequests()
    for (box, client) in ready {
      do {
        try await submit(box, client: client)
        backoff[box] = nil
      } catch {
        try? note(error, for: box)
      }
    }
  }

  private func cleanup() async throws {
    guard let state = journal else { return }
    let now = clock()
    let expired = Set(state.retired.filter { $0.until <= now }.map(\.mailbox))
    let staleID: (RemoteRelayJournal.Superseded) -> Bool = { now.timeIntervalSince($0.createdAt) >= Self.mailboxRetention }
    let removable: (RemoteRelayJournal.Delivery) -> Bool = { [inUse] entry in
      let age = now.timeIntervalSince(entry.createdAt)
      if entry.queueConfirmed || entry.abandoned { return entry.removedFromMailbox || expired.contains(entry.mailbox) || age >= Self.mailboxRetention }
      if entry.capture && entry.reply != nil { return false }  // Local acknowledgement still needs the receipt.
      if expired.contains(entry.mailbox) || age >= Self.mailboxRetention { return true }
      // Abandoned callers can resume a write or fetch a fresh page. Keep a
      // bounded window for authenticated replies that nobody has taken.
      let ttl: TimeInterval = entry.operation == "ingest" ? 86_400 : 300
      return !entry.capture && !inUse.contains(entry.nonce) && entry.reply != nil && age >= ttl
    }
    guard !expired.isEmpty || state.deliveries.contains(where: removable)
            || state.superseded.contains(where: staleID) else { return }
    try update { state in
      state.retired.removeAll { expired.contains($0.mailbox) }
      state.disabled.removeAll { expired.contains($0) }
      let removed = state.deliveries.filter(removable)
      state.deliveries.removeAll(where: removable)
      for entry in removed {
        if entry.capture && !entry.queueConfirmed && !entry.abandoned && entry.attemptedPut && entry.reply == nil && !entry.retry {
          let missing = Set(entry.recordIDs.filter { !captureExists($0) })
          state.unknownOutcomes = max(0, state.unknownOutcomes - (entry.countedMissingIDs?.count ?? 0))
          state.unknownOutcomes += missing.count
        }
        Self.tombstone(entry, in: &state)
      }
      state.superseded.removeAll { staleID($0) || expired.contains($0.mailbox) }
    }
    for box in expired {
      configs[box] = nil
      limits[box] = nil
      backoff[box] = nil
      if let access {
        let name = account(for: box)
        try? await access.withCredentials { try access.keys.remove(name) }
      }
    }
  }

  private func finishMailboxDeletes(_ box: RemoteRelayMailbox, client: any RelayMailboxClient) async throws {
    let pending = journal?.deliveries.filter {
      $0.mailbox == box && !$0.removedFromMailbox && ($0.queueConfirmed || (!$0.capture || $0.abandoned) && $0.reply != nil)
    } ?? []
    for entry in pending {
      guard mailboxOperationAllowed(entry.operation) else { continue }
      try validate()
      do { try await client.deleteDownMessage(id: entry.nonce) }
      catch RelayMailboxError.notFound {}
      try markMailboxRemoved(entry.nonce)
    }
  }

  private func markMailboxRemoved(_ nonce: String) throws {
    try update { state in
      guard let i = state.deliveries.firstIndex(where: { $0.nonce == nonce }) else { return }
      if state.deliveries[i].queueConfirmed || state.deliveries[i].abandoned {
        let settled = state.deliveries.remove(at: i)
        Self.tombstone(settled, in: &state)
      } else {
        state.deliveries[i].removedFromMailbox = true
      }
    }
  }

  private static func tombstone(_ entry: RemoteRelayJournal.Delivery, in state: inout RemoteRelayJournal) {
    state.superseded.append(.init(nonce: entry.nonce, mailbox: entry.mailbox, createdAt: entry.createdAt))
    let overflow = state.superseded.count - 4096
    if overflow > 0 { state.superseded.removeFirst(overflow) }
  }

  private func captureExists(_ id: String) -> Bool {
    guard id.utf8.count == 26, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return false }
    return FileManager.default.fileExists(atPath: captureDirectory.appendingPathComponent(id + ".enc").path)
  }

  private func markCaptureSubmitted(_ ids: [String], requireDurable: Bool) throws {
    for id in ids {
      guard captureExists(id) else {
        if requireDurable { throw Failure.unavailable }
        continue
      }
      // Matches the switch recovery marker. Publish it before handing bytes
      // to either transport, since a lost response leaves the outcome unknown.
      try BindingFile.write(Data(), named: ".submitted-" + id, in: captureDirectory)
    }
  }

  private func reconcileCapture() throws {
    let now = clock()
    let entries = journal?.deliveries.filter { $0.capture && !$0.abandoned && !$0.queueConfirmed && $0.reply == nil } ?? []
    let retired = Set(journal?.retired.filter { $0.until <= now }.map(\.mailbox) ?? [])
    for entry in entries {
      let missing = Set(entry.recordIDs.filter { !captureExists($0) })
      let counted = entry.countedMissingIDs ?? []
      let retryDue = entry.retry && !retryIsDelayed(entry.operation)
      let age = now.timeIntervalSince(entry.createdAt)
      let unobservable = retired.contains(entry.mailbox) || age >= Self.mailboxRetention
      let discard = retryDue || unobservable || age >= 86_400 || (!entry.putConfirmed && !missing.isEmpty)
      let unknown = entry.attemptedPut && !entry.retry ? missing : []
      guard discard || unknown != counted else { continue }
      try update { state in
        guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce }) else { return }
        state.unknownOutcomes = max(0, state.unknownOutcomes - counted.count) + unknown.count
        if discard { Self.tombstone(state.deliveries.remove(at: i), in: &state) }
        else { state.deliveries[i].countedMissingIDs = unknown }
      }
    }
  }

  private func advanceRetry(_ op: String, status: Int? = nil, in state: inout RemoteRelayJournal) {
    if pumping, !retryAdvancedThisCycle.insert(op).inserted { return }
    let now = clock()
    let previous = state.retryDelays?[op]
    if let previous, previous.until > now {
      if let status { state.retryDelays?[op]?.status = status }
      return
    }
    let seconds = min(3600, (previous?.seconds ?? 15) * 2)
    var delays = state.retryDelays ?? [:]
    delays[op] = .init(until: now.addingTimeInterval(seconds), seconds: seconds, status: status)
    state.retryDelays = delays
  }

  private func retryIsDelayed(_ operation: String) -> Bool {
    guard let delay = journal?.retryDelays?[operation] else { return false }
    return delay.until > clock()
  }

  private func renewSafeRequests() async throws {
    guard let active = journal?.active, journal?.disabled.contains(active) == false else { return }
    let now = clock()
    let pending = journal?.deliveries.filter {
      !$0.capture && !$0.queueConfirmed && !$0.abandoned && $0.reply == nil && Self.canReseal($0.operation)
        && !retryIsDelayed($0.operation) && ($0.retry || now.timeIntervalSince($0.createdAt) >= 86_400)
    } ?? []
    for entry in pending {
      guard mailboxOperationAllowed(entry.operation), let body = entry.body else { continue }
      let request = try await codec().makeSealedRequest(op: entry.operation, body: body)
      let limit = try await messageLimit(active)
      guard journal?.active == active else { return }
      guard mailboxOperationAllowed(entry.operation) else { continue }
      guard request.wireData.count < limit else {
        try discardOversized(entry)
        continue
      }
      try update { state in
        guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce && $0.reply == nil }) else { return }
        Self.tombstone(state.deliveries[i], in: &state)
        state.deliveries[i] = .init(nonce: request.nonce, operation: entry.operation, recordIDs: entry.recordIDs,
          mailbox: active, createdAt: now, capture: false, fingerprint: entry.fingerprint, body: body, wire: request.wireData)
      }
    }
  }

  private func submit(_ box: RemoteRelayMailbox, client: any RelayMailboxClient) async throws {
    let entries = journal?.deliveries.filter {
      !$0.abandoned && !$0.queueConfirmed && $0.mailbox == box && !$0.putConfirmed && $0.reply == nil && !$0.retry
        && !retryIsDelayed($0.operation)
    } ?? []
    for entry in entries.filter(\.capture) + entries.filter({ !$0.capture }) {
      guard mailboxOperationAllowed(entry.operation), let wire = entry.wire else { continue }
      try validate()
      let limit = try await messageLimit(box)
      // Lease the actual PUT, including its durable submission marker. Do
      // not hold the gate while probing the box or waiting for the receipt.
      let gate = Self.allowedDuringPause(entry.operation) ? nil : writeGate
      do { try gate?.begin() } catch is RemoteSwitchWriteGate.Paused { continue }
      defer { gate?.end() }
      guard wire.count < limit else {
        try discardOversized(entry)
        continue
      }
      if writeGate?.isPaused != true { try reconcileCapture() }
      guard journal?.deliveries.contains(where: { $0.nonce == entry.nonce }) == true else { continue }
      if !entry.attemptedPut {
        if entry.capture { try markCaptureSubmitted(entry.recordIDs, requireDurable: true) }
        try update { state in
          guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce }) else { return }
          state.deliveries[i].attemptedPut = true
        }
      }
      do {
        try await client.putUpMessage(id: entry.nonce, data: wire)
        submittedThisCycle = true
      }
      catch RelayMailboxError.httpError(413) {
        limits[box] = entry.capture ? min(limit, wire.count) : nil
        if entry.capture {
          try update { state in
            if entry.recordIDs.count > 1 {
              state.captureBatchLimit = min(state.captureBatchLimit ?? 200, entry.recordIDs.count / 2)
            } else if let id = entry.recordIDs.first, captureExists(id) {
              var oversized = (state.relayOversizedCaptureIDs ?? []).filter(captureExists)
              oversized.insert(id)
              state.relayOversizedCaptureIDs = oversized
            }
          }
        }
        try discardOversized(entry)
        submittedThisCycle = true  // Recheck the advertised limit before the next batch.
        return
      }
      try update { state in
        guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce }) else { return }
        state.deliveries[i].putConfirmed = true
        state.deliveries[i].wire = nil
      }
    }
  }

  private func discardOversized(_ entry: RemoteRelayJournal.Delivery) throws {
    if inUse.contains(entry.nonce) { oversizedReplies.insert(entry.nonce) }
    try discard(entry.nonce)
    if inUse.contains(entry.nonce) { oversizedReplies.insert(entry.nonce) }
  }

  private func consume(_ box: RemoteRelayMailbox, client: any RelayMailboxClient) async throws {
    var cursor: String?
    repeat {
      guard writeGate?.isPaused != true || hasPausedMailboxWork() else { return }
      try validate()
      let page = try await client.listDownMessages(after: cursor, limit: 100)
      for message in page.messages {
        guard message.size > 0, message.size <= DeviceProtocol.maxEnvelopeBytes,
              DeviceProtocol.base64URLDecode(message.id, expectedLength: 16) != nil else { continue }
        if writeGate?.isPaused == true, journal?.deliveries.contains(where: {
          $0.mailbox == box && $0.nonce == message.id && Self.allowedDuringPause($0.operation)
        }) != true { continue }
        // A previously authenticated response only needs its DELETE retried.
        if journal?.deliveries.contains(where: {
          $0.mailbox == box && $0.nonce == message.id && ($0.queueConfirmed || $0.reply != nil)
        }) == true { continue }
        let wire: Data
        do { wire = try await client.getDownMessage(id: message.id) }
        catch RelayMailboxError.notFound { continue }
        try validate()
        if let entry = journal?.deliveries.first(where: { $0.mailbox == box && $0.nonce == message.id }) {
          if mailboxOperationAllowed(entry.operation) { try await consumeReply(entry, wire: wire, client: client) }
          continue
        }
        guard writeGate?.isPaused != true else { continue }
        if journal?.superseded.contains(where: { $0.mailbox == box && $0.nonce == message.id }) == true {
          if (try? await codec().openResponseEnvelope(wireData: wire, requestNonce: message.id)) != nil {
            try await client.deleteDownMessage(id: message.id)
          }
        } else if let plain = try? await codec().openPushEnvelope(wireData: wire, messageID: message.id),
                  let push = try? RelayPushMessage.decode(from: plain) {
          try await consumePush(push, id: message.id, box: box, client: client)
        }
      }
      guard let next = page.next, !page.messages.isEmpty, next != cursor else { return }
      cursor = next
    } while true
  }

  private func consumeReply(_ entry: RemoteRelayJournal.Delivery, wire: Data,
                            client: any RelayMailboxClient) async throws {
    guard let payload = try? await codec().openResponseEnvelope(wireData: wire, requestNonce: entry.nonce) else { return }
    if payload.status == 401 {
      access?.freeze(route)
      throw DeviceClientError.deviceRemoved(message: payload.errorMessage)
    }
    guard mailboxOperationAllowed(entry.operation) else { return }
    if (500...599).contains(payload.status) && Self.canReseal(entry.operation), entry.reply == nil {
      if !entry.retry {
        try update { state in
          guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce }) else { return }
          state.deliveries[i].retry = true
          advanceRetry(entry.operation, in: &state)
        }
      }
      try await client.deleteDownMessage(id: entry.nonce)
      return
    }
    if payload.status == 200, entry.operation == "ingest",
       DeliveryReceipt.decode(payload.bodyData, batchCount: entry.recordIDs.count) == nil { return }
    if entry.reply == nil {
      try update { state in
        guard let i = state.deliveries.firstIndex(where: { $0.nonce == entry.nonce }) else { return }
        state.deliveries[i].reply = wire
        state.deliveries[i].wire = nil
        state.deliveries[i].body = nil
        if (200..<300).contains(payload.status) {
          succeededThisCycle.insert(entry.operation)
        }
        if entry.capture, payload.status == 200 {
          let resolved = state.deliveries[i].countedMissingIDs?.count ?? 0
          state.unknownOutcomes = max(0, state.unknownOutcomes - resolved)
          state.deliveries[i].countedMissingIDs = nil
        }
      }
    }
  }

  private func consumePush(_ push: RelayPushMessage, id: String, box: RemoteRelayMailbox,
                           client: any RelayMailboxClient) async throws {
    if case .unknown = push { return }
    if case .relayMoved(let next) = push {
      if journal?.active == box { try await install(next, authenticatedDirect: false) }
      try await client.deleteDownMessage(id: id)
      wakeAgain = true
      return
    }
    guard let projection, journal?.active == box, runningPushes.isEmpty else { return }
    runningPushes.insert(id)
    // A projection handler may send projection.pull/ack through this same
    // session. Keep the pump free to receive the resulting RPC receipts.
    Task { [weak self] in
      do {
        try await projection(push)
        try await self?.deleteAppliedPush(id, client: client)
      } catch { }
      await self?.pushFinished(id)
    }
  }

  private func deleteAppliedPush(_ id: String, client: any RelayMailboxClient) async throws {
    try validate()
    try await client.deleteDownMessage(id: id)
  }

  private func pushFinished(_ id: String) { runningPushes.remove(id) }

  private func note(_ error: Error, for box: RemoteRelayMailbox) throws {
    if case RelayMailboxError.unauthorized = error {
      try update { if !$0.disabled.contains(box) { $0.disabled.append(box) } }
      return
    }
    if error is CancellationError || error is RemoteSwitchWriteGate.Paused { return }
    let seconds = min(3600, (backoff[box]?.seconds ?? 15) * 2)
    backoff[box] = (clock().addingTimeInterval(seconds), seconds)
  }

  struct UnusedTransport: DeviceTransport {
    let maxEnvelopeBytes = DeviceProtocol.maxEnvelopeBytes
    func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse { throw Failure.unavailable }
  }

  private struct RoutedTransport: DeviceTransport {
    let owner: RemoteDeviceSession
    let maxEnvelopeBytes = DeviceProtocol.maxEnvelopeBytes
    func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
      try await owner.dispatch(request, timeout: nil)
    }
    func send(_ request: SealedDeviceRequest, timeout: TimeInterval) async throws -> DeviceTransportResponse {
      try await owner.dispatch(request, timeout: timeout)
    }
  }
}
