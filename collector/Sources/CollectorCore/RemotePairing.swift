import CryptoKit
import Darwin
import Foundation

/// Prepares credentials and issues a preparing binding. Service handoff owns publication of the active route.
public actor RemotePairing {
  public enum Failure: LocalizedError, Equatable {
    case adminInvitationRequired, remoteUnavailable, preparationExists, invalidReceipt, remoteCleanupRequired
    case differentHub, notFrozen, recoveryRequired, retainedIdentityInvalid

    public var errorDescription: String? {
      switch self {
      case .adminInvitationRequired: "请使用有管理权限的配对链接"
      case .remoteUnavailable: "找不到远端后台"
      case .preparationExists: "已有远端连接凭据，请先处理现有连接"
      case .invalidReceipt: "远端后台返回的配对确认无效"
      case .remoteCleanupRequired: "请联系服务器管理员清理本次配对"
      case .differentHub: "请使用当前远端后台签发的管理配对链接。更换后台前请先切回这台 Mac。"
      case .notFrozen: "当前远端连接未冻结，请使用原连接恢复验证。"
      case .retainedIdentityInvalid: "请粘贴远端后台新签发的管理配对链接。"
      case .recoveryRequired: "重新配对尚未收尾，已保留恢复进度。"
      }
    }
  }

  public struct DirectEndpoint: Sendable {
    public let transport: any DeviceTransport
    public let hello: @Sendable () async throws -> DeviceHello

    public init(transport: any DeviceTransport, hello: @escaping @Sendable () async throws -> DeviceHello) {
      self.transport = transport
      self.hello = hello
    }

    public init(origin: URL) throws {
      let direct = try DirectDeviceTransport(origin: origin, requestTimeout: 5)
      self.init(transport: direct, hello: { try await direct.hello() })
    }
  }

  public struct BonjourAddress: Sendable {
    public let hubID: String
    public let address: URL

    public init(hubID: String, address: URL) {
      self.hubID = hubID
      self.address = address
    }
  }

  public struct Prepared: Sendable {
    public let binding: HubBinding
    public let collectorLink: RemoteDeviceLink
    public let agentLink: RemoteDeviceLink.AgentLink?
    public let agentDeviceID: String
    public let relay: RemoteDeviceLink.Relay?
    public let invitationHubName: String
    public var usedMailbox: Bool? = nil
    public var agentNeedsDirectConnection: Bool { agentLink == nil }
  }

  public typealias MailboxDelivered = @Sendable () async -> Void
  public typealias MailboxTransport = @Sendable (DeviceRelayConfig) -> any DeviceTransport

  private struct PendingPair: Codable {
    static let fileName = "pending-pair.json"
    let hub_id: String
    let hub_pk: String
    let code_sha256: String
    let device_name: String
    let device_pk_sha256: String
    let expires_at: Date
    let nonce: String
    let envelope: Data

    var request: SealedDeviceRequest {
      get throws {
        guard DeviceProtocol.base64URLDecode(nonce, expectedLength: 16) != nil else { throw Failure.invalidReceipt }
        return .init(envelope: try JSONDecoder().decode(DeviceRequestEnvelope.self, from: envelope),
                     wireData: envelope, nonce: nonce)
      }
    }

    static func hash(_ data: Data) -> String { DeviceProtocol.base64URLEncode(Data(SHA256.hash(data: data))) }
  }

  private let dataDirectory: URL
  private let keys: RemoteDeviceLink.Keys
  private let endpoint: @Sendable (URL) throws -> DirectEndpoint
  private let discover: @Sendable (String) async -> [BonjourAddress]
  private let mailboxTransport: MailboxTransport
  private let clock: @Sendable () -> Date
  private var running = false
  private var rePairExpiration: Task<Void, Never>?
  private var expiration: Task<Void, Never>?

  public init(
    dataDirectory: URL, keys: RemoteDeviceLink.Keys = .keychain,
    endpoint: @escaping @Sendable (URL) throws -> DirectEndpoint = { try DirectEndpoint(origin: $0) },
    discover: (@Sendable (String) async -> [BonjourAddress])? = nil,
    mailboxTransport: @escaping MailboxTransport = { RelayDeviceTransport(mailbox: HTTPRelayMailboxClient(config: $0)) },
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.dataDirectory = dataDirectory
    self.keys = keys
    self.endpoint = endpoint
    self.discover = discover ?? { await RemotePairingBonjour.lookup(hubID: $0) }
    self.mailboxTransport = mailboxTransport
    self.clock = clock
  }

  public func prepare(invitation text: String, deviceName: String, lastSuccessfulAddress: URL? = nil,
                      manualAddress: URL? = nil, onMailboxDelivered: MailboxDelivered? = nil) async throws -> Prepared {
    let invitation = try DevicePairingInvitation.parse(text, now: clock(), allowExpired: true)
    guard invitation.role == "admin" else { throw Failure.adminInvitationRequired }
    if let manualAddress, RemoteDeviceLink.origin(manualAddress.absoluteString) == nil {
      throw DeviceClientError.invalidRequest("中枢直连地址无效")
    }
    guard !running else { throw Failure.preparationExists }
    running = true
    defer {
      running = false
      Task { try? await cleanupExpiredPreparations() }
    }

    try sweepPendingPairs()
    let previous = try HubBinding.read(from: dataDirectory)
    guard previous.phase == .local else { throw Failure.preparationExists }
    let identity = try HubBinding.Remote(hubID: invitation.hubID, hubPublicKey: invitation.hubPublicKeyBase64URL)
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    if try BindingFile.read(PendingPair.fileName, in: directory) == nil,
       (try? RemoteDeviceLink.read(from: dataDirectory, identity: identity)) != nil {
      guard invitation.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
      do {
        return try await reconnect(identity, previous: previous, addresses: [manualAddress].compactMap { $0 } + invitation.addresses)
      } catch Failure.retainedIdentityInvalid {
        let replacement = try await prepareReplacement(invitation, deviceName: deviceName, identity: identity, previous: previous,
          directory: directory, lastSuccessfulAddress: lastSuccessfulAddress, manualAddress: manualAddress,
          onMailboxDelivered: onMailboxDelivered)
        let binding = HubBinding(generation: previous.generation, target: .remote, phase: .preparing,
                                 remote: identity, updatedAt: clock())
        try binding.write(to: dataDirectory, replacing: previous)
        try? BindingFile.remove(Self.cleanupRequired, in: directory)
        return Prepared(binding: binding, collectorLink: replacement.collectorLink, agentLink: replacement.agentLink,
          agentDeviceID: replacement.agentDeviceID, relay: replacement.relay, invitationHubName: invitation.hubName)
      }
    }
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let (mac, sealed) = try pendingRequest(invitation, name: name, identity: identity, directory: directory)
    let client: DeviceClient
    let paired: PairedDevice
    let origin: URL?
    do {
      (client, paired, origin) = try await connect(invitation, sealed: sealed, key: mac,
                                                   lastSuccessfulAddress: lastSuccessfulAddress, manualAddress: manualAddress,
                                                   onMailboxDelivered: onMailboxDelivered)
    } catch DeviceClientError.inviteExpired {
      try removeFiles(identity, directory: directory)
      throw DeviceClientError.inviteExpired
    } catch let error as DeviceClientError {
      if case .operationError(_, let status, _) = error, [401, 403, 409, 410].contains(status) {
        try removeFiles(identity, directory: directory)
      }
      throw error
    }

    guard paired.hubID == identity.hub_id, paired.deviceID.hasPrefix("mac-"),
          DeviceProtocol.isValidDeviceID(paired.deviceID) else { throw Failure.invalidReceipt }
    guard paired.role == "admin" else {
      try removeFiles(identity, directory: directory)
      throw Failure.adminInvitationRequired
    }
    // Keep the pending request until publication. Retrying after an interrupted enrollment reuses both keys.
    let link = try Self.link(identity, paired, origin, invitation: invitation)
    let encoder = JSONEncoder()
    try BindingFile.write(encoder.encode(link), named: LocalDeviceLink.File.collector.rawValue, in: directory)
    let relay = paired.relay.map(RemoteDeviceLink.Relay.init)
    if let config = paired.relay, let relay {
      try saveSecret(Data(config.token.utf8), account: RemoteDeviceLink.Relay.account(deviceID: paired.deviceID))
      try BindingFile.write(encoder.encode(relay), named: RemoteDeviceLink.Relay.fileName, in: directory)
    } else {
      try keys.remove(RemoteDeviceLink.Relay.account(deviceID: paired.deviceID))
      try BindingFile.remove(RemoteDeviceLink.Relay.fileName, in: directory)
    }
    let agent = try loadOrCreateAgent(hubID: identity.hub_id)
    let (agentID, agentLink) = try await enroll(agent, client: client, identity: identity, origin: origin)
    if let agentLink {
      try BindingFile.write(encoder.encode(agentLink), named: LocalDeviceLink.File.agent.rawValue, in: directory)
    } else {
      try BindingFile.remove(LocalDeviceLink.File.agent.rawValue, in: directory)
    }
    try Task.checkCancellation()
    let binding = HubBinding(generation: previous.generation, target: .remote, phase: .preparing,
                             remote: identity, updatedAt: clock())
    try binding.write(to: dataDirectory, replacing: previous)
    // Publication is the commit point. A leftover pending file can be cleaned without removing live credentials.
    try? BindingFile.remove(PendingPair.fileName, in: directory)
    try? BindingFile.remove(Self.cleanupRequired, in: directory)
    return Prepared(binding: binding, collectorLink: link, agentLink: agentLink, agentDeviceID: agentID,
                    relay: relay, invitationHubName: invitation.hubName)
  }

  private static func link(_ identity: HubBinding.Remote, _ paired: PairedDevice, _ origin: URL?,
                           invitation: DevicePairingInvitation) throws -> RemoteDeviceLink {
    let name = paired.hubName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return try RemoteDeviceLink(identity: identity, deviceID: paired.deviceID, addresses: [origin].compactMap { $0 },
                                hubName: name.flatMap { $0.isEmpty ? nil : $0 } ?? invitation.hubName)
  }

  private func enroll(_ agent: Curve25519.KeyAgreement.PrivateKey, client: DeviceClient,
                      identity: HubBinding.Remote, origin: URL?) async throws -> (String, RemoteDeviceLink.AgentLink?) {
    struct Enrollment: Decodable { let device_id: String; let hub_id: String }
    let enrolled = try await client.send(op: "agent.enroll", body: ["agent_pk": .string(
      DeviceEnvelope.publicKeyBase64URL(agent.publicKey)
    )], as: Enrollment.self)
    guard enrolled.hub_id == identity.hub_id, enrolled.device_id.hasPrefix("agent-"),
          DeviceProtocol.isValidDeviceID(enrolled.device_id) else { throw Failure.invalidReceipt }
    let agentLink = origin.map {
      RemoteDeviceLink.AgentLink(hub_id: identity.hub_id, hub_pk: identity.hub_pk,
                                 device_id: enrolled.device_id, address: $0.absoluteString)
    }
    return (enrolled.device_id, agentLink)
  }

  /// Keep cancellation and expired-credential cleanup from racing the service cutover.
  public func withPreparedCommit(_ prepared: Prepared, operation: @Sendable () async throws -> Void) async throws {
    try await withPreparedCommit(prepared.binding, operation: operation)
  }

  public func withPreparedCommit(_ binding: HubBinding, operation: @Sendable () async throws -> Void) async throws {
    guard !running else { throw Failure.preparationExists }
    guard try HubBinding.read(from: dataDirectory) == binding, binding.phase == .preparing,
          let identity = binding.remote else { throw HubBinding.Failure.changed }
    running = true
    defer { running = false }
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    if let ready = try retainedReplacement(for: binding) {
      let transaction: RePairTransaction
      if let data = try BindingFile.read(Self.retainedTransaction, in: directory, limit: 64 * 1024) {
        transaction = try JSONDecoder().decode(RePairTransaction.self, from: data)
        guard transaction.prepared == ready else { throw Failure.recoveryRequired }
      } else {
        transaction = try makeRePairTransaction(ready, directory: directory, identity: identity)
        try BindingFile.write(JSONEncoder().encode(transaction), named: Self.retainedTransaction, in: directory, limit: 64 * 1024)
      }
      do {
        try installReplacementCredentials(transaction, identity: identity, directory: directory)
        try await operation()
      } catch {
        if (try? HubBinding.read(from: dataDirectory)) == binding {
          try restoreRePairing(transaction, identity: identity, directory: directory, transactionFile: Self.retainedTransaction)
        }
        throw error
      }
    } else {
      try await operation()
    }
    try finishPreparedCommit()
  }

  public nonisolated func retainedReplacement(for binding: HubBinding) throws -> PreparedRePairing? {
    guard binding.phase == .preparing, let identity = binding.remote else { return nil }
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    guard let ready = try readRePairPreparation(in: directory), ready.previous.phase == .local,
          ready.previous.generation == binding.generation, ready.binding.remote == identity else { return nil }
    return ready
  }

  public nonisolated func preparedUsesMailbox(_ binding: HubBinding) throws -> Bool? {
    guard binding.phase == .preparing, let identity = binding.remote,
          let marker = try BindingFile.read(Self.retainedPreparation, in: dataDirectory.appendingPathComponent(identity.dir)),
          !marker.isEmpty else { return nil }
    return marker == Data("relay".utf8)
  }

  /// 提交后也可在恢复流程里重做，直到替换凭据和准备标记全部收尾。
  public func finishPreparedCommit() throws {
    let binding = try HubBinding.read(from: dataDirectory)
    guard binding.phase == .committed, let identity = binding.remote else { return }
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    try BindingFile.remove(Self.retainedPreparation, in: directory)
    if let data = try BindingFile.read(Self.retainedTransaction, in: directory, limit: 64 * 1024) {
      let transaction = try JSONDecoder().decode(RePairTransaction.self, from: data)
      guard transaction.prepared.binding.route == binding.route else { throw Failure.recoveryRequired }
      if let old = transaction.oldDeviceID { try keys.remove(RemoteDeviceLink.Relay.account(deviceID: old)) }
      try BindingFile.remove(RemoteDeviceAccess.rejectionMarker, in: directory)
      try clearRePairPreparation(identity, directory: directory, keepRelay: true)
      try BindingFile.remove(Self.retainedTransaction, in: directory)
    }
  }

  public func cancel(_ prepared: Prepared) async throws {
    try await cancelPreparation(replacing: prepared.binding)
  }

  /// Also works after restart, when only the preparing binding and its files remain.
  public func cancelPreparation(replacing prepared: HubBinding) async throws {
    guard !running else { throw Failure.preparationExists }
    running = true
    defer { running = false }
    guard try HubBinding.read(from: dataDirectory) == prepared, prepared.phase == .preparing,
          let identity = prepared.remote else { throw HubBinding.Failure.changed }
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    if try retainedReplacement(for: prepared) != nil {
      if let data = try BindingFile.read(Self.retainedTransaction, in: directory, limit: 64 * 1024) {
        let transaction = try JSONDecoder().decode(RePairTransaction.self, from: data)
        try restoreRePairing(transaction, identity: identity, directory: directory, transactionFile: Self.retainedTransaction)
      }
      let local = HubBinding(generation: prepared.generation, target: .local, phase: .local, updatedAt: clock())
      try local.write(to: dataDirectory, replacing: prepared)
      try BindingFile.remove(Self.retainedPreparation, in: directory)
      try await abandonRePairing(identity, directory: directory)
      return
    }
    if try BindingFile.read(Self.retainedPreparation, in: directory) != nil {
      let local = HubBinding(generation: prepared.generation, target: .local, phase: .local, updatedAt: clock())
      try local.write(to: dataDirectory, replacing: prepared)
      try BindingFile.remove(Self.retainedPreparation, in: directory)
      return
    }
    let removalReceipt = ".registration-removed"
    var removed = try BindingFile.read(removalReceipt, in: directory) != nil
    if !removed, let link = try? RemoteDeviceLink.read(from: dataDirectory, identity: identity) {
      let mac = RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id)
      if let raw = try keys.read(mac), let transport = try? cancellationTransport(link) {
        let client = try DeviceClient(hubPublicKeyBase64URL: identity.hub_pk, deviceID: link.device_id,
                                      keyStore: InMemoryDeviceKeyStore(rawRepresentation: raw), transport: transport)
        removed = await Self.removeRegistration(client, deviceID: link.device_id)
        if removed { try BindingFile.write(Data(), named: removalReceipt, in: directory) }
      }
    }
    // 目录已不在（上次清理到一半）时无法确认远端已撤回：仍收敛回本机，但继续提示需要服务器管理员清理。
    try removeFiles(identity, directory: directory)
    let local = HubBinding(generation: prepared.generation, target: .local, phase: .local, updatedAt: clock())
    try local.write(to: dataDirectory, replacing: prepared)
    if !removed { throw Failure.remoteCleanupRequired }
  }

  private static let retainedPreparation = "retained-preparation"
  private static let retainedTransaction = "retained-repair-transaction.json"

  public func prepareRetained(remote: HubBinding.Remote, manualAddress: URL? = nil) async throws -> Prepared {
    guard !running else { throw Failure.preparationExists }
    running = true
    defer { running = false }
    let previous = try HubBinding.read(from: dataDirectory)
    guard previous.phase == .local else { throw Failure.preparationExists }
    return try await reconnect(remote, previous: previous, addresses: [manualAddress].compactMap { $0 })
  }

  public nonisolated func retainedRemotes() throws -> [RemoteDeviceLink] {
    try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("remote-") }.compactMap { directory in
        guard let data = try? BindingFile.read(Self.collectorFile, in: directory),
              let link = try? JSONDecoder().decode(RemoteDeviceLink.self, from: data),
              let identity = try? HubBinding.Remote(hubID: link.hub_id, hubPublicKey: link.hub_pk),
              directory.lastPathComponent == identity.dir,
              (try? BindingFile.read(PendingPair.fileName, in: directory)) == nil else { return nil }
        return link
      }.sorted { $0.hub_id < $1.hub_id }
  }

  private func reconnect(_ identity: HubBinding.Remote, previous: HubBinding, addresses: [URL]) async throws -> Prepared {
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    let link = try RemoteDeviceLink.read(from: dataDirectory, identity: identity)
    let raw: Data
    do {
      guard let key = try keys.read(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id)), key.count == 32 else {
        throw Failure.retainedIdentityInvalid
      }
      raw = key
    } catch RemoteDeviceLink.Keys.Failure.malformed {
      throw Failure.retainedIdentityInvalid
    }
    let store = try InMemoryDeviceKeyStore(rawRepresentation: raw)
    let relay = try link.relay(in: dataDirectory)
    struct Authorization: Decodable { let role: String }
    func authenticate(_ transport: any DeviceTransport) async throws {
      let client = try DeviceClient(hubPublicKeyBase64URL: identity.hub_pk, deviceID: link.device_id,
                                    keyStore: store, transport: transport)
      do {
        let payload = try await client.send(op: "relay", timeout: 5)
        let authorization = try payload.decodeBody(Authorization.self)
        guard authorization.role == "admin" else { throw Failure.retainedIdentityInvalid }
      } catch DeviceClientError.deviceRemoved {
        throw Failure.retainedIdentityInvalid
      }
    }
    let discovered = await discover(identity.hub_id).filter { $0.hubID == identity.hub_id }.map(\.address)
    var attempted: Set<URL> = []
    var authenticated: URL?
    for address in addresses + link.addresses + discovered where attempted.insert(address).inserted {
      guard RemoteDeviceLink.origin(address.absoluteString) != nil, let direct = try? endpoint(address),
            let hello = try? await direct.hello(), hello.hubID == identity.hub_id, hello.v == DeviceProtocol.version else { continue }
      do { try await authenticate(direct.transport); authenticated = address; break }
      catch Failure.retainedIdentityInvalid { throw Failure.retainedIdentityInvalid }
      catch is CancellationError { throw CancellationError() }
      catch { continue }
    }
    if authenticated == nil {
      guard let relay else { throw Failure.remoteUnavailable }
      do { try await authenticate(mailboxTransport(relay.config(deviceID: link.device_id, keys: keys))) }
      catch Failure.retainedIdentityInvalid, RelayMailboxError.unauthorized(status: 401) { throw Failure.retainedIdentityInvalid }
      catch is CancellationError { throw CancellationError() }
      catch { throw Failure.remoteUnavailable }
    }
    try Task.checkCancellation()
    let nextLink = try RemoteDeviceLink(identity: identity, deviceID: link.device_id,
      addresses: [authenticated].compactMap { $0 } + link.addresses.filter { $0 != authenticated }, hubName: link.hubName)
    let agentLink = try BindingFile.read(Self.agentFile, in: directory).map {
      let agent = try JSONDecoder().decode(RemoteDeviceLink.AgentLink.self, from: $0)
      return RemoteDeviceLink.AgentLink(hub_id: agent.hub_id, hub_pk: agent.hub_pk, device_id: agent.device_id,
        address: authenticated?.absoluteString ?? agent.address)
    }
    try BindingFile.write(JSONEncoder().encode(nextLink), named: Self.collectorFile, in: directory)
    if let agentLink { try BindingFile.write(JSONEncoder().encode(agentLink), named: Self.agentFile, in: directory) }
    try BindingFile.write(Data((authenticated == nil ? "relay" : "direct").utf8), named: Self.retainedPreparation, in: directory)
    let binding = HubBinding(generation: previous.generation, target: .remote, phase: .preparing, remote: identity, updatedAt: clock())
    try binding.write(to: dataDirectory, replacing: previous)
    try? BindingFile.remove(Self.cleanupRequired, in: directory)
    return Prepared(binding: binding, collectorLink: nextLink, agentLink: agentLink,
      agentDeviceID: agentLink?.device_id ?? "", relay: relay, invitationHubName: link.hubName ?? identity.hub_id, usedMailbox: authenticated == nil)
  }

  private func cancellationTransport(_ link: RemoteDeviceLink) throws -> any DeviceTransport {
    if let origin = link.addresses.first { return try endpoint(origin).transport }
    guard let relay = try link.relay(in: dataDirectory) else { throw Failure.remoteUnavailable }
    return try mailboxTransport(relay.config(deviceID: link.device_id, keys: keys))
  }

  private func connect(_ invitation: DevicePairingInvitation, sealed: SealedDeviceRequest,
                       key: Curve25519.KeyAgreement.PrivateKey, lastSuccessfulAddress: URL?, manualAddress: URL?,
                       onMailboxDelivered: MailboxDelivered?) async throws
    -> (DeviceClient, PairedDevice, URL?) {
    let store = InMemoryDeviceKeyStore(privateKey: key)
    var visited = Set<URL>()
    func attempt(_ transport: any DeviceTransport) async throws -> (DeviceClient, PairedDevice)? {
      let client = DeviceClient(invitation: invitation, keyStore: store, transport: transport, clock: clock)
      do {
        return (client, try await client.pair(invitation: invitation, sealed: sealed))
      } catch DeviceClientError.operationError(_, let status, _) where ![401, 403, 409, 410].contains(status) {
        return nil
      } catch DeviceClientError.transportError, DeviceClientError.hubBusy, DeviceClientError.envelopeTooLarge,
              DeviceClientError.cryptographicFailure, DeviceClientError.invalidEnvelope, DeviceClientError.plaintextError,
              RelayMailboxError.unauthorized(status: 401) {
        return nil
      }
    }
    func probe(_ candidates: [URL]) async throws -> (DeviceClient, PairedDevice, URL?)? {
      for candidate in candidates {
        try Task.checkCancellation()
        guard invitation.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
        guard let address = RemoteDeviceLink.origin(candidate.absoluteString), visited.insert(address).inserted,
              let direct = try? endpoint(address), let hello = try? await direct.hello(),
              hello.hubID == invitation.hubID, hello.v == DeviceProtocol.version else { continue }
        if let (client, paired) = try await attempt(direct.transport) { return (client, paired, address) }
      }
      return nil
    }
    if let paired = try await probe([lastSuccessfulAddress].compactMap { $0 } + invitation.addresses) { return paired }
    let discovered = await discover(invitation.hubID).filter { $0.hubID == invitation.hubID }.map(\.address)
    if let paired = try await probe(discovered + [manualAddress].compactMap { $0 }) { return paired }
    try Task.checkCancellation()
    guard invitation.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
    if let relay = invitation.relay {
      let transport = mailboxTransport(relay)
      let reporting = (transport as? RelayDeviceTransport)?.reportingDelivery(onMailboxDelivered) ?? transport
      guard let (_, paired) = try await attempt(reporting) else { throw Failure.remoteUnavailable }
      guard let activeRelay = paired.relay else { throw Failure.invalidReceipt }
      let client = try DeviceClient(hubPublicKeyBase64URL: invitation.hubPublicKeyBase64URL, deviceID: paired.deviceID,
                                    keyStore: store, transport: mailboxTransport(activeRelay), clock: clock)
      return (client, paired, nil)
    }
    throw Failure.remoteUnavailable
  }

  /// Run on host startup so an interrupted preparation also expires after a restart.
  public func cleanupExpiredPreparations() async throws {
    guard !running else { return }
    try sweepPendingPairs()
    try await expireRePairing()
  }

  private func sweepPendingPairs() throws {
    let binding = try HubBinding.read(from: dataDirectory)
    var nextExpiry: Date?
    for directory in try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
      where directory.lastPathComponent.hasPrefix("remote-") {
      if binding.remote?.dir != directory.lastPathComponent {
        try? BindingFile.remove(Self.retainedPreparation, in: directory)
      }
      guard let data = try? BindingFile.read(PendingPair.fileName, in: directory),
            let pending = try? JSONDecoder().decode(PendingPair.self, from: data),
            let identity = try? HubBinding.Remote(hubID: pending.hub_id, hubPublicKey: pending.hub_pk),
            identity.dir == directory.lastPathComponent else { continue }
      if binding.remote == identity {
        // A crash after publishing the binding must not retire the published identity.
        try BindingFile.remove(PendingPair.fileName, in: directory)
      } else if pending.expires_at <= clock() {
        try removeFiles(identity, directory: directory)
      } else {
        nextExpiry = min(pending.expires_at, nextExpiry ?? pending.expires_at)
      }
    }
    expiration?.cancel()
    expiration = nextExpiry.map { date in
      Task {
        do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSince(clock())))) }
        catch { return }
        Task { try? await cleanupExpiredPreparations() }
      }
    }
  }

  private func pendingRequest(_ invite: DevicePairingInvitation, name: String, identity: HubBinding.Remote,
                              directory: URL, replacement: Bool = false) throws -> (Curve25519.KeyAgreement.PrivateKey, SealedDeviceRequest) {
    let account = replacement ? replacementAccount(.mac, identity) : RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id)
    let file = replacement ? Self.rePairRequest : PendingPair.fileName
    func clear() throws {
      if replacement { try clearRePairPreparation(identity, directory: directory) }
      else { try removeFiles(identity, directory: directory) }
    }
    let codeHash = PendingPair.hash(Data(invite.code.utf8))
    if let data = try BindingFile.read(file, in: directory) {
      let pending = try JSONDecoder().decode(PendingPair.self, from: data)
      guard pending.hub_id == identity.hub_id, pending.hub_pk == identity.hub_pk else { throw Failure.invalidReceipt }
      if pending.expires_at <= clock() || pending.code_sha256 != codeHash {
        if pending.expires_at > clock() {
          // 还能恢复的旧请求，只在新链接本身有效时才放弃，误贴过期链接或填错名字不能毁掉它。
          guard invite.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
          _ = try DeviceClient.makePairRequest(invitation: invite, deviceName: name,
                                               publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, timestamp: clock())
        }
        try clear()
      } else {
        guard pending.device_name == name, pending.expires_at == invite.expiresAt else {
          throw Failure.preparationExists
        }
        if let raw = try keys.read(account) {
          let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
          guard PendingPair.hash(mac.publicKey.rawRepresentation) == pending.device_pk_sha256 else {
            throw Failure.invalidReceipt
          }
          return (mac, try pending.request)
        }
        // The journal is written before the key. No request can have been sent without it.
        try clear()
      }
    }
    guard invite.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
    guard try keys.read(account) == nil else { throw Failure.preparationExists }
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try DeviceClient.makePairRequest(invitation: invite, deviceName: name, publicKey: mac.publicKey,
                                                   timestamp: clock())
    if !replacement { try createDirectory(identity.dir, directory: directory) }
    let pending = PendingPair(hub_id: identity.hub_id, hub_pk: identity.hub_pk, code_sha256: codeHash, device_name: name,
                              device_pk_sha256: PendingPair.hash(mac.publicKey.rawRepresentation),
                              expires_at: invite.expiresAt, nonce: sealed.nonce, envelope: sealed.wireData)
    try BindingFile.write(JSONEncoder().encode(pending), named: file, in: directory)
    try saveSecret(mac.rawRepresentation, account: account)
    return (mac, sealed)
  }

  private func createDirectory(_ name: String, directory: URL) throws {
    let created = try BindingFile.withDirectory(dataDirectory, missing: false) { fd in
      if mkdirat(fd, name, 0o700) == 0 { return true }
      guard errno == EEXIST else { throw LocalDeviceLink.Failure.fileIO }
      return try BindingFile.withDirectory(directory, missing: false) { _ in
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw Failure.preparationExists }
        return true
      }
    }
    guard created else { throw LocalDeviceLink.Failure.fileIO }
  }

  private func loadOrCreateAgent(hubID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    let account = RemoteDeviceLink.Keys.account(.agent, hubID: hubID)
    if let raw = try keys.read(account) { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try saveSecret(key.rawRepresentation, account: account)
    return key
  }

  private nonisolated func saveSecret(_ data: Data, account: String) throws {
    let existing: Data?
    do { existing = try keys.read(account) }
    catch RemoteDeviceLink.Keys.Failure.malformed { existing = nil }
    if existing != data {
      // Keychain's create operation is add-only. Replace a rotated token before storing it.
      try keys.remove(account)
      try keys.create(account, data)
    }
    guard try keys.read(account) == data else { throw LocalDeviceLink.Failure.keyUnavailable }
  }

  private func removeFiles(_ identity: HubBinding.Remote, directory: URL) throws {
    // Keep the link until all key removals succeed so a retry still knows the relay account.
    if let link = try? RemoteDeviceLink.read(from: dataDirectory, identity: identity) {
      try keys.remove(RemoteDeviceLink.Relay.account(deviceID: link.device_id))
    }
    try keys.remove(RemoteDeviceLink.Keys.account(.agent, hubID: identity.hub_id))
    try keys.remove(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id))
    do { try FileManager.default.removeItem(at: directory) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
  }

  private static func removeRegistration(_ client: DeviceClient, deviceID: String) async -> Bool {
    await Task.detached {
      do {
        _ = try await client.send(op: "devices.remove", body: ["id": .string(deviceID)], timeout: 5)
        return true
      } catch DeviceClientError.deviceRemoved { return true }
      catch { return false }
    }.value
  }
}

extension RemotePairing {
  public struct PreparedRePairing: Codable, Equatable, Sendable {
    public let previous: HubBinding
    public let binding: HubBinding
    public let collectorLink: RemoteDeviceLink
    public let agentLink: RemoteDeviceLink.AgentLink?
    public let agentDeviceID: String
    public let relay: RemoteDeviceLink.Relay?
    fileprivate let expiresAt: Date
  }

  public typealias PublishRePairing = @Sendable (
    HubBinding.Route, HubBinding.Route, @escaping @Sendable () throws -> Void
  ) async throws -> Void
  public typealias FinishRePairing = @Sendable (PreparedRePairing) async throws -> Void

  public enum RePairingState: Equatable, Sendable {
    case idle, preparing, awaitingConfirmation(expiresAt: Date), recovery(canCancel: Bool), remoteCleanupRequired
  }

  private struct ReplacementRegistration: Codable {
    let link: RemoteDeviceLink
    let relay: RemoteDeviceLink.Relay?
  }

  private static let cleanupRequired = "repair-cleanup-required"
  private static let replacementRegistration = "pending-repair-registration.json"
  static let rePairTransaction = "repair-transaction.json"
  private static let rePairRequest = "pending-repair-request.json"
  private static let rePairReady = "pending-repair-credentials.json"
  private static let collectorFile = LocalDeviceLink.File.collector.rawValue
  private static let agentFile = LocalDeviceLink.File.agent.rawValue

  private struct RePairTransaction: Codable, Sendable {
    let prepared: PreparedRePairing
    let oldFiles: [String: Data]
    let oldDeviceID: String?
    let oldKeys: [String]
    let unknownOutcomes: Int
    let unreadableMailboxJournal: Bool
    let oldMailboxAccounts: [String]
  }

  public func prepareRePairing(invitation text: String, deviceName: String, lastSuccessfulAddress: URL? = nil,
                               manualAddress: URL? = nil,
                               onMailboxDelivered: MailboxDelivered? = nil) async throws -> PreparedRePairing {
    let invitation = try DevicePairingInvitation.parse(text, now: clock())
    guard invitation.role == "admin" else { throw Failure.adminInvitationRequired }
    guard invitation.expiresAt.timeIntervalSince(clock()) <= 300 else { throw Failure.adminInvitationRequired }
    if let manualAddress, RemoteDeviceLink.origin(manualAddress.absoluteString) == nil {
      throw DeviceClientError.invalidRequest("中枢直连地址无效")
    }
    guard !running else { throw Failure.preparationExists }
    running = true
    defer {
      running = false
      Task { try? await cleanupExpiredPreparations() }
    }

    let previous = try HubBinding.read(from: dataDirectory)
    guard previous.target == .remote, previous.phase == .committed, let identity = previous.remote else {
      throw Failure.notFrozen
    }
    guard identity.hub_id == invitation.hubID, identity.hub_pk == invitation.hubPublicKeyBase64URL else {
      throw Failure.differentHub
    }
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    guard try readRePairTransaction(in: directory) == nil else { throw Failure.recoveryRequired }
    try requireFrozen(previous, in: directory)

    return try await prepareReplacement(invitation, deviceName: deviceName, identity: identity, previous: previous,
      directory: directory, lastSuccessfulAddress: lastSuccessfulAddress, manualAddress: manualAddress,
      onMailboxDelivered: onMailboxDelivered)
  }

  private func prepareReplacement(_ invitation: DevicePairingInvitation, deviceName: String, identity: HubBinding.Remote,
                                  previous: HubBinding, directory: URL, lastSuccessfulAddress: URL?, manualAddress: URL?,
                                  onMailboxDelivered: MailboxDelivered?) async throws -> PreparedRePairing {
    guard invitation.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
    guard invitation.expiresAt.timeIntervalSince(clock()) <= 300 else { throw Failure.adminInvitationRequired }
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = try BindingFile.read(Self.rePairRequest, in: directory) {
      let pending = try JSONDecoder().decode(PendingPair.self, from: data)
      if pending.expires_at <= clock() || pending.code_sha256 != PendingPair.hash(Data(invitation.code.utf8)) {
        try await abandonRePairing(identity, directory: directory)
      }
    }
    let (mac, sealed) = try pendingRequest(invitation, name: name, identity: identity, directory: directory, replacement: true)
    let oldLink = try? RemoteDeviceLink.read(from: dataDirectory, identity: identity)
    let (client, paired, origin) = try await connect(invitation, sealed: sealed, key: mac,
      lastSuccessfulAddress: lastSuccessfulAddress ?? oldLink?.addresses.first, manualAddress: manualAddress,
      onMailboxDelivered: onMailboxDelivered)
    guard paired.hubID == identity.hub_id, paired.deviceID.hasPrefix("mac-"), paired.deviceID != oldLink?.device_id,
          DeviceProtocol.isValidDeviceID(paired.deviceID) else { throw Failure.invalidReceipt }
    guard paired.role == "admin" else { throw Failure.adminInvitationRequired }
    let link = try Self.link(identity, paired, origin, invitation: invitation)
    let relay = paired.relay.map(RemoteDeviceLink.Relay.init)
    if let config = paired.relay {
      try saveSecret(Data(config.token.utf8), account: RemoteDeviceLink.Relay.account(deviceID: paired.deviceID))
    }
    try BindingFile.write(JSONEncoder().encode(ReplacementRegistration(link: link, relay: relay)),
      named: Self.replacementRegistration, in: directory)
    let agentAccount = replacementAccount(.agent, identity)
    let agent: Curve25519.KeyAgreement.PrivateKey
    if let raw = try keys.read(agentAccount) {
      agent = try .init(rawRepresentation: raw)
    } else {
      agent = .init()
      try saveSecret(agent.rawRepresentation, account: agentAccount)
    }
    let (agentID, agentLink) = try await enroll(agent, client: client, identity: identity, origin: origin)
    try Task.checkCancellation()
    guard previous.generation < 9_007_199_254_740_990 else { throw HubBinding.Failure.invalidBinding }
    let result = PreparedRePairing(previous: previous,
      binding: .init(generation: previous.generation + 1, target: .remote, phase: .committed, remote: identity, updatedAt: clock()),
      collectorLink: link, agentLink: agentLink,
      agentDeviceID: agentID, relay: relay, expiresAt: invitation.expiresAt)
    try BindingFile.write(JSONEncoder().encode(result), named: Self.rePairReady, in: directory)
    try? BindingFile.remove(Self.cleanupRequired, in: directory)
    return result
  }

  public nonisolated func rePairingState() throws -> RePairingState {
    let binding = try HubBinding.read(from: dataDirectory)
    guard binding.phase == .committed, let identity = binding.remote else { return .idle }
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    if let transaction = try readRePairTransaction(in: directory) {
      return .recovery(canCancel: binding == transaction.prepared.previous)
    }
    if let ready = try readRePairPreparation(in: directory), ready.previous == binding, ready.expiresAt > clock() {
      return .awaitingConfirmation(expiresAt: ready.expiresAt)
    }
    if try BindingFile.read(Self.rePairRequest, in: directory) != nil { return .preparing }
    if try BindingFile.read(Self.cleanupRequired, in: directory) != nil { return .remoteCleanupRequired }
    return .idle
  }

  public nonisolated func remotesRequiringRePairingCleanup() throws -> [String] {
    try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("remote-") && (try? BindingFile.read(Self.cleanupRequired, in: $0)) != nil }
      .map { String($0.lastPathComponent.dropFirst("remote-".count)) }.sorted()
  }

  public func dismissRePairingCleanup() throws {
    for hubID in try remotesRequiringRePairingCleanup() {
      let directory = dataDirectory.appendingPathComponent("remote-" + hubID)
      try BindingFile.remove(Self.cleanupRequired, in: directory)
    }
  }

  public func cancelRePairing() async throws {
    guard !running else { throw Failure.preparationExists }
    running = true
    defer { running = false }
    let binding = try HubBinding.read(from: dataDirectory)
    guard let identity = binding.remote else { throw HubBinding.Failure.changed }
    let directory = dataDirectory.appendingPathComponent(identity.dir)
    if let transaction = try readRePairTransaction(in: directory) {
      guard binding == transaction.prepared.previous else { throw Failure.recoveryRequired }
      try restoreRePairing(transaction, identity: identity, directory: directory)
    }
    try await abandonRePairing(identity, directory: directory)
  }

  private struct RegistrationRemoval {
    let directory: URL
    let marker: Data
    let link: RemoteDeviceLink?
    let key: InMemoryDeviceKeyStore?
    let transports: [any DeviceTransport]
  }

  private func abandonRePairing(_ identity: HubBinding.Remote, directory: URL) async throws {
    if let removal = try detachRePairing(identity, directory: directory) {
      try await removeDetachedRegistration(removal)
    }
  }

  private func detachRePairing(_ identity: HubBinding.Remote, directory: URL) throws -> RegistrationRemoval? {
    let registration: ReplacementRegistration?
    if let data = try BindingFile.read(Self.replacementRegistration, in: directory) {
      registration = try JSONDecoder().decode(ReplacementRegistration.self, from: data)
    } else {
      registration = try readRePairPreparation(in: directory).map {
        ReplacementRegistration(link: $0.collectorLink, relay: $0.relay)
      }
    }
    var transports: [any DeviceTransport] = []
    var key: InMemoryDeviceKeyStore?
    if let registration, let raw = try keys.read(replacementAccount(.mac, identity)) {
      key = try InMemoryDeviceKeyStore(rawRepresentation: raw)
      transports = registration.link.addresses.compactMap { try? endpoint($0).transport }
      if let relay = registration.relay,
         let config = try? relay.config(deviceID: registration.link.device_id, keys: keys) {
        transports.append(mailboxTransport(config))
      }
    }
    let mayHavePaired = try registration != nil || BindingFile.read(Self.rePairRequest, in: directory) != nil
    // 先清理本地待提交状态，联网撤销时不会误删后来开始的新配对。
    let marker = Data(UUID().uuidString.utf8)
    if mayHavePaired { try BindingFile.write(marker, named: Self.cleanupRequired, in: directory) }
    try clearRePairPreparation(identity, directory: directory)
    guard mayHavePaired else { return nil }
    return RegistrationRemoval(directory: directory, marker: marker, link: registration?.link, key: key, transports: transports)
  }

  private func removeDetachedRegistration(_ removal: RegistrationRemoval) async throws {
    if let link = removal.link, let key = removal.key {
      for transport in removal.transports {
        let client = try DeviceClient(hubPublicKeyBase64URL: link.hub_pk, deviceID: link.device_id,
                                      keyStore: key, transport: transport)
        if await Self.removeRegistration(client, deviceID: link.device_id) {
          if try BindingFile.read(Self.cleanupRequired, in: removal.directory) == removal.marker {
            try BindingFile.remove(Self.cleanupRequired, in: removal.directory)
          }
          return
        }
      }
    }
    throw Failure.remoteCleanupRequired
  }

  /// A completed preparation survives an app restart while its invitation is valid.
  public func preparedRePairing() throws -> PreparedRePairing? {
    let current = try HubBinding.read(from: dataDirectory)
    guard current.phase == .committed, let identity = current.remote else { return nil }
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    guard try readRePairTransaction(in: directory) == nil,
          let prepared = try readRePairPreparation(in: directory),
          prepared.previous == current, prepared.expiresAt > clock() else { return nil }
    if let relay = prepared.relay {
      _ = try relay.config(deviceID: prepared.collectorLink.device_id, keys: keys)
    }
    return prepared
  }

  /// The writer must quiesce consumers, serialize with capture enqueue, and invoke commit
  /// exactly once after copying the old generation's entire queue.
  public func commitRePairing(_ prepared: PreparedRePairing, publish: PublishRePairing,
                              finish: FinishRePairing) async throws {
    guard !running else { throw Failure.preparationExists }
    running = true
    defer { running = false }
    guard try preparedRePairing() == prepared, let identity = prepared.binding.remote else {
      throw HubBinding.Failure.changed
    }
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    try requireFrozen(prepared.previous, in: directory)
    let transaction = try makeRePairTransaction(prepared, directory: directory, identity: identity)
    try BindingFile.write(JSONEncoder().encode(transaction), named: Self.rePairTransaction, in: directory, limit: 64 * 1024)
    do {
      try await publish(prepared.previous.route, prepared.binding.route) {
        try self.installReplacement(transaction, identity: identity, directory: directory)
      }
    } catch {
      let current = try HubBinding.read(from: dataDirectory)
      if current == prepared.previous {
        do { try restoreRePairing(transaction, identity: identity, directory: directory) }
        catch { throw Failure.recoveryRequired }
        throw error
      }
      guard current == prepared.binding else { throw Failure.recoveryRequired }
    }
    guard try HubBinding.read(from: dataDirectory) == prepared.binding else { throw Failure.recoveryRequired }
    do { try await finishRePairing(transaction, identity: identity, directory: directory, finish: finish) }
    catch { throw Failure.recoveryRequired }
  }

  /// Run before starting consumers or evaluating the switch checkpoint on launch.
  public func recoverRePairing(finish: FinishRePairing) async throws {
    guard !running else { throw Failure.preparationExists }
    let current = try HubBinding.read(from: dataDirectory)
    guard current.phase == .committed, let identity = current.remote else { return }
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    guard let transaction = try readRePairTransaction(in: directory) else { return }
    running = true
    defer { running = false }
    if current == transaction.prepared.previous {
      try restoreRePairing(transaction, identity: identity, directory: directory)
    } else if current == transaction.prepared.binding {
      try await finishRePairing(transaction, identity: identity, directory: directory, finish: finish)
    } else {
      throw Failure.recoveryRequired
    }
  }

  private static let replacementFiles = [collectorFile, agentFile, RemoteDeviceLink.Relay.fileName]
  private static let replacementKeys: [LocalDeviceLink.Account] = [.mac, .agent]

  private nonisolated func requireFrozen(_ binding: HubBinding, in directory: URL) throws {
    guard try HubBinding.read(from: dataDirectory) == binding else { throw HubBinding.Failure.changed }
    guard try BindingFile.read(RemoteDeviceAccess.rejectionMarker, in: directory)
      == RemoteDeviceAccess.rejectionData(binding.route) else { throw Failure.notFrozen }
  }

  private nonisolated func replacementAccount(_ account: LocalDeviceLink.Account, _ identity: HubBinding.Remote) -> String {
    RemoteDeviceLink.Keys.account(account, hubID: identity.hub_id) + ".replacement"
  }

  private nonisolated func backupAccount(_ account: LocalDeviceLink.Account, _ identity: HubBinding.Remote) -> String {
    RemoteDeviceLink.Keys.account(account, hubID: identity.hub_id) + ".previous"
  }

  private nonisolated func readRePairPreparation(in directory: URL) throws -> PreparedRePairing? {
    try BindingFile.read(Self.rePairReady, in: directory).map { try JSONDecoder().decode(PreparedRePairing.self, from: $0) }
  }

  private nonisolated func readRePairTransaction(in directory: URL) throws -> RePairTransaction? {
    try BindingFile.read(Self.rePairTransaction, in: directory, limit: 64 * 1024).map {
      try JSONDecoder().decode(RePairTransaction.self, from: $0)
    }
  }

  private func makeRePairTransaction(_ prepared: PreparedRePairing, directory: URL,
                                     identity: HubBinding.Remote) throws -> RePairTransaction {
    var files: [String: Data] = [:]
    for name in Self.replacementFiles { files[name] = try BindingFile.read(name, in: directory) }
    var oldKeys: [String] = []
    var oldMac: Data?
    for account in Self.replacementKeys {
      let old: Data?
      do { old = try keys.read(RemoteDeviceLink.Keys.account(account, hubID: identity.hub_id)) }
      catch RemoteDeviceLink.Keys.Failure.malformed { old = nil }
      if let old, old.count == 32 {
        try saveSecret(old, account: backupAccount(account, identity))
        oldKeys.append(account.rawValue)
        if account == .mac { oldMac = old }
      }
    }
    let oldID = (try? RemoteDeviceLink.read(from: dataDirectory, identity: identity))?.device_id
    let route = prepared.previous.route
    let journalName = RemoteRelayJournal.name(for: route)
    let exists = try BindingFile.read(journalName, in: directory, limit: RemoteRelayJournal.snapshotLimit) != nil
    let journal: RemoteRelayJournal?
    if exists, let oldID, let oldMac {
      journal = try? RemoteRelayJournal.load(key: RemoteRelayJournal.key(for: oldMac, route: route, deviceID: oldID),
        in: directory, name: journalName, route: route, deviceID: oldID)
    } else { journal = nil }
    return RePairTransaction(prepared: prepared, oldFiles: files, oldDeviceID: oldID, oldKeys: oldKeys,
      unknownOutcomes: journal?.outcomesOnRetirement ?? 0, unreadableMailboxJournal: exists && journal == nil,
      oldMailboxAccounts: journal?.mailboxAccounts ?? [])
  }

  private nonisolated func installReplacement(_ transaction: RePairTransaction, identity: HubBinding.Remote,
                                               directory: URL) throws {
    let prepared = transaction.prepared
    try requireFrozen(prepared.previous, in: directory)
    try installReplacementCredentials(transaction, identity: identity, directory: directory)
    try prepared.binding.write(to: dataDirectory, replacing: prepared.previous)
  }

  private nonisolated func installReplacementCredentials(_ transaction: RePairTransaction, identity: HubBinding.Remote,
                                                          directory: URL) throws {
    let prepared = transaction.prepared
    let encoder = JSONEncoder()
    for account in Self.replacementKeys {
      guard let value = try keys.read(replacementAccount(account, identity)) else { throw LocalDeviceLink.Failure.keyUnavailable }
      try saveSecret(value, account: RemoteDeviceLink.Keys.account(account, hubID: identity.hub_id))
    }
    try BindingFile.write(encoder.encode(prepared.collectorLink), named: Self.collectorFile, in: directory)
    try replaceFile(RemoteDeviceLink.Relay.fileName, with: prepared.relay.map(encoder.encode), in: directory)
    if transaction.unknownOutcomes > 0 {
      let route = prepared.binding.route, deviceID = prepared.collectorLink.device_id
      guard let raw = try keys.read(replacementAccount(.mac, identity)) else { throw LocalDeviceLink.Failure.keyUnavailable }
      var journal = RemoteRelayJournal(route: route, deviceID: deviceID)
      journal.unknownOutcomes = transaction.unknownOutcomes
      try journal.save(key: RemoteRelayJournal.key(for: raw, route: route, deviceID: deviceID), in: directory,
                       name: RemoteRelayJournal.name(for: route))
    }
    try replaceFile(Self.agentFile, with: prepared.agentLink.map(encoder.encode), in: directory)
  }

  private func restoreRePairing(_ transaction: RePairTransaction, identity: HubBinding.Remote, directory: URL,
                                transactionFile: String = RemotePairing.rePairTransaction) throws {
    for account in Self.replacementKeys {
      let target = RemoteDeviceLink.Keys.account(account, hubID: identity.hub_id)
      if transaction.oldKeys.contains(account.rawValue) {
        guard let old = try keys.read(backupAccount(account, identity)) else { throw Failure.recoveryRequired }
        try saveSecret(old, account: target)
      } else {
        try keys.remove(target)
      }
    }
    for file in Self.replacementFiles { try replaceFile(file, with: transaction.oldFiles[file], in: directory) }
    try BindingFile.remove(RemoteRelayJournal.name(for: transaction.prepared.binding.route), in: directory)
    try BindingFile.remove(transactionFile, in: directory)
    for account in Self.replacementKeys { try keys.remove(backupAccount(account, identity)) }
  }

  private func finishRePairing(_ transaction: RePairTransaction, identity: HubBinding.Remote, directory: URL,
                               finish: FinishRePairing) async throws {
    try await finish(transaction.prepared)
    for account in transaction.oldMailboxAccounts { try keys.remove(account) }
    if let old = transaction.oldDeviceID { try keys.remove(RemoteDeviceLink.Relay.account(deviceID: old)) }
    try BindingFile.remove(RemoteRelayJournal.name(for: transaction.prepared.previous.route), in: directory)
    if transaction.unreadableMailboxJournal {
      NSLog("record-anything: 旧身份的信箱日志无法解密，投递结局未知。")
    }
    try BindingFile.remove(RemoteDeviceAccess.rejectionMarker, in: directory)
    try BindingFile.remove(Self.cleanupRequired, in: directory)
    try clearRePairPreparation(identity, directory: directory, keepRelay: true)
    try BindingFile.remove(Self.rePairTransaction, in: directory)
  }

  private nonisolated func replaceFile(_ name: String, with data: Data?, in directory: URL) throws {
    if let data { try BindingFile.write(data, named: name, in: directory) }
    else { try BindingFile.remove(name, in: directory) }
  }

  private func clearRePairPreparation(_ identity: HubBinding.Remote, directory: URL, keepRelay: Bool = false) throws {
    if !keepRelay {
      let data = try BindingFile.read(Self.replacementRegistration, in: directory)
      let registration = try data.map { try JSONDecoder().decode(ReplacementRegistration.self, from: $0) }
      if let id = try registration?.link.device_id ?? readRePairPreparation(in: directory)?.collectorLink.device_id {
        try keys.remove(RemoteDeviceLink.Relay.account(deviceID: id))
      }
    }
    try BindingFile.remove(Self.replacementRegistration, in: directory)
    for account in Self.replacementKeys {
      try keys.remove(replacementAccount(account, identity))
      try keys.remove(backupAccount(account, identity))
    }
    try BindingFile.remove(Self.rePairReady, in: directory)
    try BindingFile.remove(Self.rePairRequest, in: directory)
  }

  private func expireRePairing() async throws {
    var nextExpiry: Date?
    var removals: [RegistrationRemoval] = []
    let binding = try HubBinding.read(from: dataDirectory)
    for directory in try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
      where directory.lastPathComponent.hasPrefix("remote-") {
      guard try readRePairTransaction(in: directory) == nil,
            let data = try BindingFile.read(Self.rePairRequest, in: directory) else { continue }
      let pending = try JSONDecoder().decode(PendingPair.self, from: data)
      let identity = try HubBinding.Remote(hubID: pending.hub_id, hubPublicKey: pending.hub_pk)
      guard identity.dir == directory.lastPathComponent else { throw Failure.invalidReceipt }
      if binding.remote == identity && binding.phase == .preparing { continue }
      if try BindingFile.read(Self.retainedTransaction, in: directory) != nil { continue }
      if pending.expires_at <= clock() {
        if let removal = try detachRePairing(identity, directory: directory) { removals.append(removal) }
      } else {
        nextExpiry = min(nextExpiry ?? pending.expires_at, pending.expires_at)
      }
    }
    rePairExpiration?.cancel()
    rePairExpiration = nextExpiry.map { date in
      Task {
        do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSince(clock())))) }
        catch { return }
        Task { try? await cleanupExpiredPreparations() }
      }
    }
    // 每个目录的本地状态和下一次到期已确定，联网撤销可以让前台继续。
    for removal in removals {
      do { try await removeDetachedRegistration(removal) }
      catch Failure.remoteCleanupRequired { /* 设置页会提示远端登记可能尚未撤销。 */ }
    }
  }
}
