import Foundation

public struct TranscriptionStatus {
  public let pending: Int
  public let failed: Int

  public init(pending: Int, failed: Int) {
    self.pending = pending
    self.failed = failed
  }
}

public struct OutboxStatus {
  public let bytes: Int64
  public let dropped: Int
  public let degraded: Bool

  public init(bytes: Int64 = 0, dropped: Int = 0, degraded: Bool = true) {
    self.bytes = bytes
    self.dropped = dropped
    self.degraded = degraded
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
      let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
      try PrivateFile.write(data, to: url)
    } catch {
      log.record(.statusWriteFailed, to: diagnosticDescriptor)
    }
  }
}

public struct SetupStatus: Encodable {
  public let at: String
  public let version: String
  public let build: String
  public let exit_code: Int32
  public let ok: Bool

  private init(build: DiagnosticBuild, exitCode: Int32, ok: Bool, at: Date = Date()) {
    self.at = LocalTime.iso(at)
    version = build.version
    self.build = build.build
    exit_code = exitCode
    self.ok = ok
  }

  private func write(to url: URL) throws {
    try PrivateFile.write(JSONEncoder().encode(self), to: url)
  }

  public static func run(_ process: Process, dataDirectory: URL, build: DiagnosticBuild = DiagnosticBuild(),
                         log: DiagnosticLog = .shared, diagnosticDescriptor: Int32 = STDERR_FILENO) {
    let setupLog: Int32?
    do { setupLog = try DiagnosticLog.openFile(dataDirectory.appendingPathComponent("logs/setup.log")) }
    catch { setupLog = nil; log.record(.setupLogOpenFailed, to: diagnosticDescriptor) }
    defer { if let setupLog { close(setupLog) } }

    // 子进程输出可能含路径和错误原文。日志只留退出结果。
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let exitCode: Int32
    let ok: Bool
    do {
      try process.run()
      process.waitUntilExit()
      exitCode = process.terminationStatus
      ok = process.terminationReason == .exit && exitCode == 0
    } catch {
      exitCode = -1
      ok = false
    }

    do {
      try SetupStatus(build: build, exitCode: exitCode, ok: ok)
        .write(to: dataDirectory.appendingPathComponent("setup-status.json"))
    } catch {
      log.record(.setupStatusWriteFailed, to: diagnosticDescriptor)
    }
    log.record(.setupFinished(exitCode: exitCode), to: diagnosticDescriptor)
    if let setupLog { log.record(.setupFinished(exitCode: exitCode), to: setupLog) }
  }
}
