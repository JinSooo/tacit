import Darwin
import Foundation

public enum StdioChannelError: Error, Equatable, Sendable {
  case lineTooLong
  case embeddedNewline
  case brokenPipe
  case invalidRequest
  case unsupportedOp
  case invalidSource
}

/// 基于 POSIX 文件描述符的行分隔通道（UTF-8 JSONL）。
/// 写端设置 F_SETNOSIGPIPE，避免子进程异常退出触发 SIGPIPE 终止宿主。
public final class StdioLineChannel {
  private let readFD: Int32
  private let writeFD: Int32
  private let closeOnDeinit: Bool
  private var buffer = Data()
  private var reachedEOF = false

  public init(readFD: Int32, writeFD: Int32, closeOnDeinit: Bool = false) {
    self.readFD = readFD
    self.writeFD = writeFD
    self.closeOnDeinit = closeOnDeinit
    _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
  }

  deinit {
    if closeOnDeinit {
      close(readFD)
      if writeFD != readFD { close(writeFD) }
    }
  }

  /// 子进程启动时复制标准输入/输出为私有描述符，并将原 fd 0/1 重定向到 /dev/null，
  /// 防止原生 C 库（如 sherpa-onnx）往 stdout 输出日志破坏 JSONL 协议。
  public static func captureStandardIO() -> StdioLineChannel {
    let inFD = dup(STDIN_FILENO)
    let outFD = dup(STDOUT_FILENO)
    if inFD >= 0 { _ = fcntl(inFD, F_SETFD, FD_CLOEXEC) }
    if outFD >= 0 { _ = fcntl(outFD, F_SETFD, FD_CLOEXEC) }
    let devNull = open("/dev/null", O_RDWR)
    if devNull >= 0 {
      _ = dup2(devNull, STDIN_FILENO)
      _ = dup2(devNull, STDOUT_FILENO)
      close(devNull)
    }
    return StdioLineChannel(readFD: inFD, writeFD: outFD, closeOnDeinit: true)
  }

  public func readLine(maxBytes: Int = 16 * 1024 * 1024) throws -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        var line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        if line.last == 0x0D { line.removeLast() }
        return line
      }
      if buffer.count > maxBytes { throw StdioChannelError.lineTooLong }
      if reachedEOF {
        guard !buffer.isEmpty else { return nil }
        var line = buffer
        buffer.removeAll(keepingCapacity: false)
        if line.last == 0x0D { line.removeLast() }
        return line
      }
      var chunk = [UInt8](repeating: 0, count: 16_384)
      let n = Darwin.read(readFD, &chunk, chunk.count)
      if n > 0 {
        buffer.append(contentsOf: chunk[..<n])
        if buffer.count > maxBytes && buffer.firstIndex(of: 0x0A) == nil {
          throw StdioChannelError.lineTooLong
        }
      } else if n == 0 {
        reachedEOF = true
      } else if errno == EINTR {
        continue
      } else {
        throw StdioChannelError.brokenPipe
      }
    }
  }

  public func writeLine(_ data: Data) throws {
    if data.contains(0x0A) { throw StdioChannelError.embeddedNewline }
    var framed = data
    framed.append(0x0A)
    try framed.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < framed.count {
        let n = Darwin.write(writeFD, base.advanced(by: written), framed.count - written)
        if n > 0 {
          written += n
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          throw StdioChannelError.brokenPipe
        }
      }
    }
  }
}

// MARK: - 音频子进程（ra-audio-worker）宿主代理协议

public struct AudioProxyRequest: Codable, Equatable, Sendable {
  public let id: Int
  public let op: String
  public let body: [String: DeviceJSON]

  public init(id: Int, op: String, body: [String: DeviceJSON]) {
    self.id = id
    self.op = op
    self.body = body
  }
}

public struct AudioProxyResponse: Codable, Equatable, Sendable {
  public let id: Int
  public let ok: Bool
  public let status: Int
  public let body: [String: DeviceJSON]?
  public let error: String?

  public init(id: Int, ok: Bool, status: Int, body: [String: DeviceJSON]? = nil, error: String? = nil) {
    self.id = id
    self.ok = ok
    self.status = status
    self.body = body
    self.error = error
  }
}

public enum AudioProxy {
  /// 音频子进程只能代理这 6 个音频/写入操作，不能越权调用删除或设置类 op。
  public static let allowedOps: Set<String> = [
    "audio.sync", "audio.embeddings", "audio.skipped", "audio.samples", "audio.lines", "ingest",
  ]

  public static func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }

  /// 将 ra-audio-worker 原有的 HTTP 路径与请求体转换为设备协议的 (op, body)。
  public static func translateHTTPPath(_ path: String, body: Data?) throws -> (op: String, body: [String: DeviceJSON]) {
    let cleanPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    func decodeBody() throws -> [String: DeviceJSON] {
      guard let body, !body.isEmpty else { return [:] }
      return try JSONDecoder().decode([String: DeviceJSON].self, from: body)
    }
    switch cleanPath {
    case "/v1/audio/sync":
      return ("audio.sync", [:])
    case "/v1/audio/embeddings":
      var obj = try decodeBody()
      obj.removeValue(forKey: "device")
      return ("audio.embeddings", obj)
    case "/v1/audio/samples":
      return ("audio.samples", try decodeBody())
    case "/v1/audio/lines":
      var obj = try decodeBody()
      obj.removeValue(forKey: "device")
      return ("audio.lines", obj)
    case "/v1/ingest":
      var obj = try decodeBody()
      obj.removeValue(forKey: "device")
      return ("ingest", obj)
    default:
      let prefix = "/v1/audio/conversations/"
      let suffix = "/skipped"
      if cleanPath.hasPrefix(prefix), cleanPath.hasSuffix(suffix) {
        let encoded = String(cleanPath.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encoded.isEmpty, !encoded.contains("/"),
              let ref = encoded.removingPercentEncoding, !ref.isEmpty else {
          throw StdioChannelError.invalidRequest
        }
        return ("audio.skipped", ["conversation_ref": .string(ref)])
      }
      throw StdioChannelError.unsupportedOp
    }
  }

  /// 宿主侧对音频子进程请求的白名单与字段校验。
  public static func sanitizeBody(op: String, body: [String: DeviceJSON], deviceID: String) throws -> [String: DeviceJSON] {
    guard allowedOps.contains(op) else { throw StdioChannelError.unsupportedOp }
    if op == "ingest" {
      guard let records = body["records"]?.arrayValue, !records.isEmpty, records.count <= 200 else {
        throw StdioChannelError.invalidRequest
      }
      var stamped: [DeviceJSON] = []
      stamped.reserveCapacity(records.count)
      for item in records {
        guard var obj = item.objectValue else { throw StdioChannelError.invalidRequest }
        guard obj["source"]?.stringValue == "mac.audio" else { throw StdioChannelError.invalidSource }
        obj["device"] = .string(deviceID)
        stamped.append(.object(obj))
      }
      return ["records": .array(stamped)]
    }
    var cleaned = body
    cleaned.removeValue(forKey: "device")
    return cleaned
  }

  /// 将错误映射为固定类别码，不向子进程或日志泄露底层正文。
  public static func mapError(_ error: Error) -> (status: Int, code: String) {
    switch error {
    case is RemoteSwitchWriteGate.Paused:
      return (503, "remote_delivery_paused")
    case RemoteDeviceSession.Failure.awaitingReceipt, RemoteDeviceSession.Failure.unavailable,
         RemoteDeviceSession.Failure.journalFull, RelayMailboxError.rateLimited:
      return (503, "remote_delivery_pending")
    default: break
    }
    if let channelError = error as? StdioChannelError {
      switch channelError {
      case .unsupportedOp: return (403, "unsupported_op")
      case .invalidSource: return (403, "invalid_source")
      case .invalidRequest, .lineTooLong, .embeddedNewline: return (400, "invalid_request")
      case .brokenPipe: return (502, "broken_pipe")
      }
    }
    if let clientError = error as? DeviceClientError {
      switch clientError {
      case .deviceRemoved: return (401, "device_removed")
      case .hubBusy: return (503, "hub_busy")
      case .envelopeTooLarge: return (413, "envelope_too_large")
      case .operationError(_, let status, _): return (status, "operation_error")
      case .plaintextError(let status, _): return (status, "hub_error")
      default: return (502, "transport_error")
      }
    }
    return (502, "transport_error")
  }

  /// 宿主代理循环：读取音频子进程请求，用 DeviceClient 发送并回写加密解密后的响应体。
  public static func serve(
    channel: StdioLineChannel,
    deviceID: String,
    send: @escaping (String, [String: DeviceJSON]) async throws -> DeviceResponsePayload
  ) async {
    let decoder = JSONDecoder()
    let encoder = jsonEncoder()
    while true {
      let line: Data
      do {
        guard let next = try channel.readLine() else { break }
        if next.isEmpty { continue }
        line = next
      } catch { break }

      let request: AudioProxyRequest
      do {
        request = try decoder.decode(AudioProxyRequest.self, from: line)
      } catch {
        let reply = AudioProxyResponse(id: -1, ok: false, status: 400, error: "invalid_request")
        if (try? encoder.encode(reply)).flatMap({ try? channel.writeLine($0) }) == nil { break }
        continue
      }

      let response: AudioProxyResponse
      do {
        let sanitized = try sanitizeBody(op: request.op, body: request.body, deviceID: deviceID)
        let payload = try await send(request.op, sanitized)
        response = AudioProxyResponse(id: request.id, ok: true, status: payload.status, body: payload.body)
      } catch {
        let mapped = mapError(error)
        response = AudioProxyResponse(id: request.id, ok: false, status: mapped.status, error: mapped.code)
      }
      do {
        try channel.writeLine(encoder.encode(response))
      } catch { break }
    }
  }
}

// MARK: - 外部插件（run-plugin --transport stdio）宿主代理协议

public struct PluginIngestRequest: Codable, Equatable, Sendable {
  public let type: String
  public let id: Int
  public let records: [DeviceJSON]

  public init(type: String = "ingest", id: Int, records: [DeviceJSON]) {
    self.type = type
    self.id = id
    self.records = records
  }
}

public struct PluginIngestResponse: Codable, Equatable, Sendable {
  public let type: String
  public let id: Int
  public let ok: Bool
  public let status: Int?
  public let result: [String: DeviceJSON]?
  public let error: String?

  public init(type: String = "ingest_result", id: Int, ok: Bool, status: Int? = nil,
              result: [String: DeviceJSON]? = nil, error: String? = nil) {
    self.type = type
    self.id = id
    self.ok = ok
    self.status = status
    self.result = result
    self.error = error
  }
}

public enum PluginProxy {
  /// 已知内置插件和扩展插件允许产出的来源集合。
  public static func allowedSources(for pluginName: String) -> Set<String>? {
    if pluginName.hasPrefix("ext-") {
      return ["plugin." + pluginName.replacingOccurrences(of: "-", with: "_")]
    }
    switch pluginName {
    case "browser": return ["mac.browser"]
    case "agent-sessions": return Set(AgentTools.sessionSources)
    default: return nil
    }
  }

  public static func sanitizeRecords(
    _ records: [DeviceJSON],
    deviceID: String,
    allowedSources: Set<String>?
  ) throws -> [DeviceJSON] {
    guard !records.isEmpty, records.count <= 200 else { throw StdioChannelError.invalidRequest }
    var stamped: [DeviceJSON] = []
    stamped.reserveCapacity(records.count)
    for item in records {
      guard var obj = item.objectValue else { throw StdioChannelError.invalidRequest }
      guard let source = obj["source"]?.stringValue, !source.isEmpty else {
        throw StdioChannelError.invalidSource
      }
      if source == "manual.note" || source == "manual.correction" {
        throw StdioChannelError.invalidSource
      }
      if let allowedSources, !allowedSources.contains(source) {
        throw StdioChannelError.invalidSource
      }
      obj["device"] = .string(deviceID)
      stamped.append(.object(obj))
    }
    return stamped
  }

  /// 宿主代理循环：处理 run-plugin --transport stdio 发出的 `ingest` 批次，返回最后一行运行摘要。
  public static func serve(
    channel: StdioLineChannel,
    deviceID: String,
    allowedSources: Set<String>?,
    send: @escaping (String, [String: DeviceJSON]) async throws -> DeviceResponsePayload
  ) async -> String {
    let decoder = JSONDecoder()
    let encoder = AudioProxy.jsonEncoder()
    var lastSummaryLine = ""
    while true {
      let line: Data
      do {
        guard let next = try channel.readLine() else { break }
        if next.isEmpty { continue }
        line = next
      } catch { break }

      if let request = try? decoder.decode(PluginIngestRequest.self, from: line), request.type == "ingest" {
        let response: PluginIngestResponse
        do {
          let stamped = try sanitizeRecords(request.records, deviceID: deviceID, allowedSources: allowedSources)
          let payload = try await send("ingest", ["records": .array(stamped)])
          guard DeliveryReceipt.decode(payload.bodyData, batchCount: stamped.count) != nil else {
            throw DeviceClientError.invalidEnvelope("入库回执无效")
          }
          response = PluginIngestResponse(id: request.id, ok: true, status: payload.status, result: payload.body)
        } catch {
          let mapped = AudioProxy.mapError(error)
          response = PluginIngestResponse(id: request.id, ok: false, status: mapped.status, error: mapped.code)
        }
        do {
          try channel.writeLine(encoder.encode(response))
        } catch { break }
      } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
        lastSummaryLine = text
      }
    }
    return lastSummaryLine
  }
}
