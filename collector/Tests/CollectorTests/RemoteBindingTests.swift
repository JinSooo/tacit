import AudioStore
@testable import CollectorCore
import CryptoKit
import Darwin
import Foundation
import Network
import Testing
@testable import Collector

private let localAddress = URL(string: "http://127.0.0.1:47823")!
private let remoteAddress = URL(string: "https://fixture-remote.example")!
private let macID = "mac-abcd2345"
private let agentID = "agent-abcd2345"

private final class TestState: @unchecked Sendable {
  private let lock = NSLock()
  private var accounts: [String: Data] = [:]
  private var reads: [String] = []
  private var events: [String] = []
  private var removeFailure: String?
  private var requests: [Data] = []

  var keys: RemoteDeviceLink.Keys {
    .init(read: { account in
      #expect(!Thread.isMainThread)
      return self.lock.withLock { self.reads.append(account); return self.accounts[account] }
    },
          create: { account, data in self.lock.withLock { self.accounts[account] = data } },
          remove: { account in
            try self.lock.withLock {
              if self.removeFailure == account {
                self.removeFailure = nil
                throw LocalDeviceLink.Failure.keyUnavailable
              }
              self.accounts[account] = nil
            }
          })
  }

  func failNextRemoval(_ account: String) { lock.withLock { removeFailure = account } }
  func record(_ wire: Data) { lock.withLock { requests.append(wire) } }
  var wireRequests: [Data] { lock.withLock { requests } }
  var accountNames: Set<String> { lock.withLock { Set(accounts.keys) } }
  var readAccounts: [String] { lock.withLock { reads } }
  var trace: [String] { lock.withLock { events } }
  func note(_ event: String) { lock.withLock { events.append(event) } }
}

private struct FakeTransport: DeviceTransport {
  let maxEnvelopeBytes = DeviceProtocol.maxEnvelopeBytes
  let reply: @Sendable (SealedDeviceRequest) async throws -> DeviceTransportResponse
  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse { try await reply(request) }
}

private func syntheticDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-binding-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  return dir
}

private func identity(_ hub: Curve25519.KeyAgreement.PrivateKey) throws -> HubBinding.Remote {
  try .init(hubID: DeviceProtocol.hubID(for: hub.publicKey),
            hubPublicKey: DeviceEnvelope.publicKeyBase64URL(hub.publicKey))
}

@Test func remoteSetupReadinessKeepsModelHealthWithoutLocalAgentTools() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let binding = try commit(dir, identity(.init()))
  let api = HubAPI(base: { localAddress }, token: { nil }, deviceAction: { op, _, _, route in
    #expect(op == "status.get")
    #expect(route == binding.route)
    return .init(status: 200, body: [:], bodyData: Data(#"{"distill":{}}"#.utf8))
  }, hubRoute: { binding.route })

  // The local-only endpoint really fails on this binding.
  await #expect(throws: HubError.self) { try await api.agentTools() }
  let readiness = try await api.setupReadiness(includeLocalTools: false)
  #expect(readiness.health.state == .waiting)
  #expect(readiness.tools == nil)
  #expect(SetupReadiness.unfinishedItems(health: readiness.health, tools: readiness.tools) == ["models"])
}

@Test func firstPreparationStampIsReadFromTheActiveDataDirectory() throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  #expect(!AppSetup.hasCompletedPreparation(in: dir))
  try Data(#"{"version":"fixture"}"#.utf8).write(to: dir.appendingPathComponent("app-setup.json"))
  #expect(AppSetup.hasCompletedPreparation(in: dir))
}

private func writeRemote(_ dir: URL, _ identity: HubBinding.Remote) throws -> URL {
  let sub = dir.appendingPathComponent(identity.dir)
  try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
  let link = try RemoteDeviceLink(identity: identity, deviceID: macID, addresses: [remoteAddress])
  let file = sub.appendingPathComponent("collector-link.json")
  try PrivateFile.write(JSONEncoder().encode(link), to: file)
  return file
}

private func writeLocal(_ dir: URL, _ identity: HubBinding.Remote) throws -> LocalDeviceLink.Files {
  let files = LocalDeviceLink.Files(directory: dir)
  let data = try JSONSerialization.data(withJSONObject: [
    "mode": "local", "hub_id": identity.hub_id, "hub_pk": identity.hub_pk,
    "device_id": macID, "addrs": [localAddress.absoluteString], "relay": NSNull(),
  ])
  try files.write(.collector, data)
  return files
}

private func commit(_ dir: URL, _ remote: HubBinding.Remote) throws -> HubBinding {
  let prior = try HubBinding.read(from: dir)
  let active = HubBinding(generation: prior.generation + 1, target: .remote, phase: .committed, remote: remote)
  try active.write(to: dir, replacing: prior)
  return active
}

private func invitation(_ hub: Curve25519.KeyAgreement.PrivateKey, addrs: [URL], role: String? = "admin",
                        relay: DeviceRelayConfig? = nil, expiry: Date = Date().addingTimeInterval(240),
                        code: UInt8 = 42) throws -> String {
  let remote = try identity(hub)
  var fields: [String: Any] = [
    "v": 1, "hub_id": remote.hub_id, "pk": remote.hub_pk, "name": "合成后台",
    "code": DeviceProtocol.base64URLEncode(Data(repeating: code, count: 16)),
    "expires_at": DeviceProtocol.formatRFC3339(expiry),
    "addrs": addrs.map(\.absoluteString),
  ]
  fields["role"] = role
  if let relay { fields["relay"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(relay)) }
  return "tacit://pair?d=" + DeviceProtocol.base64URLEncode(try JSONSerialization.data(withJSONObject: fields))
}

private func reply(_ sealed: SealedDeviceRequest, hub: Curve25519.KeyAgreement.PrivateKey,
                   client: Curve25519.KeyAgreement.PublicKey, body: [String: DeviceJSON],
                   status: Int64 = 200) throws -> DeviceTransportResponse {
  let bytes = try JSONEncoder().encode(DeviceJSON.object(["status": .int(status), "body": .object(body)]))
  let envelope = try DeviceEnvelope.sealResponsePlaintext(bytes, requestNonce: sealed.nonce,
                                                        senderPrivateKey: hub, recipientPublicKey: client)
  return .init(statusCode: 200, body: try JSONEncoder().encode(envelope))
}

private func request(_ sealed: SealedDeviceRequest, hub: Curve25519.KeyAgreement.PrivateKey,
                     client: Curve25519.KeyAgreement.PublicKey? = nil) throws -> DeviceJSON {
  let bytes = try DeviceEnvelope.openRequestEnvelope(sealed.envelope, recipientPrivateKey: hub, senderPublicKey: client)
  return try JSONDecoder().decode(DeviceJSON.self, from: bytes)
}

@Test(arguments: [401, 403]) func remoteBindingLegacyPreparingAndCommittedRouting(status: Int) async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let localHub = Curve25519.KeyAgreement.PrivateKey(), remoteHub = Curve25519.KeyAgreement.PrivateKey()
  let localMac = Curve25519.KeyAgreement.PrivateKey(), remoteMac = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(remoteHub)
  let metadata = try writeRemote(dir, remote)
  let files = try writeLocal(dir, identity(localHub))
  let original = try files.read(.collector)
  let state = TestState()
  let account = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  try state.keys.create(account, remoteMac.rawRepresentation)
  let localKeys = LocalDeviceLink.Keys(read: { _ in state.note("local-key"); return localMac.rawRepresentation },
                                      create: { _, _ in Issue.record("已登记的本机不应生成密钥") })
  let access = RemoteDeviceAccess(dataDirectory: dir, keys: state.keys)
  let session = HostDeviceSession(origin: { localAddress }, files: files, keys: localKeys, remoteAccess: access,
                                 transport: { address in FakeTransport { sealed in
    state.note(address.absoluteString)
    if address == remoteAddress {
      #expect(try request(sealed, hub: remoteHub, client: remoteMac.publicKey)["op"]?.stringValue == "ingest")
      return .init(statusCode: status)
    }
    #expect(address == localAddress)
    #expect(try request(sealed, hub: localHub, client: localMac.publicKey)["op"]?.stringValue == "ingest")
    return try reply(sealed, hub: localHub, client: localMac.publicKey, body: [:])
  } })
  #expect(try HubBinding.read(from: dir) == .legacyLocal)
  #expect(try await session.send(op: "ingest") != nil)
  let bindingFile = dir.appendingPathComponent(HubBinding.fileName)
  let preparing = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: remote)
  try preparing.write(to: dir, replacing: .legacyLocal)
  #expect(try await session.send(op: "ingest") != nil)
  #expect(state.readAccounts.isEmpty)
  let active = try commit(dir, remote)
  #expect(active.route.generation == 1)
  if status == 401 {
    await #expect(throws: RemoteDeviceAccess.Failure.frozen) { try await session.send(op: "ingest") }
  } else {
    await #expect(throws: DeviceClientError.plaintextError(status: 403, message: nil)) {
      try await session.send(op: "ingest")
    }
  }
  if status == 401 {
    #expect(throws: RemoteDeviceAccess.Failure.frozen) {
      try RemoteDeviceAccess(dataDirectory: dir, keys: state.keys).validate(active.route)
    }
    await #expect(throws: RemoteDeviceAccess.Failure.frozen) { try await session.send(op: "ingest") }
  } else {
    try RemoteDeviceAccess(dataDirectory: dir, keys: state.keys).validate(active.route)
  }
  #expect(state.trace == ["local-key", localAddress.absoluteString, localAddress.absoluteString, remoteAddress.absoluteString])
  #expect(state.readAccounts == [account])
  #expect(try files.read(.collector) == original)
  #expect(FileManager.default.fileExists(atPath: metadata.path))
  #expect(try HubBinding.read(from: dir) == active)
  #expect(try FileManager.default.attributesOfItem(atPath: bindingFile.path)[.posixPermissions] as? Int == 0o600)
}

@Test func remoteBindingMalformedOrSymlinkDoesNotDowngradeToLocal() throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let binding = dir.appendingPathComponent(HubBinding.fileName)
  try PrivateFile.write(Data(#"{"version":2,"target":"local"}"#.utf8), to: binding)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  try PrivateFile.write(Data(#"{"target":"remote","phase":"committed"}"#.utf8), to: binding)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  try PrivateFile.write(Data(#"{}"#.utf8), to: binding)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  try FileManager.default.removeItem(at: binding)
  try FileManager.default.createSymbolicLink(at: binding, withDestinationURL: dir.appendingPathComponent("absent"))
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
}

@Test func remotePairingChecksActualRoleAndCleansKeys() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let state = TestState()
  let pairing = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: { _ in
    .init(transport: FakeTransport { sealed in
      let json = try request(sealed, hub: hub)
      let key = try DeviceEnvelope.publicKey(base64URL: try #require(json["body"]?["device_pk"]?.stringValue))
      #expect(json["op"]?.stringValue == "pair")
      return try reply(sealed, hub: hub, client: key, body: [
        "device_id": .string(macID), "hub_id": .string(remote.hub_id), "name": .string("合成 Mac"), "role": .string("view"),
      ])
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  })
  await #expect(throws: RemotePairing.Failure.adminInvitationRequired) {
    try await pairing.prepare(invitation: invitation(hub, addrs: [remoteAddress]), deviceName: "合成 Mac")
  }
  #expect(state.accountNames.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(remote.dir).path))
  #expect(try HubBinding.read(from: dir) == .legacyLocal)
}

@Test func remotePairingProbeOrderEnrollmentAndCancellation() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), impostor = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let last = URL(string: "https://last.example")!
  let invite = URL(string: "https://invite.example")!
  let lan = URL(string: "http://fixture.local:48634")!
  let wrong = URL(string: "http://wrong.local:48635")!
  let state = TestState()
  let macAccount = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  let agentAccount = RemoteDeviceLink.Keys.account(.agent, hubID: remote.hub_id)
  let pairing = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: { address in
    .init(transport: FakeTransport { sealed in
      let rawMac = try state.keys.read(macAccount)
      let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(rawMac))
      let publicKey = mac.publicKey
      let input = try request(sealed, hub: hub, client: sealed.envelope.device == nil ? nil : publicKey)
      let op = try #require(input["op"]?.stringValue)
      state.note("\(op):\(address.host!)")
      switch op {
      case "pair":
        #expect(input["body"]?["device_pk"]?.stringValue == DeviceEnvelope.publicKeyBase64URL(publicKey))
        if address == lan { return .init(statusCode: 502) }
        let signer = address == invite ? impostor : hub
        return try reply(sealed, hub: signer, client: publicKey, body: [
          "device_id": .string(macID), "hub_id": .string(remote.hub_id), "name": .string("合成 Mac"), "role": .string("admin"),
        ])
      case "agent.enroll":
        let rawAgent = try state.keys.read(agentAccount)
        let agent = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(rawAgent))
        #expect(input["body"]?["agent_pk"]?.stringValue == DeviceEnvelope.publicKeyBase64URL(agent.publicKey))
        #expect(try RemoteDeviceLink.read(from: dir, identity: remote).addresses == [remoteAddress])
        return try reply(sealed, hub: hub, client: publicKey, body: [
          "device_id": .string(agentID), "hub_id": .string(remote.hub_id),
        ])
      case "devices.remove":
        #expect(input["body"]?["id"]?.stringValue == macID)
        return try reply(sealed, hub: hub, client: publicKey, body: ["deleted": .bool(true)])
      default:
        Issue.record("Unexpected op \(op)")
        return .init(statusCode: 400)
      }
    }, hello: {
      state.note("hello:\(address.host!)")
      return DeviceHello(hubID: address == last ? DeviceProtocol.hubID(for: impostor.publicKey) : remote.hub_id)
    })
  }, discover: { hubID in
    state.note("discover:\(hubID)")
    return [.init(hubID: DeviceProtocol.hubID(for: impostor.publicKey), address: wrong),
            .init(hubID: hubID, address: lan)]
  })
  let prepared = try await pairing.prepare(invitation: invitation(hub, addrs: [last, invite]), deviceName: "合成 Mac",
                                            lastSuccessfulAddress: last, manualAddress: remoteAddress)
  #expect(state.trace == [
    "hello:last.example", "hello:invite.example", "pair:invite.example", "discover:\(remote.hub_id)",
    "hello:fixture.local", "pair:fixture.local", "hello:fixture-remote.example",
    "pair:fixture-remote.example", "agent.enroll:fixture-remote.example",
  ])
  #expect(prepared.binding.phase == .preparing && prepared.binding.route == .local)
  #expect(prepared.agentLink?.address == remoteAddress.absoluteString)
  #expect(prepared.collectorLink.hubName == "合成后台")
  #expect(state.accountNames == [macAccount, agentAccount])
  let directory = dir.appendingPathComponent(remote.dir)
  for name in ["collector-link.json", "agent-link.json"] {
    #expect(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int == 0o600)
  }
  state.failNextRemoval(macAccount)
  await #expect(throws: LocalDeviceLink.Failure.keyUnavailable) {
    try await pairing.cancelPreparation(replacing: prepared.binding)
  }
  #expect(try HubBinding.read(from: dir) == prepared.binding)
  let restarted = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: { _ in
    Issue.record("已确认撤掉配对，不应再次发请求")
    throw RemotePairing.Failure.remoteUnavailable
  })
  try await restarted.cancelPreparation(replacing: prepared.binding)
  #expect(state.trace.last == "devices.remove:fixture-remote.example")
  #expect(state.accountNames.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: directory.path))
  #expect(try HubBinding.read(from: dir).phase == .local)
}

@Test func remoteDirectTransportRejectsCrossOriginRedirect() async throws {
  let parameters = NWParameters.tcp
  parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
  let listener = try NWListener(using: parameters)
  defer { listener.cancel() }
  let queue = DispatchQueue(label: "remote-binding.redirect")
  let response = Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:1/v1/device/hello\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
  listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
      connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in connection.cancel() })
    }
  }
  let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        listener.stateUpdateHandler = nil
        continuation.resume(returning: listener.port!.rawValue)
      case .failed(let error):
        listener.stateUpdateHandler = nil
        continuation.resume(throwing: error)
      default: break
      }
    }
    listener.start(queue: queue)
  }
  let transport = try DirectDeviceTransport(origin: URL(string: "http://127.0.0.1:\(port)")!)
  await #expect(throws: DeviceClientError.plaintextError(status: 307, message: nil)) { try await transport.hello() }
}

private actor DelayedReceipt {
  private var pending: CheckedContinuation<Void, Never>?
  var started: Bool { pending != nil }

  func wait() async { await withCheckedContinuation { pending = $0 } }
  func release() { pending?.resume(); pending = nil }
}

private func waitFor(_ condition: () async -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  let reached = await condition()
  try #require(reached, "Timed out waiting for the synthetic request")
}

@Test func remoteBindingLateUploadReceiptOnlySettlesItsGeneration() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let localHub = Curve25519.KeyAgreement.PrivateKey(), remoteHub = Curve25519.KeyAgreement.PrivateKey()
  let localMac = Curve25519.KeyAgreement.PrivateKey(), remoteMac = Curve25519.KeyAgreement.PrivateKey()
  let identity = try identity(remoteHub)
  let remoteLink = try writeRemote(dir, identity)
  let files = try writeLocal(dir, try .init(hubID: DeviceProtocol.hubID(for: localHub.publicKey),
                                           hubPublicKey: DeviceEnvelope.publicKeyBase64URL(localHub.publicKey)))
  try PrivateFile.write(Data("fixture-token".utf8), to: dir.appendingPathComponent("token"))
  let state = TestState()
  let key = SymmetricKey(size: .bits256)
  let gate = DelayedReceipt()
  try state.keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id), remoteMac.rawRepresentation)
  let session = HostDeviceSession(origin: { localAddress }, files: files,
                                  keys: .init(read: { _ in localMac.rawRepresentation }, create: { _, _ in }),
                                  remoteAccess: RemoteDeviceAccess(dataDirectory: dir, keys: state.keys),
                                  transport: { address in FakeTransport { sealed in
    if address == localAddress {
      #expect(try request(sealed, hub: localHub, client: localMac.publicKey)["op"]?.stringValue == "ingest")
      await gate.wait()
      return try reply(sealed, hub: localHub, client: localMac.publicKey,
                       body: ["accepted": .int(1), "duplicates": .int(0), "rejected": .array([])])
    }
    #expect(address == remoteAddress)
    #expect(try request(sealed, hub: remoteHub, client: remoteMac.publicKey)["op"]?.stringValue == "ingest")
    state.note("remote-upload")
    return .init(statusCode: 401)
  } })
  let config = Config(dataDir: dir, fixedPort: "48638", bun: "")
  let client = HubClient(config: config, deviceSession: session,
                         openOutbox: { try OutboxStore(dataDirectory: $0, key: key) })
  let record = Record(device: "mac", source: "mac.screen", kind: "event", start: Date(), context: nil,
                      title: "合成事件", body: "合成正文", capture: .init(method: "ax"))
  client.enqueue([record])
  client.flush()
  do { try await waitFor { await gate.started } }
  catch { await gate.release(); throw error }
  let active = try commit(dir, identity)
  client.enqueue([record])
  await gate.release()
  try await waitFor { state.trace == ["remote-upload"] && client.lastError != nil }
  let newDir = HubClient.outboxDirectory(in: dir, for: active.route)
  #expect(try OutboxStore(dataDirectory: dir, key: key).count == 0)
  let remaining = try OutboxStore(dataDirectory: newDir, key: key).restore(limit: 10)
  #expect(remaining.records == [RecordRedaction.record(record)])
  #expect(remaining.unreadable == 0)
  #expect(client.pendingCount == 1)
  #expect(FileManager.default.fileExists(atPath: remoteLink.path))
  #expect(state.trace == ["remote-upload"])
}

@Test @MainActor func remoteBindingViewerRetiresCacheSnapshotAndHTTPFallback() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(Curve25519.KeyAgreement.PrivateKey())
  let files = try writeLocal(dir, identity(hub))
  let widget = dir.appendingPathComponent("today.json")
  let snapshot = WidgetSnapshot(day: "2026-11-24", summary: "合成本机快照")
  let state = TestState()
  let api = HubAPI(base: { localAddress }, token: { state.note("http-token"); return nil },
                   deviceAction: { _, _, _, _ in nil }, hubRoute: { try HubBinding.read(from: dir).route })
  let key = InMemoryProjectionCacheKeyProvider()
  let source = AdaptiveViewerDataSource(
    http: HTTPViewerDataSource(api: api), dataDir: dir, originProvider: { localAddress },
    widgetSnapshotURL: widget, files: files, cacheKeyProvider: key,
    remoteAccess: RemoteDeviceAccess(dataDirectory: dir, keys: state.keys),
    onBindingChanged: { state.note("reset-page") },
    sessionFactory: { link, _, wipe, update in
      let device = try DeviceClient(hubPublicKey: hub.publicKey, deviceID: link.device_id,
                                    keyStore: InMemoryDeviceKeyStore(privateKey: .init()),
                                    transport: FakeTransport { _ in throw URLError(.notConnectedToInternet) })
      let cache = try ProjectionCache(dataDirectory: dir, widgetSnapshotURL: widget, keyProvider: key)
      return ProjectionSync(client: device, cache: cache, onWipe: wipe, onUpdate: update)
    }
  )
  defer { source.stop() }
  #expect(await source.activateIfLinked())
  let old = try #require(source.activeSync)
  try old.cache.reset(toEpoch: 7, hubID: DeviceProtocol.hubID(for: hub.publicKey))
  old.rawCache.set("old", data: Data("合成原文".utf8))
  try PrivateFile.write(JSONEncoder().encode(snapshot), to: widget)
  let active = try commit(dir, remote)
  // No remote link is available. Neither the adaptive viewer nor direct HubAPI may read local data.
  await source.refreshBinding()
  await #expect(throws: HubError.self) { try await source.diary(Date()) }
  await #expect(throws: HubError.self) { try await api.get(DeviceJSON.self, "/v1/settings/hub") }
  await #expect(throws: HubError.self) {
    try await api.get(DeviceJSON.self, "/v1/status", device: .init("status.get"))
  }
  #expect(state.trace == ["reset-page"])
  #expect(!FileManager.default.fileExists(atPath: widget.path))
  #expect(!FileManager.default.fileExists(atPath: old.cache.databaseURL.path))
  #expect(old.rawCache.count == 0)
  old.rawCache.set("late", data: Data("迟到原文".utf8))
  #expect(old.rawCache.count == 0)
  let fresh = try ProjectionCache(dataDirectory: dir, widgetSnapshotURL: widget, keyProvider: key)
  #expect(try fresh.cursor() == .zero)
  #expect(throws: HubBinding.Failure.changed) { try old.cache.reset(toEpoch: 8, hubID: remote.hub_id) }
  #expect(throws: HubBinding.Failure.changed) { try old.cache.wipe() }
  #expect(try fresh.cursor() == .zero)
  #expect(try !ProjectionCache.prepareBinding(active.route, in: dir, widgetSnapshotURL: widget))
}

@Test func remotePairingRetainsRequestAcrossLostReceipt() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let state = TestState()
  let invite = try invitation(hub, addrs: [remoteAddress])
  let account = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  let pending = dir.appendingPathComponent(remote.dir).appendingPathComponent("pending-pair.json")
  let endpoint: @Sendable (URL) throws -> RemotePairing.DirectEndpoint = { _ in
    .init(transport: FakeTransport { sealed in
      let raw = try #require(try state.keys.read(account))
      let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
      let input = try request(sealed, hub: hub, client: sealed.envelope.device == nil ? nil : mac.publicKey)
      if input["op"]?.stringValue == "pair" {
        let attempt = state.trace.count
        state.record(sealed.wireData)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(try FileManager.default.attributesOfItem(atPath: pending.path)[.posixPermissions] as? Int == 0o600)
        let journal = try Data(contentsOf: pending)
        let parsed = try #require(JSONSerialization.jsonObject(with: journal) as? [String: Any])
        #expect(parsed["code"] == nil)
        #expect(parsed["private_key"] == nil)
        let code = try #require(input["body"]?["code"]?.stringValue)
        #expect(!String(decoding: journal, as: UTF8.self).contains(code))
        state.note(try #require(input["body"]?["device_pk"]?.stringValue) + ":" + sealed.nonce)
        if attempt == 0 { throw DeviceClientError.transportError("合成丢回执") }
        return try reply(sealed, hub: hub, client: mac.publicKey, body: [
          "device_id": .string(macID), "hub_id": .string(remote.hub_id), "name": .string("合成 Mac"), "role": .string("admin"),
        ])
      }
      return try reply(sealed, hub: hub, client: mac.publicKey, body: [
        "device_id": .string(agentID), "hub_id": .string(remote.hub_id),
      ])
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  }
  let first = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: endpoint, discover: { _ in [] })
  await #expect(throws: RemotePairing.Failure.remoteUnavailable) {
    try await first.prepare(invitation: invite, deviceName: "合成 Mac")
  }
  #expect(state.accountNames.contains(account))
  #expect(FileManager.default.fileExists(atPath: pending.path))
  // 第 2 轮审查回归：误贴同一后台的过期链接或填错名字，不能毁掉还能恢复的请求。
  let stale = try invitation(hub, addrs: [remoteAddress], expiry: Date().addingTimeInterval(-60), code: 7)
  await #expect(throws: DeviceClientError.inviteExpired) {
    try await first.prepare(invitation: stale, deviceName: "合成 Mac")
  }
  await #expect(throws: (any Error).self) {
    try await first.prepare(invitation: try invitation(hub, addrs: [remoteAddress], code: 7), deviceName: "")
  }
  #expect(FileManager.default.fileExists(atPath: pending.path))
  #expect(state.accountNames.contains(account))
  let afterRestart = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: endpoint, discover: { _ in [] })
  _ = try await afterRestart.prepare(invitation: invite, deviceName: "合成 Mac")
  #expect(state.trace.count == 2 && Set(state.trace).count == 1)
  #expect(Set(state.wireRequests).count == 1)
  #expect(!FileManager.default.fileExists(atPath: pending.path))
}

@Test func remotePairingMailboxPersistsOnlyTokenReferenceAndEnrolls() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let state = TestState()
  let box = DeviceProtocol.base64URLEncode(Data(repeating: 3, count: 16))
  let relayURL = "https://fixture-mailbox.example"
  let inviteRelay = try DeviceRelayConfig(url: relayURL, space: box, up: box, down: box,
                                         token: "fixture-invitation-token")
  let activeRelay = try DeviceRelayConfig(url: relayURL, space: box, up: box, down: box,
                                         token: "fixture-registered-device-token")
  let relayBody = try JSONDecoder().decode(DeviceJSON.self, from: JSONEncoder().encode(activeRelay))
  let pairing = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: { _ in
    .init(transport: FakeTransport { _ in
      state.note("direct")
      return .init(statusCode: 403)
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  }, discover: { _ in [] }, mailboxTransport: { config in
    FakeTransport { sealed in
      let raw = try #require(try state.keys.read(RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)))
      let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
      let input = try request(sealed, hub: hub, client: sealed.envelope.device == nil ? nil : mac.publicKey)
      let op = try #require(input["op"]?.stringValue)
      state.note(op)
      if op == "pair" {
        #expect(config == inviteRelay)
        return try reply(sealed, hub: hub, client: mac.publicKey, body: [
          "device_id": .string(macID), "hub_id": .string(remote.hub_id), "name": .string("合成 Mac"),
          "role": .string("admin"), "relay": relayBody,
        ])
      }
      #expect(config == activeRelay)
      if op == "agent.enroll" {
        return try reply(sealed, hub: hub, client: mac.publicKey, body: [
          "device_id": .string(agentID), "hub_id": .string(remote.hub_id),
        ])
      }
      #expect(op == "devices.remove")
      return try reply(sealed, hub: hub, client: mac.publicKey, body: ["deleted": .bool(true)])
    }
  })
  let prepared = try await pairing.prepare(invitation: invitation(hub, addrs: [remoteAddress], relay: inviteRelay),
                                           deviceName: "合成 Mac")
  #expect(prepared.collectorLink.addresses.isEmpty)
  #expect(try RemoteDeviceLink.read(from: dir, identity: remote) == prepared.collectorLink)
  #expect(prepared.agentLink == nil && prepared.agentNeedsDirectConnection)
  #expect(prepared.agentDeviceID == agentID)
  let relay = try #require(try prepared.collectorLink.relay(in: dir))
  #expect(prepared.relay == relay)
  #expect(try relay.config(deviceID: macID, keys: state.keys) == activeRelay)
  let folder = dir.appendingPathComponent(remote.dir)
  let relayFile = folder.appendingPathComponent(RemoteDeviceLink.Relay.fileName)
  #expect(try FileManager.default.attributesOfItem(atPath: relayFile.path)[.posixPermissions] as? Int == 0o600)
  #expect(try !String(contentsOf: relayFile, encoding: .utf8).contains(activeRelay.token))
  #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("agent-link.json").path))
  #expect(state.trace == ["direct", "pair", "agent.enroll"])
  try await pairing.cancel(prepared)
  #expect(state.trace.last == "devices.remove")
  #expect(state.accountNames.isEmpty)
}

@Test func remotePairingRejectsLegacyInviteBeforeProbe() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let state = TestState()
  let pairing = RemotePairing(dataDirectory: dir, keys: state.keys, endpoint: { _ in
    Issue.record("缺少管理员角色的邀请不得触网")
    throw RemotePairing.Failure.remoteUnavailable
  })
  await #expect(throws: RemotePairing.Failure.adminInvitationRequired) {
    try await pairing.prepare(invitation: invitation(hub, addrs: [remoteAddress], role: nil), deviceName: "合成 Mac")
  }
  #expect(state.readAccounts.isEmpty)
  #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func remotePairingExpiresPendingCredentialsOnRestart() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let state = TestState()
  let now = Date()
  let invite = try invitation(hub, addrs: [], expiry: now.addingTimeInterval(120))
  let first = RemotePairing(dataDirectory: dir, keys: state.keys, discover: { _ in [] }, clock: { now })
  await #expect(throws: RemotePairing.Failure.remoteUnavailable) {
    try await first.prepare(invitation: invite, deviceName: "合成 Mac")
  }
  #expect(!state.accountNames.isEmpty)
  let restarted = RemotePairing(dataDirectory: dir, keys: state.keys, clock: { now.addingTimeInterval(121) })
  try await restarted.cleanupExpiredPreparations()
  #expect(state.accountNames.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(remote.dir).path))
}

@Test func remotePairingCancelsWhenLocalDirectoryAlreadyAbsent() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let remote = try identity(Curve25519.KeyAgreement.PrivateKey())
  let prepared = HubBinding(generation: 0, target: .remote, phase: .preparing, remote: remote)
  try prepared.write(to: dir, replacing: .legacyLocal)
  let pairing = RemotePairing(dataDirectory: dir, keys: TestState().keys)
  // 第 2 轮审查回归：目录没了不代表远端已撤回，收敛回本机但继续提示。
  await #expect(throws: RemotePairing.Failure.remoteCleanupRequired) {
    try await pairing.cancelPreparation(replacing: prepared)
  }
  #expect(try HubBinding.read(from: dir).phase == .local)
}

@Test @MainActor func remoteViewerKeepsCacheOnBusiness403AndRecoversAfter401() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  _ = try writeRemote(dir, remote)
  let binding = try commit(dir, remote)
  let state = TestState()
  let account = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  try state.keys.create(account, mac.rawRepresentation)
  let access = RemoteDeviceAccess(dataDirectory: dir, keys: state.keys)
  let api = HubAPI(base: { localAddress }, token: { nil })
  let direct = FakeTransport { sealed in
    let op = try #require(request(sealed, hub: hub, client: mac.publicKey)["op"]?.stringValue)
    switch op {
    case "settings.relay.put":
      return try reply(sealed, hub: hub, client: mac.publicKey, body: ["error": .string("开通码错误")], status: 403)
    case "records.get":
      return try reply(sealed, hub: hub, client: mac.publicKey, body: ["error": .string("私密读取受限")], status: 403)
    case "settings.relay.test":
      return .init(statusCode: 403)
    case "settings.hub.get":
      return try reply(sealed, hub: hub, client: mac.publicKey, body: ["error": .string("设备未配对或已移除")], status: 401)
    case "status.get":
      return try reply(sealed, hub: hub, client: mac.publicKey, body: [:])
    default:
      throw DeviceClientError.transportError("合成投影暂不可用")
    }
  }
  let source = AdaptiveViewerDataSource(http: HTTPViewerDataSource(api: api), dataDir: dir,
                                        originProvider: { localAddress }, cacheKeyProvider: InMemoryProjectionCacheKeyProvider(),
                                        remoteAccess: access, remoteTransport: { _ in direct })
  defer { source.stop() }
  #expect(await source.activateIfLinked())
  let sync = try #require(source.activeSync)
  try sync.cache.reset(toEpoch: 2, hubID: remote.hub_id)
  sync.rawCache.set("old", data: Data("合成".utf8))
  await #expect(throws: DeviceClientError.operationError(op: "records.get", status: 403, message: "私密读取受限")) {
    try await sync.getRecords(ids: ["fixture"], includePrivate: true)
  }
  for op in ["settings.relay.put", "settings.relay.test"] {
    await #expect(throws: HubError.self) { try await source.sendAction(op: op, body: [:], timeout: nil) }
  }
  #expect(try sync.cache.cursor().epoch == 2)
  #expect(sync.rawCache.count == 1)
  #expect(state.readAccounts == [account])
  await #expect(throws: HubError.self) { try await source.sendAction(op: "settings.hub.get", body: [:], timeout: nil) }
  #expect(source.activeSync == nil)
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { try access.validate(binding.route) }
  #expect(!FileManager.default.fileExists(atPath: sync.cache.databaseURL.path))
  #expect(sync.rawCache.count == 0)
  await #expect(throws: DeviceClientError.deviceRemoved(message: nil)) {
    try await access.reauthenticate(binding.route, transport: FakeTransport { _ in .init(statusCode: 401) })
  }
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { try access.validate(binding.route) }
  try await access.reauthenticate(binding.route, transport: direct)
  try RemoteDeviceAccess(dataDirectory: dir, keys: state.keys).validate(binding.route)
  await source.refreshBinding()
  let recovered = try #require(source.activeSync)
  #expect(recovered !== sync)
  #expect(try await source.sendAction(op: "status.get", body: [:], timeout: nil) != nil)
}

@Test func remoteProjectionRetiresBeforeLatePullAndRawReceipts() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
  let pullGate = DelayedReceipt(), rawGate = DelayedReceipt()
  let transport = FakeTransport { sealed in
    let input = try request(sealed, hub: hub, client: mac.publicKey)
    switch input["op"]?.stringValue {
    case "projection.pull":
      await pullGate.wait()
      return try reply(sealed, hub: hub, client: mac.publicKey, body: [
        "epoch": .int(1), "reset": .bool(false), "cursor": .int(1), "more": .bool(false), "changes": .array([]),
        "server_time": .string(DeviceProtocol.formatRFC3339(Date())),
      ])
    case "records.get":
      await rawGate.wait()
      return try reply(sealed, hub: hub, client: mac.publicKey, body: [
        "missing": .array([]), "records": .array([.object(["id": .string("r"), "body": .string("合成")])]),
      ])
    default:
      Issue.record("退役后的投影不能确认游标")
      return .init(statusCode: 400)
    }
  }
  let client = try DeviceClient(hubPublicKey: hub.publicKey, deviceID: macID,
                                keyStore: InMemoryDeviceKeyStore(privateKey: mac), transport: transport)
  let cache = try ProjectionCache(dataDirectory: dir, keyProvider: InMemoryProjectionCacheKeyProvider())
  let sync = ProjectionSync(client: client, cache: cache, retireOnAccessLoss: true, onWipe: { reason in
    #expect(reason == .deviceRemoved)
    #expect(throws: HubBinding.Failure.changed) { try cache.cursor() }
    try? ProjectionCache.discardPersisted(in: dir, widgetSnapshotURL: nil)
  })
  let pull = Task { try await sync.pullToLatest() }
  let raw = Task { try await sync.getRecords(ids: ["r"]) }
  do {
    try await waitFor { await pullGate.started }
    try await waitFor { await rawGate.started }
    try await sync.discardRemovedDevice()
  } catch {
    await pullGate.release()
    await rawGate.release()
    throw error
  }
  await pullGate.release()
  await rawGate.release()
  await #expect(throws: HubBinding.Failure.changed) { try await pull.value }
  await #expect(throws: HubBinding.Failure.changed) { try await raw.value }
  #expect(!FileManager.default.fileExists(atPath: cache.databaseURL.path))
  #expect(sync.rawCache.count == 0)
}

@Test @MainActor func viewerBindingResetIsolatesSettingsDrafts() throws {
  let api = HubAPI(base: { localAddress }, token: { nil })
  let store = ViewerStore(api: api, dataSource: HTTPViewerDataSource(api: api), device: "mac", controls: nil)
  let old = store.preferences
  let settings = try JSONDecoder().decode(GeneralSettingsInfo.self, from: Data("""
    {"injectTokens":800,"askDoneDays":0,"archiveDays":7,"timelinePolish":"hourly",
     "timelineOverview":"hourly","modelUsage":{"daysWithUsage":0,"todayTokens":0},"ranges":{}}
    """.utf8))
  old.saved = settings
  old.draft = settings
  old.draft?.injectTokens = 1234
  old.busy = true
  store.extensions.message = "旧后台"
  store.resetForBindingChange()
  old.error = "迟到的旧后台响应"
  #expect(store.preferences !== old)
  #expect(store.preferences.saved == nil && store.preferences.draft == nil)
  #expect(!store.preferences.busy && store.preferences.error == nil)
  #expect(store.extensions.message == nil)
}

@Test func remoteBindingRejectsUnsafeFilesAndAllowsReadOnlyV1() throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent(HubBinding.fileName)
  let v1 = #"{"version":1,"generation":1,"target":"local","phase":"local","remote":null}"#
  for invalid in [#"{"mode":"local"}"#, #"{"version":0,"target":"local"}"#, #"{"phase":"committed"}"#] {
    try PrivateFile.write(Data(invalid.utf8), to: file)
    #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  }
  let padded = Data((v1 + String(repeating: " ", count: 65_536 - v1.utf8.count)).utf8)
  try PrivateFile.write(padded, to: file)
  #expect(chmod(file.path, 0o400) == 0)
  #expect(try HubBinding.read(from: dir).generation == 1)
  #expect(chmod(file.path, 0o640) == 0)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  try FileManager.default.removeItem(at: file)
  try PrivateFile.write(padded + Data(" ".utf8), to: file)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
  try FileManager.default.removeItem(at: file)
  #expect(mkfifo(file.path, 0o600) == 0)
  #expect(throws: HubBinding.Failure.invalidBinding) { try HubBinding.read(from: dir) }
}

@Test func collectorClearsLocalKeyErrorOnEmptyNewGeneration() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let files = try writeLocal(dir, identity(Curve25519.KeyAgreement.PrivateKey()))
  let state = TestState()
  let session = HostDeviceSession(origin: { localAddress }, files: files,
                                  keys: .init(read: { _ in nil }, create: { _, _ in Issue.record("不应创建本机密钥") }),
                                  remoteAccess: RemoteDeviceAccess(dataDirectory: dir, keys: state.keys),
                                  transport: { _ in
    Issue.record("坏密钥或空队列不应触网")
    throw DeviceClientError.transportError("合成")
  })
  let key = SymmetricKey(size: .bits256)
  let client = HubClient(config: Config(dataDir: dir, fixedPort: "48648", bun: ""), deviceSession: session,
                         openOutbox: { try OutboxStore(dataDirectory: $0, key: key) })
  client.enqueue([Record(device: "mac", source: "mac.screen", kind: "event", start: Date(), context: nil,
                         title: "合成", body: "合成", capture: .init(method: "ax"))])
  client.flush()
  try await waitFor { client.lastError != nil }
  #expect(client.lastError == "本机后台连接凭据不可用，待发送记录已保留。")
  _ = try commit(dir, identity(Curve25519.KeyAgreement.PrivateKey()))
  client.flush()
  try await waitFor { client.lastError == nil }
  #expect(try OutboxStore(dataDirectory: dir, key: key).count == 1)
}

@Test(ChineseUITrait()) func remoteBindingInvalidConfigQueuesWithoutLocalFallback() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let files = try writeLocal(dir, identity(hub))
  try PrivateFile.write(Data("fixture-token".utf8), to: dir.appendingPathComponent("token"))
  try PrivateFile.write(Data(#"{}"#.utf8), to: dir.appendingPathComponent(HubBinding.fileName))
  let access = RemoteDeviceAccess(dataDirectory: dir, keys: TestState().keys)
  let session = HostDeviceSession(origin: { localAddress }, files: files,
                                  keys: .init(read: { _ in Issue.record("invalid binding read local key"); return nil },
                                              create: { _, _ in Issue.record("invalid binding created local key") }),
                                  remoteAccess: access, transport: { _ in
    Issue.record("invalid binding attempted networking")
    throw DeviceClientError.transportError("fixture")
  })
  await #expect(throws: HubBinding.Failure.invalidBinding) { try await session.send(op: "ingest") }
  let api = HubAPI(base: { localAddress }, token: { Issue.record("invalid binding read token"); return nil },
                   hubRoute: { try access.route() })
  let source = AdaptiveViewerDataSource(http: HTTPViewerDataSource(api: api), dataDir: dir,
                                        originProvider: { localAddress }, cacheKeyProvider: InMemoryProjectionCacheKeyProvider(),
                                        remoteAccess: access)
  defer { source.stop() }
  await #expect(throws: HubError.self) { try await api.get(DeviceJSON.self, "/v1/settings/hub") }
  do {
    _ = try await source.diary(Date())
    Issue.record("invalid binding allowed a viewer request")
  } catch let error as HubError {
    #expect(error.message == "后台连接配置无法读取")
  }
  let key = SymmetricKey(size: .bits256)
  let queue = HubClient(config: Config(dataDir: dir, fixedPort: "48648", bun: ""), deviceSession: session,
                        openOutbox: { try OutboxStore(dataDirectory: $0, key: key) })
  queue.enqueue([Record(device: "mac", source: "mac.screen", kind: "event", start: Date(), context: nil,
                         title: "合成", body: "合成", capture: .init(method: "ax"))])
  queue.flush()
  try await waitFor { queue.lastError != nil && queue.pendingCount == 1 }
  let unassigned = HubClient.outboxDirectory(in: dir, for: nil)
  #expect(try OutboxStore(dataDirectory: unassigned, key: key).count == 1)
  #expect(try OutboxStore(dataDirectory: dir, key: key).count == 0)
}

// 第 2 轮审查回归：重启后首次解冻时，并发校验把磁盘冻结标记读进内存，不能打断解冻。
@Test func remoteReauthenticationSurvivesConcurrentValidationAfterRestart() async throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  _ = try writeRemote(dir, remote)
  let binding = try commit(dir, remote)
  let state = TestState()
  try state.keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id), mac.rawRepresentation)
  RemoteDeviceAccess(dataDirectory: dir, keys: state.keys).freeze(binding.route)
  let restarted = RemoteDeviceAccess(dataDirectory: dir, keys: state.keys)
  let direct = FakeTransport { sealed in
    #expect(throws: RemoteDeviceAccess.Failure.frozen) { try restarted.validate(binding.route) }
    return try reply(sealed, hub: hub, client: mac.publicKey, body: [:])
  }
  let newAddress = URL(string: "http://127.0.0.1:48729")!
  try await restarted.reauthenticate(binding.route, transport: direct, authenticatedAddress: newAddress)
  try restarted.validate(binding.route)
  #expect(try RemoteDeviceLink.read(from: dir, identity: remote).addresses == [newAddress, remoteAddress])
}

private struct LostPairMailbox: RelayMailboxClient {
  let events: TestState
  let failPUT: Bool

  func listDownMessages(after: String?, limit: Int) async throws -> (messages: [RelayMessageMeta], next: String?) {
    ([], nil)
  }

  func getDownMessage(id: String) async throws -> Data {
    events.note("read")
    throw RelayMailboxError.notFound
  }

  func deleteDownMessage(id: String) async throws { Issue.record("Deleted an unauthenticated receipt") }

  func putUpMessage(id: String, data: Data) async throws {
    events.note("put")
    if failPUT { throw RelayMailboxError.unauthorized(status: 401) }
  }
}

@Test(arguments: [false, true]) func remotePairingMailboxDeliveryPrecedesReceiptAndRequiresSuccessfulPUT(failPUT: Bool) async throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let state = TestState()
  let relay = try DeviceRelayConfig(url: "http://127.0.0.1:48718", space: DeviceEnvelope.randomNonce(),
    up: DeviceEnvelope.randomNonce(), down: DeviceEnvelope.randomNonce(),
    token: DeviceProtocol.base64URLEncode(Data(repeating: 7, count: 32)))
  let pairing = RemotePairing(dataDirectory: directory, keys: state.keys, discover: { _ in [] },
    mailboxTransport: { _ in
      RelayDeviceTransport(mailbox: LostPairMailbox(events: state, failPUT: failPUT), replyTimeout: 0.03)
    })
  await #expect(throws: RemotePairing.Failure.remoteUnavailable) {
    try await pairing.prepare(invitation: invitation(hub, addrs: [], relay: relay), deviceName: "合成 Mac",
      onMailboxDelivered: {
        #expect((try? HubBinding.read(from: directory)) == .legacyLocal)
        state.note("waiting")
      })
  }
  if failPUT {
    #expect(state.trace == ["put"])
  } else {
    #expect(state.trace.prefix(3) == ["put", "waiting", "read"])
    #expect(state.trace.filter { $0 == "waiting" }.count == 1)
  }
  #expect(try HubBinding.read(from: directory) == .legacyLocal)
}

@Test func remoteRePairingRequiresFrozenSameHubAndRestoresInterruptedCommit() async throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let hub = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  let connectionFile = try writeRemote(directory, remote)
  let credentialsDirectory = connectionFile.deletingLastPathComponent()
  let active = try commit(directory, remote)
  let oldMac = Curve25519.KeyAgreement.PrivateKey(), oldAgent = Curve25519.KeyAgreement.PrivateKey()
  let state = TestState()
  let macAccount = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  let agentAccount = RemoteDeviceLink.Keys.account(.agent, hubID: remote.hub_id)
  try state.keys.create(macAccount, oldMac.rawRepresentation)
  try state.keys.create(agentAccount, oldAgent.rawRepresentation)
  let agentFile = credentialsDirectory.appendingPathComponent("agent-link.json")
  let oldAgentLink = Data(#"{"synthetic":"old agent"}"#.utf8)
  try PrivateFile.write(oldAgentLink, to: agentFile)
  let nextID = "mac-replace2"
  let access = RemoteDeviceAccess(dataDirectory: directory, keys: state.keys)
  let pairing = RemotePairing(dataDirectory: directory, keys: state.keys, endpoint: { _ in
    .init(transport: FakeTransport { sealed in
      let raw = try #require(try state.keys.read(macAccount + ".replacement"))
      let replacement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
      let input = try request(sealed, hub: hub, client: sealed.envelope.device == nil ? nil : replacement.publicKey)
      switch input["op"]?.stringValue {
      case "pair":
        return try reply(sealed, hub: hub, client: replacement.publicKey, body: [
          "device_id": .string(nextID), "hub_id": .string(remote.hub_id), "role": .string("admin"),
          "name": .string("合成 Mac"), "hub_name": .string("认证后台"),
        ])
      case "agent.enroll":
        let pk = try #require(input["body"]?["agent_pk"]?.stringValue)
        #expect(pk != DeviceEnvelope.publicKeyBase64URL(oldAgent.publicKey))
        return try reply(sealed, hub: hub, client: replacement.publicKey, body: [
          "device_id": .string(agentID), "hub_id": .string(remote.hub_id),
        ])
      default:
        Issue.record("Unexpected request")
        return .init(statusCode: 400)
      }
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  }, discover: { _ in [] })

  let text = try invitation(hub, addrs: [remoteAddress])
  await #expect(throws: RemotePairing.Failure.notFrozen) {
    try await pairing.prepareRePairing(invitation: text, deviceName: "合成 Mac")
  }
  access.freeze(active.route)
  await #expect(throws: RemotePairing.Failure.differentHub) {
    try await pairing.prepareRePairing(invitation: invitation(.init(), addrs: [remoteAddress]), deviceName: "合成 Mac")
  }
  await #expect(throws: RemotePairing.Failure.adminInvitationRequired) {
    try await pairing.prepareRePairing(invitation: invitation(hub, addrs: [remoteAddress],
      expiry: Date().addingTimeInterval(600)), deviceName: "合成 Mac")
  }

  let prepared = try await pairing.prepareRePairing(invitation: text, deviceName: "合成 Mac")
  if case .awaitingConfirmation = try pairing.rePairingState() {} else { Issue.record("Missing durable confirmation state") }
  #expect(prepared.collectorLink.hubName == "认证后台")
  #expect(prepared.binding.generation == active.generation + 1)
  #expect(try RemoteDeviceLink.read(from: directory, identity: remote).device_id == macID)
  #expect(try state.keys.read(macAccount) == oldMac.rawRepresentation)

  let journalFile = RemoteRelayJournal.name(for: active.route)
  let box = RemoteRelayMailbox(try .init(url: "http://127.0.0.1:48718", space: DeviceEnvelope.randomNonce(),
    up: DeviceEnvelope.randomNonce(), down: DeviceEnvelope.randomNonce(),
    token: DeviceProtocol.base64URLEncode(Data(repeating: 8, count: 32))))
  let lost = ULID.make()
  var journal = RemoteRelayJournal(route: active.route, deviceID: macID)
  journal.deliveries = [
    .init(nonce: try DeviceEnvelope.randomNonce(), operation: "ingest", recordIDs: [lost], mailbox: box,
      createdAt: Date(), capture: true, fingerprint: Data(), putConfirmed: true, attemptedPut: true),
    .init(nonce: try DeviceEnvelope.randomNonce(), operation: "ingest", recordIDs: [ULID.make()], mailbox: box,
      createdAt: Date(), capture: false, fingerprint: Data(), putConfirmed: true, attemptedPut: true),
  ]
  let oldKey = RemoteRelayJournal.key(for: oldMac.rawRepresentation, route: active.route, deviceID: macID)
  try journal.save(key: oldKey, in: credentialsDirectory, name: journalFile)

  let restarted = RemotePairing(dataDirectory: directory, keys: state.keys, discover: { _ in [] })
  #expect(try await restarted.preparedRePairing() == prepared)
  await #expect(throws: RemotePairing.Failure.recoveryRequired) {
    try await restarted.commitRePairing(prepared, publish: { _, _, publish in
      // Stop after replacing the active keys and collector link, just before publication.
      try FileManager.default.removeItem(at: agentFile)
      try FileManager.default.createSymbolicLink(at: agentFile, withDestinationURL: directory.appendingPathComponent("absent"))
      try publish()
    }, finish: { _ in Issue.record("Publication advanced despite interrupted credentials") })
  }
  #expect(try HubBinding.read(from: directory) == active)
  #expect(try restarted.rePairingState() == .recovery(canCancel: true))
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { try access.validate(active.route) }
  try FileManager.default.removeItem(at: agentFile)
  let recovered = RemotePairing(dataDirectory: directory, keys: state.keys, discover: { _ in [] })
  try await recovered.recoverRePairing(finish: { _ in Issue.record("Unpublished binding should roll back") })
  #expect(try RemoteDeviceLink.read(from: directory, identity: remote).device_id == macID)
  #expect(try state.keys.read(macAccount) == oldMac.rawRepresentation)
  #expect(try Data(contentsOf: agentFile) == oldAgentLink)
  #expect(try await recovered.preparedRePairing() == prepared)

  // Invalid key contents should not block publishing valid replacement credentials.
  try state.keys.remove(agentAccount)
  try state.keys.create(agentAccount, Data([0]))
  await #expect(throws: RemotePairing.Failure.recoveryRequired) {
    try await recovered.commitRePairing(prepared, publish: { _, _, publish in try publish() },
      finish: { _ in throw LocalDeviceLink.Failure.fileIO })
  }
  #expect(try HubBinding.read(from: directory) == prepared.binding)
  #expect(try recovered.rePairingState() == .recovery(canCancel: false))
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { try access.validate(prepared.binding.route) }
  let afterPublication = RemotePairing(dataDirectory: directory, keys: state.keys, discover: { _ in [] })
  try await afterPublication.recoverRePairing(finish: { #expect($0 == prepared) })
  let activeLink = try RemoteDeviceLink.read(from: directory, identity: remote)
  #expect(activeLink.hubName == "认证后台" && activeLink.device_id == nextID)
  let mac = try #require(try state.keys.read(macAccount))
  #expect(mac != oldMac.rawRepresentation)
  #expect(!RemoteDeviceSession.hasJournal(in: directory, for: active.route))
  let newKey = RemoteRelayJournal.key(for: mac, route: prepared.binding.route, deviceID: nextID)
  let newJournal = try RemoteRelayJournal.load(key: newKey, in: credentialsDirectory,
    name: RemoteRelayJournal.name(for: prepared.binding.route), route: prepared.binding.route, deviceID: nextID)
  #expect(newJournal.unknownOutcomes == 2 && newJournal.deliveries.isEmpty)
  #expect(try afterPublication.rePairingState() == .idle)
  #expect(state.accountNames == [macAccount, agentAccount])
  try access.validate(prepared.binding.route)
}

@Test func retainedRemoteCredentialsReconnectAfterReturningLocal() async throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  _ = try writeRemote(directory, remote)
  let active = try commit(directory, remote)
  let state = TestState()
  let macAccount = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  try state.keys.create(macAccount, mac.rawRepresentation)
  let returning = HubBinding(generation: active.generation, target: .remote, phase: .switching_back, remote: remote)
  try returning.write(to: directory, replacing: active)
  let local = HubBinding(generation: active.generation + 1, target: .local, phase: .local)
  try local.write(to: directory, replacing: returning)
  let pairing = RemotePairing(dataDirectory: directory, keys: state.keys, endpoint: { _ in
    .init(transport: FakeTransport { sealed in
      let input = try request(sealed, hub: hub, client: mac.publicKey)
      #expect(input["op"] == .string("relay"))
      return try reply(sealed, hub: hub, client: mac.publicKey, body: ["role": .string("admin")])
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  }, discover: { _ in [] })
  let cleanup = directory.appendingPathComponent(remote.dir).appendingPathComponent("repair-cleanup-required")
  try PrivateFile.write(Data(), to: cleanup)
  let prepared = try await pairing.prepare(invitation: invitation(hub, addrs: [remoteAddress]), deviceName: "合成 Mac")
  #expect(prepared.collectorLink.device_id == macID)
  #expect(try HubBinding.read(from: directory) == prepared.binding)
  #expect(try state.keys.read(macAccount) == mac.rawRepresentation)
  #expect(try pairing.remotesRequiringRePairingCleanup().isEmpty)
  try PrivateFile.write(Data(), to: cleanup)
  try await pairing.dismissRePairingCleanup()
  #expect(try pairing.remotesRequiringRePairingCleanup().isEmpty)
}

@Test func malformedActiveMacKeyFreezesWhileTransientFailureDoesNot() throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let remote = try identity(.init())
  _ = try writeRemote(directory, remote)
  let route = try commit(directory, remote).route
  let link = try RemoteDeviceLink.read(from: directory, identity: remote)
  let transport = FakeTransport { _ in Issue.record("Invalid key reached transport"); return .init(statusCode: 500) }
  let unavailable = RemoteDeviceLink.Keys(read: { _ in throw LocalDeviceLink.Failure.keyUnavailable },
    create: { _, _ in }, remove: { _ in })
  let first = RemoteDeviceAccess(dataDirectory: directory, keys: unavailable)
  #expect(throws: DeviceClientError.self) { _ = try first.makeClient(for: route, link: link, transport: transport) }
  try first.validate(route)
  let malformed = RemoteDeviceLink.Keys(read: { _ in throw RemoteDeviceLink.Keys.Failure.malformed },
    create: { _, _ in }, remove: { _ in })
  let second = RemoteDeviceAccess(dataDirectory: directory, keys: malformed)
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { _ = try second.makeClient(for: route, link: link, transport: transport) }
  #expect(throws: RemoteDeviceAccess.Failure.frozen) { try first.validate(route) }
}

// 2026-11-24 终审回归：已撤销或降权的保留身份需要新管理邀请，取消保留原登记。
@Test(arguments: ["revoked", "downgraded", "missing", "malformed", "offline"])
func finalReviewInvalidRetainedIdentityCanPairAgain(scenario: String) async throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let hub = Curve25519.KeyAgreement.PrivateKey(), old = Curve25519.KeyAgreement.PrivateKey()
  let remote = try identity(hub)
  _ = try writeRemote(directory, remote)
  let state = TestState()
  let account = RemoteDeviceLink.Keys.account(.mac, hubID: remote.hub_id)
  if scenario != "missing" {
    try state.keys.create(account, scenario == "malformed" ? Data([7]) : old.rawRepresentation)
  }
  let underlying = state.keys
  let oldSecret = try underlying.read(account)
  let keys = RemoteDeviceLink.Keys(read: { name in
    let value = try underlying.read(name)
    if name == account, let value, value.count != 32 { throw RemoteDeviceLink.Keys.Failure.malformed }
    return value
  }, create: underlying.create, remove: underlying.remove)
  let newID = "mac-replace2"
  let flow = RemotePairing(dataDirectory: directory, keys: keys, endpoint: { _ in
    let replacement = try state.keys.read(account + ".replacement")
    return .init(transport: FakeTransport { sealed in
      if sealed.envelope.device == macID {
        if scenario == "offline" { throw DeviceClientError.transportError("Synthetic offline") }
        if scenario == "revoked" { return .init(statusCode: 401) }
        return try reply(sealed, hub: hub, client: old.publicKey, body: ["role": .string("view")])
      }
      let raw = try #require(replacement)
      let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey
      let input = try request(sealed, hub: hub, client: sealed.envelope.device == nil ? nil : key)
      switch input["op"]?.stringValue {
      case "pair":
        return try reply(sealed, hub: hub, client: key, body: [
          "device_id": .string(newID), "hub_id": .string(remote.hub_id), "role": .string("admin"), "name": .string("合成 Mac"),
        ])
      case "agent.enroll":
        return try reply(sealed, hub: hub, client: key,
                         body: ["device_id": .string(agentID), "hub_id": .string(remote.hub_id)])
      case "devices.remove": return try reply(sealed, hub: hub, client: key, body: [:])
      default: throw RemotePairing.Failure.invalidReceipt
      }
    }, hello: { DeviceHello(hubID: remote.hub_id) })
  }, discover: { _ in [] })
  let text = try invitation(hub, addrs: [remoteAddress])
  if scenario == "offline" {
    await #expect(throws: RemotePairing.Failure.remoteUnavailable) {
      try await flow.prepare(invitation: text, deviceName: "合成 Mac")
    }
    #expect(try state.keys.read(account + ".replacement") == nil)
    #expect(try state.keys.read(account) == oldSecret)
    return
  }
  await #expect(throws: RemotePairing.Failure.retainedIdentityInvalid) { try await flow.prepareRetained(remote: remote) }
  let prepared = try await flow.prepare(invitation: text, deviceName: "合成 Mac")
  #expect(prepared.collectorLink.device_id == newID)
  #expect(try state.keys.read(account) == oldSecret)
  try await flow.cancel(prepared)
  #expect(try RemoteDeviceLink.read(from: directory, identity: remote).device_id == macID)
  #expect(try state.keys.read(account) == oldSecret)
  if scenario == "malformed" {
    let next = try await flow.prepare(invitation: invitation(hub, addrs: [remoteAddress], code: 43), deviceName: "合成 Mac")
    try await flow.withPreparedCommit(next.binding) {
      let active = HubBinding(generation: next.binding.generation + 1, target: .remote, phase: .committed, remote: remote)
      try active.write(to: directory, replacing: next.binding)
    }
    #expect(try keys.read(account)?.count == 32)
    #expect(try RemoteDeviceLink.read(from: directory, identity: remote).device_id == newID)
  }
}

// 2026-11-24 终审回归：旧远端撤销等待回执时，可照常确认另一台后台。
@Test func finalReviewExpiredPairingCleanupDoesNotBlockAnotherRemote() async throws {
  let directory = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let expiredHub = Curve25519.KeyAgreement.PrivateKey(), newHub = Curve25519.KeyAgreement.PrivateKey()
  let oldRemote = try identity(expiredHub), newRemote = try identity(newHub)
  let oldFile = try writeRemote(directory, oldRemote)
  _ = try writeRemote(directory, newRemote)
  let oldDirectory = oldFile.deletingLastPathComponent()
  let replacement = Curve25519.KeyAgreement.PrivateKey(), newMac = Curve25519.KeyAgreement.PrivateKey()
  let replacementLink = try RemoteDeviceLink(identity: oldRemote, deviceID: "mac-replace2", addresses: [localAddress])
  let pending = try JSONSerialization.data(withJSONObject: [
    "hub_id": oldRemote.hub_id, "hub_pk": oldRemote.hub_pk, "device_name": "合成 Mac",
    "code_sha256": "synthetic", "device_pk_sha256": "synthetic",
    "expires_at": 0, "nonce": "unused", "envelope": "",
  ])
  let registration = try JSONSerialization.data(withJSONObject: [
    "link": try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacementLink)),
  ])
  try PrivateFile.write(pending, to: oldDirectory.appendingPathComponent("pending-repair-request.json"))
  try PrivateFile.write(registration, to: oldDirectory.appendingPathComponent("pending-repair-registration.json"))
  let keys = TestState().keys
  try keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: oldRemote.hub_id) + ".replacement", replacement.rawRepresentation)
  try keys.create(RemoteDeviceLink.Keys.account(.mac, hubID: newRemote.hub_id), newMac.rawRepresentation)
  let suspended = DelayedReceipt()
  let flow = RemotePairing(dataDirectory: directory, keys: keys, endpoint: { address in
    if address == localAddress {
      return .init(transport: FakeTransport { sealed in
        await suspended.wait()
        return try reply(sealed, hub: expiredHub, client: replacement.publicKey, body: [:])
      }, hello: { DeviceHello(hubID: oldRemote.hub_id) })
    }
    return .init(transport: FakeTransport { sealed in
      try reply(sealed, hub: newHub, client: newMac.publicKey, body: ["role": .string("admin")])
    }, hello: { DeviceHello(hubID: newRemote.hub_id) })
  }, discover: { _ in [] })
  let cleanup = Task { try await flow.cleanupExpiredPreparations() }
  do {
    try await waitFor { await suspended.started }
    let prepared = try await flow.prepareRetained(remote: newRemote)
    try await flow.withPreparedCommit(prepared.binding) {
      let active = HubBinding(generation: prepared.binding.generation + 1, target: .remote, phase: .committed, remote: newRemote)
      try active.write(to: directory, replacing: prepared.binding)
    }
    #expect(try HubBinding.read(from: directory).route.remote == newRemote)
  } catch {
    await suspended.release()
    _ = await cleanup.result
    throw error
  }
  await suspended.release()
  try await cleanup.value
  #expect(try flow.remotesRequiringRePairingCleanup().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(newRemote.dir)
    .appendingPathComponent("retained-preparation").path))
}


// Settings must be able to save a local port even when no service has created hub.json yet.
@Test func offlinePortUpdatesLiveOriginAndPreservesOtherSettings() throws {
  let dir = try syntheticDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let config = Config(dataDir: dir, bun: "")
  let file = dir.appendingPathComponent("hub.json")
  try config.writeHubPort(52631)
  #expect(config.hubURL.port == 52631)
  try PrivateFile.write(Data(#"{"port":52631,"lan_port":52632,"timezone":"Asia/Taipei"}"#.utf8), to: file)
  try config.writeHubPort(52633)
  #expect(config.hubURL.port == 52633)
  let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  #expect(fields["lan_port"] as? Int == 52632)
  #expect(fields["timezone"] as? String == "Asia/Taipei")
  #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
  let fixed = Config(dataDir: dir, fixedPort: "52634", bun: "")
  #expect(throws: HubError.self) { try fixed.writeHubPort(52635) }
  #expect(config.hubURL.port == 52633)
  _ = try commit(dir, identity(Curve25519.KeyAgreement.PrivateKey()))
  #expect(throws: HubError.self) { try config.writeHubPort(52635) }
  #expect(config.hubURL.port == 52633)
}

@Test @MainActor func timelineShowsPreparationOnlyAfterCheckingThatTheBackendIsUnreachable() {
  let ready = AppSetup.checklistStep(activity: .running, reachable: true, inStartupGrace: true, startupMessage: nil)
  #expect(ready == nil)
  #expect(ReviewPage.allowsDayRecords(backendSetup: ready))

  let preparing = AppSetup.checklistStep(activity: .running, reachable: false, inStartupGrace: true, startupMessage: nil)
  #expect(preparing == .preparing)
  #expect(!ReviewPage.allowsDayRecords(backendSetup: preparing))

  let failed = AppSetup.checklistStep(activity: .finished(.backgroundBlocked), reachable: true,
                                      inStartupGrace: true, startupMessage: nil)
  #expect(failed == .failed(L10n.Settings.setupFailure(.backgroundBlocked)))
  #expect(!ReviewPage.allowsDayRecords(backendSetup: failed))
}
