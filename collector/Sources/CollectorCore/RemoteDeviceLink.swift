import CryptoKit
import Foundation

public struct RemoteDeviceLink: Codable, Equatable, Sendable {
  public let hub_id: String
  public let hub_pk: String
  public let device_id: String
  public let hubName: String?
  public let mode: String
  public let addrs: [String]

  private enum CodingKeys: String, CodingKey { case hub_id, hub_pk, device_id, mode, addrs; case hubName = "hub_name" }

  public init(identity: HubBinding.Remote, deviceID: String, addresses: [URL], hubName: String? = nil) throws {
    guard deviceID.hasPrefix("mac-"), DeviceProtocol.isValidDeviceID(deviceID),
          addresses.allSatisfy({ Self.origin($0.absoluteString) != nil }) else {
      throw LocalDeviceLink.Failure.invalidLink
    }
    hub_id = identity.hub_id
    hub_pk = identity.hub_pk
    device_id = deviceID
    self.hubName = hubName
    mode = "remote"
    addrs = addresses.map(\.absoluteString)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let identity = try HubBinding.Remote(hubID: values.decode(String.self, forKey: .hub_id),
                                         hubPublicKey: values.decode(String.self, forKey: .hub_pk))
    let addresses = try values.decode([String].self, forKey: .addrs)
    let parsed = addresses.compactMap(Self.origin)
    guard try values.decode(String.self, forKey: .mode) == "remote", addresses.count == parsed.count else {
      throw LocalDeviceLink.Failure.invalidLink
    }
    try self.init(identity: identity, deviceID: values.decode(String.self, forKey: .device_id), addresses: parsed,
                  hubName: values.decodeIfPresent(String.self, forKey: .hubName))
  }

  public var addresses: [URL] { addrs.compactMap(Self.origin) }

  static func origin(_ address: String) -> URL? {
    guard let scheme = URLComponents(string: address)?.scheme?.lowercased(),
          scheme == "https" || scheme == "http" else { return nil }
    return DevicePairingInvitation.normalizeOrigin(address)
  }

  public static func read(from dataDirectory: URL, identity: HubBinding.Remote) throws -> Self {
    let directory = dataDirectory.appendingPathComponent(identity.dir, isDirectory: true)
    guard let data = try BindingFile.read(LocalDeviceLink.File.collector.rawValue, in: directory),
          let link = try? JSONDecoder().decode(Self.self, from: data),
          link.hub_id == identity.hub_id, link.hub_pk == identity.hub_pk else {
      throw LocalDeviceLink.Failure.invalidLink
    }
    return link
  }

  public struct AgentLink: Codable, Equatable, Sendable {
    public let hub_id: String
    public let hub_pk: String
    public let device_id: String
    public let address: String
  }

  /// The relay token lives in the Keychain account for the registered Mac.
  public struct Relay: Codable, Equatable, Sendable {
    public static let fileName = "relay.json"
    public let url: String
    public let space: String
    public let up: String
    public let down: String

    init(_ config: DeviceRelayConfig) {
      (url, space, up, down) = (config.url, config.space, config.up, config.down)
    }

    public static func account(deviceID: String) -> String { "relay-device-\(deviceID)" }

    public func config(deviceID: String, keys: Keys) throws -> DeviceRelayConfig {
      guard let data = try keys.read(Self.account(deviceID: deviceID)),
            let token = String(data: data, encoding: .utf8) else { throw LocalDeviceLink.Failure.keyUnavailable }
      return try DeviceRelayConfig(url: url, space: space, up: up, down: down, token: token)
    }
  }

  public func relay(in dataDirectory: URL) throws -> Relay? {
    let directory = dataDirectory.appendingPathComponent("remote-\(hub_id)", isDirectory: true)
    return try BindingFile.read(Relay.fileName, in: directory).map { try JSONDecoder().decode(Relay.self, from: $0) }
  }

  public struct Keys: Sendable {
    public enum Failure: Error { case malformed }
    public let read: @Sendable (String) throws -> Data?
    public let create: @Sendable (String, Data) throws -> Void
    public let remove: @Sendable (String) throws -> Void

    public init(read: @escaping @Sendable (String) throws -> Data?,
                create: @escaping @Sendable (String, Data) throws -> Void,
                remove: @escaping @Sendable (String) throws -> Void) {
      self.read = read
      self.create = create
      self.remove = remove
    }

    public static func account(_ key: LocalDeviceLink.Account, hubID: String) -> String {
      "\(key.rawValue).\(hubID)"
    }

    public static let keychain = Keys(read: { account in
      let result = try SecurityCLI.run(["find-generic-password", "-s", "record-anything", "-a", account, "-w"])
      if result.status == 44 { return nil }
      guard result.status == 0 else { throw LocalDeviceLink.Failure.keyUnavailable }
      guard let data = DeviceProtocol.hexDecode(result.text),
            account.hasPrefix("relay-device-") || data.count == 32 else { throw Failure.malformed }
      return data
    }, create: { account, value in
      let command = try SecurityCLI.addGenericPasswordCommand(service: "record-anything", account: account,
                                                               hexValue: DeviceProtocol.hexEncode(value),
                                                               replace: account.hasPrefix("relay-device-"))
      _ = try SecurityCLI.run(["-i"], stdin: command)
    }, remove: { account in
      let result = try SecurityCLI.run(["delete-generic-password", "-s", "record-anything", "-a", account])
      guard result.status == 0 || result.status == 44 else { throw LocalDeviceLink.Failure.keyUnavailable }
    })
  }
}

/// Shared by the Mac host's upload and viewer sessions. The rejection marker is scoped to one generation.
public final class RemoteDeviceAccess: @unchecked Sendable {
  public enum Failure: Error, Equatable { case frozen, unavailable }
  public typealias TransportFactory = @Sendable (URL) throws -> any DeviceTransport

  public let dataDirectory: URL
  let keys: RemoteDeviceLink.Keys
  let writeGate: RemoteSwitchWriteGate?
  private var sharedSession: RemoteDeviceSession?
  private let lock = NSLock()
  private let keyLoadLock = NSLock()
  private let keyQueue = DispatchQueue(label: "record-anything.remote-credentials", qos: .utility)
  private var observed: HubBinding.Route?
  private var revision = UUID()
  private var frozen = false
  private var privateKey: Data?
  static let rejectionMarker = ".authorization-frozen"

  public init(dataDirectory: URL, keys: RemoteDeviceLink.Keys = .keychain, writeGate: RemoteSwitchWriteGate? = nil) {
    self.dataDirectory = dataDirectory
    self.keys = keys
    self.writeGate = writeGate
  }

  /// All in-process Mac clients of the active generation share one selector and mailbox consumer.
  public func session(for route: HubBinding.Route, link: RemoteDeviceLink,
                      transport: @escaping TransportFactory) throws -> RemoteDeviceSession {
    try lock.withLock {
      try validateLocked(route)
      let stamp = revision
      if let sharedSession, sharedSession.route == route, sharedSession.revision == stamp,
         sharedSession.link == link { return sharedSession }
      let result = RemoteDeviceSession(access: self, route: route, link: link, revision: stamp, transport: transport)
      releaseSessionLocked()
      sharedSession = result
      return result
    }
  }

  func relayJournalKey(for route: HubBinding.Route, link: RemoteDeviceLink, revision: UUID) throws -> SymmetricKey {
    // The registered device's key remains in the Keychain. Derive a separate
    // local encryption key and bind it to this device and generation.
    _ = try client(for: route, link: link, transport: RemoteDeviceSession.UnusedTransport(),
                   clock: { Date() }, stamp: revision, recovering: false)
    return try lock.withLock {
      try validateLocked(route, expectedRevision: revision)
      guard let privateKey else { throw LocalDeviceLink.Failure.keyUnavailable }
      return RemoteRelayJournal.key(for: privateKey, route: route, deviceID: link.device_id)
    }
  }

  public func isMailboxIdleForSwitch() async -> Bool {
    let session = lock.withLock { sharedSession }
    return await session?.isMailboxIdle ?? true
  }

  public func route() throws -> HubBinding.Route {
    try lock.withLock { try observeLocked() }
  }

  private func observeLocked() throws -> HubBinding.Route {
    let route = try? HubBinding.read(from: dataDirectory).route
    if observed != route {
      observed = route
      invalidateLocked()
      frozen = false
    }
    guard let route else { throw HubBinding.Failure.invalidBinding }
    return route
  }

  private func validateLocked(_ route: HubBinding.Route, expectedRevision: UUID? = nil,
                              allowFrozen: Bool = false) throws {
    guard try observeLocked() == route, expectedRevision == nil || revision == expectedRevision else {
      throw HubBinding.Failure.changed
    }
    guard let remote = route.remote else { return }
    if try BindingFile.read(RemotePairing.rePairTransaction, in: directory(remote), limit: 64 * 1024) != nil {
      throw Failure.frozen
    }
    // 先把磁盘上的冻结标记同步进内存（会换 revision），再决定放不放行；这样解冻途中并发的校验
    // 看到 frozen 已为 true，不会再换 revision 打断解冻。
    if try frozen || BindingFile.read(Self.rejectionMarker, in: directory(remote)) == Self.rejectionData(route) {
      if !frozen { invalidateLocked() }
      frozen = true
      if !allowFrozen { throw Failure.frozen }
    }
  }

  public func validate(_ expected: HubBinding.Route) throws {
    _ = try credentialRevision(for: expected)
  }

  public func credentialRevision(for route: HubBinding.Route) throws -> UUID {
    try lock.withLock {
      try validateLocked(route)
      return revision
    }
  }

  private func invalidateLocked() {
    revision = UUID()
    privateKey = nil
    releaseSessionLocked()
  }

  private func releaseSessionLocked() {
    guard let retired = sharedSession else { return }
    sharedSession = nil
    Task { await retired.stopMailbox() }
  }

  func withCredentials<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      keyQueue.async { continuation.resume(with: Result(catching: action)) }
    }
  }

  public func freeze(_ route: HubBinding.Route) { freeze(route, expectedRevision: nil) }

  private func freeze(_ route: HubBinding.Route, expectedRevision: UUID?) {
    guard let remote = route.remote else { return }
    lock.withLock {
      guard (try? observeLocked()) == route, expectedRevision == nil || revision == expectedRevision else { return }
      invalidateLocked()
      frozen = true
      try? BindingFile.write(Self.rejectionData(route), named: Self.rejectionMarker, in: directory(remote))
    }
  }

  /// Verify the currently bound identity with an authenticated RPC before clearing its rejection marker.
  public func reauthenticate(_ route: HubBinding.Route, transport: any DeviceTransport, authenticatedAddress: URL? = nil) async throws {
    try writeGate?.begin()
    defer { writeGate?.end() }
    let (link, client, stamp) = try await withCheckedThrowingContinuation { continuation in
      keyQueue.async {
        continuation.resume(with: Result {
          guard let identity = route.remote else { throw Failure.unavailable }
          let link = try RemoteDeviceLink.read(from: self.dataDirectory, identity: identity)
          let stamp = try self.lock.withLock {
            try self.validateLocked(route, allowFrozen: true)
            return self.revision
          }
          let client = try self.client(for: route, link: link, transport: transport, clock: { Date() },
                                       stamp: stamp, recovering: true)
          return (link, client, stamp)
        })
      }
    }
    _ = try await client.send(op: "status.get")
    try lock.withLock {
      try validateLocked(route, expectedRevision: stamp, allowFrozen: true)
      guard let identity = route.remote,
            try RemoteDeviceLink.read(from: dataDirectory, identity: identity) == link else {
        throw HubBinding.Failure.changed
      }
      if let authenticatedAddress {
        let updated = try RemoteDeviceLink(identity: identity, deviceID: link.device_id,
          addresses: [authenticatedAddress] + link.addresses.filter { $0 != authenticatedAddress }, hubName: link.hubName)
        let target = directory(identity)
        if let data = try BindingFile.read(LocalDeviceLink.File.agent.rawValue, in: target) {
          let agent = try JSONDecoder().decode(RemoteDeviceLink.AgentLink.self, from: data)
          guard agent.hub_id == identity.hub_id, agent.hub_pk == identity.hub_pk else { throw HubBinding.Failure.changed }
          let updatedAgent = RemoteDeviceLink.AgentLink(hub_id: agent.hub_id, hub_pk: agent.hub_pk,
            device_id: agent.device_id, address: authenticatedAddress.absoluteString)
          try BindingFile.write(JSONEncoder().encode(updatedAgent), named: LocalDeviceLink.File.agent.rawValue, in: target)
        }
        try BindingFile.write(JSONEncoder().encode(updated), named: LocalDeviceLink.File.collector.rawValue, in: target)
      }
      try BindingFile.remove(Self.rejectionMarker, in: directory(identity))
      invalidateLocked()
      frozen = false
    }
  }

  public func makeClient(for route: HubBinding.Route, link: RemoteDeviceLink, transport: any DeviceTransport,
                         clock: @escaping @Sendable () -> Date = { Date() }) throws -> DeviceClient {
    let stamp = try credentialRevision(for: route)
    return try client(for: route, link: link, transport: transport, clock: clock, stamp: stamp, recovering: false)
  }

  public func makeClientInBackground(for route: HubBinding.Route, link: RemoteDeviceLink,
                                     transport: any DeviceTransport) async throws -> DeviceClient {
    try await withCredentials { try self.makeClient(for: route, link: link, transport: transport) }
  }

  private func client(for route: HubBinding.Route, link: RemoteDeviceLink, transport: any DeviceTransport,
                      clock: @escaping @Sendable () -> Date, stamp: UUID, recovering: Bool) throws -> DeviceClient {
    guard let identity = route.remote, link.hub_id == identity.hub_id, link.hub_pk == identity.hub_pk else {
      throw LocalDeviceLink.Failure.invalidLink
    }
    // Read outside the routing lock, so a Keychain prompt does not block route validation.
    let raw = try keyLoadLock.withLock {
      let cached = try lock.withLock {
        try validateLocked(route, expectedRevision: stamp, allowFrozen: recovering)
        return recovering ? nil : privateKey
      }
      let raw: Data
      do {
        guard let key = try cached ?? keys.read(RemoteDeviceLink.Keys.account(.mac, hubID: identity.hub_id)) else {
          freeze(route, expectedRevision: stamp)
          throw LocalDeviceLink.Failure.keyUnavailable
        }
        guard key.count == 32 else { throw RemoteDeviceLink.Keys.Failure.malformed }
        raw = key
      } catch RemoteDeviceLink.Keys.Failure.malformed {
        freeze(route, expectedRevision: stamp)
        throw Failure.frozen
      } catch {
        throw DeviceClientError.keyStoreError(error.localizedDescription)
      }
      try lock.withLock {
        try validateLocked(route, expectedRevision: stamp, allowFrozen: recovering)
        if !recovering { privateKey = raw }
      }
      return raw
    }
    let store: any DeviceKeyStore
    if recovering {
      store = try InMemoryDeviceKeyStore(rawRepresentation: raw)
    } else {
      store = SharedKey(read: {
        try self.lock.withLock {
          try self.validateLocked(route, expectedRevision: stamp)
          return self.privateKey
        }
      })
    }
    return try DeviceClient(
      hubPublicKeyBase64URL: link.hub_pk, deviceID: link.device_id, keyStore: store, transport: transport, clock: clock,
      cachePrivateKey: false, validateRequest: {
        try self.lock.withLock { try self.validateLocked(route, expectedRevision: stamp, allowFrozen: recovering) }
      },
      onAuthorizationFailure: { self.freeze(route, expectedRevision: stamp) }
    )
  }

  private struct SharedKey: DeviceKeyStore {
    let read: @Sendable () throws -> Data?
    func readPrivateKey() throws -> Data? { try read() }
    func writePrivateKey(_ rawRepresentation: Data) throws { throw LocalDeviceLink.Failure.keyUnavailable }
    func deletePrivateKey() throws { throw LocalDeviceLink.Failure.keyUnavailable }
  }

  private func directory(_ remote: HubBinding.Remote) -> URL {
    dataDirectory.appendingPathComponent(remote.dir, isDirectory: true)
  }

  static func rejectionData(_ route: HubBinding.Route) -> Data { Data(String(route.generation).utf8) }
}
