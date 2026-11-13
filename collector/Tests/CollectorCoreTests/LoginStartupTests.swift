import Foundation
import Testing
@testable import CollectorCore

@Test func startupSwitchPreservesDefinitionsAndSupportsManualLaunch() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let startup = LoginStartup(home: root, dataDir: root.appendingPathComponent("data"))
  #expect(!startup.installed)
  try FileManager.default.createDirectory(at: startup.agents, withIntermediateDirectories: true)
  for job in LoginStartup.jobs { try Data("definition-\(job)".utf8).write(to: startup.file(job, enabled: true)) }
  #expect(startup.enabled)
  try startup.setEnabled(false)
  #expect(startup.installed && !startup.enabled && !startup.mixed)
  for job in LoginStartup.jobs {
    #expect(!FileManager.default.fileExists(atPath: startup.file(job, enabled: true).path))
    #expect(try String(contentsOf: startup.file(job, enabled: false), encoding: .utf8) == "definition-\(job)")
  }
  try startup.setEnabled(false)
  try startup.setEnabled(true)
  #expect(startup.enabled && !startup.mixed)
}

@Test func startupConflictDoesNotPartiallyMoveJobs() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let startup = LoginStartup(home: root, dataDir: root.appendingPathComponent("data"))
  for dir in [startup.agents, startup.manual] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
  for job in LoginStartup.jobs { try Data(job.utf8).write(to: startup.file(job, enabled: true)) }
  try Data("conflict".utf8).write(to: startup.file("collector", enabled: false))
  #expect(throws: (any Error).self) { try startup.setEnabled(false) }
  #expect(FileManager.default.fileExists(atPath: startup.file("hub", enabled: true).path))
  #expect(!FileManager.default.fileExists(atPath: startup.file("hub", enabled: false).path))
}
