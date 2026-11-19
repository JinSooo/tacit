import Darwin
import Foundation
import Testing
@testable import CollectorCore

@Test func collectorRedirectsNullStderrAndAppendsAfterCopyTruncate() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appendingPathComponent("logs/collector.log")
  let fd = open("/dev/null", O_WRONLY | O_CLOEXEC)
  try #require(fd >= 0)
  defer { close(fd) }
  try DiagnosticLog.redirectIfNeeded(to: log, descriptor: fd)
  let diagnostics = DiagnosticLog()
  diagnostics.record(.started(DiagnosticBuild(), .finder), to: fd)
  let first = try String(contentsOf: log, encoding: .utf8)
  #expect(first.contains("\"code\":\"started\""))
  #expect(first.contains("\"launched_by\":\"finder\""))
  #expect(DiagnosticLog.isFile(log, on: fd))
  #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
  #expect(try FileManager.default.attributesOfItem(atPath: log.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
  try Data().write(to: log)
  diagnostics.record(.uncaughtException(NSExceptionName("com.apple.coreaudio.avfaudio")), to: fd)
  let next = try Data(contentsOf: log)
  let line = try #require(JSONSerialization.jsonObject(with: next) as? [String: String])
  #expect(line["name"] == "com.apple.coreaudio.avfaudio")
  #expect(line["code"] == "uncaught_exception")
  #expect(ISO8601DateFormatter().date(from: line["at"] ?? "") != nil)
  #expect(line["reason"] == nil)
}

@Test func workerExitDiagnosticsAreSingleLineAndRateLimitedPerCode() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appendingPathComponent("collector.log")
  let fd = try DiagnosticLog.openFile(log)
  defer { close(fd) }
  let diagnostics = DiagnosticLog()
  diagnostics.record(.audioWorkerExit(status: 9, reason: .signal), to: fd, uptime: 100)
  diagnostics.record(.audioWorkerExit(status: 2, reason: .exit), to: fd, uptime: 699)
  diagnostics.record(.outboxDropped(total: 5), to: fd, uptime: 699)
  diagnostics.record(.audioWorkerExit(status: 3, reason: .exit), to: fd, uptime: 700)
  let lines = try logLines(log)
  try #require(lines.count == 3)
  #expect(lines[0]["component"] as? String == "audio-worker")
  #expect(lines[0]["code"] as? String == "audio_worker_exit")
  #expect(lines[0]["reason"] as? String == "signal")
  #expect(lines[0]["status"] as? Int == 9)
  #expect(lines[0]["count"] as? Int == 1)
  #expect(lines[1]["code"] as? String == "outbox_dropped")
  #expect(lines[1]["dropped"] as? Int == 5)
  #expect(lines[2]["reason"] as? String == "exit")
  #expect(lines[2]["status"] as? Int == 3)
  #expect(lines[2]["count"] as? Int == 3)
}

@Test func collectorStatusEncodesDiagnosticsAndReportsWriteFailure() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appendingPathComponent("collector.log")
  let fd = try DiagnosticLog.openFile(log)
  defer { close(fd) }
  let path = root.appendingPathComponent("collector-status.json")
  let outbox = OutboxStatus(bytes: 4096, dropped: 2, degraded: true)
  CollectorStatus.write(["queue": 4], transcription: .init(pending: 3, failed: 1), outbox: outbox, to: path)
  let status = try object(path)
  #expect(status["queue"] as? Int == 4)
  #expect(status["transcription"] as? [String: Int] == ["pending": 3, "failed": 1])
  #expect(status["outboxBytes"] as? Int == 4096)
  #expect(status["outboxDropped"] as? Int == 2)
  #expect(status["outboxDegraded"] as? Bool == true)
  CollectorStatus.write([:], transcription: nil, outbox: .init(degraded: false), to: path)
  #expect(try object(path)["transcription"] is NSNull)
  #expect(try object(path)["outboxDegraded"] as? Bool == false)
  let diagnostics = DiagnosticLog()
  for _ in 0..<2 {
    CollectorStatus.write([:], transcription: nil, outbox: outbox, to: path.appendingPathComponent("bad-parent"),
                          log: diagnostics, diagnosticDescriptor: fd)
  }
  let lines = try logLines(log)
  try #require(lines.count == 1)
  #expect(lines[0]["code"] as? String == "status_write_failed")
  #expect(lines[0]["count"] as? Int == 1)
}

@Test func setupStatusReflectsChildExitEvenWhenSetupLogCannotOpen() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let collectorLog = root.appendingPathComponent("logs/collector.log")
  let setupLog = root.appendingPathComponent("logs/setup.log")
  let fd = try DiagnosticLog.openFile(collectorLog)
  defer { close(fd) }
  let url = root.appendingPathComponent("setup-status.json")
  let build = DiagnosticBuild()
  let diagnostics = DiagnosticLog()

  let ok = Process()
  ok.executableURL = URL(fileURLWithPath: "/bin/sh")
  ok.arguments = ["-c", "echo synthetic-child-output; exit 0"]
  SetupStatus.run(ok, dataDirectory: root, build: build, log: diagnostics, diagnosticDescriptor: fd)
  #expect(try object(url)["ok"] as? Bool == true)
  #expect(try logLines(setupLog).first?["exit_code"] as? Int == 0)
  #expect(try FileManager.default.attributesOfItem(atPath: setupLog.path)[.posixPermissions] as? Int == 0o600)

  try FileManager.default.removeItem(at: setupLog)
  try FileManager.default.createDirectory(at: setupLog, withIntermediateDirectories: false)
  let failed = Process()
  failed.executableURL = ok.executableURL
  failed.arguments = ["-c", "echo synthetic-error >&2; exit 7"]
  SetupStatus.run(failed, dataDirectory: root, build: build, log: diagnostics, diagnosticDescriptor: fd)
  let status = try object(url)
  #expect(status["ok"] as? Bool == false)
  #expect(status["exit_code"] as? Int == 7)
  #expect(status["version"] as? String == build.version)
  #expect(status["build"] as? String == build.build)
  #expect(ISO8601DateFormatter().date(from: status["at"] as? String ?? "") != nil)
  #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
  let lines = try logLines(collectorLog)
  #expect(lines.compactMap { $0["code"] as? String } == ["setup_finished", "setup_log_open_failed", "setup_finished"])
  #expect(lines.last?["exit_code"] as? Int == 7)
}

private func object(_ url: URL) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func logLines(_ url: URL) throws -> [[String: Any]] {
  try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
    try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
  }
}
