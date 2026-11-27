import Foundation

public struct TranscriptionStatus: Equatable, Sendable {
  public let pending: Int
  public let failed: Int

  public init(pending: Int, failed: Int) {
    self.pending = pending
    self.failed = failed
  }
}

public struct OutboxStatus: Equatable, Sendable {
  public let bytes: Int64
  public let dropped: Int
  public let degraded: Bool
  public let quarantined: Int

  public init(bytes: Int64 = 0, dropped: Int = 0, degraded: Bool = true, quarantined: Int = 0) {
    self.bytes = bytes
    self.dropped = dropped
    self.degraded = degraded
    self.quarantined = quarantined
  }
}

/// 设备协议 `collector.status` 上报载荷（docs/contracts.md 6.10.3）。
/// 录音关闭时显式编码 `"transcription": null`，让中枢区分“未开启”与“未上报”。
public struct CollectorStatusReport: Codable, Equatable, Sendable {
  public struct Transcription: Codable, Equatable, Sendable {
    public let pending: Int
    public let failed: Int
    public init(pending: Int, failed: Int) {
      self.pending = pending
      self.failed = failed
    }
  }

  public let time: String
  public let transcription: Transcription?
  public let outbox_bytes: Int64
  public let outbox_dropped: Int
  public let outbox_degraded: Bool
  public let hub_busy: Int
  public let queue_peak: Int

  private enum CodingKeys: String, CodingKey {
    case time, transcription, outbox_bytes, outbox_dropped, outbox_degraded, hub_busy, queue_peak
  }

  public init(
    time: String,
    transcription: TranscriptionStatus?,
    outbox: OutboxStatus,
    hubBusy: Int,
    queuePeak: Int
  ) {
    self.time = time
    self.transcription = transcription.map { Transcription(pending: $0.pending, failed: $0.failed) }
    self.outbox_bytes = max(0, outbox.bytes)
    self.outbox_dropped = max(0, outbox.dropped)
    self.outbox_degraded = outbox.degraded
    self.hub_busy = max(0, hubBusy)
    self.queue_peak = max(0, queuePeak)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(time, forKey: .time)
    if let transcription {
      try container.encode(transcription, forKey: .transcription)
    } else {
      try container.encodeNil(forKey: .transcription)
    }
    try container.encode(outbox_bytes, forKey: .outbox_bytes)
    try container.encode(outbox_dropped, forKey: .outbox_dropped)
    try container.encode(outbox_degraded, forKey: .outbox_degraded)
    try container.encode(hub_busy, forKey: .hub_busy)
    try container.encode(queue_peak, forKey: .queue_peak)
  }
}

/// 采集健康上报节流器：常规每 60 秒一次；出现或加重错误时提前上报（受最短冷却限制）。
public struct CollectorStatusThrottle: Sendable {
  public let interval: TimeInterval
  public let errorCooldown: TimeInterval
  private var lastSentAt: TimeInterval?
  private var lastDegraded = false
  private var lastDropped = 0
  private var lastFailedTranscriptions = 0
  private var lastHubBusy = 0
  private var lastHadError = false

  public init(interval: TimeInterval = 60, errorCooldown: TimeInterval = 5) {
    self.interval = interval
    self.errorCooldown = errorCooldown
  }

  public func shouldSend(_ report: CollectorStatusReport, hasError: Bool, force: Bool = false, now: TimeInterval) -> Bool {
    if force { return true }
    guard let lastSentAt else { return true }
    let elapsed = now - lastSentAt
    if elapsed >= interval { return true }
    let errorEscalated = (report.outbox_degraded && !lastDegraded)
      || report.outbox_dropped > lastDropped
      || (report.transcription?.failed ?? 0) > lastFailedTranscriptions
      || report.hub_busy > lastHubBusy
      || (hasError && !lastHadError)
    return errorEscalated && elapsed >= errorCooldown
  }

  public mutating func recordSent(_ report: CollectorStatusReport, hasError: Bool, at now: TimeInterval) {
    lastSentAt = now
    lastDegraded = report.outbox_degraded
    lastDropped = report.outbox_dropped
    lastFailedTranscriptions = report.transcription?.failed ?? 0
    lastHubBusy = report.hub_busy
    lastHadError = hasError
  }
}

public enum CollectorStatus {
  public static func write(_ fields: [String: Any], transcription: TranscriptionStatus?, outbox: OutboxStatus,
                           to url: URL, log: DiagnosticLog = .shared, diagnosticDescriptor: Int32 = STDERR_FILENO) {
    do {
      var status = fields
      status["transcription"] = transcription.map { ["pending": $0.pending, "failed": $0.failed] } as Any? ?? NSNull()
      status["outboxBytes"] = outbox.bytes
      status["outboxDropped"] = outbox.dropped
      status["outboxDegraded"] = outbox.degraded
      status["outboxQuarantined"] = outbox.quarantined
      let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
      try PrivateFile.write(data, to: url)
    } catch {
      log.record(.statusWriteFailed, to: diagnosticDescriptor)
    }
  }
}

public struct SetupStatus: Codable {
  public enum Reason: String, Codable {
    case bundleIncomplete = "bundle_incomplete"
    case database
    case backgroundBlocked = "background_blocked"
    case serviceUnhealthy = "service_unhealthy"
    case portInUse = "port_in_use"
    case unknown

    public static func fromStandardError(_ text: String) -> Self {
      let prefix = "setup_error:"
      guard let line = text.split(whereSeparator: \.isNewline).last, line.hasPrefix(prefix) else { return .unknown }
      return Self(rawValue: String(line.dropFirst(prefix.count))) ?? .unknown
    }
  }

  public let at: String
  public let version: String
  public let build: String
  public let exit_code: Int32
  public let ok: Bool
  public let reason: Reason?

  private enum CodingKeys: String, CodingKey { case at, version, build, exit_code, ok, reason }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    at = try values.decode(String.self, forKey: .at)
    version = try values.decode(String.self, forKey: .version)
    build = try values.decode(String.self, forKey: .build)
    exit_code = try values.decode(Int32.self, forKey: .exit_code)
    ok = try values.decode(Bool.self, forKey: .ok)
    reason = ok ? nil : (try? values.decode(Reason.self, forKey: .reason)) ?? .unknown
  }

  private init(build: DiagnosticBuild, exitCode: Int32, ok: Bool, reason: Reason?) {
    at = LocalTime.iso(Date())
    version = build.version
    self.build = build.build
    exit_code = exitCode
    self.ok = ok
    self.reason = reason
  }

  private func write(to url: URL) throws {
    try PrivateFile.write(JSONEncoder().encode(self), to: url)
  }

  @discardableResult
  public static func run(_ process: Process, dataDirectory: URL, build: DiagnosticBuild = DiagnosticBuild(),
                         log: DiagnosticLog = .shared, diagnosticDescriptor: Int32 = STDERR_FILENO) -> SetupStatus {
    let setupLog: Int32?
    do { setupLog = try DiagnosticLog.openFile(dataDirectory.appendingPathComponent("logs/setup.log")) }
    catch { setupLog = nil; log.record(.setupLogOpenFailed, to: diagnosticDescriptor) }
    defer { if let setupLog { close(setupLog) } }

    // setup 的输出是后台准备自己的步骤说明，留在本机 0600 的 setup.log 供排障（随 hub 轮转）；
    // 诊断信息只摘取其中的结构化事件，不复制这些文本。
    let output = setupLog.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) } ?? FileHandle.nullDevice
    if let setupLog { log.record(.setupStarted, to: setupLog) }
    process.standardOutput = output
    let stderr = Pipe()
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    let exitCode: Int32
    let ok: Bool
    var reason: Reason = .unknown
    do {
      try process.run()
      let errors = stderr.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      try? output.write(contentsOf: errors)
      reason = Reason.fromStandardError(String(decoding: errors, as: UTF8.self))
      exitCode = process.terminationStatus
      ok = process.terminationReason == .exit && exitCode == 0
    } catch {
      exitCode = -1
      ok = false
    }

    let status = SetupStatus(build: build, exitCode: exitCode, ok: ok, reason: ok ? nil : reason)
    do {
      try status.write(to: dataDirectory.appendingPathComponent("setup-status.json"))
    } catch {
      log.record(.setupStatusWriteFailed, to: diagnosticDescriptor)
    }
    log.record(.setupFinished(exitCode: exitCode), to: diagnosticDescriptor)
    if let setupLog { log.record(.setupFinished(exitCode: exitCode), to: setupLog) }
    return status
  }
}

public enum LocalBackendPreparation {
  public static func deliveryError(_ error: String, preparing: Bool, inStartupGrace: Bool) -> String? {
    preparing || inStartupGrace ? nil : error
  }
}
