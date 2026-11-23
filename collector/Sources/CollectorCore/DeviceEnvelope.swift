import CryptoKit
import Foundation
import Security

/// 设备协议基础常量与编码工具（对应 docs/contracts.md 6.1–6.5、6.10）。
public enum DeviceProtocol {
  public static let version = 1
  public static let requestInfo = "tacit-device-v1"
  public static let responseInfo = "tacit-device-v1/response"
  public static let maxEnvelopeBytes = 8 * 1024 * 1024
  public static let maxResponseBytes = 24 * 1024 * 1024
  public static let ciphersuite = HPKE.Ciphersuite(
    kem: .Curve25519_HKDF_SHA256,
    kdf: .HKDF_SHA256,
    aead: .AES_GCM_128
  )

  private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
  private static let allowedDevicePrefixes: Set<String> = ["android", "mac", "agent", "linux", "windows"]

  public static func isValidHubID(_ value: String) -> Bool {
    guard value.count == 26 else { return false }
    return value.unicodeScalars.allSatisfy(isLowerBase32Scalar)
  }

  /// 兼容 6.1 的 `android-<8>` 与 6.10.1 扩展后的五类设备前缀。
  public static func isValidDeviceID(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2,
          allowedDevicePrefixes.contains(String(parts[0])),
          parts[1].count == 8 else { return false }
    return parts[1].unicodeScalars.allSatisfy(isLowerBase32Scalar)
  }

  public static func hubID(forPublicKey rawPublicKey: Data) throws -> String {
    guard rawPublicKey.count == 32 else {
      throw DeviceClientError.invalidKey("公钥长度必须为 32 字节")
    }
    let digest = Data(SHA256.hash(data: rawPublicKey))
    return base32LowercaseEncode(digest.prefix(16))
  }

  public static func hubID(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
    let digest = Data(SHA256.hash(data: publicKey.rawRepresentation))
    return base32LowercaseEncode(digest.prefix(16))
  }

  public static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// 严格校验无填充的规范 base64url（拒绝非规范尾位、空白和标准 base64 字符）。
  public static func base64URLDecode(_ string: String, expectedLength: Int? = nil) -> Data? {
    guard !string.isEmpty else { return nil }
    guard string.unicodeScalars.allSatisfy(isBase64URLScalar) else { return nil }
    var padded = string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = padded.count % 4
    if remainder == 1 { return nil }
    if remainder > 0 { padded.append(String(repeating: "=", count: 4 - remainder)) }
    guard let data = Data(base64Encoded: padded) else { return nil }
    if let expectedLength, data.count != expectedLength { return nil }
    guard base64URLEncode(data) == string else { return nil }
    return data
  }

  public static func base32LowercaseEncode(_ data: Data) -> String {
    var result = ""
    result.reserveCapacity((data.count * 8 + 4) / 5)
    var buffer = 0
    var bits = 0
    for byte in data {
      buffer = (buffer << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        result.append(base32Alphabet[(buffer >> bits) & 31])
      }
    }
    if bits > 0 {
      result.append(base32Alphabet[(buffer << (5 - bits)) & 31])
    }
    return result
  }

  public static func hexDecode(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var bytes = Data()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  public static func hexEncode(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  public static func formatRFC3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public static func parseRFC3339(_ value: String) -> Date? {
    // 严格校验 RFC 3339 基本语法与日历日期，避免接受非标准格式。
    let pattern = #"^(\d{4})-(\d{2})-(\d{2})[Tt](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:[Zz]|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let yearRange = Range(match.range(at: 1), in: value),
          let monthRange = Range(match.range(at: 2), in: value),
          let dayRange = Range(match.range(at: 3), in: value),
          let year = Int(value[yearRange]),
          let month = Int(value[monthRange]),
          let day = Int(value[dayRange]) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 0
    components.minute = 0
    components.second = 0
    guard let checkDate = calendar.date(from: components) else { return nil }
    let verified = calendar.dateComponents([.year, .month, .day], from: checkDate)
    guard verified.year == year, verified.month == month, verified.day == day else { return nil }

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = withFraction.date(from: value) { return parsed }
    let withoutFraction = ISO8601DateFormatter()
    withoutFraction.formatOptions = [.withInternetDateTime]
    return withoutFraction.date(from: value)
  }

  private static func isLowerBase32Scalar(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x32 && scalar.value <= 0x37)
  }

  private static func isBase64URLScalar(_ scalar: UnicodeScalar) -> Bool {
    let v = scalar.value
    return (v >= 0x41 && v <= 0x5A)
      || (v >= 0x61 && v <= 0x7A)
      || (v >= 0x30 && v <= 0x39)
      || v == 0x2D
      || v == 0x5F
  }
}

/// 可发送的通用 JSON 值，供设备协议请求/响应 body 使用。
public enum DeviceJSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([DeviceJSON])
  case object([String: DeviceJSON])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int64.self) {
      self = .int(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([DeviceJSON].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: DeviceJSON].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值类型")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let v): try container.encode(v)
    case .int(let v): try container.encode(v)
    case .double(let v): try container.encode(v)
    case .string(let v): try container.encode(v)
    case .array(let v): try container.encode(v)
    case .object(let v): try container.encode(v)
    }
  }

  public var stringValue: String? {
    if case .string(let v) = self { return v }
    return nil
  }

  public var intValue: Int64? {
    if case .int(let v) = self { return v }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  public var arrayValue: [DeviceJSON]? {
    if case .array(let v) = self { return v }
    return nil
  }

  public var objectValue: [String: DeviceJSON]? {
    if case .object(let v) = self { return v }
    return nil
  }

  public subscript(key: String) -> DeviceJSON? {
    objectValue?[key]
  }
}

/// 设备私钥存储接口：私钥仅存在于内存和调用方提供的实现中。
/// 接入 Mac 钥匙串时应沿用仓库规则（仅经 `/usr/bin/security` 读写）。
public protocol DeviceKeyStore: Sendable {
  /// 读取 32 字节 X25519 原始私钥；尚无私钥时返回 nil。
  func readPrivateKey() throws -> Data?
  /// 写入 32 字节 X25519 原始私钥。
  func writePrivateKey(_ rawRepresentation: Data) throws
  /// 删除已保存的私钥。
  func deletePrivateKey() throws
}

public extension DeviceKeyStore {
  func loadPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
    guard let raw = try readPrivateKey() else { return nil }
    guard raw.count == 32 else {
      throw DeviceClientError.invalidKey("私钥长度必须为 32 字节")
    }
    do {
      return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    } catch {
      throw DeviceClientError.invalidKey("无法解析 X25519 私钥")
    }
  }

  func savePrivateKey(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
    try writePrivateKey(key.rawRepresentation)
  }

  func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    if let existing = try loadPrivateKey() { return existing }
    let created = Curve25519.KeyAgreement.PrivateKey()
    try savePrivateKey(created)
    return created
  }
}

/// 内存私钥存储实现（适合内存会话与单测；不落盘）。
public final class InMemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var rawKey: Data?

  public init() {
    self.rawKey = nil
  }

  public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
    self.rawKey = privateKey.rawRepresentation
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == 32 else {
      throw DeviceClientError.invalidKey("私钥长度必须为 32 字节")
    }
    _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    self.rawKey = rawRepresentation
  }

  public init(hex: String) throws {
    guard let raw = DeviceProtocol.hexDecode(hex), raw.count == 32 else {
      throw DeviceClientError.invalidKey("十六进制私钥格式无效")
    }
    _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    self.rawKey = raw
  }

  public func readPrivateKey() throws -> Data? {
    lock.lock(); defer { lock.unlock() }
    return rawKey
  }

  public func writePrivateKey(_ rawRepresentation: Data) throws {
    guard rawRepresentation.count == 32 else {
      throw DeviceClientError.invalidKey("私钥长度必须为 32 字节")
    }
    lock.lock(); defer { lock.unlock() }
    rawKey = rawRepresentation
  }

  public func deletePrivateKey() throws {
    lock.lock(); defer { lock.unlock() }
    rawKey = nil
  }
}

/// 请求外层信封：`{ "v": 1, "device": "mac-..." | null, "enc": "<base64url>", "ct": "<base64url>" }`。
public struct DeviceRequestEnvelope: Codable, Equatable, Sendable {
  public let v: Int
  public let device: String?
  public let enc: String
  public let ct: String

  private enum CodingKeys: String, CodingKey {
    case v, device, enc, ct
  }

  public init(v: Int = DeviceProtocol.version, device: String?, enc: String, ct: String) {
    self.v = v
    self.device = device
    self.enc = enc
    self.ct = ct
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    v = try container.decode(Int.self, forKey: .v)
    guard container.contains(.device) else {
      throw DecodingError.keyNotFound(
        CodingKeys.device,
        DecodingError.Context(codingPath: container.codingPath, debugDescription: "缺少 device 字段")
      )
    }
    if try container.decodeNil(forKey: .device) {
      device = nil
    } else {
      device = try container.decode(String.self, forKey: .device)
    }
    enc = try container.decode(String.self, forKey: .enc)
    ct = try container.decode(String.self, forKey: .ct)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(v, forKey: .v)
    // 中枢要求配对请求的 device 显式为 JSON null，不能省略该键。
    if let device {
      try container.encode(device, forKey: .device)
    } else {
      try container.encodeNil(forKey: .device)
    }
    try container.encode(enc, forKey: .enc)
    try container.encode(ct, forKey: .ct)
  }
}

/// 响应外层信封：`{ "v": 1, "enc": "<base64url>", "ct": "<base64url>" }`。
public struct DeviceResponseEnvelope: Codable, Equatable, Sendable {
  public let v: Int
  public let enc: String
  public let ct: String

  public init(v: Int = DeviceProtocol.version, enc: String, ct: String) {
    self.v = v
    self.enc = enc
    self.ct = ct
  }
}

/// 已封装并序列化的设备请求，携带明文 nonce 供响应校验与未来信箱消息编号复用。
public struct SealedDeviceRequest: Equatable, Sendable {
  public let envelope: DeviceRequestEnvelope
  public let wireData: Data
  public let nonce: String

  public init(envelope: DeviceRequestEnvelope, wireData: Data, nonce: String) {
    self.envelope = envelope
    self.wireData = wireData
    self.nonce = nonce
  }
}

/// 解密后的设备响应明文 `{ "status": number, "body": object }`。
public struct DeviceResponsePayload: Equatable, Sendable {
  public let status: Int
  public let body: [String: DeviceJSON]
  public let bodyData: Data

  public init(status: Int, body: [String: DeviceJSON], bodyData: Data) {
    self.status = status
    self.body = body
    self.bodyData = bodyData
  }

  public var errorMessage: String? {
    body["error"]?.stringValue
  }

  public func decodeBody<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    do {
      return try decoder.decode(type, from: bodyData)
    } catch {
      throw DeviceClientError.invalidEnvelope("响应体解码失败")
    }
  }
}

private struct DevicePlaintextRequestWire: Encodable {
  let op: String
  let ts: String
  let nonce: String
  let body: DeviceJSON
}

private struct DevicePlaintextResponseWire: Decodable {
  let status: Int
  let body: [String: DeviceJSON]
}

/// 6.2 HPKE 信封封装与解包实现。
public enum DeviceEnvelope {
  public static func randomNonce() throws -> String {
    var bytes = Data(count: 16)
    let status = bytes.withUnsafeMutableBytes { ptr in
      SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw DeviceClientError.cryptographicFailure("生成随机 nonce 失败")
    }
    return DeviceProtocol.base64URLEncode(bytes)
  }

  public static func publicKey(base64URL: String) throws -> Curve25519.KeyAgreement.PublicKey {
    guard let raw = DeviceProtocol.base64URLDecode(base64URL, expectedLength: 32) else {
      throw DeviceClientError.invalidKey("公钥 base64url 格式或长度无效")
    }
    do {
      return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    } catch {
      throw DeviceClientError.invalidKey("无法解析 X25519 公钥")
    }
  }

  public static func publicKeyBase64URL(_ key: Curve25519.KeyAgreement.PublicKey) -> String {
    DeviceProtocol.base64URLEncode(key.rawRepresentation)
  }

  /// 使用 HPKE base（配对，`deviceID == nil`）或 auth（已配对，`deviceID != nil`）封装请求明文字节。
  public static func sealRequestPlaintext(
    _ plaintext: Data,
    deviceID: String?,
    hubPublicKey: Curve25519.KeyAgreement.PublicKey,
    senderPrivateKey: Curve25519.KeyAgreement.PrivateKey?
  ) throws -> DeviceRequestEnvelope {
    let aadString: String
    if let deviceID {
      guard DeviceProtocol.isValidDeviceID(deviceID) else {
        throw DeviceClientError.invalidRequest("设备编号格式无效")
      }
      aadString = deviceID
    } else {
      aadString = ""
    }
    let info = Data(DeviceProtocol.requestInfo.utf8)
    let aad = Data(aadString.utf8)
    do {
      var sender: HPKE.Sender
      if deviceID != nil {
        guard let senderPrivateKey else {
          throw DeviceClientError.invalidKey("已配对请求缺少设备私钥")
        }
        sender = try HPKE.Sender(
          recipientKey: hubPublicKey,
          ciphersuite: DeviceProtocol.ciphersuite,
          info: info,
          authenticatedBy: senderPrivateKey
        )
      } else {
        sender = try HPKE.Sender(
          recipientKey: hubPublicKey,
          ciphersuite: DeviceProtocol.ciphersuite,
          info: info
        )
      }
      let ciphertext = try sender.seal(plaintext, authenticating: aad)
      return DeviceRequestEnvelope(
        v: DeviceProtocol.version,
        device: deviceID,
        enc: DeviceProtocol.base64URLEncode(sender.encapsulatedKey),
        ct: DeviceProtocol.base64URLEncode(ciphertext)
      )
    } catch let error as DeviceClientError {
      throw error
    } catch {
      throw DeviceClientError.cryptographicFailure("请求信封加密失败")
    }
  }

  /// 解开请求信封（供互通测试和双向验证使用）。
  public static func openRequestEnvelope(
    _ envelope: DeviceRequestEnvelope,
    recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    senderPublicKey: Curve25519.KeyAgreement.PublicKey? = nil
  ) throws -> Data {
    guard envelope.v == DeviceProtocol.version else {
      throw DeviceClientError.invalidEnvelope("不支持的信封版本")
    }
    if let device = envelope.device, !DeviceProtocol.isValidDeviceID(device) {
      throw DeviceClientError.invalidEnvelope("信封 device 格式无效")
    }
    guard let enc = DeviceProtocol.base64URLDecode(envelope.enc, expectedLength: 32),
          let ct = DeviceProtocol.base64URLDecode(envelope.ct),
          ct.count >= 16 else {
      throw DeviceClientError.invalidEnvelope("信封 enc 或 ct 格式无效")
    }
    let info = Data(DeviceProtocol.requestInfo.utf8)
    let aad = Data((envelope.device ?? "").utf8)
    do {
      var recipient: HPKE.Recipient
      if envelope.device != nil {
        guard let senderPublicKey else {
          throw DeviceClientError.invalidKey("已配对请求解包缺少发送方公钥")
        }
        recipient = try HPKE.Recipient(
          privateKey: recipientPrivateKey,
          ciphersuite: DeviceProtocol.ciphersuite,
          info: info,
          encapsulatedKey: enc,
          authenticatedBy: senderPublicKey
        )
      } else {
        recipient = try HPKE.Recipient(
          privateKey: recipientPrivateKey,
          ciphersuite: DeviceProtocol.ciphersuite,
          info: info,
          encapsulatedKey: enc
        )
      }
      return try recipient.open(ct, authenticating: aad)
    } catch let error as DeviceClientError {
      throw error
    } catch {
      throw DeviceClientError.cryptographicFailure("请求信封解密失败")
    }
  }

  /// 封装响应明文字节（auth 模式、`tacit-device-v1/response`、AAD 为请求 nonce）。
  public static func sealResponsePlaintext(
    _ plaintext: Data,
    requestNonce: String,
    senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    recipientPublicKey: Curve25519.KeyAgreement.PublicKey
  ) throws -> DeviceResponseEnvelope {
    guard DeviceProtocol.base64URLDecode(requestNonce, expectedLength: 16) != nil else {
      throw DeviceClientError.invalidRequest("请求 nonce 格式无效")
    }
    do {
      var sender = try HPKE.Sender(
        recipientKey: recipientPublicKey,
        ciphersuite: DeviceProtocol.ciphersuite,
        info: Data(DeviceProtocol.responseInfo.utf8),
        authenticatedBy: senderPrivateKey
      )
      let ciphertext = try sender.seal(plaintext, authenticating: Data(requestNonce.utf8))
      return DeviceResponseEnvelope(
        v: DeviceProtocol.version,
        enc: DeviceProtocol.base64URLEncode(sender.encapsulatedKey),
        ct: DeviceProtocol.base64URLEncode(ciphertext)
      )
    } catch {
      throw DeviceClientError.cryptographicFailure("响应信封加密失败")
    }
  }

  /// 解开中枢返回的响应信封（auth 模式、`tacit-device-v1/response`、AAD 为请求 nonce）。
  public static func openResponseEnvelope(
    _ envelope: DeviceResponseEnvelope,
    requestNonce: String,
    recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    hubPublicKey: Curve25519.KeyAgreement.PublicKey
  ) throws -> Data {
    guard envelope.v == DeviceProtocol.version else {
      throw DeviceClientError.invalidEnvelope("不支持的响应信封版本")
    }
    guard DeviceProtocol.base64URLDecode(requestNonce, expectedLength: 16) != nil else {
      throw DeviceClientError.invalidRequest("请求 nonce 格式无效")
    }
    guard let enc = DeviceProtocol.base64URLDecode(envelope.enc, expectedLength: 32),
          let ct = DeviceProtocol.base64URLDecode(envelope.ct),
          ct.count >= 16 else {
      throw DeviceClientError.invalidEnvelope("响应信封 enc 或 ct 格式无效")
    }
    do {
      var recipient = try HPKE.Recipient(
        privateKey: recipientPrivateKey,
        ciphersuite: DeviceProtocol.ciphersuite,
        info: Data(DeviceProtocol.responseInfo.utf8),
        encapsulatedKey: enc,
        authenticatedBy: hubPublicKey
      )
      return try recipient.open(ct, authenticating: Data(requestNonce.utf8))
    } catch {
      throw DeviceClientError.cryptographicFailure("响应信封解密失败")
    }
  }

  /// 构造明文 `{op, ts, nonce, body}` 并加密封装成线上请求 JSON。
  public static func makeRequest(
    op: String,
    body: [String: DeviceJSON] = [:],
    deviceID: String?,
    hubPublicKey: Curve25519.KeyAgreement.PublicKey,
    senderPrivateKey: Curve25519.KeyAgreement.PrivateKey?,
    timestamp: Date = Date(),
    nonce: String? = nil
  ) throws -> SealedDeviceRequest {
    guard !op.isEmpty else {
      throw DeviceClientError.invalidRequest("op 不能为空")
    }
    let resolvedNonce: String
    if let nonce {
      guard DeviceProtocol.base64URLDecode(nonce, expectedLength: 16) != nil else {
        throw DeviceClientError.invalidRequest("nonce 必须是 16 字节 base64url")
      }
      resolvedNonce = nonce
    } else {
      resolvedNonce = try randomNonce()
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let plaintext: Data
    do {
      plaintext = try encoder.encode(DevicePlaintextRequestWire(
        op: op,
        ts: DeviceProtocol.formatRFC3339(timestamp),
        nonce: resolvedNonce,
        body: .object(body)
      ))
    } catch {
      throw DeviceClientError.invalidRequest("请求明文编码失败")
    }
    let envelope = try sealRequestPlaintext(
      plaintext,
      deviceID: deviceID,
      hubPublicKey: hubPublicKey,
      senderPrivateKey: senderPrivateKey
    )
    let wireData: Data
    do {
      wireData = try encoder.encode(envelope)
    } catch {
      throw DeviceClientError.invalidEnvelope("请求信封编码失败")
    }
    return SealedDeviceRequest(envelope: envelope, wireData: wireData, nonce: resolvedNonce)
  }

  /// 接受任意可编码为 JSON 对象的请求体，构造并封装请求。
  public static func makeRequest<Body: Encodable>(
    op: String,
    body: Body,
    deviceID: String?,
    hubPublicKey: Curve25519.KeyAgreement.PublicKey,
    senderPrivateKey: Curve25519.KeyAgreement.PrivateKey?,
    timestamp: Date = Date(),
    nonce: String? = nil
  ) throws -> SealedDeviceRequest {
    let encodedBody: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      encodedBody = try encoder.encode(body)
    } catch {
      throw DeviceClientError.invalidRequest("请求体编码失败")
    }
    let jsonValue: DeviceJSON
    do {
      jsonValue = try JSONDecoder().decode(DeviceJSON.self, from: encodedBody)
    } catch {
      throw DeviceClientError.invalidRequest("请求体不是合法 JSON")
    }
    guard case .object(let dictionary) = jsonValue else {
      throw DeviceClientError.invalidRequest("请求 body 必须是 JSON 对象")
    }
    return try makeRequest(
      op: op,
      body: dictionary,
      deviceID: deviceID,
      hubPublicKey: hubPublicKey,
      senderPrivateKey: senderPrivateKey,
      timestamp: timestamp,
      nonce: nonce
    )
  }

  /// 解析并解密响应 JSON，校验 `{ status, body }` 结构。
  public static func openResponse(
    wireData: Data,
    requestNonce: String,
    recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    hubPublicKey: Curve25519.KeyAgreement.PublicKey
  ) throws -> DeviceResponsePayload {
    let envelope: DeviceResponseEnvelope
    do {
      envelope = try JSONDecoder().decode(DeviceResponseEnvelope.self, from: wireData)
    } catch {
      throw DeviceClientError.invalidEnvelope("响应信封 JSON 格式无效")
    }
    let plaintext = try openResponseEnvelope(
      envelope,
      requestNonce: requestNonce,
      recipientPrivateKey: recipientPrivateKey,
      hubPublicKey: hubPublicKey
    )
    let wire: DevicePlaintextResponseWire
    do {
      wire = try JSONDecoder().decode(DevicePlaintextResponseWire.self, from: plaintext)
    } catch {
      throw DeviceClientError.invalidEnvelope("响应明文结构无效")
    }
    guard (100...599).contains(wire.status) else {
      throw DeviceClientError.invalidEnvelope("响应 status 超出有效范围")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let bodyData: Data
    do {
      bodyData = try encoder.encode(DeviceJSON.object(wire.body))
    } catch {
      throw DeviceClientError.invalidEnvelope("响应体序列化失败")
    }
    return DeviceResponsePayload(status: wire.status, body: wire.body, bodyData: bodyData)
  }
}
