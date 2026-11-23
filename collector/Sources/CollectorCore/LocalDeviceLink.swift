import CryptoKit
import Darwin
import Foundation

/// 同机登记使用的公开连接信息。写入 collector 文件表示两份配置均已准备好。
public struct LocalDeviceLink: Codable, Equatable, Sendable {
  public let hub_id: String
  public let hub_pk: String
  public let device_id: String
  public let mode: String
  public let addrs: [String]

  private enum CodingKeys: String, CodingKey { case hub_id, hub_pk, device_id, mode, addrs, relay }

  private init(hubID: String, hubKey: String, deviceID: String, origin: URL) {
    hub_id = hubID
    hub_pk = hubKey
    device_id = deviceID
    mode = "local"
    addrs = [origin.absoluteString]
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    hub_id = try values.decode(String.self, forKey: .hub_id)
    hub_pk = try values.decode(String.self, forKey: .hub_pk)
    device_id = try values.decode(String.self, forKey: .device_id)
    mode = try values.decode(String.self, forKey: .mode)
    addrs = try values.decode([String].self, forKey: .addrs)
    guard try values.decodeNil(forKey: .relay),
          mode == "local", addrs.count == 1,
          let address = URL(string: addrs[0]), Self.isLoopbackOrigin(address),
          device_id.hasPrefix("mac-"), DeviceProtocol.isValidDeviceID(device_id),
          try Self.hubMatches(hub_id, hub_pk) else { throw Failure.invalidLink }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(hub_id, forKey: .hub_id)
    try values.encode(hub_pk, forKey: .hub_pk)
    try values.encode(device_id, forKey: .device_id)
    try values.encode(mode, forKey: .mode)
    try values.encode(addrs, forKey: .addrs)
    try values.encodeNil(forKey: .relay)
  }

  public enum Account: String {
    case mac = "mac-device-key"
    case agent = "agent-device-key"
  }

  public enum File: String {
    case collector = "collector-link.json"
    case agent = "agent-link.json"
  }

  public enum Failure: Error, Equatable {
    case unsafeFile, fileIO, invalidLink, keyUnavailable, offline, busy, conflict, rejected
  }

  public struct Keys {
    public let read: (Account) throws -> Data?
    public let create: (Account, Data) throws -> Void

    public init(read: @escaping (Account) throws -> Data?, create: @escaping (Account, Data) throws -> Void) {
      self.read = read
      self.create = create
    }

    public static let keychain = Keys(read: { account in
      let result = try SecurityCLI.run(["find-generic-password", "-s", "record-anything", "-a", account.rawValue, "-w"])
      if result.status == 44 { return nil }
      guard result.status == 0, let raw = DeviceProtocol.hexDecode(result.text), raw.count == 32 else {
        throw Failure.keyUnavailable
      }
      return raw
    }, create: { account, raw in
      let hex = DeviceProtocol.hexEncode(raw)
      let command = try SecurityCLI.addGenericPasswordCommand(service: "record-anything", account: account.rawValue, hexValue: hex)
      _ = try SecurityCLI.run(["-i"], stdin: command)
    })

    fileprivate func confirmedKey(_ account: Account) throws -> Curve25519.KeyAgreement.PrivateKey {
      do {
        var raw = try read(account)
        if raw == nil {
          try create(account, Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
          // -i 的退出码不可靠。并发首次写入时使用先落入钥匙串的那把。
          raw = try read(account)
        }
        guard let raw, raw.count == 32 else { throw Failure.keyUnavailable }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
      } catch {
        throw Failure.keyUnavailable
      }
    }
  }

  public struct Files {
    public let read: (File) throws -> Data?
    public let write: (File, Data) throws -> Void
    public let removeCollector: () throws -> Void

    public init(read: @escaping (File) throws -> Data?, write: @escaping (File, Data) throws -> Void,
                removeCollector: @escaping () throws -> Void) {
      self.read = read
      self.write = write
      self.removeCollector = removeCollector
    }

    public init(directory: URL) {
      // 用目录 fd 固定操作目标。读取和登记时拒绝符号链接，包括断开的链接。
      func withDirectory<T>(missing: T, _ operation: (Int32) throws -> T) throws -> T {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return missing }
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        return try operation(fd)
      }
      func safeEntry(_ dir: Int32, _ file: File) throws -> Bool {
        var info = stat()
        if fstatat(dir, file.rawValue, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          if errno == ENOENT { return false }
          throw Failure.fileIO
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else { throw Failure.unsafeFile }
        return true
      }
      read = { file in
        try withDirectory(missing: nil as Data?) { dir in
          let fd = openat(dir, file.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
          if fd < 0 && errno == ENOENT { return nil }
          guard fd >= 0 else { throw Failure.unsafeFile }
          defer { close(fd) }
          var info = stat()
          guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_mode & 0o777 == 0o600, info.st_size <= 4096 else { throw Failure.unsafeFile }
          return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097) ?? Data()
        }
      }
      write = { file, data in
        let written = try withDirectory(missing: false) { dir in
          let temp = ".local-device-link-" + UUID().uuidString
          let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
          guard fd >= 0 else { throw Failure.fileIO }
          defer { close(fd); _ = unlinkat(dir, temp, 0) }
          let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
          guard fchmod(fd, 0o600) == 0 else { throw Failure.fileIO }
          try handle.write(contentsOf: data)
          guard fsync(fd) == 0 else { throw Failure.fileIO }
          _ = try safeEntry(dir, file)
          if file == .collector {
            // 登记完成标记只新建。并发完成时保留先写入的配置。
            if linkat(dir, temp, dir, file.rawValue, 0) != 0 {
              guard errno == EEXIST, try safeEntry(dir, file) else { throw Failure.fileIO }
            }
          } else {
            guard renameat(dir, temp, dir, file.rawValue) == 0 else { throw Failure.fileIO }
          }
          return true
        }
        guard written else { throw Failure.fileIO }
      }
      removeCollector = {
        try withDirectory(missing: ()) { dir in
          guard try safeEntry(dir, .collector) else { return }
          if unlinkat(dir, File.collector.rawValue, 0) != 0 && errno != ENOENT { throw Failure.fileIO }
        }
      }
    }

    public func collector() throws -> LocalDeviceLink? {
      guard let data = try read(.collector) else { return nil }
      do { return try JSONDecoder().decode(LocalDeviceLink.self, from: data) }
      catch { throw Failure.invalidLink }
    }
  }

  public typealias HTTP = (URLRequest) async throws -> DeviceTransportResponse

  public static func request(_ request: URLRequest, session: URLSession = .shared) async throws -> DeviceTransportResponse {
    do {
      let (body, response) = try await session.data(for: request, delegate: NoRedirectSessionDelegate.shared)
      guard let response = response as? HTTPURLResponse else { throw Failure.offline }
      return DeviceTransportResponse(statusCode: response.statusCode, body: body)
    } catch {
      throw Failure.offline
    }
  }

  /// 先确认健康检查，再读取和确认私钥。Agent 配置先发布，崩溃后可用原密钥重试。
  public static func bootstrap(
    origin: URL, token: String?, files: Files, keys: Keys,
    http: HTTP = { try await request($0) }
  ) async throws -> LocalDeviceLink? {
    guard let token, !token.isEmpty else { return nil }
    if let link = try files.collector() { return link }
    _ = try files.read(.agent)
    guard isLoopbackOrigin(origin) else { throw Failure.invalidLink }
    let health = try await http(URLRequest(url: origin.appendingPathComponent("v1/health"),
                                           cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3))
    if health.statusCode == 503 { throw Failure.busy }
    guard health.statusCode == 200,
          (try? JSONDecoder().decode(Health.self, from: health.body).ok) == true else { throw Failure.offline }

    let mac = try keys.confirmedKey(.mac), agent = try keys.confirmedKey(.agent)
    var request = URLRequest(url: origin.appendingPathComponent("v1/settings/devices/local-bootstrap"), timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode([
      "mac_pk": DeviceEnvelope.publicKeyBase64URL(mac.publicKey),
      "agent_pk": DeviceEnvelope.publicKeyBase64URL(agent.publicKey),
    ])
    let response = try await http(request)
    switch response.statusCode {
    case 200: break
    case 409: throw Failure.conflict
    case 503: throw Failure.busy
    default: throw Failure.rejected
    }

    guard let reply = try? JSONDecoder().decode(BootstrapReply.self, from: response.body),
          reply.endpoint == origin.appendingPathComponent("v1/device").absoluteString,
          reply.mac_device_id.hasPrefix("mac-"), DeviceProtocol.isValidDeviceID(reply.mac_device_id),
          reply.agent_device_id.hasPrefix("agent-"), DeviceProtocol.isValidDeviceID(reply.agent_device_id),
          (try? hubMatches(reply.hub_id, reply.hub_pk)) == true else { throw Failure.invalidLink }
    let link = LocalDeviceLink(hubID: reply.hub_id, hubKey: reply.hub_pk, deviceID: reply.mac_device_id, origin: origin)
    let agentLink = AgentLink(hub_id: reply.hub_id, hub_pk: reply.hub_pk,
                              device_id: reply.agent_device_id, address: origin.absoluteString)
    let encoder = JSONEncoder()
    try files.write(.agent, encoder.encode(agentLink))
    try files.write(.collector, encoder.encode(link))
    return try files.collector()
  }

  private struct Health: Decodable { let ok: Bool }
  private struct BootstrapReply: Decodable {
    let mac_device_id: String
    let agent_device_id: String
    let hub_id: String
    let hub_pk: String
    let endpoint: String
  }

  private struct AgentLink: Encodable {
    let hub_id: String
    let hub_pk: String
    let device_id: String
    let address: String
  }

  private static func hubMatches(_ id: String, _ key: String) throws -> Bool {
    try DeviceProtocol.hubID(for: DeviceEnvelope.publicKey(base64URL: key)) == id
  }

  private static func isLoopbackOrigin(_ url: URL) -> Bool {
    guard let port = url.port, (1...65535).contains(port) else { return false }
    return url.absoluteString == "http://127.0.0.1:\(port)"
  }
}
