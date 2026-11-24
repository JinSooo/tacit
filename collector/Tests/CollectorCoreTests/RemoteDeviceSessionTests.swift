import CryptoKit
import Foundation
import Testing
@testable import CollectorCore

private final class RelayTestState: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var instant = Date()
  private var reads = 0
  var readCount: Int { lock.withLock { reads } }
  var keys: RemoteDeviceLink.Keys {
    .init(read: { key in self.lock.withLock { self.reads += 1; return self.values[key] } },
          create: { key, value in self.lock.withLock { self.values[key] = value } },
          remove: { key in self.lock.withLock { self.values[key] = nil } })
  }
  var now: Date { lock.withLock { instant } }
  func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private actor RelayBox: RelayMailboxClient {
  var sent: [(String, Data)] = []
  var down: [(String, Data)] = []
  var deleted: [String] = []
  var downloaded: [String] = []
  private var suspendGetID: String?
  private var suspendedGet: CheckedContinuation<Void, Never>?
  var nextError: RelayMailboxError?
  private var suspendedPut: CheckedContinuation<Void, Never>?
  private var suspendPut = false

  func failNext(_ error: RelayMailboxError) { nextError = error }
  func deliver(id: String, wire: Data) { down.append((id, wire)) }
  func listDownMessages(after: String?, limit: Int) -> (messages: [RelayMessageMeta], next: String?) {
    (down.map { .init(id: $0.0, size: $0.1.count) }, nil)
  }
  func getDownMessage(id: String) async throws -> Data {
    downloaded.append(id)
    if id == suspendGetID {
      suspendGetID = nil
      await withCheckedContinuation { suspendedGet = $0 }
    }
    guard let data = down.first(where: { $0.0 == id })?.1 else { throw RelayMailboxError.notFound }
    return data
  }
  func deleteDownMessage(id: String) {
    deleted.append(id)
    down.removeAll { $0.0 == id }
  }
  func pauseGet(_ id: String) { suspendGetID = id }
  func resumeGet() {
    suspendedGet?.resume()
    suspendedGet = nil
    suspendGetID = nil
  }
  func suspendNextPut() { suspendPut = true }
  func resumePut() {
    suspendedPut?.resume()
    suspendedPut = nil
  }
  func putUpMessage(id: String, data: Data) async throws {
    sent.append((id, data))
    if suspendPut {
      suspendPut = false
      await withCheckedContinuation { suspendedPut = $0 }
    }
    if let nextError {
      self.nextError = nil
      throw nextError
    }
  }
}

private struct RelayTestDirect: DeviceTransport {
  let maxEnvelopeBytes = DeviceProtocol.maxEnvelopeBytes
  let perform: @Sendable (SealedDeviceRequest) throws -> DeviceTransportResponse
  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse { try perform(request) }
}

private struct RelayFixture {
  let directory: URL
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let device = Curve25519.KeyAgreement.PrivateKey()
  let state = RelayTestState()
  let firstBox = RelayBox()
  let secondBox = RelayBox()
  let first: DeviceRelayConfig
  let second: DeviceRelayConfig
  let access: RemoteDeviceAccess
  let route: HubBinding.Route
  let link: RemoteDeviceLink
  let outbox: URL

  init(addresses: [URL] = [], writeGate: RemoteSwitchWriteGate? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("tacit-relay-" + UUID().uuidString)
    first = try Self.config()
    second = try Self.config()
    let remote = try HubBinding.Remote(hubID: DeviceProtocol.hubID(for: hub.publicKey),
      hubPublicKey: DeviceEnvelope.publicKeyBase64URL(hub.publicKey))
    let parent = directory.appendingPathComponent(remote.dir, isDirectory: true)
    link = try RemoteDeviceLink(identity: remote, deviceID: "mac-abcd2345", addresses: addresses)
    let preparing = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: remote)
    let committed = HubBinding(generation: 1, target: .remote, phase: .committed, remote: remote)
    route = committed.route
    outbox = directory.appendingPathComponent("outbox-1-\(remote.hub_id)/outbox", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    try preparing.write(to: directory, replacing: .legacyLocal)
    try committed.write(to: directory, replacing: preparing)
    try BindingFile.write(JSONEncoder().encode(link), named: LocalDeviceLink.File.collector.rawValue, in: parent)
    try BindingFile.write(JSONEncoder().encode(RemoteDeviceLink.Relay(first)), named: "relay.json", in: parent)
    try state.keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id), device.rawRepresentation)
    try state.keys.create(RemoteDeviceLink.Relay.account(deviceID: link.device_id), Data(first.token.utf8))
    access = RemoteDeviceAccess(dataDirectory: directory, keys: state.keys, writeGate: writeGate)
  }

  private static func config() throws -> DeviceRelayConfig {
    try .init(url: "http://127.0.0.1:48669", space: DeviceEnvelope.randomNonce(),
              up: DeviceEnvelope.randomNonce(), down: DeviceEnvelope.randomNonce(),
              token: DeviceEnvelope.randomNonce() + DeviceEnvelope.randomNonce())
  }

  func session(limit: Int = 1_048_576, direct: @escaping RemoteDeviceAccess.TransportFactory = { _ in
    throw RemoteDeviceSession.Failure.unavailable
  }) throws -> RemoteDeviceSession {
    let firstSpace = first.space
    let firstBox = firstBox
    let secondBox = secondBox
    return try RemoteDeviceSession(access: access, route: route, link: link,
      revision: access.credentialRevision(for: route), transport: direct,
      mailboxServices: .init(open: { $0.space == firstSpace ? firstBox : secondBox },
                             limit: { _ in limit }, automatic: false), clock: { [state] in state.now })
  }

  func record(_ body: String = "synthetic relay data") throws -> Record {
    let record = Record(device: "mac", source: "mac.screen", kind: "event", start: state.now,
                        context: nil, title: "Fixture", body: body, capture: .init(method: "ax"))
    // The relay stage observes the queue's durable file identity. The real
    // encrypted OutboxStore is exercised by the process test.
    try Data([0]).write(to: outbox.appendingPathComponent(record.id + ".enc"))
    return record
  }

  func wire(_ plaintext: [String: DeviceJSON], id: String) throws -> Data {
    let envelope = try DeviceEnvelope.sealResponsePlaintext(JSONEncoder().encode(plaintext), requestNonce: id,
      senderPrivateKey: hub, recipientPublicKey: device.publicKey)
    return try JSONEncoder().encode(envelope)
  }

  func reply(_ id: String, accepted: Int) throws -> Data {
    try wire(["status": .int(200), "body": .object([
      "accepted": .int(Int64(accepted)), "duplicates": .int(0), "rejected": .array([]),
    ])], id: id)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func enqueueCapture(_ records: [Record], session: RemoteDeviceSession) async throws {
  do {
    _ = try await session.sendCapture(records)
    Issue.record("Relay PUT is not a delivery receipt")
  } catch RemoteDeviceSession.Failure.awaitingReceipt {}
}

@Test func sharedRelayReusesCiphertextAfterLostPutAndDoesNotDeleteIncompleteReceipt() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let record = try f.record()
  let first = try f.session()
  try await enqueueCapture([record], session: first)
  await f.firstBox.failNext(.transportError("dropped response"))
  await first.runPump()
  let attempt = try #require(await f.firstBox.sent.first)
  let recovered = try f.session()
  await recovered.runPump()
  let submissions = await f.firstBox.sent
  #expect(submissions.count == 2)
  #expect(submissions.last?.0 == attempt.0)
  #expect(submissions.last?.1 == attempt.1)

  await f.firstBox.deliver(id: attempt.0, wire: try f.reply(attempt.0, accepted: 0))
  await recovered.runPump()
  #expect(try await recovered.completedCapture() == nil)
  #expect(await f.firstBox.deleted.isEmpty)
  await f.firstBox.deleteDownMessage(id: attempt.0)
  let earlyID = try DeviceEnvelope.randomNonce()
  let unknownID = try DeviceEnvelope.randomNonce()
  await f.firstBox.deliver(id: earlyID, wire: try f.reply(earlyID, accepted: 1))
  await f.firstBox.deliver(id: unknownID, wire: try f.wire(["kind": .string("future.event")], id: unknownID))
  await f.firstBox.deliver(id: attempt.0, wire: try f.reply(attempt.0, accepted: 1))
  await recovered.runPump()
  let delivered = try #require(try await recovered.completedCapture())
  #expect(delivered.ids == [record.id])
  #expect(await f.firstBox.deleted == [attempt.0]) // only the fixture removed the invalid response
  try await recovered.confirmCapture(nonce: attempt.0)
  await recovered.runPump()
  #expect(await f.firstBox.deleted == [attempt.0, attempt.0])
  await f.firstBox.deliver(id: attempt.0, wire: try f.reply(attempt.0, accepted: 1))
  await recovered.runPump()
  #expect(await f.firstBox.deleted == [attempt.0, attempt.0, attempt.0])
  #expect(try await recovered.completedCapture() == nil)
}

@Test func sharedRelayRetiresOldBoxAndSettlesItsReceipt() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let record = try f.record()
  try await enqueueCapture([record], session: session)
  await session.runPump()
  let nonce = try #require(await f.firstBox.sent.first?.0)
  let change = try DeviceEnvelope.randomNonce()
  let config = try JSONDecoder().decode(DeviceJSON.self, from: JSONEncoder().encode(f.second))
  await f.firstBox.deliver(id: change, wire: try f.wire(["kind": .string("relay.moved"), "relay": config], id: change))
  await session.runPump()
  #expect(try await session.selectedEndpoint() == .relay(f.second))
  let restarted = try f.session()
  try await enqueueCapture([try f.record("new space")], session: restarted)
  await restarted.runPump()
  #expect(await f.secondBox.sent.count == 1)
  await f.firstBox.deliver(id: nonce, wire: try f.reply(nonce, accepted: 1))
  await restarted.runPump()
  #expect(try await restarted.completedCapture()?.ids == [record.id])
  try await restarted.confirmCapture(nonce: nonce)
  await restarted.runPump()
  #expect(await f.firstBox.deleted.contains(nonce))
}

@Test func sharedRelaySkipsOversizedCaptureAndDoesNotRestoreEvictedCiphertext() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session(limit: 2048)
  let big = try f.record(String(repeating: "z", count: 5000))
  let small = try f.record()
  try await enqueueCapture([big, small], session: session)
  await session.runPump()
  #expect(try await session.reservedCaptureIDs() == [small.id])
  #expect(await f.firstBox.sent.count == 1)
  try FileManager.default.removeItem(at: f.outbox.appendingPathComponent(small.id + ".enc"))
  f.state.advance(86_401)
  await session.runPump()
  #expect(try await session.unknownCaptureOutcomes() == 1)
  #expect(await f.firstBox.sent.count == 1)
  #expect(FileManager.default.fileExists(atPath: f.outbox.appendingPathComponent(big.id + ".enc").path))
}

@Test(arguments: [429, 507]) func sharedRelayBacksOffAfterCapacityErrors(status: Int) async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  try await enqueueCapture([try f.record()], session: session)
  await f.firstBox.failNext(.rateLimited(status: status))
  await session.runPump()
  await session.runPump()
  #expect(await f.firstBox.sent.count == 1)
  f.state.advance(31)
  await session.runPump()
  #expect(await f.firstBox.sent.count == 2)
}

@Test func sharedRelayNeverReroutesAForbiddenIngestOrUncertainDelete() async throws {
  let f = try RelayFixture(addresses: [URL(string: "http://127.0.0.1:48668")!])
  defer { f.remove() }
  let session = try f.session { _ in
    RelayTestDirect { request in
      if request.operation == "delete" { throw DeviceClientError.transportError("response lost") }
      return DeviceTransportResponse(statusCode: 403)
    }
  }
  let record = try f.record()
  await #expect(throws: DeviceClientError.plaintextError(status: 403, message: nil)) {
    _ = try await session.sendCapture([record])
  }
  let client = try await session.clientInBackground()
  await #expect(throws: DeviceClientError.transportError("response lost")) {
    _ = try await client.send(op: "delete", body: ["ids": .array([.string(record.id)])])
  }
  await session.runPump()
  #expect(await f.firstBox.sent.isEmpty)
}

@Test(arguments: [400, 403, 409, 429])
func relayRegressionReleasesRequestRejectionWithoutDroppingCapture(status: Int) async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let record = try f.record()
  try await enqueueCapture([record], session: session)
  await session.runPump()
  let nonce = try #require(await f.firstBox.sent.first?.0)
  await f.firstBox.deliver(id: nonce, wire: try f.wire(["status": .int(Int64(status)), "body": .object([:])], id: nonce))
  await session.runPump()

  let restarted = try f.session()
  let done = try #require(try await restarted.completedCapture())
  #expect(done.ids == [record.id])
  #expect(done.nonce == nonce)
  #expect(done.rejectedStatus == status)
  try await restarted.releaseRejectedCapture(nonce: nonce, status: status)
  await restarted.runPump()
  #expect(try await restarted.completedCapture() == nil)
  #expect(FileManager.default.fileExists(atPath: f.outbox.appendingPathComponent(record.id + ".enc").path))
  #expect(try await restarted.reservedCaptureIDs().isEmpty)
  let again = try f.session()
  await #expect(throws: DeviceClientError.operationError(op: "ingest", status: status, message: nil)) {
    _ = try await again.sendCapture([record])
  }
  f.state.advance(31)
  try await enqueueCapture([record], session: again)
  await again.runPump()
  #expect(await f.firstBox.sent.count == 2)
  #expect(try await again.reservedCaptureIDs() == [record.id])
}

private extension RelayFixture {
  func journal() throws -> RemoteRelayJournal {
    let key = try access.relayJournalKey(for: route, link: link, revision: access.credentialRevision(for: route))
    return try RemoteRelayJournal.load(key: key, in: directory.appendingPathComponent("remote-\(link.hub_id)"),
      name: "relay-delivery-\(route.generation).enc", route: route, deviceID: link.device_id)
  }

  func waitForDelivery(op: String) async throws -> RemoteRelayJournal.Delivery {
    for _ in 0..<200 {
      if let entry = try journal().deliveries.first(where: { $0.operation == op }) { return entry }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteDeviceSession.Failure.awaitingReceipt
  }
}

@Test func relayRegressionDeliversFreshPageForTheSameCursor() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  // Each reply is close to a real relay page limit. Keeping all the pages
  // would exceed the journal snapshot limit before this loop finishes.
  let page = String(repeating: "x", count: 635_000)
  for cursorValue in 1...11 {
    let fetch = Task { try await client.send(op: "projection.pull", body: ["cursor": .int(5)], timeout: 2) }
    defer { fetch.cancel() }
    let pending = try await f.waitForDelivery(op: "projection.pull")
    await session.runPump()
    await f.firstBox.deliver(id: pending.nonce, wire: try f.wire(
      ["status": .int(200), "body": .object(["cursor": .int(Int64(cursorValue)), "page": .string(page)])], id: pending.nonce))
    await session.runPump()
    #expect(try await fetch.value.body["cursor"] == .int(Int64(cursorValue)))
    try #require(try f.journal().deliveries.isEmpty)
  }
}

@Test func relayRegressionPumpStopsSubmittingDuringSwitchPause() async throws {
  let gate = RemoteSwitchWriteGate()
  let f = try RelayFixture(writeGate: gate)
  defer { f.remove() }
  let session = try f.session()
  let record = try f.record()
  try await enqueueCapture([record], session: session)
  gate.setPaused(true)
  await session.runPump()
  #expect(gate.isIdle)
  #expect(await f.firstBox.sent.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: f.outbox.appendingPathComponent(".submitted-" + record.id).path))
  gate.setPaused(false)
  await session.runPump()
  #expect(await f.firstBox.sent.count == 1)
}

@Test func relayRegressionAudioWaitReleasesSwitchAfterPause() async throws {
  let gate = RemoteSwitchWriteGate()
  let f = try RelayFixture(writeGate: gate)
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  let sync = Task {
    try gate.begin()
    defer { gate.end() }
    return try await client.send(op: "audio.sync", timeout: 2)
  }
  defer { sync.cancel() }
  _ = try await f.waitForDelivery(op: "audio.sync")
  gate.setPaused(true)
  for _ in 0..<75 where !gate.isIdle { try await Task.sleep(for: .milliseconds(10)) }
  #expect(gate.isIdle)
  await #expect(throws: RemoteSwitchWriteGate.Paused.self) { _ = try await sync.value }
}

@Test func relayRegressionRetriesMissingDeleteAfterProcessRestart() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  try await enqueueCapture([try f.record()], session: session)
  await session.runPump()
  let nonce = try #require(await f.firstBox.sent.first?.0)
  await f.firstBox.deliver(id: nonce, wire: try f.reply(nonce, accepted: 1))
  await session.runPump()
  try await session.confirmCapture(nonce: nonce)
  // The mailbox has deleted the reply, but the process died before it could save that fact.
  await f.firstBox.deleteDownMessage(id: nonce)
  let restarted = try f.session()
  await restarted.runPump()
  #expect(try f.journal().deliveries.isEmpty)
  #expect(await f.firstBox.deleted == [nonce, nonce])
  #expect(try await restarted.unknownCaptureOutcomes() == 0)
}

@Test func relayRegressionExpiresRetiredBoxAndCountsUnknownCapture() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let record = try f.record()
  let missing = try f.record()
  try await enqueueCapture([record, missing], session: session)
  await session.runPump()

  let change = try DeviceEnvelope.randomNonce()
  let next = try JSONDecoder().decode(DeviceJSON.self, from: JSONEncoder().encode(f.second))
  await f.firstBox.deliver(id: change, wire: try f.wire(["kind": .string("relay.moved"), "relay": next], id: change))
  await session.runPump()
  f.state.advance(7 * 86_400 + 1)
  try FileManager.default.removeItem(at: f.outbox.appendingPathComponent(missing.id + ".enc"))

  let restarted = try f.session()
  await restarted.runPump()
  #expect(try f.journal().deliveries.isEmpty)
  #expect(try f.journal().retired.isEmpty)
  #expect(try await restarted.unknownCaptureOutcomes() == 1)
  #expect(try await restarted.reservedCaptureIDs().isEmpty)
  try await enqueueCapture([record], session: restarted)
  await restarted.runPump()
  #expect(await f.secondBox.sent.count == 1)
  #expect(try await restarted.unknownCaptureOutcomes() == 1)
}

@Test func relayRegressionResealsAfterPersistentExponentialDelay() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  let call = Task { try await client.send(op: "audio.sync", timeout: 0.05) }
  _ = try await f.waitForDelivery(op: "audio.sync")
  await #expect(throws: RemoteDeviceSession.Failure.awaitingReceipt) { _ = try await call.value }
  await session.runPump()

  let firstNonce = try #require(await f.firstBox.sent.last?.0)
  await f.firstBox.deliver(id: firstNonce, wire: try f.wire(["status": .int(503), "body": .object([:])], id: firstNonce))
  await session.runPump()
  #expect(await f.firstBox.sent.count == 1)
  let restarted = try f.session()
  f.state.advance(29)
  await restarted.runPump()
  #expect(await f.firstBox.sent.count == 1)
  f.state.advance(2)
  await restarted.runPump()
  #expect(await f.firstBox.sent.count == 2)
  let secondNonce = try #require(await f.firstBox.sent.last?.0)
  #expect(secondNonce != firstNonce)
  await f.firstBox.deliver(id: secondNonce, wire: try f.wire(["status": .int(503), "body": .object([:])], id: secondNonce))
  await restarted.runPump()
  f.state.advance(59)
  await restarted.runPump()
  #expect(await f.firstBox.sent.count == 2)
  f.state.advance(2)
  await restarted.runPump()
  #expect(await f.firstBox.sent.count == 3)
}

@Test func relayRegressionCredentialsAreCachedAcrossEndpointChecks() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  #expect(try await session.selectedEndpoint() == .relay(f.first))

  let restarted = try f.session()
  let before = f.state.readCount
  _ = try await restarted.clientInBackground()
  _ = try await restarted.clientInBackground()
  #expect(try await restarted.selectedEndpoint() == .relay(f.first))
  #expect(try await restarted.selectedEndpoint() == .relay(f.first))
  await restarted.runPump()
  #expect(f.state.readCount - before == 1)
}

@Test func relayRegressionEvictedRecordDoesNotSupersedeConfirmedBatch() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let evicted = try f.record("evicted")
  let retained = try f.record("retained")
  try await enqueueCapture([evicted, retained], session: session)
  await session.runPump()
  let nonce = try #require(await f.firstBox.sent.first?.0)
  try FileManager.default.removeItem(at: f.outbox.appendingPathComponent(evicted.id + ".enc"))

  for _ in 0..<2 {
    #expect(try await session.reservedCaptureIDs().contains(retained.id))
    #expect(try await session.unknownCaptureOutcomes() == 1)
    await session.runPump()
  }
  await f.firstBox.deliver(id: nonce, wire: try f.reply(nonce, accepted: 2))
  await session.runPump()
  #expect(try await session.completedCapture()?.ids == [evicted.id, retained.id])
  #expect(try await session.unknownCaptureOutcomes() == 0)
  try await session.confirmCapture(nonce: nonce)
  #expect(try await f.session().unknownCaptureOutcomes() == 0)
  #expect(await f.firstBox.sent.count == 1)
}

@Test func relayRegressionMailbox413ReleasesSlotAndReportsError() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  for value in 1...6 {
    let fetch = Task {
      try await client.send(op: "history.import.batch", body: ["batch": .int(Int64(value))], timeout: 2)
    }
    defer { fetch.cancel() }
    _ = try await f.waitForDelivery(op: "history.import.batch")
    await f.firstBox.failNext(.httpError(status: 413))
    await session.runPump()
    await #expect(throws: DeviceClientError.envelopeTooLarge(message: "信箱请求太大，需重新分批")) {
      _ = try await fetch.value
    }
    #expect(try f.journal().deliveries.isEmpty)
  }
}

@Test(arguments: [false, true])
func relayRegressionBindingChangeDiscardsSharedSession(freeze: Bool) async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  weak let released = try f.access.session(for: f.route, link: f.link) { _ in
    throw RemoteDeviceSession.Failure.unavailable
  }
  try #require(released != nil)
  if freeze {
    f.access.freeze(f.route)
  } else {
    let committed = try HubBinding.read(from: f.directory)
    let switching = HubBinding(generation: committed.generation, target: .remote, phase: .switching_back,
                               remote: committed.remote)
    try switching.write(to: f.directory, replacing: committed)
    try HubBinding(generation: 2, target: .local, phase: .local, remote: nil).write(to: f.directory, replacing: switching)
    #expect(try f.access.route().remote == nil)
  }
  for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
  #expect(released == nil)
}

@Test func relayRegressionMarksOnlyRecordsInsideTheSealedBatchAsSubmitted() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session(limit: 2048)
  // Both records fit individually, but not together.
  let body = String(repeating: "x", count: 800)
  let records = try [f.record(body), f.record(body)]
  let budget = try await session.recordBatchBudget()
  #expect(records.allSatisfy { session.captureRecordFits($0, budget: budget) })

  try await enqueueCapture(records, session: session)
  await session.runPump()
  #expect(try await session.reservedCaptureIDs() == [records[0].id])
  let files = try FileManager.default.contentsOfDirectory(atPath: f.outbox.path)
  #expect(files.filter { $0.hasPrefix(".submitted-") } == [".submitted-" + records[0].id])
  #expect(files.contains(records[1].id + ".enc")) // no marker means copyForSwitch considers it never submitted
}

@Test func relayRegressionInFlightPutHoldsSwitchLeaseThroughConfirmation() async throws {
  let gate = RemoteSwitchWriteGate()
  let f = try RelayFixture(writeGate: gate)
  defer { f.remove() }
  let session = try f.session()
  try await enqueueCapture([try f.record()], session: session)

  await f.firstBox.suspendNextPut()
  let pump = Task { await session.runPump() }
  for _ in 0..<100 {
    if await !f.firstBox.sent.isEmpty { break }
    try? await Task.sleep(for: .milliseconds(10))
  }
  gate.setPaused(true)
  #expect(await f.firstBox.sent.count == 1)
  #expect(!gate.isIdle)

  await f.firstBox.resumePut()
  await pump.value
  #expect(gate.isIdle)
  #expect(try f.journal().deliveries.first?.putConfirmed == true)
}

@Test func relayRegressionDirectRouteWinsOverUnclaimedMailboxReply() async throws {
  let origin = try #require(URL(string: "http://127.0.0.1:48690"))
  let f = try RelayFixture(addresses: [origin])
  defer { f.remove() }
  let directAvailableAt = f.state.now.addingTimeInterval(1)
  let session = try f.session { _ in
    guard f.state.now >= directAvailableAt else { throw RemoteDeviceSession.Failure.unavailable }
    return RelayTestDirect { request in
      let reply = try f.wire(["status": .int(200), "body": .object(["path": .string("direct")])], id: request.nonce)
      return DeviceTransportResponse(statusCode: 200, body: reply)
    }
  }
  let client = try await session.clientInBackground()
  let call = Task { try await client.send(op: "status.get", timeout: 0.05) }
  let pending = try await f.waitForDelivery(op: "status.get")
  await #expect(throws: RemoteDeviceSession.Failure.awaitingReceipt) { _ = try await call.value }
  await session.runPump()
  await f.firstBox.deliver(id: pending.nonce, wire: try f.wire(
    ["status": .int(200), "body": .object(["path": .string("relay")])], id: pending.nonce))
  await session.runPump()
  try #require(try f.journal().deliveries.first?.reply != nil)

  f.state.advance(2)
  await session.networkChanged()
  #expect(try await client.send(op: "status.get", timeout: 2).body["path"] == .string("direct"))
}

@Test func relayRegressionExpiredCaptureIsReleasedBeforeFirstPump() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let record = try f.record()
  try await enqueueCapture([record], session: session)
  await session.runPump()
  let file = f.outbox.appendingPathComponent(record.id + ".enc")
  try FileManager.default.removeItem(at: file)
  _ = try await session.reservedCaptureIDs()
  #expect(try await session.unknownCaptureOutcomes() == 1)
  try Data([0]).write(to: file) // The same durable ID is available for retry again.
  f.state.advance(30 * 86_400 + 1)

  let restarted = try f.session()
  #expect(try await restarted.reservedCaptureIDs().isEmpty)
  #expect(try await restarted.unknownCaptureOutcomes() == 0)
  #expect(try f.journal().deliveries.isEmpty)
}

@Test(arguments: ["history.import.changes", "history.import.verify", "history.import.status", "status.get",
                 "history.import.batch", "history.import.finish"])
func historyMailboxNeverReusesConsumedReply(op: String) async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let previousNonce = try DeviceEnvelope.randomNonce()
  let body: [String: DeviceJSON] = ["session_id": .string(UUID().uuidString)]
  let encoded = try JSONEncoder().encode(body)
  let fingerprint = Data(SHA256.hash(data: Data(op.utf8) + Data([0]) + encoded))
  let box = RemoteRelayMailbox(f.first)
  var entry = RemoteRelayJournal.Delivery(nonce: previousNonce, operation: op, recordIDs: [],
    mailbox: box, createdAt: f.state.now, capture: false, fingerprint: fingerprint, body: nil, wire: nil)
  entry.putConfirmed = true
  entry.queueConfirmed = true // Durable reply left by the pre-D delivery code.
  let refused = op == "history.import.batch" || op == "history.import.finish"
  entry.reply = try f.wire(["status": .int(refused ? 403 : 200),
                           "body": .object(["error": .string("authorization_expired")])], id: previousNonce)
  var journal = try f.journal()
  journal.deliveries = [entry]
  let key = try f.access.relayJournalKey(for: f.route, link: f.link, revision: f.access.credentialRevision(for: f.route))
  try journal.save(key: key, in: f.directory.appendingPathComponent("remote-\(f.link.hub_id)"),
                   name: "relay-delivery-\(f.route.generation).enc")
  let session = try f.session()
  let client = try await session.clientInBackground()
  let fetch = Task { try await client.send(op: op, body: body, timeout: 3) }
  defer { fetch.cancel() }
  var fresh: RemoteRelayJournal.Delivery?
  for _ in 0..<100 {
    fresh = try f.journal().deliveries.first { $0.operation == op && $0.nonce != previousNonce }
    if fresh != nil { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  let pending = try #require(fresh)
  await session.runPump()
  await f.firstBox.deliver(id: pending.nonce, wire: try f.wire(
    ["status": .int(200), "body": .object(["fresh": .bool(true)])], id: pending.nonce))
  await session.runPump()
  #expect(try await fetch.value.body["fresh"] == .bool(true))
  #expect(await f.firstBox.sent.map(\.0) == [pending.nonce])
}

@Test func historyMailboxSwitchBackRequiresFreshUnclaimedReply() async throws {
  let op = "history.import.changes"
  let gate = RemoteSwitchWriteGate()
  gate.setPaused(true)
  let f = try RelayFixture(writeGate: gate)
  defer { f.remove() }
  let previousNonce = try DeviceEnvelope.randomNonce()
  let body: [String: DeviceJSON] = ["session_id": .string(UUID().uuidString)]
  let encoded = try JSONEncoder().encode(body)
  let fingerprint = Data(SHA256.hash(data: Data(op.utf8) + Data([0]) + encoded))
  let box = RemoteRelayMailbox(f.first)
  var entry = RemoteRelayJournal.Delivery(nonce: previousNonce, operation: op, recordIDs: [],
    mailbox: box, createdAt: f.state.now, capture: false, fingerprint: fingerprint, body: nil, wire: nil)
  entry.putConfirmed = true
  entry.queueConfirmed = false // The earlier caller timed out before receiving this reply.
  entry.reply = try f.wire(["status": .int(200), "body": .object(["fresh": .bool(false)])], id: previousNonce)
  var journal = try f.journal()
  let backlog = try (0..<5).map { _ in
    RemoteRelayJournal.Delivery(nonce: try DeviceEnvelope.randomNonce(), operation: "history.import.batch",
      recordIDs: [], mailbox: box, createdAt: f.state.now, capture: false, fingerprint: Data(), putConfirmed: true)
  }
  journal.deliveries = [entry] + backlog
  let key = try f.access.relayJournalKey(for: f.route, link: f.link, revision: f.access.credentialRevision(for: f.route))
  try journal.save(key: key, in: f.directory.appendingPathComponent("remote-\(f.link.hub_id)"),
                   name: "relay-delivery-\(f.route.generation).enc")
  let session = try f.session()
  let client = try await session.clientInBackground()
  let fetch = Task { try await client.send(op: op, body: body, timeout: 3) }
  defer { fetch.cancel() }
  var fresh: RemoteRelayJournal.Delivery?
  for _ in 0..<100 {
    fresh = try f.journal().deliveries.first { $0.operation == op && $0.nonce != previousNonce }
    if fresh != nil { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  let pending = try #require(fresh)
  await session.runPump()
  await f.firstBox.deliver(id: pending.nonce, wire: try f.wire(
    ["status": .int(200), "body": .object(["fresh": .bool(true)])], id: pending.nonce))
  await session.runPump()
  #expect(try await fetch.value.body["fresh"] == .bool(true))
  #expect(await f.firstBox.sent.map(\.0) == [pending.nonce])
  #expect(try f.journal().deliveries.filter { $0.operation == "history.import.batch" }.count == 5)
}

@Test func relayCapture413SplitsAndIsolatesASingleRecordUntilDirectReturns() async throws {
  let f = try RelayFixture(addresses: [URL(string: "http://127.0.0.1:48705")!])
  defer { f.remove() }
  let session = try f.session()
  let large = try f.record("synthetic reply too large"), small = try f.record()
  try await enqueueCapture([large, small], session: session)
  await session.runPump()
  let batch = try #require(await f.firstBox.sent.first?.0)
  await f.firstBox.deliver(id: batch, wire: try f.wire(["status": .int(413), "body": .object([:])], id: batch))
  await session.runPump()
  let denied = try #require(try await session.completedCapture())
  #expect(denied.ids == [large.id, small.id])
  try await session.releaseRejectedCapture(nonce: batch, status: 413)
  f.state.advance(31)
  let restarted = try f.session()
  #expect(try await restarted.captureBatchLimits().count == 1)
  try await enqueueCapture([large, small], session: restarted)
  await restarted.runPump()
  let single = try #require(await f.firstBox.sent.last?.0)
  #expect(single != batch)
  await f.firstBox.deliver(id: single, wire: try f.wire(["status": .int(413), "body": .object([:])], id: single))
  await restarted.runPump()
  #expect(try await restarted.completedCapture()?.ids == [large.id])
  try await restarted.releaseRejectedCapture(nonce: single, status: 413)
  f.state.advance(61)
  #expect(try await restarted.captureBatchLimits().requiresDirect == [large.id])
  #expect(FileManager.default.fileExists(atPath: f.outbox.appendingPathComponent(large.id + ".enc").path))
  try await enqueueCapture([large, small], session: restarted)
  await restarted.runPump()
  #expect(try await restarted.reservedCaptureIDs() == [small.id])
  let direct = try f.session { _ in RelayTestDirect { _ in DeviceTransportResponse(statusCode: 200) } }
  #expect(try await direct.captureBatchLimits().requiresDirect.isEmpty)
  #expect(try await direct.captureBatchLimits().count == 200)
}

@Test func relayDeletesDeliveredReplyInSameMultiMessagePump() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  let first = Task { try await client.send(op: "history.import.changes", timeout: 4) }
  defer { first.cancel() }
  let firstEntry = try await f.waitForDelivery(op: "history.import.changes")
  let second = Task { try await client.send(op: "history.import.status", timeout: 4) }
  defer { second.cancel() }
  let secondEntry = try await f.waitForDelivery(op: "history.import.status")
  await session.runPump()
  for entry in [firstEntry, secondEntry] {
    await f.firstBox.deliver(id: entry.nonce, wire: try f.wire(
      ["status": .int(200), "body": .object(["marker": .string(entry.operation)])], id: entry.nonce))
  }
  await f.firstBox.pauseGet(secondEntry.nonce)
  let pump = Task { await session.runPump() }
  defer { Task { await f.firstBox.resumeGet() } }
  #expect(try await first.value.body["marker"] == .string(firstEntry.operation))
  let firstStored = try f.journal().deliveries.first { $0.nonce == firstEntry.nonce }
  #expect(firstStored?.queueConfirmed == true && firstStored?.reply == nil)
  await f.firstBox.resumeGet()
  await pump.value
  #expect(try await second.value.body["marker"] == .string(secondEntry.operation))
  #expect(Set(await f.firstBox.deleted) == [firstEntry.nonce, secondEntry.nonce])
  await session.runPump()
  #expect(await f.firstBox.downloaded == [firstEntry.nonce, secondEntry.nonce])
}

@Test func relayAdvancesSameOperationBackoffOnceThenDirectSuccessClearsIt() async throws {
  let f = try RelayFixture(addresses: [URL(string: "http://127.0.0.1:48705")!])
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  let first = Task { try await client.send(op: "status.get", body: ["fixture": .int(1)], timeout: 0.05) }
  _ = try await f.waitForDelivery(op: "status.get")
  await #expect(throws: RemoteDeviceSession.Failure.awaitingReceipt) { _ = try await first.value }
  let second = Task { try await client.send(op: "status.get", body: ["fixture": .int(2)], timeout: 0.05) }
  await #expect(throws: RemoteDeviceSession.Failure.awaitingReceipt) { _ = try await second.value }
  await session.runPump()
  let sent = await f.firstBox.sent
  try #require(sent.count == 2)
  for (index, (id, _)) in sent.enumerated() {
    await f.firstBox.deliver(id: id, wire: try f.wire(
      ["status": .int(index == 0 ? 503 : 200), "body": .object([:])], id: id))
  }
  await session.runPump()
  #expect(try f.journal().retryDelays?["status.get"]?.seconds == 30)

  let direct = try f.session { _ in
    RelayTestDirect { request in DeviceTransportResponse(statusCode: 200, body: try f.wire(
      ["status": .int(200), "body": .object([:])], id: request.nonce)) }
  }
  let viaDirect = try await direct.clientInBackground()
  #expect(try await viaDirect.send(op: "status.get").status == 200)
  #expect(try f.journal().retryDelays?["status.get"] == nil)

  let relay = try f.session()
  await relay.runPump()
  let latest = try #require(await f.firstBox.sent.last?.0)
  try #require(!sent.contains(where: { $0.0 == latest }))
  await f.firstBox.deliver(id: latest, wire: try f.wire(["status": .int(503), "body": .object([:])], id: latest))
  await relay.runPump()
  #expect(try f.journal().retryDelays?["status.get"]?.seconds == 30)
}

// 2026-11-24 终审回归：探测超时不占用信箱队列，迟到回执不能确认下一次探测。
@Test func selectedRelayDoesNotCountAsConnectedWithoutAuthenticatedReply() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let old = Task { await session.connectionState(timeout: 0.10) }
  let previous = try await f.waitForDelivery(op: "status.get").nonce
  await session.runPump()
  #expect(await old.value == .unconfirmed(.relay))
  for _ in 0..<5 {
    #expect(await session.connectionState(timeout: 0.01) == .unconfirmed(.relay))
  }
  #expect(try f.journal().deliveries.isEmpty)
  await f.firstBox.deliver(id: previous, wire: try f.wire(["status": .int(200), "body": .object([:])], id: previous))
  let check = Task { await session.connectionState(timeout: 2) }
  let nonce = try await f.waitForDelivery(op: "status.get").nonce
  #expect(nonce != previous)
  await session.runPump()
  await f.firstBox.deliver(id: nonce, wire: try f.wire(["status": .int(200), "body": .object([:])], id: nonce))
  await session.runPump()
  #expect(await check.value == .connected(.relay))
}

// 2026-11-24 终审回归：已有退避时，同轮成功回执和 503 不会提前续投。
@Test func finalReviewMixedReceiptsPreserveExistingRelayBackoff() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let client = try await session.clientInBackground()
  for index in 1...3 {
    await #expect(throws: RemoteDeviceSession.Failure.awaitingReceipt) {
      _ = try await client.send(op: "status.get", body: ["fixture": .int(Int64(index))], timeout: 0.01)
    }
  }
  await session.runPump()
  let ids = await f.firstBox.sent.map { $0.0 }
  try #require(ids.count == 3)
  func deliver(_ index: Int, _ status: Int64) async throws {
    let id = ids[index]
    await f.firstBox.deliver(id: id, wire: try f.wire(["status": .int(status), "body": .object([:])], id: id))
  }
  try await deliver(0, 503)
  await session.runPump()
  let until = try #require(f.journal().retryDelays?["status.get"]?.until)
  try await deliver(1, 200)
  try await deliver(2, 503)
  await session.runPump()
  #expect(try f.journal().retryDelays?["status.get"]?.until == until)
  #expect(await f.firstBox.sent.count == 3)
}

private actor ModelTestTransport: DeviceTransport {
  let maxEnvelopeBytes = DeviceProtocol.maxEnvelopeBytes
  let makeReply: @Sendable (SealedDeviceRequest) throws -> DeviceTransportResponse
  var requestCount = 0

  init(makeReply: @escaping @Sendable (SealedDeviceRequest) throws -> DeviceTransportResponse) {
    self.makeReply = makeReply
  }

  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
    if request.operation == "settings.models.test" {
      requestCount += 1
      try await Task.sleep(for: .milliseconds(400))
    }
    return try makeReply(request)
  }
}

@Test func modelConnectionTestSerializesDifferentTiers() async throws {
  let f = try RelayFixture(addresses: [URL(string: "http://127.0.0.1:48729")!])
  defer { f.remove() }
  let transport = ModelTestTransport { sealed in
    DeviceTransportResponse(statusCode: 200, body: try f.wire(
      ["status": .int(200), "body": .object([:])], id: sealed.nonce))
  }
  let session = try f.session { _ in transport }
  let client = try await session.clientInBackground()
  let first = Task { try await client.send(op: "settings.models.test", body: ["tier": .string("minute")]) }
  for _ in 0..<150 {
    if await transport.requestCount > 0 { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  await #expect(throws: DeviceClientError.operationError(op: "settings.models.test", status: 409, message: "上一次测试还没结束")) {
    _ = try await client.send(op: "settings.models.test", body: ["tier": .string("hour")])
  }
  #expect(try await first.value.status == 200)
  #expect(await transport.requestCount == 1)
}

@Test func relayCaptureAdaptsToLowerHTTPPutLimitEvenIfAdvertisementIsUnchanged() async throws {
  let f = try RelayFixture()
  defer { f.remove() }
  let session = try f.session()
  let records = [try f.record("first"), try f.record("second")]
  try await enqueueCapture(records, session: session)
  await f.firstBox.failNext(.httpError(status: 413))
  await session.runPump()
  #expect(try await session.captureBatchLimits().count == 1)
  #expect(try await session.reservedCaptureIDs().isEmpty)
  let restarted = try f.session()
  try await enqueueCapture(records, session: restarted)
  await f.firstBox.failNext(.httpError(status: 413))
  await restarted.runPump()
  #expect(try await restarted.captureBatchLimits().requiresDirect == [records[0].id])
  #expect(try await restarted.reservedCaptureIDs().isEmpty)
  #expect(await f.firstBox.sent.count == 2)
}
