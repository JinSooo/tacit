import Foundation
import CollectorCore

/// 本机登记与批次传输共用当前端口。Outbox 由 HubClient 管理，只有完整回执才确认。
actor CollectorUpload {
  static let batchLimit = 200
  static let byteLimit = 4 * 1024 * 1024

  struct Delivery {
    let records: [Record]
    let body: Data
    let route: HubBinding.Route
  }

  enum Failure: Error { case noToken, batchTooLarge }

  private struct Body: Encodable {
    let device: String?
    let records: [Record]
  }

  private let config: Config
  private let files: LocalDeviceLink.Files
  private let keys: LocalDeviceLink.Keys
  private let session: URLSession
  private let deviceSession: HostDeviceSession
  private let log: (String) -> Void
  private let onLinked: (@Sendable (LocalDeviceLink) -> Void)?
  private var preparing = false
  private var prepareAfter = 0.0
  private var prepareStopped = false

  init(config: Config, files: LocalDeviceLink.Files? = nil, keys: LocalDeviceLink.Keys = .keychain,
       session: URLSession = .shared, deviceSession: HostDeviceSession? = nil,
       log: @escaping @Sendable (String) -> Void = { NSLog("record-anything: %@", $0) },
       onLinked: (@Sendable (LocalDeviceLink) -> Void)? = nil) {
    self.config = config
    let resolvedFiles = files ?? .init(directory: config.dataDir)
    self.files = resolvedFiles
    self.keys = keys
    self.session = session
    self.deviceSession = deviceSession ?? HostDeviceSession(
      origin: { config.hubURL }, files: resolvedFiles, keys: keys, session: session, log: log,
      remoteAccess: RemoteDeviceAccess(dataDirectory: config.dataDir)
    )
    self.log = log
    self.onLinked = onLinked
  }

  func prepare() async {
    guard config.allowsLocalHub, !prepareStopped, !preparing, ProcessInfo.processInfo.systemUptime >= prepareAfter else { return }
    preparing = true
    defer {
      preparing = false
      prepareAfter = ProcessInfo.processInfo.systemUptime + 30
    }
    do {
      let link = try await LocalDeviceLink.bootstrap(origin: config.hubURL, token: config.token, files: files, keys: keys,
        http: { try await LocalDeviceLink.request($0, session: self.session) })
      if let link {
        prepareStopped = true
        onLinked?(link)
      }
    } catch LocalDeviceLink.Failure.conflict {
      log("local-bootstrap: key_conflict")
      prepareStopped = true
      await deviceSession.disableForSession()
    } catch LocalDeviceLink.Failure.unsafeFile, LocalDeviceLink.Failure.invalidLink {
      log("local-bootstrap: invalid_link")
      prepareStopped = true
    } catch LocalDeviceLink.Failure.offline, LocalDeviceLink.Failure.busy {
      // 等待启动或中枢写锁释放。期间上传继续使用旧接口。
    } catch {
      log("local-bootstrap: unavailable")
    }
  }

  func remoteSession(for route: HubBinding.Route) async throws -> RemoteDeviceSession? {
    try await deviceSession.connection(for: route)?.remoteSession
  }

  func send(_ pending: [Record], on expected: HubBinding.Route? = nil,
            beforeRemoteSubmit: (([String]) async throws -> Void)? = nil) async throws -> Delivery {
    let route = try config.hubRoute()
    if let expected, expected != route { throw HubBinding.Failure.changed }
    if let conn = try await deviceSession.connection(for: route) {
      let records = try Self.batch(pending, legacyDevice: nil, assignedDevice: conn.deviceID)
      if route.remote != nil {
        try await beforeRemoteSubmit?(records.map(\.id))
      }
      do {
        let reply = try await conn.client.send(op: "ingest", body: Body(device: nil, records: records))
        return Delivery(records: records, body: reply.bodyData, route: route)
      } catch DeviceClientError.deviceRemoved where route.remote == nil {
        prepareStopped = true
        await deviceSession.handleDeviceRemoved(on: route)
        // 只重传被拒绝的那一批。保留原来的记录 ID 与本机队列内容。
        return try await sendLegacy(Array(pending.prefix(records.count)), on: route)
      }
    }
    return try await sendLegacy(pending, on: route)
  }

  private func sendLegacy(_ pending: [Record], on route: HubBinding.Route) async throws -> Delivery {
    guard route.remote == nil, try config.hubRoute() == route else { throw HubBinding.Failure.changed }
    guard let token = config.token, !token.isEmpty else { throw Failure.noToken }
    let records = try Self.batch(pending, legacyDevice: config.device, assignedDevice: nil)
    var request = URLRequest(url: config.hubURL.appendingPathComponent("v1/ingest"), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try Self.encoder().encode(Body(device: config.device, records: records))
    let reply = try await LocalDeviceLink.request(request, session: session)
    guard reply.statusCode == 200 else {
      throw DeviceClientError.plaintextError(status: reply.statusCode, message: nil)
    }
    return Delivery(records: records, body: reply.body, route: route)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }

  static func batch(_ input: [Record], legacyDevice: String?, assignedDevice: String?) throws -> [Record] {
    let encoder = encoder()
    var bytes = try encoder.encode(Body(device: legacyDevice, records: [])).count
    var batch: [Record] = []
    for var record in input.prefix(batchLimit) {
      if let assignedDevice { record.device = assignedDevice }
      let size = try encoder.encode(record).count + (batch.isEmpty ? 0 : 1)
      guard bytes + size <= byteLimit else { break }
      bytes += size
      batch.append(record)
    }
    guard !batch.isEmpty else { throw Failure.batchTooLarge }
    return batch
  }
}
