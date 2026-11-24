import CollectorCore
import Darwin
import Foundation

struct HistoryBackupFiles: Sendable {
  let directory: URL
  private var fs: FileManager { .default }
  private let pendingAudit = "history.db.audit-pending"
  var database: URL { directory.appendingPathComponent("history.db") }

  private func names() throws -> [String] {
    try fs.contentsOfDirectory(atPath: directory.path).filter { name in
      ["history.db", "history.db-wal", "history.db-shm", "history.db-journal", pendingAudit].contains(name) ||
        name.range(of: #"^history\.db\.migration-v[0-9]+\.bak(\.tmp)?$"#, options: .regularExpression) != nil
    }
  }

  func size() throws -> Int64 { try size(of: names()) }

  private func size(of files: [String]) throws -> Int64 {
    try files.reduce(0) { total, name in
      let path = directory.appendingPathComponent(name).path
      if name == pendingAudit {
        guard try fs.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeDirectory else {
          throw HistoryImporter.Failure.backupUnavailable
        }
        return try fs.contentsOfDirectory(atPath: path).reduce(total) { subtotal, entry in
          try subtotal + regularFileSize(path + "/" + entry)
        }
      }
      return try total + regularFileSize(path)
    }
  }

  private func regularFileSize(_ path: String) throws -> Int64 {
    let attrs = try fs.attributesOfItem(atPath: path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          let size = attrs[.size] as? NSNumber else { throw HistoryImporter.Failure.backupUnavailable }
    return size.int64Value
  }

  func remove() throws {
    let files = try names()
    _ = try size(of: files)
    for file in files where file != "history.db" {
      try fs.removeItem(at: directory.appendingPathComponent(file))
    }
    if files.contains("history.db") { try fs.removeItem(at: database) }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw HistoryImporter.Failure.backupUnavailable }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw HistoryImporter.Failure.backupUnavailable }
  }
}

struct FrozenHistoryCommands {
  enum Failure: Error { case snapshotChanged, subprocess }
  let runtime: String
  let bun: String
  let directory: URL
  let environment: [String: String]?
  let entry: String
  private let queue = DispatchQueue(label: "record-anything.history-commands", qos: .utility)

  init(runtime: String, bun: String, directory: URL, environment: [String: String]? = nil, entry: String? = nil) {
    self.runtime = runtime
    self.bun = bun
    self.directory = directory
    self.environment = environment
    self.entry = entry ?? runtime + "/hub/src/cli.ts"
  }

  func export(after cursor: String?, limit: Int) async throws -> HistoryExportPage {
    let args = ["--limit", String(limit)] + (cursor.map { ["--after", $0] } ?? [])
    return try JSONDecoder().decode(HistoryExportPage.self, from: await run("history-export", args: args))
  }

  func apply(_ changes: [HistoryWithdrawal]) async throws {
    struct Page: Codable { let changes: [HistoryWithdrawal] }
    struct Result: Decodable {
      struct Item: Decodable {
        enum Status: String, Decodable { case applied, already, missing }
        let id: String
        let status: Status
      }
      let items: [Item]
    }
    guard !changes.isEmpty else { return }
    let data = try JSONEncoder().encode(Page(changes: changes))
    let result = try JSONDecoder().decode(Result.self, from: await run("history-reconcile", args: [], input: data))
    guard result.items.map(\.id) == changes.map(\.id) else { throw HistoryImporter.Failure.invalidReceipt }
  }

  private func run(_ operation: String, args: [String], input: Data? = nil) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result { try execute(operation, args: args, input: input) })
      }
    }
  }

  static func writeInput(_ data: Data, to fd: Int32) -> Bool {
    guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { return false }
    return data.withUnsafeBytes { buffer in
      guard let start = buffer.baseAddress else { return true }
      var sent = 0
      while sent < buffer.count {
        let count = Darwin.write(fd, start.advanced(by: sent), buffer.count - sent)
        if count == -1, errno == EINTR { continue }
        // A child that exits before reading stdin yields EPIPE. Let the caller
        // finish collecting its exit status and diagnostics.
        guard count > 0 else { return false }
        sent += count
      }
      return true
    }
  }

  private func execute(_ operation: String, args: [String], input: Data?) throws -> Data {
    let process = Process()
    let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: bun)
    process.arguments = [entry, operation, "--data-dir", directory.path] + args
    process.currentDirectoryURL = URL(fileURLWithPath: runtime)
    process.environment = environment
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin

    let inputFD = stdin.fileHandleForWriting.fileDescriptor
    let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    try process.run()
    deadline.schedule(deadline: .now() + 25)
    let pid = process.processIdentifier
    deadline.setEventHandler { if process.isRunning { kill(pid, SIGKILL) } }
    deadline.resume()
    defer {
      deadline.cancel()
      if process.isRunning { kill(pid, SIGKILL); process.waitUntilExit() }
    }
    let inputWritten: Bool
    if let input {
      inputWritten = Self.writeInput(input, to: inputFD)
      try stdin.fileHandleForWriting.close()
    } else { inputWritten = true }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    // Both commands report only fixed categories on failure. Discard stderr after recognizing a
    // changed source, and never show or record the raw child output in the application's status.
    let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if process.terminationStatus != 0 || !inputWritten {
      if error.split(whereSeparator: \.isWhitespace).contains(where: { $0 == "(snapshot_changed)" || $0 == "snapshot_changed" }) {
        throw Failure.snapshotChanged
      }
      throw Failure.subprocess
    }
    return data
  }
}
