import Foundation
import CollectorCore

/// 本机登记与批次传输共用当前端口。Outbox 由 HubClient 管理，只有完整回执才确认。
actor CollectorUpload {
  static let batchLimit = 200
  static let byteLimit = 4 * 1024 * 1024

  struct Delivery {
    let records: [Record]
    let body: Data
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
  private let log: (String) -> Void
  private var preparing = false
  private var prepareAfter = 0.0
  private var prepareStopped = false
  private var useLegacy = false
  private var active: (link: LocalDeviceLink, origin: URL, client: DeviceClient)?

  init(config: Config, files: LocalDeviceLink.Files? = nil, keys: LocalDeviceLink.Keys = .keychain,
       session: URLSession = .shared, log: @escaping (String) -> Void = { NSLog("record-anything: %@", $0) }) {
    self.config = config
    self.files = files ?? .init(directory: config.dataDir)
    self.keys = keys
    self.session = session
    self.log = log
  }

  func prepare() async {
    guard !prepareStopped, !preparing, ProcessInfo.processInfo.systemUptime >= prepareAfter else { return }
    preparing = true
    defer {
      preparing = false
      prepareAfter = ProcessInfo.processInfo.systemUptime + 30
    }
    do {
      let link = try await LocalDeviceLink.bootstrap(origin: config.hubURL, token: config.token, files: files, keys: keys,
        http: { try await LocalDeviceLink.request($0, session: self.session) })
      if link != nil { prepareStopped = true }
    } catch LocalDeviceLink.Failure.conflict {
      log("local-bootstrap: key_conflict")
      prepareStopped = true
      useLegacy = true
    } catch LocalDeviceLink.Failure.unsafeFile, LocalDeviceLink.Failure.invalidLink {
      log("local-bootstrap: invalid_link")
      prepareStopped = true
    } catch LocalDeviceLink.Failure.offline, LocalDeviceLink.Failure.busy {
      // 等待启动或中枢写锁释放。期间上传继续使用旧接口。
    } catch {
      log("local-bootstrap: unavailable")
    }
  }

  func send(_ pending: [Record]) async throws -> Delivery {
    if !useLegacy, let link = try? files.collector() {
      let origin = config.hubURL
      let client: DeviceClient
      if let active, active.link == link, active.origin == origin {
        client = active.client
      } else {
        guard let raw = try keys.read(.mac) else { throw LocalDeviceLink.Failure.keyUnavailable }
        client = try DeviceClient(hubPublicKeyBase64URL: link.hub_pk, deviceID: link.device_id,
                                  keyStore: InMemoryDeviceKeyStore(rawRepresentation: raw),
                                  transport: DirectDeviceTransport(origin: origin, session: session))
        active = (link, origin, client)
      }
      let records = try Self.batch(pending, legacyDevice: nil, assignedDevice: link.device_id)
      do {
        let reply = try await client.send(op: "ingest", body: Body(device: nil, records: records))
        return Delivery(records: records, body: reply.bodyData)
      } catch DeviceClientError.deviceRemoved {
        prepareStopped = true
        useLegacy = true
        active = nil
        do { try files.removeCollector() }
        catch { log("device-ingest: link_removal_failed") }
        // 只重传被拒绝的那一批。保留原来的记录 ID 与本机队列内容。
        return try await sendLegacy(Array(pending.prefix(records.count)))
      }
    }
    return try await sendLegacy(pending)
  }

  private func sendLegacy(_ pending: [Record]) async throws -> Delivery {
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
    return Delivery(records: records, body: reply.body)
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
