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

/// 从安装盘或被系统随机挪动的位置打开时不能注册后台服务：路径在弹出安装盘或重启后就失效。
@Test func appPlacementOnlyPreparesServicesFromApplications() {
  let home = "/Users/someone"
  #expect(AppPlacement.of(bundlePath: "/Applications/Tacit.app", home: home) == .installed)
  #expect(AppPlacement.of(bundlePath: "/Users/someone/Applications/Tacit.app", home: home) == .installed)
  #expect(AppPlacement.of(bundlePath: "/Volumes/Tacit/Tacit.app", home: home) == .mustMove)
  #expect(AppPlacement.of(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Tacit.app", home: home) == .mustMove)
  #expect(AppPlacement.of(bundlePath: "/Users/someone/src/tacit/collector/build/Tacit.app", home: home) == .elsewhere)
  #expect(AppPlacement.of(bundlePath: "/Applications/Utilities/Tacit.app", home: home) == .elsewhere)
}

@Test func bundledAppMustMoveFromDownloadsAndDesktopButSourceBuildCanRun() throws {
  let home = "/Users/someone"
  for folder in ["Downloads", "Desktop"] {
    let path = "\(home)/\(folder)/Tacit.app"
    #expect(AppPlacement.of(bundlePath: path, home: home, hasBundledRuntime: true) == .mustMove)
    #expect(AppPlacement.of(bundlePath: path, home: home, hasBundledRuntime: false) == .elsewhere)
  }
  #expect(AppPlacement.of(bundlePath: "/Applications/Tacit.app", home: home, hasBundledRuntime: true) == .installed)
  #expect(AppPlacement.of(bundlePath: "\(home)/Applications/Tacit.app", home: home, hasBundledRuntime: true) == .installed)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("collector")
  let app = source.appendingPathComponent("build/Tacit.app").path
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  #expect(AppPlacement.of(bundlePath: app, home: home, hasBundledRuntime: true) == .mustMove)
  try Data().write(to: source.appendingPathComponent("Package.swift"))
  #expect(AppPlacement.of(bundlePath: app, home: home, hasBundledRuntime: true) == .elsewhere)
}

/// 2026-11-25 虚拟机实测：安装包首次打开后采集端崩溃，要到下次登录才有 launchd 拉起。
@Test func collectorStandbyIsLoadedOrStartedOnlyWhenLoginStartIsOn() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let startup = LoginStartup(home: root, dataDir: root.appendingPathComponent("data"))
  var calls: [[String]] = []
  var printResult: (Int32, String) = (113, "")
  let fake: ([String]) -> (Int32, String) = { args in
    calls.append(args)
    return args.first == "print" ? printResult : (0, "")
  }
  startup.ensureCollectorStandby(launchctl: fake)
  #expect(calls.isEmpty)

  try FileManager.default.createDirectory(at: startup.agents, withIntermediateDirectories: true)
  try Data("definition".utf8).write(to: startup.file("collector", enabled: true))
  startup.ensureCollectorStandby(launchctl: fake)
  #expect(calls.last?.first == "bootstrap")

  calls = []; printResult = (0, "state = not running")
  startup.ensureCollectorStandby(launchctl: fake)
  #expect(calls.last?.first == "kickstart")

  calls = []; printResult = (0, "state = running")
  startup.ensureCollectorStandby(launchctl: fake)
  #expect(calls.map(\.first) == ["print"])
}

@Test func cleanQuitMarkerRoundTrips() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(!CleanQuitMarker.isMarked(in: root))
  CleanQuitMarker.mark(in: root)
  #expect(CleanQuitMarker.isMarked(in: root))
  CleanQuitMarker.clear(in: root)
  #expect(!CleanQuitMarker.isMarked(in: root))
}
