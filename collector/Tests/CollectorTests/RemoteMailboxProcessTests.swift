import AudioStore
import CollectorCore
import CryptoKit
import Foundation
import Testing
@testable import Collector

private struct RelayProcessFailure: Error {
  let reason: String
}

private final class FixtureKeys: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  var store: RemoteDeviceLink.Keys {
    .init(read: { key in self.lock.withLock { self.values[key] } },
          create: { key, data in self.lock.withLock { self.values[key] = data } },
          remove: { key in self.lock.withLock { self.values[key] = nil } })
  }
}

@Test @MainActor func sharedRelayAcrossProcesses() async throws {
  try await runRelayProcess(rePair: false)
}

@Test @MainActor func sharedRelayAcrossProcessesRePairing() async throws {
  try await runRelayProcess(rePair: true)
}

@MainActor private func runRelayProcess(rePair: Bool) async throws {
  guard ProcessInfo.processInfo.environment["TACIT_RELAY_PROCESS_TEST"] == "1" else { return }
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tacit-mailbox-process-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let relayPort = rePair ? 48723 : 48720
  let adminPort = relayPort + 1, devicePort = relayPort + 2
  let relay = URL(string: "http://127.0.0.1:\(relayPort)")!
  let admin = URL(string: "http://127.0.0.1:\(adminPort)")!
  let deviceOrigin = URL(string: "http://127.0.0.1:\(devicePort)")!
  let bun = ProcessInfo.processInfo.environment["TACIT_TEST_BUN"] ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".bun/bin/bun").path
  let fixtureID = ULID.make()
  let invitationFile = temporary.appendingPathComponent("invitation")
  let countFile = temporary.appendingPathComponent("count")
  let queuedID = ULID.make()
  let queuedCountFile = temporary.appendingPathComponent("queued-count")
  let tokenFile = temporary.appendingPathComponent("admin-token")

  func start(_ name: String, _ script: String) throws -> Process {
    let entry = temporary.appendingPathComponent(name + ".ts")
    try Data(script.utf8).write(to: entry)
    let command = Process()
    command.executableURL = URL(fileURLWithPath: bun)
    command.arguments = [entry.path]
    command.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": temporary.path]
    command.standardOutput = FileHandle.standardError
    command.standardError = FileHandle.standardError
    try command.run()
    return command
  }
  func stop(_ process: Process) {
    if process.isRunning { process.terminate(); process.waitUntilExit() }
  }
  func waitFor(_ description: String, _ check: () async throws -> Bool) async throws {
    for _ in 0..<160 {
      if try await check() { return }
      try await Task.sleep(for: .milliseconds(125))
    }
    throw RelayProcessFailure(reason: description)
  }
  let relayProcess = try start("relay", """
    import { startRelay } from "\(repository.path)/relay/src/bun.ts";
    const service = startRelay({ hostname: "127.0.0.1", port: \(relayPort), db: process.env.TMPDIR + "/relay.db" });
    process.on("SIGTERM", () => { service.stop(true); process.exit(0); });
    """)
  defer { stop(relayProcess) }
  try await waitFor("relay hello") {
    guard let (_, response) = try? await URLSession.shared.data(from: relay.appendingPathComponent("v1/hello")) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }
  let hubProcess = try start("hub", """
    import { existsSync, readFileSync, writeFileSync } from "node:fs";
    import { setup } from "\(repository.path)/hub/test/helpers.ts";
    import { startServer } from "\(repository.path)/hub/src/server.ts";
    import { WireError } from "\(repository.path)/hub/src/devices/envelope.ts";
    import { DistillStore } from "\(repository.path)/hub/src/distill/store.ts";
    const ctx = setup();
    writeFileSync(ctx.dir + "/hub.json", JSON.stringify({ lan_port: \(devicePort) }));
    let key = null;
    const secrets = new Map();
    const server = startServer({
      db: ctx.db, token: ctx.config.token, agentToken: "fixture-agent", port: \(adminPort),
      settings: { dataDir: ctx.dir, probePort: async () => {} },
      deviceDeps: {
        name: "Mailbox fixture", addresses: () => ["127.0.0.1"],
        keys: { read: () => key, write: value => { key = value; } },
        relayKeys: { read: id => secrets.get(id) ?? null, write: (id, value) => { secrets.set(id, value); },
          remove: id => { secrets.delete(id); } },
      },
    });
    async function admin(path, method, body) {
      const response = await fetch(new URL(path, server.url), { method,
        headers: { Authorization: "Bearer " + ctx.config.token, "Content-Type": "application/json" },
        body: JSON.stringify(body) });
      if (!response.ok) throw Error(path + " returned " + response.status);
      return await response.json();
    }
    await admin("/v1/settings/relay", "PUT", { mode: "custom", url: "\(relay.absoluteString)" });
    const pairing = await admin("/v1/settings/devices/pairing", "POST", { role: "admin" });
    const store = new DistillStore(ctx.db);
    store.upsertProject({ id: "p-fixture-relay", name: "Synthetic project", keys: { repos: [], hosts: [], chats: [] }, confirmed: 1, brief: "Synthetic projection" });
    writeFileSync("\(tokenFile.path)", ctx.config.token, { mode: 0o600 });
    writeFileSync("\(invitationFile.path)", pairing.uri, { mode: 0o600 });
    const count = ctx.db.db.prepare("SELECT count(*) AS n FROM records WHERE id = ?");
    setInterval(() => {
      writeFileSync("\(countFile.path)", String(count.get("\(fixtureID)").n));
      writeFileSync("\(queuedCountFile.path)", String(count.get("\(queuedID)").n));
    }, 100);
    const withdraw = process.env.TMPDIR + "/withdraw";
    const withdrawn = process.env.TMPDIR + "/withdrawn";
    const denyCapture = process.env.TMPDIR + "/deny-capture";
    const oversizeCapture = process.env.TMPDIR + "/oversize-capture";
    const originalIngest = ctx.db.ingest.bind(ctx.db);
    ctx.db.ingest = (records, ...args) => {
      if (existsSync(denyCapture) && records.some(record => record?.id === readFileSync(denyCapture, "utf8"))) {
        throw new WireError(403, "synthetic request rejection");
      }
      if (existsSync(oversizeCapture) && records.some(record => record?.id === readFileSync(oversizeCapture, "utf8"))) {
        throw new WireError(413, "synthetic downstream capacity");
      }
      return originalIngest(records, ...args);
    };
    setInterval(() => {
      if (existsSync(withdraw) && !existsSync(withdrawn)) {
        if (!ctx.db.delete(readFileSync(withdraw, "utf8"))) throw Error("missing imported history fixture");
        writeFileSync(withdrawn, "");
      }
    }, 100);
    process.on("SIGTERM", async () => { await server.stop(true); ctx.cleanup(); process.exit(0); });
    """)
  defer { stop(hubProcess) }
  try await waitFor("hub invitation") { FileManager.default.fileExists(atPath: invitationFile.path) }
  let invite = try DevicePairingInvitation.parse(String(contentsOf: invitationFile, encoding: .utf8))
  let key = Curve25519.KeyAgreement.PrivateKey()
  let pairing = try await DeviceClient(invitation: invite, keyStore: InMemoryDeviceKeyStore(privateKey: key),
    transport: DirectDeviceTransport(origin: deviceOrigin)).pair(invitation: invite, deviceName: "Synthetic Mac")
  let mailbox = try #require(pairing.relay)
  let identity = try HubBinding.Remote(hubID: invite.hubID, hubPublicKey: DeviceEnvelope.publicKeyBase64URL(invite.hubPublicKey))
  let data = temporary.appendingPathComponent("mac", isDirectory: true)
  let remote = data.appendingPathComponent(identity.dir, isDirectory: true)
  try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
  let link = try RemoteDeviceLink(identity: identity, deviceID: pairing.deviceID, addresses: [])
  try PrivateFile.write(JSONEncoder().encode(link), to: remote.appendingPathComponent("collector-link.json"))
  struct RelayMetadata: Codable { let url: String; let space: String; let up: String; let down: String }
  try PrivateFile.write(JSONEncoder().encode(RelayMetadata(url: mailbox.url, space: mailbox.space, up: mailbox.up, down: mailbox.down)),
    to: remote.appendingPathComponent("relay.json"))
  let preparing = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: identity)
  let committed = HubBinding(generation: 1, target: .remote, phase: .committed, remote: identity)
  try preparing.write(to: data, replacing: .legacyLocal)
  try committed.write(to: data, replacing: preparing)
  let keys = FixtureKeys().store
  try keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id), key.rawRepresentation)
  try keys.create(RemoteDeviceLink.Relay.account(deviceID: pairing.deviceID), Data(mailbox.token.utf8))
  let gate = RemoteSwitchWriteGate()
  let access = RemoteDeviceAccess(dataDirectory: data, keys: keys, writeGate: gate)
  let host = HostDeviceSession(origin: { admin }, files: .init(directory: data), remoteAccess: access,
    transport: { _ in throw RelayProcessFailure(reason: "direct transport forbidden after pairing") })
  let connection = try #require(try await host.connection())
  let session = try #require(connection.remoteSession)
  #expect(try await session.selectedEndpoint() == .relay(mailbox))
  let config = Config(dataDir: data, fixedPort: String(adminPort), repo: nil, bun: bun)
  let queueKey = SymmetricKey(size: .bits256)
  let collector = HubClient(config: config, deviceSession: host, writeGate: gate,
    openOutbox: { try OutboxStore(dataDirectory: $0, key: queueKey) })
  var record = Record(device: "mac", source: "manual.note", kind: "event", start: Date(),
                      context: nil, title: "Fixture", body: "Synthetic e2e", capture: .init(method: "manual"))
  record.id = fixtureID
  collector.enqueue([record])
  try await waitFor("ingest receipt and durable dequeue") {
    collector.flush()
    await session.wakeMailbox()
    return collector.pendingCount == 0 && collector.sent == 1
  }
  let outbox = try OutboxStore(dataDirectory: HubClient.outboxDirectory(in: data, for: committed.route), key: queueKey)
  #expect(outbox.count == 0)
  collector.enqueue([record])
  try await waitFor("duplicate receipt and durable dequeue") {
    collector.flush()
    await session.wakeMailbox()
    return collector.pendingCount == 0 && collector.sent == 2
  }
  try await waitFor("one row after retry") { (try? String(contentsOf: countFile, encoding: .utf8)) == "1" }
  if rePair {
    let token = try String(contentsOf: tokenFile, encoding: .utf8)
    func control(_ method: String, _ path: String) async throws -> Data {
      var request = URLRequest(url: URL(string: path, relativeTo: admin)!)
      request.httpMethod = method
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      if method == "POST" {
        request.httpBody = Data(#"{"role":"admin"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      let (body, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw RelayProcessFailure(reason: "management request failed: " + method + " " + path)
      }
      return body
    }
    func mintInvitation() async throws -> String {
      struct Invitation: Decodable { let uri: String }
      return try JSONDecoder().decode(Invitation.self, from: await control("POST", "/v1/settings/devices/pairing")).uri
    }
    // Keep a second administrator so removal uses the real protection rules.
    let spare = try DevicePairingInvitation.parse(try await mintInvitation())
    _ = try await DeviceClient(invitation: spare, keyStore: InMemoryDeviceKeyStore(privateKey: .init()),
      transport: DirectDeviceTransport(origin: deviceOrigin)).pair(invitation: spare, deviceName: "Synthetic second Mac")

    gate.setPaused(true)
    var queued = Record(device: "mac", source: "manual.note", kind: "event", start: Date(),
                        context: nil, title: "Queued before removal", body: "Synthetic", capture: .init(method: "manual"))
    queued.id = queuedID
    collector.enqueue([record, queued])
    try await waitFor("two encrypted records awaiting delivery before removal") {
      try await collector.settleForSwitch() && collector.pendingCount == 2
    }
    // The first ID is already in History. A surviving submission marker models a lost receipt.
    let oldQueue = try OutboxStore(dataDirectory: HubClient.outboxDirectory(in: data, for: committed.route), key: queueKey)
    try oldQueue.markSubmitted([record.id])
    _ = try await control("DELETE", "/v1/settings/devices/" + pairing.deviceID)
    gate.setPaused(false)
    do {
      try await access.reauthenticate(committed.route, transport: DirectDeviceTransport(origin: deviceOrigin))
      Issue.record("The hub accepted the removed Mac")
    } catch {
      #expect(throws: RemoteDeviceAccess.Failure.frozen) { try access.validate(committed.route) }
    }

    let pairingFlow = RemotePairing(dataDirectory: data, keys: keys, discover: { _ in [] })
    let abandoned = try await pairingFlow.prepareRePairing(invitation: try await mintInvitation(),
      deviceName: "Synthetic abandoned Mac", manualAddress: deviceOrigin)
    try await pairingFlow.cancelRePairing()
    let listed = try await control("GET", "/v1/settings/devices")
    #expect(!String(decoding: listed, as: UTF8.self).contains(abandoned.collectorLink.device_id))
    #expect(!String(decoding: listed, as: UTF8.self).contains(abandoned.agentDeviceID))
    let prepared = try await pairingFlow.prepareRePairing(invitation: try await mintInvitation(),
      deviceName: "Synthetic Mac repaired", manualAddress: deviceOrigin)
    #expect(prepared.collectorLink.device_id != pairing.deviceID)
    #expect(prepared.collectorLink.hubName == "Mailbox fixture")
    try await performProcessRePair(prepared, pairing: pairingFlow, config: config, hub: collector, gate: gate)

    #expect(try await collector.switchBackPendingCount(on: prepared.binding.route) <= 1)
    try await waitFor("both records acknowledged after re-pairing") {
      collector.flush()
      return collector.pendingCount == 0 && collector.sent == 2
    }
    try await waitFor("each record exists once after replay") {
      (try? String(contentsOf: countFile, encoding: .utf8)) == "1"
        && (try? String(contentsOf: queuedCountFile, encoding: .utf8)) == "1"
    }
    #expect(try HubBinding.read(from: data).generation == committed.generation + 1)
    let retired = try OutboxStore(dataDirectory: HubClient.outboxDirectory(in: data, for: committed.route), key: queueKey)
    #expect(retired.count == 0)
    print("Mac removed and frozen; re-paired; one new record plus one replay acknowledged; one row per ID")
    // 2026-11-24 终审回归：切回本机后撤销保留身份，重新邀请并经正常切换入口提交。
    let persistence = DiskRemoteSwitchPersistence(directory: data)
    let current = try persistence.binding()
    let returning = HubBinding(generation: current.generation, target: .remote, phase: .switching_back, remote: identity)
    try returning.write(to: data, replacing: current)
    let local = HubBinding(generation: returning.generation + 1, target: .local, phase: .local)
    try local.write(to: data, replacing: returning)
    try persistence.clearCheckpoint()

    let mailboxOnly: @Sendable (URL) throws -> RemotePairing.DirectEndpoint = { _ in
      throw RelayProcessFailure(reason: "fixture permits only the mailbox")
    }
    let retainedFlow = RemotePairing(dataDirectory: data, keys: keys, endpoint: mailboxOnly, discover: { _ in [] })
    let validRetained = try await retainedFlow.prepareRetained(remote: identity)
    #expect(validRetained.collectorLink.device_id == prepared.collectorLink.device_id)
    #expect(validRetained.usedMailbox == true)
    #expect(try retainedFlow.preparedUsesMailbox(validRetained.binding) == true)
    try await retainedFlow.cancel(validRetained)
    _ = try await control("DELETE", "/v1/settings/devices/" + prepared.collectorLink.device_id)
    await #expect(throws: RemotePairing.Failure.retainedIdentityInvalid) {
      try await retainedFlow.prepareRetained(remote: identity)
    }
    let pairedAgain = try await retainedFlow.prepare(invitation: try await mintInvitation(), deviceName: "Synthetic retained replacement")
    #expect(pairedAgain.collectorLink.device_id != prepared.collectorLink.device_id)
    #expect(try RemoteDeviceLink.read(from: data, identity: identity).device_id == prepared.collectorLink.device_id)
    let restarted = RemotePairing(dataDirectory: data, keys: keys, endpoint: mailboxOnly, discover: { _ in [] })
    let staged = try #require(try restarted.retainedReplacement(for: pairedAgain.binding))
    #expect(staged.collectorLink == pairedAgain.collectorLink)
    let handoff = RemoteSwitch(persistence: persistence, services: SyntheticRetainedSwitchServices(),
      runtime: .init(gate: gate, settled: { true }, suspendBonjour: { _ in },
        publish: { _, _, _, commit in try commit() }, bindingChanged: {},
        finishCommit: { _, _ in }, finishReturn: { _, _, _ in }), pairing: restarted)
    try await handoff.commit(prepared: pairedAgain.binding, agentNeedsDirectConnection: staged.agentLink == nil)
    try await handoff.recover()
    let active = try persistence.binding()
    #expect(active.generation == local.generation + 1 && active.phase == .committed)
    #expect(try RemoteDeviceLink.read(from: data, identity: identity).device_id == staged.collectorLink.device_id)
    let raw = try #require(try keys.read(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id)))
    let newClient = try DeviceClient(hubPublicKeyBase64URL: identity.hub_pk, deviceID: staged.collectorLink.device_id,
      keyStore: InMemoryDeviceKeyStore(rawRepresentation: raw), transport: DirectDeviceTransport(origin: deviceOrigin))
    #expect(try await newClient.send(op: "relay").body["role"] == .string("admin"))
    print("retained identity revoked; new invitation paired through mailbox; restarted switch confirmed the new admin")
    return
  }
  let cache = try ProjectionCache(dataDirectory: data, keyProvider: InMemoryProjectionCacheKeyProvider())
  let sync = ProjectionSync(client: connection.client, cache: cache, deviceSession: session)
  let wake = Task {
    while !Task.isCancelled {
      await session.wakeMailbox()
      try await Task.sleep(for: .milliseconds(250))
    }
  }
  defer { wake.cancel() }
  let result = try await sync.pullToLatest()
  #expect(result.pagesFetched > 0)
  #expect(try cache.get(kind: .project, id: "p-fixture-relay") != nil)
  #expect((try? String(contentsOf: countFile, encoding: .utf8)) == "1")
  print("relay ingest receipt acknowledged; encrypted outbox empty; one database row; projection cursor", result.cursor.seq)

  // The sender sees all five durable records. The actual relay batch contains
  // four, leaving one safe to copy when returning to the local backend.
  let text = String(repeating: "a", count: 150_000)
  let records = (0..<5).map { index in
    Record(device: "mac", source: "manual.note", kind: "event", start: Date(),
           context: nil, title: "Split fixture \(index)", body: text, capture: .init(method: "manual"))
  }.sorted { $0.id < $1.id }
  collector.enqueue(records)
  try await waitFor("five durable records") { collector.pendingCount == records.count }
  collector.flush()
  let submitted = Set(records.prefix(4).map(\.id))
  try await waitFor("four submission markers after relay split") {
    await session.wakeMailbox()
    return submitted.allSatisfy {
      FileManager.default.fileExists(atPath: outbox.root.appendingPathComponent(".submitted-" + $0).path)
    }
  }
  gate.setPaused(true)
  try await waitFor("relay pump stopped") {
    guard gate.isIdle else { return false }
    return await access.isMailboxIdleForSwitch()
  }
  let reopened = try OutboxStore(dataDirectory: HubClient.outboxDirectory(in: data, for: committed.route), key: queueKey)
  let copied = try OutboxStore(dataDirectory: temporary.appendingPathComponent("returned"), key: queueKey)
  try reopened.copyForSwitch(to: copied, onlyUnsubmitted: true)
  #expect(copied.restore(limit: 10).records.map(\.id) == [records[4].id])
  gate.setPaused(false)
  let sourceID = ULID.make()
  let sourceRecord: DeviceJSON = .object([
    "id": .string(sourceID), "device": .string("mac"), "source": .string("manual.note"),
    "t_start": .string(DeviceProtocol.formatRFC3339(Date())), "schema": .int(1), "kind": .string("event"),
    "title": .string("Synthetic backup"), "body": .string("Synthetic history"),
    "capture": .object(["method": .string("manual")]), "sensitivity": .string("normal"),
  ])
  let snapshot = String(repeating: "a", count: 64)
  let begin = try await connection.client.send(op: "history.import.begin", body: [
    "hub_id": .string(identity.hub_id), "snapshot_id": .string(snapshot), "identities": .array([
      .object(["device": .string("mac"), "kind": .string("mac"), "sources": .array([.string("manual.note")])]),
    ]),
  ])
  let sessionID = try #require(begin.body["session_id"]?.stringValue)
  let sessionBody: [String: DeviceJSON] = ["session_id": .string(sessionID)]
  _ = try await connection.client.send(op: "history.import.batch",
    body: sessionBody.merging(["batch_number": .int(1), "records": .array([sourceRecord])]) { _, right in right })
  _ = try await connection.client.send(op: "history.import.finish", body: sessionBody)
  try Data().write(to: data.appendingPathComponent("history.db"))
  var importState = HistoryImportJournal(generation: committed.generation)
  importState.sourceCheckedGeneration = committed.generation
  importState.attempt = .init(snapshot: snapshot, total: 1, pageSize: 2, privateCount: 0,
                             session: sessionID, pending: [sourceID])
  importState.sessions[sessionID] = .init(cursor: 999999)
  try HistoryImportJournalFile.write(JSONEncoder().encode(importState), in: data, for: identity)
  try Data(sourceID.utf8).write(to: temporary.appendingPathComponent("withdraw"))
  try await waitFor("history withdrawal committed") {
    FileManager.default.fileExists(atPath: temporary.appendingPathComponent("withdrawn").path)
  }
  var withdrawn: [HistoryWithdrawal] = []
  var reads: Set<String> = []
  let history = HistoryImporter(directory: data, gate: gate, operations: .init(
    binding: { committed },
    budget: { _ in throw RelayProcessFailure(reason: "history writes must stay paused") },
    send: { _, op, body in
      reads.insert(op)
      return try await connection.client.send(op: op, body: body, timeout: 12).bodyData
    },
    export: { _, _ in
      let content = withdrawn.isEmpty ? [sourceRecord] : []
      return try JSONDecoder().decode(HistoryExportPage.self, from: JSONEncoder().encode(DeviceJSON.object([
        "snapshot_id": .string(snapshot), "identities": .array([]), "records": .array(content),
        "total": .int(Int64(content.count)), "private_count": .int(0),
      ])))
    },
    apply: { withdrawn.append(contentsOf: $0) }
  ))
  gate.setPaused(true)
  try #require(await history.reconcileForReturn(on: committed.route) == .reconciled)
  #expect(reads == ["history.import.changes", "history.import.verify", "history.import.status"])
  #expect(!withdrawn.isEmpty && withdrawn.allSatisfy { $0 == HistoryWithdrawal(id: sourceID, kind: .deleted) })
  #expect(gate.isPaused)
  print("relay-only paused return checked expired waterline, verified the imported ID, and applied the remote deletion")

  gate.setPaused(false)
  try await waitFor("drain the remaining capture fixtures") {
    if collector.pendingCount == 0 { return true }
    collector.flush()
    return false
  }
  var retry = record
  retry.id = ULID.make()
  retry.body = "Synthetic retryable capture"
  try Data(retry.id.utf8).write(to: temporary.appendingPathComponent("deny-capture"))
  let priorRejected = collector.rejected
  collector.enqueue([retry])
  try await waitFor("request-level 403 was reported") {
    // Old versions immediately cleared the displayed error by starting the
    // next POST, so the rejection counter is also an observable completion.
    if collector.lastError == "hub 返回 403" || collector.rejected > priorRejected { return true }
    collector.flush()
    return false
  }
  #expect(collector.rejected == priorRejected)
  #expect(collector.pendingCount == 1)
  let pending = try OutboxStore(dataDirectory: HubClient.outboxDirectory(in: data, for: committed.route), key: queueKey)
  #expect(pending.restore(limit: 10).records.first?.id == retry.id)
  #expect(pending.restore(limit: 10).records.first?.body == retry.body)
  print("request-level 403 kept the original ID and body in the encrypted outbox")
  let returning = HubBinding(generation: committed.generation, target: .remote, phase: .switching_back, remote: identity)
  try returning.write(to: data, replacing: committed)
  let local = HubBinding(generation: committed.generation + 1, target: .local, phase: .local)
  try local.write(to: data, replacing: returning)
  let reconnect = RemotePairing(dataDirectory: data, keys: keys, discover: { _ in [] })
  let retained = try await reconnect.prepareRetained(remote: identity, manualAddress: deviceOrigin)
  #expect(retained.collectorLink.device_id == pairing.deviceID)
  #expect(retained.binding.phase == .preparing)
  print("returned to local and authenticated the retained Mac against the same remote hub")

  let reconnected = HubBinding(generation: local.generation + 1, target: .remote, phase: .committed, remote: identity)
  try reconnected.write(to: data, replacing: retained.binding)
  let reconnectedConnection = try await host.connection(for: reconnected.route)
  let reconnectedSession = try #require(reconnectedConnection?.remoteSession)
  #expect(collector.sent == 0)
  var isolated = record
  isolated.id = ULID.make()
  try Data(isolated.id.utf8).write(to: temporary.appendingPathComponent("oversize-capture"))
  collector.enqueue([isolated])
  try await waitFor("413 capture isolated while history may continue") {
    collector.flush()
    let limits = try await reconnectedSession.captureBatchLimits()
    guard limits.requiresDirect.contains(isolated.id) else { return false }
    return await collector.mayImportHistory(on: reconnected.route)
  }
  #expect(collector.pendingCount == 1)
  print("relay 413 left one direct-only capture and allowed historical import to run")

}


@MainActor private func performProcessRePair(_ prepared: RemotePairing.PreparedRePairing, pairing: RemotePairing,
                                            config: Config, hub: HubClient, gate: RemoteSwitchWriteGate) async throws {
  let persistence = DiskRemoteSwitchPersistence(directory: config.dataDir)
  let original = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: prepared.binding.remote)
  let local = LocalSwitchSnapshot(hub: .init(plist: Data(), login: false, loaded: false), distill: nil,
                                  loginEnabled: false, distillEnabled: false)
  try persistence.save(.init(step: .committed, prepared: original, local: local, agentNeedsDirectConnection: true))
  let services = LaunchdRemoteSwitchServices(config: config,
    startup: LoginStartup(home: config.dataDir, dataDir: config.dataDir), execute: { _, _, _ in
      throw RelayProcessFailure(reason: "re-pair must not call launchd")
    })
  let handoff = RemoteSwitch(persistence: persistence, services: services,
    runtime: .init(gate: gate, settled: { try await hub.settleForSwitch() }, suspendBonjour: { _ in },
      publish: { oldLocal, from, to, commit in
        try await hub.publishSwitch(previousLocal: oldLocal, from: from, to: to, commit: commit)
      }, bindingChanged: {}, finishCommit: { try await hub.finishSwitchToRemote(from: $0, to: $1) },
      finishReturn: { _, _, _ in }), pairing: pairing)
  try await handoff.commitRePairing(prepared)
  try await handoff.recover()
  let checkpoint = try #require(try persistence.checkpoint())
  #expect(checkpoint.prepared.route == .local)
  #expect(checkpoint.remote.route == prepared.binding.route)
  #expect(checkpoint.returned.generation == prepared.binding.generation + 1)
}

private struct SyntheticRetainedSwitchServices: RemoteSwitchServices {
  func snapshot() async throws -> LocalSwitchSnapshot {
    .init(hub: .init(plist: Data(), login: false, loaded: false), distill: nil, loginEnabled: false, distillEnabled: false)
  }
  func stop(_ job: LocalSwitchJob) async throws {}
  func verifyClosedDatabase() async throws {}
  func withdrawDefinitions() async throws {}
  func preflightReturn(_ local: LocalSwitchSnapshot) async throws {}
  func discardStagedHub() async throws {}
  func startHubForVerification(_ local: LocalSwitchSnapshot) async throws {}
  func verifyLocalHub() async throws {}
  func restore(_ local: LocalSwitchSnapshot, afterSwitchBack: Bool) async throws {}
}
