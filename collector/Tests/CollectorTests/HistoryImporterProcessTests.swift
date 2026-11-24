import CollectorCore
import CryptoKit
import Foundation
import Testing
@testable import Collector

private enum ImportProcessFailure: Error { case timeout, disconnected }

private final class ImportFixtureKeys: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Data] = [:]
  var store: RemoteDeviceLink.Keys {
    .init(read: { key in self.lock.withLock { self.storage[key] } },
          create: { key, data in self.lock.withLock { self.storage[key] = data } },
          remove: { key in self.lock.withLock { self.storage[key] = nil } })
  }
}

@Test @MainActor func historyImportAcrossProcesses() async throws {
  guard ProcessInfo.processInfo.environment["TACIT_HISTORY_IMPORT_PROCESS_TEST"] == "1" else { return }
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tacit-history-import-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: tmp) }
  let source = tmp.appendingPathComponent("source")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
  let bun = ProcessInfo.processInfo.environment["TACIT_TEST_BUN"] ??
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path
  let secret = "synthetic-history-e2e-test-key"
  let env = ["PATH": "/usr/bin:/bin", "TMPDIR": tmp.path, "RA_DB_KEY": secret]
  let admin = URL(string: "http://127.0.0.1:48726")!
  let deviceOrigin = URL(string: "http://127.0.0.1:48727")!
  let invitationFile = tmp.appendingPathComponent("invitation")
  let summaryFile = tmp.appendingPathComponent("summary")
  let removed = ULID.make(), withdrawn = ULID.make(), correction = ULID.make(), hidden = ULID.make(), phone = ULID.make()

  func script(_ name: String, _ content: String) throws -> String {
    let file = tmp.appendingPathComponent(name + ".ts")
    try Data(content.utf8).write(to: file)
    return file.path
  }

  func start(_ script: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bun)
    process.arguments = [script]
    process.environment = env
    process.standardOutput = FileHandle.standardError
    process.standardError = FileHandle.standardError
    try process.run()
    return process
  }

  func waitFor(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<120 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ImportProcessFailure.timeout
  }

  let seed = try start(script("source", """
    import { HubDB } from "\(repository.path)/hub/src/db.ts";
    import { fixture } from "\(repository.path)/hub/test/helpers.ts";
    const db = new HubDB("\(source.path)/history.db", process.env.RA_DB_KEY!);
    const reply = db.ingest([
      fixture({id: "\(removed)", source: "manual.note", body: "Synthetic item to delete"}),
      fixture({id: "\(withdrawn)", source: "manual.note", body: "Synthetic item to privatize"}),
      fixture({id: "\(correction)", source: "manual.correction", corrects: "\(withdrawn)", body: "Synthetic current revision"}),
      fixture({id: "\(hidden)", sensitivity: "private", body: "Local-only fixture"}),
      fixture({id: "\(phone)", source: "android.audio", device: "android-synthetic"}),
    ]);
    if (reply.accepted !== 5) throw Error("fixture was not ingested");
    db.close();
    """))
  seed.waitUntilExit()
  try #require(seed.terminationStatus == 0)

  // Use only the production command functions with an injected test key. No installed app or
  // system keychain is used by the fixture.
  let entry = try script("commands", """
    import { runHistoryExport } from "\(repository.path)/hub/src/history-export.ts";
    import { runHistoryReconcile } from "\(repository.path)/hub/src/history-reconcile.ts";
    import { HubDB } from "\(repository.path)/hub/src/db.ts";
    const [op, ...args] = process.argv.slice(2);
    const key = () => process.env.RA_DB_KEY!;
    try {
      if (op === "history-export") runHistoryExport(args, key);
      else if (op === "history-reconcile") await runHistoryReconcile(args, key);
      else {
        const db = new HubDB("\(source.path)/history.db", key());
        const deleted = db.get("\(removed)");
        const privateRecord = db.effective("\(withdrawn)");
        console.log(JSON.stringify({deleted, body: privateRecord?.body, sensitivity: privateRecord?.sensitivity}));
        db.close();
      }
    } catch (e) { console.error(e.code ?? e.message); process.exitCode = 1; }
    """)
  let commands = FrozenHistoryCommands(runtime: repository.path, bun: bun, directory: source, environment: env, entry: entry)
  let firstPage = try await commands.export(after: nil, limit: 2)
  #expect(firstPage.total == 3 && firstPage.private_count == 1)

  let server = try start(script("destination", """
    import { writeFileSync } from "node:fs";
    import { HubDB } from "\(repository.path)/hub/src/db.ts";
    import { startServer } from "\(repository.path)/hub/src/server.ts";
    const hub = new HubDB("\(tmp.path)/destination.db", process.env.RA_DB_KEY!);
    const token = "synthetic-history-admin";
    let key = null;
    const server = startServer({
      db: hub, token, agentToken: "synthetic-history-agent", port: 48726, lanPort: 48727, mode: "mac",
      deviceDeps: { name: "History fixture", addresses: () => ["127.0.0.1"],
        keys: { read: () => key, write: value => { key = value; } } },
    });
    const response = await fetch(new URL("/v1/settings/devices/pairing", server.url), {
      method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify({role:"admin"}),
    });
    if (!response.ok) throw Error("pairing failed " + response.status);
    writeFileSync("\(invitationFile.path)", (await response.json()).uri, {mode: 0o600});
    setInterval(() => writeFileSync("\(summaryFile.path)", JSON.stringify({
      records: hub.db.prepare("SELECT id FROM records ORDER BY id").all().map(r => r.id),
      batches: hub.db.prepare("SELECT COUNT(*) n FROM history_import_batches").get().n,
    })), 40);
    process.on("SIGTERM", async () => { await server.stop(true); hub.close(); process.exit(0); });
    """))
  defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
  try await waitFor { FileManager.default.fileExists(atPath: invitationFile.path) }

  let invite = try DevicePairingInvitation.parse(String(contentsOf: invitationFile, encoding: .utf8))
  let key = Curve25519.KeyAgreement.PrivateKey()
  let pairing = try await DeviceClient(invitation: invite, keyStore: InMemoryDeviceKeyStore(privateKey: key),
    transport: DirectDeviceTransport(origin: deviceOrigin)).pair(invitation: invite, deviceName: "Synthetic Mac")
  let remote = try HubBinding.Remote(hubID: invite.hubID, hubPublicKey: DeviceEnvelope.publicKeyBase64URL(invite.hubPublicKey))
  let remoteDirectory = source.appendingPathComponent(remote.dir)
  try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: false)
  let link = try RemoteDeviceLink(identity: remote, deviceID: pairing.deviceID, addresses: [deviceOrigin])
  try PrivateFile.write(JSONEncoder().encode(link), to: remoteDirectory.appendingPathComponent("collector-link.json"))
  let preparing = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: remote)
  let binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: remote)
  try preparing.write(to: source, replacing: .legacyLocal)
  try binding.write(to: source, replacing: preparing)
  let keys = ImportFixtureKeys().store
  try keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id), key.rawRepresentation)
  let access = RemoteDeviceAccess(dataDirectory: source, keys: keys)
  let host = HostDeviceSession(origin: { admin }, files: .init(directory: source), remoteAccess: access)
  var dropNext = true
  var disconnected = false
  var replayed = false
  let operations = HistoryImporter.Operations(
    binding: { try HubBinding.read(from: source) },
    budget: { route in
      let session = try #require(try await host.connection(for: route)?.remoteSession)
      return try await session.historyImportRecordBudget()
    },
    send: { route, op, body in
      if disconnected { throw ImportProcessFailure.disconnected }
      let client = try #require(try await host.connection(for: route)?.client)
      let reply = try await client.send(op: op, body: body)
      if op == "history.import.batch", dropNext {
        dropNext = false
        disconnected = true
        throw ImportProcessFailure.disconnected
      }
      if op == "history.import.batch", body["batch_number"] == .int(1) { replayed = true }
      return reply.bodyData
    },
    export: { try await commands.export(after: $0, limit: $1) },
    apply: { try await commands.apply($0) },
    deviceID: { try RemoteDeviceLink.read(from: source, identity: $0).device_id }
  )
  let gate = RemoteSwitchWriteGate()
  func importer() -> HistoryImporter { .init(directory: source, gate: gate, pageSize: 2, operations: operations) }
  var app = importer()
  var progress: HistoryImportProgress?
  app.onChange = { value, _ in progress = value }
  try await waitFor {
    await app.tick()
    return progress?.hasPendingReceipt == true
  }
  #expect(progress?.confirmed == 0)
  await app.tick()
  #expect(progress?.hasPendingReceipt == true)
  app = importer()
  app.onChange = { value, _ in progress = value }
  disconnected = false
  try await waitFor {
    await app.tick()
    return progress?.isComplete == true
  }
  #expect(replayed)
  #expect(progress?.confirmed == 3 && progress?.privateCount == 1)

  struct Summary: Decodable, Equatable { let records: [String]; let batches: Int }
  try await waitFor {
    let data = try? Data(contentsOf: summaryFile)
    let current = data.flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
    return current == Summary(records: [removed, withdrawn, correction].sorted(), batches: 2)
  }

  func writeRemote(_ endpoint: String, method: String, body: [String: DeviceJSON]) async throws {
    var request = URLRequest(url: admin.appendingPathComponent(endpoint))
    request.httpMethod = method
    request.setValue("Bearer synthetic-history-admin", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    let (_, response) = try await URLSession.shared.data(for: request)
    try #require((response as? HTTPURLResponse)?.statusCode == 200, "Failed to \(method) \(endpoint)")
  }

  // Exercise the importer's identity handoff against the actual hub. The
  // re-pairing coordinator owns publication in production.
  let oldCheckpoint = try #require(try HistoryImportJournalFile.read(in: source, for: remote))
  let oldState = try JSONDecoder().decode(HistoryImportJournal.self, from: oldCheckpoint)
  let oldSession = try #require(oldState.attempt?.session)
  var newInviteRequest = URLRequest(url: admin.appendingPathComponent("v1/settings/devices/pairing"))
  newInviteRequest.httpMethod = "POST"
  newInviteRequest.setValue("Bearer synthetic-history-admin", forHTTPHeaderField: "Authorization")
  newInviteRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
  newInviteRequest.httpBody = Data(#"{"role":"admin"}"#.utf8)
  let (newInviteData, newInviteResponse) = try await URLSession.shared.data(for: newInviteRequest)
  try #require((newInviteResponse as? HTTPURLResponse)?.statusCode == 200)
  struct Invitation: Decodable { let uri: String }
  let newInvite = try DevicePairingInvitation.parse(JSONDecoder().decode(Invitation.self, from: newInviteData).uri)
  let newKey = Curve25519.KeyAgreement.PrivateKey()
  let newPairing = try await DeviceClient(invitation: newInvite, keyStore: InMemoryDeviceKeyStore(privateKey: newKey),
    transport: DirectDeviceTransport(origin: deviceOrigin)).pair(invitation: newInvite, deviceName: "Synthetic Mac re-paired")
  let newLink = try RemoteDeviceLink(identity: remote, deviceID: newPairing.deviceID, addresses: [deviceOrigin])
  try #require(newLink.device_id != link.device_id)
  try await writeRemote("v1/settings/devices/\(pairing.deviceID)", method: "DELETE", body: [:])
  try PrivateFile.write(JSONEncoder().encode(newLink), to: remoteDirectory.appendingPathComponent("collector-link.json"))
  try keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id), newKey.rawRepresentation)
  let newBinding = HubBinding(generation: 2, target: .remote, phase: .committed, remote: remote)
  try PrivateFile.write(JSONEncoder().encode(newBinding), to: source.appendingPathComponent(HubBinding.fileName))
  app = importer()
  progress = nil
  app.onChange = { value, _ in progress = value }
  try await waitFor {
    await app.tick()
    return progress?.isComplete == true
  }
  #expect(progress?.alreadyPresent == 3 && progress?.confirmed == 3)
  let newCheckpoint = try #require(try HistoryImportJournalFile.read(in: source, for: remote))
  let newState = try JSONDecoder().decode(HistoryImportJournal.self, from: newCheckpoint)
  let newSession = try #require(newState.attempt?.session)
  #expect(newSession != oldSession && Set(newState.sessions.keys) == [oldSession, newSession])
  #expect(newState.sessions[oldSession]?.withdrawalOnly == true)
  print("replacement device opened a new import session and confirmed three records already on the hub")

  try await writeRemote("v1/records", method: "DELETE", body: ["ids": .array([.string(removed)])])
  try await writeRemote("v1/records", method: "POST", body: [
    "id": .string(ULID.make()), "schema": .int(1), "device": .string("mac"), "source": .string("manual.correction"),
    "kind": .string("event"), "t_start": .string(DeviceProtocol.formatRFC3339(Date())),
    "title": .string("Remote revision"), "body": .string("Remote-only text"), "corrects": .string(withdrawn),
    "capture": .object(["method": .string("manual")]), "sensitivity": .string("private"),
  ])
  #expect(await app.reconcileForReturn(on: newBinding.route) == .reconciled)
  let remaining = try await commands.export(after: nil, limit: 40)
  #expect(remaining.total == 0)
  let inspection = Process(), output = Pipe()
  inspection.executableURL = URL(fileURLWithPath: bun)
  inspection.arguments = [entry, "inspect"]
  inspection.environment = env
  inspection.standardOutput = output
  try inspection.run()
  let result = output.fileHandleForReading.readDataToEndOfFile()
  inspection.waitUntilExit()
  #expect(inspection.terminationStatus == 0)
  let inspected = try JSONDecoder().decode([String: DeviceJSON].self, from: result)
  #expect(inspected == ["deleted": .null, "body": .string("Synthetic current revision"), "sensitivity": .string("private")])
  print("history import resumed after lost receipt; two stored batches, three eligible records; local deletion and privacy withdrawal verified")
}
