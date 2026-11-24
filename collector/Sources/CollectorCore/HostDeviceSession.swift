import Foundation

/// Shared device session for the Mac host. Only the local route supports the legacy HTTP interface.
public actor HostDeviceSession {
  public struct Connection: Sendable {
    public let route: HubBinding.Route
    public let deviceID: String
    public let client: DeviceClient
    public let remoteSession: RemoteDeviceSession?
  }

  private struct Active {
    let connection: Connection
    let localLink: LocalDeviceLink?
    let remoteLink: RemoteDeviceLink?
    let origin: URL
    let credentialRevision: UUID?
  }

  private let origin: @Sendable () -> URL
  private let files: LocalDeviceLink.Files
  private let keys: LocalDeviceLink.Keys
  private let remoteAccess: RemoteDeviceAccess?
  private let transport: RemoteDeviceAccess.TransportFactory
  private let log: @Sendable (String) -> Void
  private var useLegacy = false
  private var active: Active?

  public init(
    origin: @escaping @Sendable () -> URL,
    files: LocalDeviceLink.Files,
    keys: LocalDeviceLink.Keys = .keychain,
    session: URLSession? = nil,
    requestTimeout: TimeInterval = 30,
    log: @escaping @Sendable (String) -> Void = { NSLog("record-anything: %@", $0) },
    remoteAccess: RemoteDeviceAccess? = nil,
    transport: RemoteDeviceAccess.TransportFactory? = nil
  ) {
    self.origin = origin
    self.files = files
    self.keys = keys
    self.remoteAccess = remoteAccess
    self.transport = transport ?? { try DirectDeviceTransport(origin: $0, session: session, requestTimeout: requestTimeout) }
    self.log = log
  }

  public func route() throws -> HubBinding.Route { try remoteAccess?.route() ?? .local }

  /// The legacy audio coordinator only understands local material and retention commands.
  public func currentLink() -> LocalDeviceLink? {
    guard !useLegacy, let route = try? route(), route.remote == nil else { return nil }
    return try? files.collector()
  }

  public func disableForSession() {
    useLegacy = true
    if active?.connection.route.remote == nil { active = nil }
  }

  /// An old request must not remove the current route's credentials.
  public func handleDeviceRemoved(on route: HubBinding.Route) {
    guard (try? self.route()) == route else { return }
    if route.remote != nil {
      if active?.connection.route == route { active = nil }
      return
    }
    disableForSession()
    do { try files.removeCollector() }
    catch { log("device-session: link_removal_failed") }
  }

  public func connection(for expected: HubBinding.Route? = nil) async throws -> Connection? {
    let route = try route()
    if let expected, expected != route { throw HubBinding.Failure.changed }
    if active?.connection.route != route { active = nil }
    if let identity = route.remote, let remoteAccess {
      let stamp: UUID
      do { stamp = try remoteAccess.credentialRevision(for: route) }
      catch { active = nil; throw error }
      let link = try RemoteDeviceLink.read(from: remoteAccess.dataDirectory, identity: identity)
      if let active, active.credentialRevision == stamp, active.remoteLink == link { return active.connection }
      let remote = try remoteAccess.session(for: route, link: link, transport: transport)
      active = nil
      let client = try await remote.clientInBackground()
      guard try remoteAccess.credentialRevision(for: route) == stamp else { throw HubBinding.Failure.changed }
      let connection = Connection(route: route, deviceID: link.device_id, client: client, remoteSession: remote)
      active = Active(connection: connection, localLink: nil, remoteLink: link,
                      origin: link.addresses.first ?? origin(), credentialRevision: stamp)
      return connection
    }

    guard !useLegacy, let link = try? files.collector() else {
      active = nil
      return nil
    }
    let currentOrigin = origin()
    if let active, active.connection.route == route, active.localLink == link, active.origin == currentOrigin {
      return active.connection
    }
    guard let raw = try keys.read(.mac) else { throw LocalDeviceLink.Failure.keyUnavailable }
    let client = try DeviceClient(
      hubPublicKeyBase64URL: link.hub_pk,
      deviceID: link.device_id,
      keyStore: InMemoryDeviceKeyStore(rawRepresentation: raw),
      transport: transport(currentOrigin),
      validateRequest: { [remoteAccess] in
        guard try remoteAccess?.route() ?? .local == route else { throw HubBinding.Failure.changed }
      }
    )
    let connection = Connection(route: route, deviceID: link.device_id, client: client, remoteSession: nil)
    active = Active(connection: connection, localLink: link, remoteLink: nil, origin: currentOrigin, credentialRevision: nil)
    return connection
  }

  public func send(op: String, body: [String: DeviceJSON] = [:], on route: HubBinding.Route? = nil) async throws -> DeviceResponsePayload? {
    try await perform(on: route) { connection in
      if op == "ingest", let remote = connection.remoteSession { return try await remote.sendIngest(body) }
      return try await connection.client.send(op: op, body: body)
    }
  }

  public func send<Body: Encodable & Sendable>(op: String, body: Body, on route: HubBinding.Route? = nil) async throws -> DeviceResponsePayload? {
    try await perform(on: route) { try await $0.client.send(op: op, body: body) }
  }

  private func perform(
    on expected: HubBinding.Route?, _ request: (Connection) async throws -> DeviceResponsePayload
  ) async throws -> DeviceResponsePayload? {
    guard let conn = try await connection(for: expected) else { return nil }
    do {
      let reply = try await request(conn)
      guard try route() == conn.route else { throw HubBinding.Failure.changed }
      return reply
    } catch let error as DeviceClientError {
      guard try route() == conn.route else { throw HubBinding.Failure.changed }
      if case .deviceRemoved = error {
        handleDeviceRemoved(on: conn.route)
        // Legacy audio callers interpret deviceRemoved as permission to retry through local HTTP.
        if conn.route.remote != nil { throw RemoteDeviceAccess.Failure.frozen }
      }
      throw error
    }
  }
}
