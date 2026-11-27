import CryptoKit
import Foundation

/// 设备协议错误分类（按 docs/contracts.md 6.2 与 6.4 区分）。
public enum DeviceClientError: Error, Equatable, Sendable {
  /// 邀请链接格式无效或公钥与 hub_id 不匹配。
  case invalidInvitation(String)
  /// 邀请已过期。
  case inviteExpired
  /// 密钥格式或长度无效。
  case invalidKey(String)
  /// 本地请求参数不合法。
  case invalidRequest(String)
  /// 信封格式或解密后的载荷结构不合法。
  case invalidEnvelope(String)
  /// HPKE 加解密或鉴权失败。
  case cryptographicFailure(String)
  /// 调用方提供的密钥存储读写失败。
  case keyStoreError(String)
  /// 6.2：HTTP 401，设备未配对或已被中枢移除（后续请求直接拒绝）。
  case deviceRemoved(message: String?)
  /// 6.2：本地或中枢 HTTP 413，信封超过大小上限。
  case envelopeTooLarge(message: String?)
  /// 6.2：中枢 HTTP 503（例如数据库忙，可稍后重试）。
  case hubBusy(message: String?)
  /// 6.2：其他无法加密回复的明文 HTTP 错误（400、500 等）。
  case plaintextError(status: Int, message: String?)
  /// 6.2：HTTP 200 加密回复内业务状态非 2xx（400、403、409、429、503 等）。
  case operationError(op: String, status: Int, message: String?)
  /// 底层网络或传输层失败。
  case transportError(String, code: URLError.Code? = nil)
}

/// 配对设备平台标识（6.4 当前中枢支持 android，6.10 扩展至 mac 等）。
public enum DevicePlatform: String, Codable, Equatable, Sendable {
  case mac
  case android
  case agent
  case linux
  case windows
}

/// 6.8.7 邀请或配对回复中的中转信箱配置。
public struct DeviceRelayConfig: Codable, Equatable, Sendable {
  public let url: String
  public let space: String
  public let up: String
  public let down: String
  public let token: String

  public init(url: String, space: String, up: String, down: String, token: String) throws {
    guard let normalizedURL = Self.normalizeRelayURL(url) else {
      throw DeviceClientError.invalidInvitation("信箱地址无效")
    }
    guard DeviceProtocol.base64URLDecode(space, expectedLength: 16) != nil,
          DeviceProtocol.base64URLDecode(up, expectedLength: 16) != nil,
          DeviceProtocol.base64URLDecode(down, expectedLength: 16) != nil else {
      throw DeviceClientError.invalidInvitation("信箱空间或箱体编号无效")
    }
    guard Self.isValidToken(token) else {
      throw DeviceClientError.invalidInvitation("信箱令牌格式无效")
    }
    self.url = normalizedURL
    self.space = space
    self.up = up
    self.down = down
    self.token = token
  }

  private enum CodingKeys: String, CodingKey {
    case url, space, up, down, token
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let url = try container.decode(String.self, forKey: .url)
    let space = try container.decode(String.self, forKey: .space)
    let up = try container.decode(String.self, forKey: .up)
    let down = try container.decode(String.self, forKey: .down)
    let token = try container.decode(String.self, forKey: .token)
    try self.init(url: url, space: space, up: up, down: down, token: token)
  }

  private static func normalizeRelayURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    guard trimmed.rangeOfCharacter(from: disallowed) == nil,
          !trimmed.contains("\\"),
          let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          (1...65535).contains(components.port ?? 443),
          scheme == "https" || (scheme == "http" && (host == "127.0.0.1" || host == "localhost")),
          let url = components.url else { return nil }
    var normalized = url.absoluteString
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  private static func isValidToken(_ token: String) -> Bool {
    guard (20...200).contains(token.count) else { return false }
    return token.unicodeScalars.allSatisfy { scalar in
      let v = scalar.value
      return (v >= 0x41 && v <= 0x5A)
        || (v >= 0x61 && v <= 0x7A)
        || (v >= 0x30 && v <= 0x39)
        || v == 0x2D
        || v == 0x5F
    }
  }
}

/// 6.4 配对邀请（解析自 `tacit://pair?d=<base64url(JSON)>`）。
public struct DevicePairingInvitation: Equatable, Sendable {
  public let hubID: String
  public let hubName: String
  public let hubPublicKeyBase64URL: String
  public let hubPublicKeyData: Data
  public let code: String
  public let addresses: [URL]
  public let expiresAt: Date
  public let relay: DeviceRelayConfig?
  public let role: String?

  /// 邀请授予的角色能否接收下推整理结果（6.11.1：view / admin）。
  public var receivesProjection: Bool { role == "view" || role == "admin" }

  public var hubPublicKey: Curve25519.KeyAgreement.PublicKey {
    // 构造时已校验为有效的 32 字节 X25519 公钥。
    try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: hubPublicKeyData)
  }

  private struct WireInvitation: Decodable {
    let v: Int
    let hub_id: String
    let name: String
    let pk: String
    let code: String
    let addrs: [String]
    let expires_at: String
    let relay: DeviceRelayConfig?
    let role: String?
  }

  /// 解析并校验 `tacit://pair?d=...` 邀请链接。
  public static func parse(_ input: String, now: Date = Date()) throws -> DevicePairingInvitation {
    try parse(input, now: now, allowExpired: false)
  }

  static func parse(_ input: String, now: Date, allowExpired: Bool) throws -> DevicePairingInvitation {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          components.scheme == "tacit",
          components.host == "pair",
          components.user == nil,
          components.password == nil,
          components.port == nil,
          components.path.isEmpty,
          components.fragment == nil,
          let rawQuery = components.percentEncodedQuery,
          rawQuery.hasPrefix("d="),
          rawQuery.count <= 16_384,
          !rawQuery.contains("&") else {
      throw DeviceClientError.invalidInvitation("邀请链接格式无效")
    }
    let payloadToken = String(rawQuery.dropFirst(2))
    guard let jsonData = DeviceProtocol.base64URLDecode(payloadToken) else {
      throw DeviceClientError.invalidInvitation("邀请链接格式无效")
    }
    let wire: WireInvitation
    do {
      wire = try JSONDecoder().decode(WireInvitation.self, from: jsonData)
    } catch let error as DeviceClientError {
      throw error
    } catch {
      throw DeviceClientError.invalidInvitation("邀请链接格式无效")
    }
    guard wire.v == DeviceProtocol.version else {
      throw DeviceClientError.invalidInvitation("不支持的邀请版本")
    }
    guard DeviceProtocol.isValidHubID(wire.hub_id) else {
      throw DeviceClientError.invalidInvitation("后台服务身份无效")
    }
    guard let publicKeyData = DeviceProtocol.base64URLDecode(wire.pk, expectedLength: 32) else {
      throw DeviceClientError.invalidInvitation("后台服务身份无法确认")
    }
    do {
      _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
    } catch {
      throw DeviceClientError.invalidInvitation("后台服务身份无法确认")
    }
    let computedHubID = try DeviceProtocol.hubID(forPublicKey: publicKeyData)
    guard computedHubID == wire.hub_id else {
      throw DeviceClientError.invalidInvitation("后台服务身份无法确认")
    }
    guard DeviceProtocol.base64URLDecode(wire.code, expectedLength: 16) != nil else {
      throw DeviceClientError.invalidInvitation("邀请码格式无效")
    }
    let hubName = wire.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hubName.isEmpty else {
      throw DeviceClientError.invalidInvitation("后台服务名称不能为空")
    }
    guard let expiresAt = DeviceProtocol.parseRFC3339(wire.expires_at) else {
      throw DeviceClientError.invalidInvitation("邀请过期时间无效")
    }
    guard allowExpired || expiresAt > now else {
      throw DeviceClientError.inviteExpired
    }
    if let role = wire.role, !["collect", "view", "admin"].contains(role) {
      throw DeviceClientError.invalidInvitation("邀请权限角色无效")
    }
    var seen = Set<String>()
    var normalizedAddresses: [URL] = []
    for rawAddress in wire.addrs {
      if let origin = normalizeOrigin(rawAddress), seen.insert(origin.absoluteString).inserted {
        normalizedAddresses.append(origin)
      }
    }
    return DevicePairingInvitation(
      hubID: wire.hub_id,
      hubName: hubName,
      hubPublicKeyBase64URL: wire.pk,
      hubPublicKeyData: publicKeyData,
      code: wire.code,
      addresses: normalizedAddresses,
      expiresAt: expiresAt,
      relay: wire.relay,
      role: wire.role
    )
  }

  /// 归一化设备直连地址（如 `192.0.2.1:47824`、`[fd00::1]:47824`、`https://mac.example.net/`）。
  public static func normalizeOrigin(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    guard !trimmed.isEmpty,
          trimmed.rangeOfCharacter(from: disallowed) == nil,
          !trimmed.contains("\\") else { return nil }
    let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
    guard let components = URLComponents(string: withScheme),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          components.path.isEmpty || components.path == "/" else { return nil }
    if let port = components.port, !(1...65535).contains(port) { return nil }
    var normalized = URLComponents()
    normalized.scheme = scheme
    normalized.percentEncodedHost = components.percentEncodedHost
    normalized.port = components.port
    return normalized.url
  }
}

/// 配对成功后的设备注册结果。
public struct PairedDevice: Equatable, Sendable {
  public let deviceID: String
  public let hubID: String
  public let name: String
  public let relay: DeviceRelayConfig?
  public let role: String?
  public let hubName: String?

  public init(deviceID: String, hubID: String, name: String, relay: DeviceRelayConfig? = nil, role: String? = nil, hubName: String? = nil) {
    self.deviceID = deviceID
    self.hubID = hubID
    self.name = name
    self.relay = relay
    self.role = role
    self.hubName = hubName
  }
}

/// `GET /v1/device/hello` 返回的中枢身份响应。
public struct DeviceHello: Codable, Equatable, Sendable {
  public let hubID: String
  public let v: Int

  private enum CodingKeys: String, CodingKey {
    case hubID = "hub_id"
    case v
  }

  public init(hubID: String, v: Int = DeviceProtocol.version) {
    self.hubID = hubID
    self.v = v
  }
}

/// 传输层返回的原始响应（状态码 + 原始字节）。
public struct DeviceTransportResponse: Equatable, Sendable {
  public let statusCode: Int
  public let body: Data

  let authenticatedNonce: String?

  public init(statusCode: Int, body: Data = Data()) {
    self.init(statusCode: statusCode, body: body, authenticatedNonce: nil)
  }

  init(statusCode: Int, body: Data, authenticatedNonce: String?) {
    self.statusCode = statusCode
    self.body = body
    self.authenticatedNonce = authenticatedNonce
  }
}

/// 可注入的设备传输层协议：可分别由直连 HTTP、本机快路或中转信箱实现。
public protocol DeviceTransport: Sendable {
  /// 单条请求信封的传输字节上限。
  var maxEnvelopeBytes: Int { get }
  /// 发送已封装的请求信封，返回响应状态码与原始响应体。
  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse
  func send(_ request: SealedDeviceRequest, timeout: TimeInterval) async throws -> DeviceTransportResponse
}

public extension DeviceTransport {
  func send(_ request: SealedDeviceRequest, timeout: TimeInterval) async throws -> DeviceTransportResponse {
    try await send(request)
  }
}

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  static let shared = NoRedirectSessionDelegate()

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// 直连 `POST /v1/device` 与 `GET /v1/device/hello` 的 URLSession 传输层实现（也适用于本机快路 `127.0.0.1`）。
public struct DirectDeviceTransport: DeviceTransport, Sendable {
  public let origin: URL
  public let maxEnvelopeBytes: Int
  public let maxResponseBytes: Int
  public let requestTimeout: TimeInterval
  public let helloTimeout: TimeInterval
  private let session: URLSession

  private static let sharedEphemeralSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    return URLSession(configuration: config)
  }()

  public init(
    origin: URL,
    session: URLSession? = nil,
    requestTimeout: TimeInterval = 20,
    helloTimeout: TimeInterval = 2.5,
    maxEnvelopeBytes: Int = DeviceProtocol.maxEnvelopeBytes,
    maxResponseBytes: Int = DeviceProtocol.maxResponseBytes
  ) throws {
    guard let normalized = DevicePairingInvitation.normalizeOrigin(origin.absoluteString) else {
      throw DeviceClientError.invalidRequest("后台直连地址无效")
    }
    self.origin = normalized
    self.session = session ?? Self.sharedEphemeralSession
    self.requestTimeout = requestTimeout
    self.helloTimeout = helloTimeout
    self.maxEnvelopeBytes = maxEnvelopeBytes
    self.maxResponseBytes = maxResponseBytes
  }

  /// 本机快路便捷构造器（`http://127.0.0.1:<port>`，对应 6.10.2）。
  public static func loopback(
    port: Int,
    session: URLSession? = nil,
    requestTimeout: TimeInterval = 20,
    helloTimeout: TimeInterval = 2.5
  ) throws -> DirectDeviceTransport {
    guard (1...65535).contains(port),
          let url = URL(string: "http://127.0.0.1:\(port)") else {
      throw DeviceClientError.invalidRequest("本机端口无效")
    }
    return try DirectDeviceTransport(
      origin: url,
      session: session,
      requestTimeout: requestTimeout,
      helloTimeout: helloTimeout
    )
  }

  public func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
    try await send(request, timeout: requestTimeout)
  }

  public func send(_ request: SealedDeviceRequest, timeout: TimeInterval) async throws -> DeviceTransportResponse {
    if request.wireData.count > maxEnvelopeBytes {
      throw DeviceClientError.envelopeTooLarge(message: nil)
    }
    let endpoint = origin.appendingPathComponent("v1/device")
    var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    urlRequest.httpBody = request.wireData
    return try await perform(urlRequest, limit: maxResponseBytes)
  }

  /// 调用 `GET /v1/device/hello` 检查中枢身份。
  public func hello() async throws -> DeviceHello {
    let endpoint = origin.appendingPathComponent("v1/device/hello")
    var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: helloTimeout)
    urlRequest.httpMethod = "GET"
    urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    let reply = try await perform(urlRequest, limit: 4096)
    guard reply.statusCode == 200 else {
      throw DeviceClientError.plaintextError(status: reply.statusCode, message: parsePlaintextErrorMessage(reply.body))
    }
    let hello: DeviceHello
    do {
      hello = try JSONDecoder().decode(DeviceHello.self, from: reply.body)
    } catch {
      throw DeviceClientError.invalidEnvelope("后台服务返回的内容读不懂")
    }
    guard hello.v == DeviceProtocol.version, DeviceProtocol.isValidHubID(hello.hubID) else {
      throw DeviceClientError.invalidEnvelope("后台服务版本或身份无法确认")
    }
    return hello
  }

  /// 核对目标地址是否属于指定中枢。
  public func matchesHub(hubID: String) async -> Bool {
    guard DeviceProtocol.isValidHubID(hubID) else { return false }
    guard let hello = try? await hello() else { return false }
    return hello.hubID == hubID
  }

  private func perform(_ urlRequest: URLRequest, limit: Int) async throws -> DeviceTransportResponse {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest, delegate: NoRedirectSessionDelegate.shared)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      let code = (error as? URLError)?.code
      throw DeviceClientError.transportError(UserFacingError.networkMessage(code ?? .unknown), code: code)
    }
    guard let http = response as? HTTPURLResponse else {
      throw DeviceClientError.transportError("后台服务返回的内容读不懂")
    }
    if data.count > limit {
      throw DeviceClientError.envelopeTooLarge(message: "响应体超过限制")
    }
    return DeviceTransportResponse(statusCode: http.statusCode, body: data)
  }
}

private struct PlaintextErrorBody: Decodable {
  let error: String
}

private func parsePlaintextErrorMessage(_ data: Data) -> String? {
  guard !data.isEmpty else { return nil }
  return try? JSONDecoder().decode(PlaintextErrorBody.self, from: data).error
}

private struct PairRequestBody: Encodable {
  let code: String
  let device_pk: String
  let name: String
  let platform: String
}

private struct PairResponseBody: Decodable {
  let device_id: String
  let hub_id: String
  let name: String
  let hub_name: String?
  let relay: DeviceRelayConfig?
  let role: String?
}

/// 设备协议客户端：管理请求封包、响应解包、配对与错误分类，传输层与私钥存储均通过协议注入。
public actor DeviceClient {
  public let hubPublicKey: Curve25519.KeyAgreement.PublicKey
  public let hubID: String
  public private(set) var deviceID: String?
  public private(set) var isRemoved: Bool = false

  private let keyStore: any DeviceKeyStore
  private let transport: any DeviceTransport
  private let clock: @Sendable () -> Date
  private let cachePrivateKey: Bool
  private let validateRequest: @Sendable () throws -> Void
  private let onAuthorizationFailure: (@Sendable () -> Void)?
  private var cachedPrivateKey: Curve25519.KeyAgreement.PrivateKey?
  private var isPairing = false

  public init(
    hubPublicKey: Curve25519.KeyAgreement.PublicKey,
    deviceID: String? = nil,
    keyStore: any DeviceKeyStore,
    transport: any DeviceTransport,
    clock: @escaping @Sendable () -> Date = { Date() },
    cachePrivateKey: Bool = true,
    validateRequest: @escaping @Sendable () throws -> Void = {},
    onAuthorizationFailure: (@Sendable () -> Void)? = nil
  ) throws {
    if let deviceID, !DeviceProtocol.isValidDeviceID(deviceID) {
      throw DeviceClientError.invalidRequest("设备编号格式无效")
    }
    self.hubPublicKey = hubPublicKey
    self.hubID = DeviceProtocol.hubID(for: hubPublicKey)
    self.deviceID = deviceID
    self.keyStore = keyStore
    self.transport = transport
    self.clock = clock
    self.cachePrivateKey = cachePrivateKey
    self.validateRequest = validateRequest
    self.onAuthorizationFailure = onAuthorizationFailure
  }

  public init(
    hubPublicKeyBase64URL: String,
    deviceID: String? = nil,
    keyStore: any DeviceKeyStore,
    transport: any DeviceTransport,
    clock: @escaping @Sendable () -> Date = { Date() },
    cachePrivateKey: Bool = true,
    validateRequest: @escaping @Sendable () throws -> Void = {},
    onAuthorizationFailure: (@Sendable () -> Void)? = nil
  ) throws {
    let key = try DeviceEnvelope.publicKey(base64URL: hubPublicKeyBase64URL)
    try self.init(hubPublicKey: key, deviceID: deviceID, keyStore: keyStore, transport: transport, clock: clock,
                  cachePrivateKey: cachePrivateKey, validateRequest: validateRequest, onAuthorizationFailure: onAuthorizationFailure)
  }

  public init(
    invitation: DevicePairingInvitation,
    keyStore: any DeviceKeyStore,
    transport: any DeviceTransport,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.hubPublicKey = invitation.hubPublicKey
    self.hubID = invitation.hubID
    self.deviceID = nil
    self.keyStore = keyStore
    self.transport = transport
    self.clock = clock
    self.cachePrivateKey = true
    self.validateRequest = {}
    self.onAuthorizationFailure = nil
  }

  /// 读取或生成本设备私钥并返回 base64url 公钥。
  public func publicKeyBase64URL() throws -> String {
    let key = try resolvePrivateKey(createIfMissing: true)
    return DeviceEnvelope.publicKeyBase64URL(key.publicKey)
  }

  /// 构造并加密一条设备请求信封（供 WebSocket 首帧 `events.subscribe` 或信箱上行复用）。
  public func makeSealedRequest(
    op: String,
    body: [String: DeviceJSON] = [:],
    nonce: String? = nil
  ) throws -> SealedDeviceRequest {
    if isRemoved {
      throw DeviceClientError.deviceRemoved(message: nil)
    }
    try validateRequest()
    let currentDeviceID = deviceID
    let privateKey = try resolvePrivateKey(createIfMissing: currentDeviceID == nil)
    return try DeviceEnvelope.makeRequest(
      op: op,
      body: body,
      deviceID: currentDeviceID,
      hubPublicKey: hubPublicKey,
      senderPrivateKey: currentDeviceID == nil ? nil : privateKey,
      timestamp: clock(),
      nonce: nonce
    )
  }

  /// 解开中枢通过信箱 `down` 主动下发的加密消息（6.8.7 / 6.9.5：HPKE auth、`tacit-device-v1/response`、AAD 为消息 id）。
  public func openPushEnvelope(wireData: Data, messageID: String) throws -> Data {
    let privateKey = try resolvePrivateKey(createIfMissing: false)
    let envelope: DeviceResponseEnvelope
    do {
      envelope = try JSONDecoder().decode(DeviceResponseEnvelope.self, from: wireData)
    } catch {
      throw DeviceClientError.invalidEnvelope("推送信封 JSON 格式无效")
    }
    return try DeviceEnvelope.openResponseEnvelope(
      envelope,
      requestNonce: messageID,
      recipientPrivateKey: privateKey,
      hubPublicKey: hubPublicKey
    )
  }

  /// 解开中枢经信箱 `down` 返回的普通请求响应（携带 `{ status, body }`）。
  public func openResponseEnvelope(wireData: Data, requestNonce: String) throws -> DeviceResponsePayload {
    let privateKey = try resolvePrivateKey(createIfMissing: false)
    return try DeviceEnvelope.openResponse(
      wireData: wireData,
      requestNonce: requestNonce,
      recipientPrivateKey: privateKey,
      hubPublicKey: hubPublicKey
    )
  }

  /// 发送设备操作并返回已解密的响应载荷。
  public func send(op: String, body: [String: DeviceJSON] = [:], timeout: TimeInterval? = nil) async throws -> DeviceResponsePayload {
    if isRemoved {
      throw DeviceClientError.deviceRemoved(message: nil)
    }
    try validateRequest()
    let currentDeviceID = deviceID
    let privateKey = try resolvePrivateKey(createIfMissing: currentDeviceID == nil)
    let sealed = try DeviceEnvelope.makeRequest(
      op: op,
      body: body,
      deviceID: currentDeviceID,
      hubPublicKey: hubPublicKey,
      senderPrivateKey: currentDeviceID == nil ? nil : privateKey,
      timestamp: clock()
    )
    return try await dispatch(op: op, sealed: sealed, currentDeviceID: currentDeviceID, privateKey: privateKey, timeout: timeout)
  }

  /// 发送带强类型 Encodable 请求体的设备操作。
  public func send<Body: Encodable>(op: String, body: Body) async throws -> DeviceResponsePayload {
    if isRemoved {
      throw DeviceClientError.deviceRemoved(message: nil)
    }
    try validateRequest()
    let currentDeviceID = deviceID
    let privateKey = try resolvePrivateKey(createIfMissing: currentDeviceID == nil)
    let sealed = try DeviceEnvelope.makeRequest(
      op: op,
      body: body,
      deviceID: currentDeviceID,
      hubPublicKey: hubPublicKey,
      senderPrivateKey: currentDeviceID == nil ? nil : privateKey,
      timestamp: clock()
    )
    return try await dispatch(op: op, sealed: sealed, currentDeviceID: currentDeviceID, privateKey: privateKey)
  }

  /// 发送请求并将成功响应的 body 解码为强类型。
  public func send<Body: Encodable, Response: Decodable>(
    op: String,
    body: Body,
    as responseType: Response.Type
  ) async throws -> Response {
    let payload = try await send(op: op, body: body)
    return try payload.decodeBody(responseType)
  }

  /// 发送 JSON 字典请求并将成功响应的 body 解码为强类型。
  public func send<Response: Decodable>(
    op: String,
    body: [String: DeviceJSON] = [:],
    as responseType: Response.Type
  ) async throws -> Response {
    let payload = try await send(op: op, body: body)
    return try payload.decodeBody(responseType)
  }

  /// 使用 6.4 邀请执行 `pair` 配对，成功后记录分配的 `device_id` 并切换到 auth 模式。
  public func pair(
    invitation: DevicePairingInvitation,
    deviceName: String,
    platform: DevicePlatform = .mac
  ) async throws -> PairedDevice {
    try validatePair(invitation)
    let key = try resolvePrivateKey(createIfMissing: true)
    let sealed = try Self.makePairRequest(invitation: invitation, deviceName: deviceName,
                                          platform: platform, publicKey: key.publicKey, timestamp: clock())
    return try await pair(invitation: invitation, sealed: sealed)
  }

  static func makePairRequest(invitation: DevicePairingInvitation, deviceName: String,
                              platform: DevicePlatform = .mac, publicKey: Curve25519.KeyAgreement.PublicKey,
                              timestamp: Date) throws -> SealedDeviceRequest {
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 200 else { throw DeviceClientError.invalidRequest("设备名称无效") }
    return try DeviceEnvelope.makeRequest(
      op: "pair", body: PairRequestBody(code: invitation.code,
        device_pk: DeviceEnvelope.publicKeyBase64URL(publicKey), name: name, platform: platform.rawValue),
      deviceID: nil, hubPublicKey: try DeviceEnvelope.publicKey(base64URL: invitation.hubPublicKeyBase64URL),
      senderPrivateKey: nil, timestamp: timestamp
    )
  }

  private func validatePair(_ invitation: DevicePairingInvitation) throws {
    if isRemoved { throw DeviceClientError.deviceRemoved(message: nil) }
    guard deviceID == nil, !isPairing else { throw DeviceClientError.invalidRequest("当前客户端已配对或正在配对") }
    guard invitation.hubID == hubID, invitation.hubPublicKeyData == hubPublicKey.rawRepresentation else {
      throw DeviceClientError.invalidInvitation("邀请链接属于另一个后台服务")
    }
    guard invitation.expiresAt > clock() else { throw DeviceClientError.inviteExpired }
  }

  func pair(invitation: DevicePairingInvitation, sealed: SealedDeviceRequest) async throws -> PairedDevice {
    try validatePair(invitation)
    isPairing = true
    defer { isPairing = false }
    let privateKey = try resolvePrivateKey(createIfMissing: false)
    let response = try await dispatch(op: "pair", sealed: sealed, currentDeviceID: nil, privateKey: privateKey)
    let reply = try response.decodeBody(PairResponseBody.self)
    guard reply.hub_id == invitation.hubID else {
      throw DeviceClientError.invalidEnvelope("配对回复的 hub_id 与邀请不匹配")
    }
    guard DeviceProtocol.isValidDeviceID(reply.device_id) else {
      throw DeviceClientError.invalidEnvelope("配对回复的 device_id 格式无效")
    }
    await (transport as? RelayDeviceTransport)?.confirmAuthenticatedReply(sealed.nonce)
    self.deviceID = reply.device_id
    return PairedDevice(
      deviceID: reply.device_id,
      hubID: reply.hub_id,
      name: reply.name,
      relay: reply.relay,
      role: reply.role,
      hubName: reply.hub_name
    )
  }

  private func resolvePrivateKey(createIfMissing: Bool) throws -> Curve25519.KeyAgreement.PrivateKey {
    if let cachedPrivateKey { return cachedPrivateKey }
    let loaded: Curve25519.KeyAgreement.PrivateKey?
    do {
      loaded = try keyStore.loadPrivateKey()
    } catch let error as DeviceClientError {
      throw error
    } catch {
      throw DeviceClientError.keyStoreError(L10n.Settings.keychainUnavailable)
    }
    if let loaded {
      if cachePrivateKey { cachedPrivateKey = loaded }
      return loaded
    }
    guard createIfMissing else {
      throw DeviceClientError.invalidKey("密钥存储中缺少设备私钥")
    }
    let created = Curve25519.KeyAgreement.PrivateKey()
    do {
      try keyStore.savePrivateKey(created)
    } catch let error as DeviceClientError {
      throw error
    } catch {
      throw DeviceClientError.keyStoreError(L10n.Settings.keychainUnavailable)
    }
    cachedPrivateKey = created
    return created
  }

  private func dispatch(
    op: String,
    sealed: SealedDeviceRequest,
    currentDeviceID: String?,
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    timeout: TimeInterval? = nil
  ) async throws -> DeviceResponsePayload {
    try validateRequest()
    if sealed.wireData.count > transport.maxEnvelopeBytes {
      throw DeviceClientError.envelopeTooLarge(message: nil)
    }
    let reply: DeviceTransportResponse
    if let timeout {
      reply = try await transport.send(sealed, timeout: timeout)
    } else {
      reply = try await transport.send(sealed)
    }
    if reply.statusCode != 200 {
      let message = parsePlaintextErrorMessage(reply.body)
      switch reply.statusCode {
      case 401 where currentDeviceID != nil:
        onAuthorizationFailure?()
        isRemoved = true
        throw DeviceClientError.deviceRemoved(message: message)
      case 413:
        throw DeviceClientError.envelopeTooLarge(message: message)
      case 503:
        throw DeviceClientError.hubBusy(message: message)
      default:
        throw DeviceClientError.plaintextError(status: reply.statusCode, message: message)
      }
    }
    let payload = try DeviceEnvelope.openResponse(
      wireData: reply.body,
      requestNonce: reply.authenticatedNonce ?? sealed.nonce,
      recipientPrivateKey: privateKey,
      hubPublicKey: hubPublicKey
    )
    if op != "pair" {
      await (transport as? RelayDeviceTransport)?.confirmAuthenticatedReply(sealed.nonce)
    }
    if payload.status == 401, currentDeviceID != nil {
      onAuthorizationFailure?()
      isRemoved = true
      throw DeviceClientError.deviceRemoved(message: payload.errorMessage)
    }
    if !(200..<300).contains(payload.status) {
      throw DeviceClientError.operationError(op: op, status: payload.status, message: payload.errorMessage)
    }
    return payload
  }

  nonisolated func validateCurrentIdentity() throws { try validateRequest() }
}
