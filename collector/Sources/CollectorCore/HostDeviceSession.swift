import Foundation

/// 宿主进程（Tacit.app）共享的本机设备会话：统一读取 `collector-link.json`、缓存按端口切换的 `DeviceClient`，
/// 并在 401 移除或 409 冲突时一致地切回旧接口。子进程不直接持有私钥。
public actor HostDeviceSession {
  public struct Connection: Sendable {
    public let link: LocalDeviceLink
    public let client: DeviceClient
  }

  private let origin: @Sendable () -> URL
  private let files: LocalDeviceLink.Files
  private let keys: LocalDeviceLink.Keys
  private let session: URLSession?
  private let requestTimeout: TimeInterval
  private let log: @Sendable (String) -> Void
  private var useLegacy = false
  private var active: (link: LocalDeviceLink, origin: URL, client: DeviceClient)?

  public init(
    origin: @escaping @Sendable () -> URL,
    files: LocalDeviceLink.Files,
    keys: LocalDeviceLink.Keys = .keychain,
    session: URLSession? = nil,
    requestTimeout: TimeInterval = 30,
    log: @escaping @Sendable (String) -> Void = { NSLog("record-anything: %@", $0) }
  ) {
    self.origin = origin
    self.files = files
    self.keys = keys
    self.session = session
    self.requestTimeout = requestTimeout
    self.log = log
  }

  /// 当前可用的本机设备连接元数据；未登记或本轮已回退旧接口时为 nil。
  public func currentLink() -> LocalDeviceLink? {
    guard !useLegacy else { return nil }
    return try? files.collector()
  }

  /// 登记冲突（409）等情况，本次运行停用设备协议并沿用旧接口。
  public func disableForSession() {
    useLegacy = true
    active = nil
  }

  /// 设备已被中枢移除（401）：撤下 `collector-link.json`，本次运行切回旧接口。
  public func handleDeviceRemoved() {
    useLegacy = true
    active = nil
    do { try files.removeCollector() }
    catch { log("device-session: link_removal_failed") }
  }

  public func connection() throws -> Connection? {
    guard !useLegacy, let link = try? files.collector() else {
      active = nil
      return nil
    }
    let currentOrigin = origin()
    if let active, active.link == link, active.origin == currentOrigin {
      return Connection(link: link, client: active.client)
    }
    guard let raw = try keys.read(.mac) else { throw LocalDeviceLink.Failure.keyUnavailable }
    let client = try DeviceClient(
      hubPublicKeyBase64URL: link.hub_pk,
      deviceID: link.device_id,
      keyStore: InMemoryDeviceKeyStore(rawRepresentation: raw),
      transport: DirectDeviceTransport(origin: currentOrigin, session: session, requestTimeout: requestTimeout)
    )
    active = (link, currentOrigin, client)
    return Connection(link: link, client: client)
  }

  public func send(op: String, body: [String: DeviceJSON] = [:]) async throws -> DeviceResponsePayload? {
    guard let conn = try connection() else { return nil }
    do {
      return try await conn.client.send(op: op, body: body)
    } catch DeviceClientError.deviceRemoved(let message) {
      handleDeviceRemoved()
      throw DeviceClientError.deviceRemoved(message: message)
    }
  }

  public func send<Body: Encodable & Sendable>(op: String, body: Body) async throws -> DeviceResponsePayload? {
    guard let conn = try connection() else { return nil }
    do {
      return try await conn.client.send(op: op, body: body)
    } catch DeviceClientError.deviceRemoved(let message) {
      handleDeviceRemoved()
      throw DeviceClientError.deviceRemoved(message: message)
    }
  }
}
