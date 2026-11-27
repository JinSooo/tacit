import AudioStore
import CollectorCore
import CryptoKit
import Foundation
import Testing
@testable import Collector

private enum SwitchFault: Error { case interrupted, offline }

private func preparedBinding() throws -> HubBinding {
  let key = Data(repeating: 11, count: 32)
  let identity = try HubBinding.Remote(hubID: DeviceProtocol.hubID(forPublicKey: key),
                                        hubPublicKey: DeviceProtocol.base64URLEncode(key))
  return HubBinding(generation: 0, target: .remote, phase: .preparing, remote: identity)
}

private final class SwitchFixture: RemoteSwitchPersistence, RemoteSwitchServices {
  let prepared: HubBinding
  var current: HubBinding
  var saved: RemoteSwitchCheckpoint?
  var loaded: Set<LocalSwitchJob> = [.distill, .hub]
  var definitions = true
  var events: [String] = []
  var crashAfter: String?
  var offline = false
  var failDatabase = false
  var failPreflight = false
  var failProbe = false
  var busyPublications = 0
  var agentLinkExists = false
  var bonjourSuspended = false
  let local = LocalSwitchSnapshot(hub: .init(plist: Data([1]), login: false, loaded: true),
                                  distill: .init(plist: Data([2]), login: false, loaded: true),
                                  loginEnabled: false, distillEnabled: true)

  init() throws {
    prepared = try preparedBinding()
    current = prepared
  }

  func restart() { crashAfter = nil; offline = false }
  func event(_ name: String) throws {
    guard !offline else { throw SwitchFault.interrupted }
    events.append(name)
    if name == crashAfter {
      offline = true
      throw SwitchFault.interrupted
    }
  }

  func binding() throws -> HubBinding {
    guard !offline else { throw SwitchFault.interrupted }
    return current
  }

  func publish(_ next: HubBinding, replacing previous: HubBinding) throws {
    guard !offline else { throw SwitchFault.interrupted }
    #expect(previous == current)
    current = next
    try event("bind-\(next.phase.rawValue)")
  }

  func checkpoint() throws -> RemoteSwitchCheckpoint? { saved }
  func save(_ checkpoint: RemoteSwitchCheckpoint) throws {
    guard !offline else { throw SwitchFault.interrupted }
    saved = checkpoint
    try event("save-\(checkpoint.step.rawValue)")
  }

  func clearCheckpoint() throws {
    guard !offline else { throw SwitchFault.interrupted }
    saved = nil
    try event("clear")
  }

  func hasAgentLink(for remote: HubBinding.Remote) -> Bool { agentLinkExists }
  func clearAgentContext(for route: HubBinding.Route) throws { try event("agent-\(route.generation)") }
  func snapshot() throws -> LocalSwitchSnapshot { try event("snapshot"); return local }

  func stop(_ job: LocalSwitchJob) async throws {
    guard !offline else { throw SwitchFault.interrupted }
    loaded.remove(job)
    try event("stop-\(job.rawValue)")
  }

  func verifyClosedDatabase() throws {
    #expect(loaded.isEmpty)
    try event("database")
    if failDatabase { throw RemoteSwitch.Failure.databaseInUse }
  }

  func withdrawDefinitions() throws {
    guard !offline else { throw SwitchFault.interrupted }
    definitions = false
    try event("withdraw")
  }

  func preflightReturn(_ local: LocalSwitchSnapshot) async throws {
    try event("return-preflight")
    if failPreflight { throw RemoteSwitch.Failure.localHubUnverified }
  }

  func discardStagedHub() async throws { try event("discard-staged") }

  func startHubForVerification(_ local: LocalSwitchSnapshot) async throws {
    #expect(local == self.local)
    #expect(!definitions)
    loaded.insert(.hub)
    try event("probe-start")
  }

  func verifyLocalHub() async throws {
    #expect(loaded == [.hub])
    try event("probe-verify")
    if failProbe { throw RemoteSwitch.Failure.localHubUnverified }
  }

  func restore(_ local: LocalSwitchSnapshot, afterSwitchBack: Bool) async throws {
    guard !offline else { throw SwitchFault.interrupted }
    #expect(local == self.local)
    definitions = true
    loaded = [.hub, .distill]
    try event(afterSwitchBack ? "restore-return" : "restore-rollback")
  }

  @MainActor func coordinator(gate: RemoteSwitchWriteGate = .init(), timeout: TimeInterval = 1) -> RemoteSwitch {
    RemoteSwitch(persistence: self, services: self, runtime: .init(gate: gate, settled: {
      try self.event("settled")
      return true
    }, suspendBonjour: { suspended in
      self.bonjourSuspended = suspended
      self.events.append(suspended ? "bonjour-stop" : "bonjour-allow")
    }, publish: { prior, _, next, publish in
      if self.busyPublications > 0 {
        self.busyPublications -= 1
        try self.event("publication-busy")
        throw RemoteSwitch.Failure.busy
      }
      if prior != nil { try self.event("queue-copy") }
      try self.event("audio-close-\(next.generation)")
      try publish()
    }, bindingChanged: {
      self.events.append("viewer-refresh")
    }, finishCommit: { _, _ in
      try self.event("queue-retire-local")
    }, finishReturn: { _, _, _ in
      try self.event("queue-retire")
    }), drainTimeout: timeout)
  }
}

@Test @MainActor private func remoteSwitchCommitsAfterClosingDatabaseBonjourAndAudio() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: true)
  #expect(fixture.current.phase == .committed)
  #expect(fixture.current.generation == 1)
  #expect(fixture.events == ["settled", "snapshot", "save-committing", "stop-distill", "stop-hub",
                             "database", "withdraw", "bonjour-stop", "agent-0", "database",
                             "audio-close-1", "bind-committed", "queue-retire-local", "agent-0", "save-committed", "viewer-refresh"])
  #expect(fixture.loaded.isEmpty && !fixture.definitions && fixture.bonjourSuspended)
  #expect(!gate.isPaused)
  #expect(coordinator.agentNeedsDirectConnection)
}

@Test @MainActor private func remoteSwitchRecoversLocalOnTimeoutOrUnsafeDatabase() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate, timeout: 0.025)
  try gate.begin()
  await #expect(throws: RemoteSwitch.Failure.drainTimedOut) {
    try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  }
  #expect(fixture.current.route == .local && fixture.loaded == [.hub, .distill])
  #expect(fixture.events == ["bonjour-allow"])
  #expect(!gate.isPaused)
  gate.end()
  fixture.failDatabase = true
  await #expect(throws: RemoteSwitch.Failure.databaseInUse) {
    try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  }
  #expect(fixture.current.route == .local && fixture.loaded == [.hub, .distill])
  #expect(fixture.events.contains("restore-rollback"))
  #expect(fixture.saved == nil && fixture.definitions && !fixture.bonjourSuspended)
  #expect(!gate.isPaused)
}

@Test(arguments: ["settled", "snapshot", "save-committing", "stop-distill", "stop-hub", "database",
                  "withdraw", "agent-0", "audio-close-1", "bind-committed", "save-committed"])
@MainActor private func remoteSwitchCommitRecoversAcrossInterruptedSteps(step: String) async throws {
  let fixture = try SwitchFixture()
  fixture.crashAfter = step
  await #expect(throws: (any Error).self) {
    try await fixture.coordinator().commit(prepared: fixture.prepared, agentNeedsDirectConnection: true)
  }
  fixture.restart()
  let gate = RemoteSwitchWriteGate()
  try await fixture.coordinator(gate: gate).recover()
  #expect(!gate.isPaused)
  if ["bind-committed", "save-committed"].contains(step) {
    #expect(fixture.current.generation == 1 && fixture.current.phase == .committed)
    #expect(fixture.loaded.isEmpty && !fixture.definitions && fixture.bonjourSuspended)
    #expect(fixture.saved?.step == .committed)
  } else {
    #expect(fixture.current.route == .local && fixture.loaded == [.hub, .distill])
    #expect(fixture.saved == nil && fixture.definitions && !fixture.bonjourSuspended)
  }
}

@Test @MainActor private func remoteSwitchRequiresCompleteReconciliationBeforeOpeningLocalDatabase() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  await #expect(throws: SwitchFault.offline) { try await coordinator.switchBack { _ in throw SwitchFault.offline } }
  await #expect(throws: RemoteSwitch.Failure.reconciliationIncomplete) {
    try await coordinator.switchBack { _ in false }
  }
  #expect(fixture.current.phase == .committed && fixture.current.route.remote != nil)
  #expect(fixture.loaded.isEmpty && !fixture.events.contains("probe-start") && !gate.isPaused)
  try await coordinator.switchBack { route in
    #expect(route.generation == 1 && route.remote != nil)
    #expect(fixture.current.phase == .committed && gate.isPaused && fixture.loaded.isEmpty)
    try fixture.event("reconcile")
    return true
  }
  #expect(Array(fixture.events.suffix(15)) == ["reconcile", "save-reconciled", "bind-switching_back", "probe-start", "probe-verify",
                                             "agent-1", "queue-copy", "audio-close-2", "bind-local",
                                             "restore-return", "agent-1", "queue-retire", "viewer-refresh",
                                             "clear", "bonjour-allow"])
  #expect(fixture.current.phase == .local && fixture.current.generation == 2)
  #expect(fixture.saved == nil && fixture.definitions && fixture.loaded == [.hub, .distill] && !gate.isPaused)
}

@Test(arguments: ["return-preflight", "save-reconciling", "bind-switching_back", "reconcile", "save-reconciled", "probe-start",
                  "probe-verify", "agent-1", "queue-copy", "audio-close-2", "bind-local",
                  "restore-return", "queue-retire", "clear"])
@MainActor private func remoteSwitchReturnRecoversAcrossInterruptedSteps(step: String) async throws {
  let fixture = try SwitchFixture()
  let coordinator = fixture.coordinator()
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  fixture.crashAfter = step
  await #expect(throws: (any Error).self) {
    try await coordinator.switchBack { _ in try fixture.event("reconcile"); return true }
  }
  fixture.restart()
  let gate = RemoteSwitchWriteGate()
  let restarted = fixture.coordinator(gate: gate)
  try await restarted.recover()
  #expect(!gate.isPaused)
  if !["bind-local", "restore-return", "queue-retire", "clear"].contains(step) {
    #expect(fixture.current.phase == .committed && fixture.loaded.isEmpty && !fixture.definitions)
    try await restarted.switchBack { _ in true }
  }
  #expect(fixture.current.phase == .local && fixture.current.generation == 2)
  #expect(fixture.saved == nil && fixture.definitions && !fixture.bonjourSuspended)
  #expect(fixture.loaded == [.hub, .distill])
}

private func withTempSwitchDirectory(_ run: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try run(directory)
}

@Test private func remoteSwitchLoginDoesNotStartFrozenServicesAndUpgradeUsesRemoteSetup() throws {
  try withTempSwitchDirectory { directory in
    let startup = LoginStartup(home: directory, dataDir: directory)
    try FileManager.default.createDirectory(at: startup.agents, withIntermediateDirectories: true)
    for job in LoginStartup.jobs { try Data().write(to: startup.file(job, enabled: true)) }
    let prepared = try preparedBinding()
    try prepared.write(to: directory, replacing: .legacyLocal)
    #expect(AppSetup.shouldRunBundledSetup(in: directory))
    try LocalServiceStartupPolicy.writeCheckpoint(Data("checkpoint".utf8), in: directory)
    #expect(!AppSetup.shouldRunBundledSetup(in: directory))
    startup.startServices { args in Issue.record("Started during local recovery: \(args)"); return 1 }
    try LocalServiceStartupPolicy.removeCheckpoint(in: directory)
    let committed = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
    try committed.write(to: directory, replacing: prepared)
    #expect(AppSetup.shouldRunBundledSetup(in: directory))
    #expect(!LocalServiceStartupPolicy.allowsBackground(in: directory))
    startup.startServices { args in Issue.record("Started with remote binding: \(args)"); return 1 }
    try startup.setEnabled(false)
    #expect(FileManager.default.fileExists(atPath: startup.file("collector", enabled: false).path))
    #expect(!FileManager.default.fileExists(atPath: startup.file("hub", enabled: false).path))
    #expect(!FileManager.default.fileExists(atPath: startup.file("distill", enabled: false).path))
  }
}

@Test private func remoteSwitchClearsAgentTextKeepingAuditAndOtherTarget() throws {
  try withTempSwitchDirectory { directory in
    let fixture = try SwitchFixture()
    let remote = try #require(fixture.prepared.remote)
    let localIdentity = directory.appendingPathComponent("agent-context-cache/local-agent")
    let remoteIdentity = directory.appendingPathComponent(remote.dir).appendingPathComponent("agent-context-cache/remote-agent")
    let fs = FileManager.default
    for identity in [localIdentity, remoteIdentity] {
      try fs.createDirectory(at: identity.appendingPathComponent("audit"), withIntermediateDirectories: true)
      try Data([7]).write(to: identity.appendingPathComponent("body.enc"))
      try Data([8]).write(to: identity.appendingPathComponent("audit/entry.enc"))
    }
    try DiskRemoteSwitchPersistence(directory: directory).clearAgentContext(for: fixture.prepared.route)
    #expect(!fs.fileExists(atPath: localIdentity.appendingPathComponent("body.enc").path))
    #expect(try Data(contentsOf: localIdentity.appendingPathComponent("audit/entry.enc")) == Data([8]))
    #expect(try Data(contentsOf: remoteIdentity.appendingPathComponent("body.enc")) == Data([7]))
  }
}

@Test private func remoteSwitchSealsConversationWithLastCapturedTime() throws {
  try withTempSwitchDirectory { directory in
    let store = try AudioStore(dataDirectory: directory, key: SymmetricKey(size: .bits256))
    let start = Date(timeIntervalSince1970: 123_456_000)
    let end = start.addingTimeInterval(5)
    var open = AudioMetadata(start: start)
    open.segments = [AudioSegment(file: "mic-0001.enc", track: .mic, start: start, end: end, dbfs: -12)]
    try store.writeMetadata(open)
    let closed = try AudioCoordinator.closeConversation(open, in: store)
    #expect(closed.status == .closed && closed.t_end == LocalTime.iso(end))
    #expect(try store.conversations() == [closed])
  }
}

@Test private func remoteSwitchCopiesOnlyNeverSubmittedRecordsAndRetiresAfterPublication() throws {
  try withTempSwitchDirectory { directory in
    let key = SymmetricKey(size: .bits256)
    func record(_ source: String) -> Record {
      Record(device: "mac", source: source, kind: "activity", start: Date(), context: nil,
             title: "虚构行程", body: "测试内容", capture: .init(method: "manual"))
    }
    let pending = record("mac.screen")
    let submitted = record("mac.screen")
    let correction = record("manual.correction")
    let remote = directory.appendingPathComponent("remote")
    let local = directory.appendingPathComponent("local")
    do {
      let source = try OutboxStore(dataDirectory: remote, key: key)
      for item in [pending, submitted, correction] { _ = try source.append(item) }
      try source.markSubmitted([submitted.id])
    }
    do {
      let source = try OutboxStore(dataDirectory: remote, key: key)
      let target = try OutboxStore(dataDirectory: local, key: key)
      try source.copyForSwitch(to: target, onlyUnsubmitted: true)
      #expect(source.count == 3)
      #expect(target.restore(limit: 10).records == [RecordRedaction.record(pending)])
    }
    // Simulate a restart after copying, then another recovery after publication.
    let source = try OutboxStore(dataDirectory: remote, key: key)
    let target = try OutboxStore(dataDirectory: local, key: key)
    try source.copyForSwitch(to: target, onlyUnsubmitted: true)
    try source.removeSwitchCopies(in: target, onlyUnsubmitted: true)
    try source.removeSwitchCopies(in: target, onlyUnsubmitted: true)
    #expect(Set(source.restore(limit: 10).records.map(\.id)) == [submitted.id, correction.id])
    #expect(target.restore(limit: 10).records == [RecordRedaction.record(pending)])
  }
}

private func switchRecord() -> Record {
  Record(device: "mac", source: "mac.screen", kind: "activity", start: Date(), context: nil,
         title: "虚构行程", body: "测试内容", capture: .init(method: "manual"))
}

private func tempSwitchDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test @MainActor private func B2RegressionOfflineReturnResumesRemote() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  let remote = fixture.current.route
  let priorStops = fixture.events.filter { $0.hasPrefix("stop-") }.count
  await #expect(throws: SwitchFault.offline) { try await coordinator.switchBack { _ in throw SwitchFault.offline } }
  #expect(fixture.current.phase == .committed && fixture.current.route == remote)
  #expect(fixture.saved?.step == .committed)
  #expect(!gate.isPaused && fixture.loaded.isEmpty)
  #expect(fixture.events.filter { $0.hasPrefix("stop-") }.count == priorStops)
  try await coordinator.recover()
  #expect(!gate.isPaused && fixture.current.phase == .committed)
}

@Test private func B2RegressionForwardMovesQueuedAndHandoffRecords() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = SymmetricKey(size: .bits256)
  let open: (URL) throws -> OutboxStore = { try OutboxStore(dataDirectory: $0, key: key) }
  let gate = RemoteSwitchWriteGate()
  let client = HubClient(config: Config(dataDir: directory, bun: ""), writeGate: gate, openOutbox: open)
  let prepared = try preparedBinding()
  try prepared.write(to: directory, replacing: .legacyLocal)
  let next = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
  let first = switchRecord(), handoff = switchRecord(), afterPublication = switchRecord()
  client.enqueue([first])
  gate.setPaused(true)
  _ = try await client.settleForSwitch()
  client.enqueue([handoff])
  try await client.publishSwitch(previousLocal: nil, from: prepared.route, to: next.route) {
    try next.write(to: directory, replacing: prepared)
    client.enqueue([afterPublication])
  }
  try await client.finishSwitchToRemote(from: prepared.route, to: next.route)
  let target = try open(HubClient.outboxDirectory(in: directory, for: next.route))
  #expect(Set(target.restore(limit: 10).records.map(\.id)) == [first.id, handoff.id, afterPublication.id])
  #expect(try open(directory).count == 0)
  #expect(client.pendingCount == 3)
}

@Test private func B2RegressionPausedAudioDoesNotInventory() throws {
  try withTempSwitchDirectory { directory in
    let store = try AudioStore(dataDirectory: directory, key: SymmetricKey(size: .bits256))
    let start = Date()
    var closed = AudioMetadata(start: start)
    closed.t_end = LocalTime.iso(start)
    try closed.transition(to: .closed, at: start)
    try store.writeMetadata(closed)
    let gate = RemoteSwitchWriteGate()
    gate.setPaused(true)
    let audio = AudioCoordinator(config: Config(dataDir: directory, bun: ""), writeGate: gate, initialStorage: (.local, store))
    audio.update(enabled: false)
    audio.shutdown()
    #expect(audio.transcriptionStatus().pending == 0)
  }
}

@Test(arguments: [nil, 0, 30] as [Int?])
private func B2RegressionAudioPreservesRetentionAndPendingOnRemote(days: Int?) throws {
  try withTempSwitchDirectory { directory in
    let prepared = try preparedBinding()
    let binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
    let remote = try #require(binding.remote)
    let folder = directory.appendingPathComponent(remote.dir).appendingPathComponent("audio-generation-1")
    if let days {
      try JSONSerialization.data(withJSONObject: ["retention_days": days])
        .write(to: directory.appendingPathComponent("collector-audio-state.json"))
    }
    let store = try AudioStore(dataDirectory: folder, key: SymmetricKey(size: .bits256))
    func conversation(age: TimeInterval, done: Bool) throws -> AudioMetadata {
      let start = Date().addingTimeInterval(-age * 86_400)
      var meta = AudioMetadata(start: start)
      meta.t_end = LocalTime.iso(start)
      try meta.transition(to: .closed, at: start)
      if done { try meta.transition(to: .done, at: start) }
      try store.writeMetadata(meta)
      return meta
    }
    let recent = try conversation(age: 10, done: true)
    let old = try conversation(age: 40, done: true)
    let pending = try conversation(age: 40, done: false)
    let audio = AudioCoordinator(config: Config(dataDir: directory, bun: ""), initialStorage: (binding.route, store))
    audio.update(enabled: false)
    audio.shutdown()
    let kept = Set(try store.conversations().map(\.id))
    #expect(kept.contains(recent.id) && kept.contains(pending.id))
    #expect(kept.contains(old.id) == (days != 30))
  }
}

@Test private func B2RegressionCorruptOutboxDoesNotBlockHealthyCopies() throws {
  try withTempSwitchDirectory { directory in
    let key = SymmetricKey(size: .bits256)
    let targetDirectory = directory.appendingPathComponent("target")
    let (bad, good) = (switchRecord(), switchRecord())
    let source = try OutboxStore(dataDirectory: directory, key: key)
    for item in [bad, good] { _ = try source.append(item) }
    let damaged = source.root.appendingPathComponent(bad.id + ".enc")
    try Data("bad ciphertext".utf8).write(to: damaged)
    let outgoing = OutboxBuffer { source }
    let incoming = OutboxBuffer { try OutboxStore(dataDirectory: targetDirectory, key: key) }
    outgoing.retry(at: 0)
    incoming.retry(at: 0)
    #expect(outgoing.batch(limit: 10).map(\.id) == [good.id])
    #expect(outgoing.isPersisted)
    try outgoing.copyForSwitch(to: incoming, onlyUnsubmitted: true)
    #expect(incoming.batch(limit: 10).map(\.id) == [good.id])
    #expect(!FileManager.default.fileExists(atPath: damaged.path))
    #expect(outgoing.status.quarantined == 1 && outgoing.count == 1)
    #expect(try OutboxStore(dataDirectory: directory, key: key).quarantined == 1)
    let status = directory.appendingPathComponent("status.json")
    CollectorStatus.write([:], transcription: nil, outbox: outgoing.status, to: status)
    let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any]
    #expect(fields?["outboxQuarantined"] as? Int == 1)
  }
}

@Test @MainActor private func remoteSwitchChecksReturnPrerequisitesBeforePauseAndCancelsFailedVerification() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  let committed = fixture.current
  fixture.failPreflight = true
  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) {
    try await coordinator.switchBack { _ in Issue.record("Should not reconcile without a backup"); return true }
  }
  #expect(fixture.current == committed && fixture.saved?.step == .committed && !gate.isPaused)
  fixture.failPreflight = false
  await #expect(throws: RemoteSwitch.Failure.reconciliationIncomplete) {
    try await coordinator.switchBack(preflight: { _ in
      #expect(!gate.isPaused && fixture.current == committed)
      return false
    }, reconcile: { _ in Issue.record("Should not reconcile when prerequisites fail"); return true })
  }
  fixture.failProbe = true
  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) {
    try await coordinator.switchBack { _ in true }
  }
  #expect(fixture.current.phase == .committed && fixture.current.route == committed.route)
  #expect(fixture.saved?.step == .committed && fixture.loaded.isEmpty && !gate.isPaused)
  #expect(fixture.events.contains("discard-staged"))
}

@Test @MainActor private func remoteSwitchRestartCancelsStagedHubAndRequiresFreshReconciliation() async throws {
  let fixture = try SwitchFixture()
  let first = fixture.coordinator()
  try await first.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  fixture.crashAfter = "probe-start"
  await #expect(throws: (any Error).self) { try await first.switchBack { _ in true } }
  fixture.restart()
  let previouslyVerified = fixture.events.filter { $0 == "probe-verify" }.count
  let gate = RemoteSwitchWriteGate()
  let restarted = fixture.coordinator(gate: gate)
  try await restarted.recover()
  #expect(fixture.current.phase == .committed && fixture.current.generation == 1)
  #expect(fixture.saved?.step == .committed && fixture.loaded.isEmpty && !gate.isPaused)
  #expect(fixture.events.filter { $0 == "probe-verify" }.count == previouslyVerified)
  #expect(fixture.events.contains("discard-staged"))
}

@Test @MainActor private func remoteSwitchExplicitlyCancelsInterruptedReturnAndWaitsForBusyPublication() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  fixture.busyPublications = 1
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  #expect(fixture.events.contains("publication-busy"))
  fixture.crashAfter = "probe-start"
  await #expect(throws: (any Error).self) { try await coordinator.switchBack { _ in true } }
  fixture.restart()
  try await coordinator.cancelSwitchBack()
  #expect(fixture.current.phase == .committed && fixture.current.generation == 1)
  #expect(fixture.saved?.step == .committed && fixture.loaded.isEmpty && !gate.isPaused)
}

@Test private func remoteSwitchRetiredRemoteReceiptsDoNotCountAsPending() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let prepared = try preparedBinding()
  try prepared.write(to: directory, replacing: .legacyLocal)
  let remote = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
  try remote.write(to: directory, replacing: prepared)
  let local = HubBinding(generation: 2, target: .local, phase: .local)
  let key = SymmetricKey(size: .bits256)
  let open: (URL) throws -> OutboxStore = { try OutboxStore(dataDirectory: $0, key: key) }
  let old = try open(HubClient.outboxDirectory(in: directory, for: remote.route))
  let submitted = switchRecord()
  _ = try old.append(submitted)
  try old.markSubmitted([submitted.id])
  let eligible = switchRecord()
  var correction = switchRecord()
  correction.source = "manual.correction"
  _ = try old.append(eligible)
  _ = try old.append(correction)
  let gate = RemoteSwitchWriteGate()
  gate.setPaused(true)
  let client = HubClient(config: Config(dataDir: directory, bun: ""), writeGate: gate, openOutbox: open)
  _ = try await client.settleForSwitch()
  #expect(client.pendingCount == 3)
  let preview = try await client.switchBackPendingCount(on: remote.route)
  #expect(preview == 1)
  try await client.publishSwitch(previousLocal: prepared.route, from: remote.route, to: local.route) {
    try local.write(to: directory, replacing: remote)
  }
  try await client.finishSwitchBack(previousLocal: prepared.route, remote: remote.route, local: local.route)
  #expect(client.pendingCount == preview)
  let transferred = try open(HubClient.outboxDirectory(in: directory, for: local.route))
  #expect(transferred.restore(limit: 10).records.map(\.id) == [eligible.id])
  #expect(try open(HubClient.outboxDirectory(in: directory, for: remote.route)).count == 2)
  await #expect(throws: HubBinding.Failure.changed) { try await client.switchBackPendingCount(on: remote.route) }
}

@Test private func remoteSwitchRetryRebuildsUnpublishedTargetAfterSourceReceipt() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let prepared = try preparedBinding()
  try prepared.write(to: directory, replacing: .legacyLocal)
  let remote = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
  try remote.write(to: directory, replacing: prepared)
  let local = HubBinding(generation: 2, target: .local, phase: .local)
  let key = SymmetricKey(size: .bits256)
  let open: (URL) throws -> OutboxStore = { try OutboxStore(dataDirectory: $0, key: key) }
  let source = try open(HubClient.outboxDirectory(in: directory, for: remote.route))
  let acknowledged = switchRecord(), remaining = switchRecord()
  _ = try source.append(acknowledged)
  _ = try source.append(remaining)
  let staged = try open(HubClient.outboxDirectory(in: directory, for: local.route))
  try source.copyForSwitch(to: staged, onlyUnsubmitted: true)
  try source.acknowledge([acknowledged.id])
  let client = HubClient(config: Config(dataDir: directory, bun: ""), openOutbox: open)
  try await client.publishSwitch(previousLocal: prepared.route, from: remote.route, to: local.route) {
    try local.write(to: directory, replacing: remote)
  }
  #expect(try open(HubClient.outboxDirectory(in: directory, for: local.route)).restore(limit: 10).records.map(\.id) == [remaining.id])
}

@Test @MainActor private func remoteSwitchRereadsAgentLinkAndAcceptsMissingRemoteCache() throws {
  try withTempSwitchDirectory { directory in
    let prepared = try preparedBinding()
    try prepared.write(to: directory, replacing: .legacyLocal)
    let remote = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
    let identity = try #require(remote.remote)
    let persistence = DiskRemoteSwitchPersistence(directory: directory)
    let fixture = try SwitchFixture()
    let coordinator = RemoteSwitch(persistence: persistence, services: fixture, runtime: .init(
      gate: .init(), settled: { true }, suspendBonjour: { _ in }, publish: { _, _, _, _ in },
      bindingChanged: {}, finishCommit: { _, _ in }, finishReturn: { _, _, _ in }))
    #expect(!coordinator.agentNeedsDirectConnection)
    try remote.write(to: directory, replacing: prepared)
    try persistence.clearAgentContext(for: remote.route)
    #expect(coordinator.agentNeedsDirectConnection)
    let folder = directory.appendingPathComponent(identity.dir)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("agent-link.json")
    try PrivateFile.write(Data("{}".utf8), to: link)
    #expect(!coordinator.agentNeedsDirectConnection)
    try FileManager.default.removeItem(at: link)
    #expect(coordinator.agentNeedsDirectConnection)
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: directory.appendingPathComponent("missing"))
    #expect(throws: (any Error).self) { try persistence.clearAgentContext(for: remote.route) }
  }
}

@Test(ChineseUITrait()) private func remoteSwitchLoginChangesAreBlockedBeforeCheckpointExists() throws {
  try withTempSwitchDirectory { directory in
    let gate = RemoteSwitchWriteGate()
    let startup = LoginStartup(home: directory, dataDir: directory, beginWrite: gate.begin, endWrite: gate.end)
    try FileManager.default.createDirectory(at: startup.agents, withIntermediateDirectories: true)
    for job in LoginStartup.jobs { try Data().write(to: startup.file(job, enabled: true)) }
    let prepared = try preparedBinding()
    try prepared.write(to: directory, replacing: .legacyLocal)
    gate.setPaused(true)
    do {
      try startup.setEnabled(false)
      Issue.record("Login startup moved while paused")
    } catch {
      #expect(error.localizedDescription == "后台正在切换，登录启动暂时无法更改。")
    }
    #expect(gate.isIdle && startup.enabled)
    gate.setPaused(false)
    try startup.setEnabled(false)
    #expect(gate.isIdle && !startup.enabled)
  }
}

@Test private func remoteSwitchAudioRecoversInterruptedTargetConversation() throws {
  try withTempSwitchDirectory { directory in
    let key = SymmetricKey(size: .bits256)
    let openStore: (URL) throws -> AudioStore = { try AudioStore(dataDirectory: $0, key: key) }
    let prepared = try preparedBinding()
    let binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
    let remote = try #require(binding.remote)
    let remoteStore = try openStore(directory.appendingPathComponent(remote.dir).appendingPathComponent("audio-generation-1"))
    let local = HubBinding(generation: 2, target: .local, phase: .local)
    let target = try openStore(directory)
    let start = Date(), end = start.addingTimeInterval(10)
    var interrupted = AudioMetadata(start: start)
    interrupted.segments = [AudioSegment(file: "mic-0001.enc", track: .mic, start: start, end: end, dbfs: -12)]
    try target.writeMetadata(interrupted)
    let audio = AudioCoordinator(config: Config(dataDir: directory, bun: ""),
                                 openStore: openStore, initialStorage: (binding.route, remoteStore))
    var published = false
    try audio.publishSwitch(to: local.route) {
      let restored = try target.conversations()
      #expect(restored.first?.status == .closed)
      published = true
    }
    #expect(published)
    #expect(try target.conversations().first?.t_end == LocalTime.iso(end))
  }
}

private final class FakeSwitchLaunchd {
  let directory: URL
  let startup: LoginStartup
  var registered: [String: String] = [:]
  var commands: [[String]] = []
  var failFormalBootstrap = false
  var probeStatus = 200
  var probePID = 2468
  var openedForWriting = true
  var requests: [URLRequest] = []

  init(directory: URL) {
    self.directory = directory
    startup = LoginStartup(home: directory, dataDir: directory)
  }

  var staged: URL { directory.appendingPathComponent("dev.record-anything.hub.switch-back.plist") }
  var database: URL { directory.appendingPathComponent("history.db") }

  func execute(_ executable: String, _ args: [String], _ timeout: TimeInterval)
    throws -> LaunchdRemoteSwitchServices.CommandResult {
    #expect(!Thread.isMainThread)
    commands.append(args)
    #expect(timeout == (args.first == "bootout" ? 30 : 5))
    if executable == "/usr/sbin/lsof" {
      #expect(args.last == database.path)
      return args.contains("-t")
        ? .init(status: 1, stdout: "")
        : .init(status: 0, stdout: openedForWriting ? "p2468\nau\n" : "p2468\nar\n")
    }
    #expect(executable == "/bin/launchctl")
    let last = try #require(args.last)
    let job = URL(fileURLWithPath: last).lastPathComponent
    switch args.first {
    case "print":
      if let definition = registered[job] { return .init(status: 0, stdout: "path = \(definition)\npid = 2468\n") }
      return .init(status: last.hasPrefix("gui/") && !job.hasPrefix("dev.") ? 0 : 113, stdout: "")
    case "bootout":
      registered.removeValue(forKey: job)
      return .init(status: 0, stdout: "")
    case "bootstrap":
      let isStaged = last == staged.path
      if !isStaged && failFormalBootstrap { return .init(status: 5, stdout: "") }
      let label = isStaged ? LocalSwitchJob.hub.label : URL(fileURLWithPath: last).deletingPathExtension().lastPathComponent
      registered[label] = last
      return .init(status: 0, stdout: "")
    default:
      Issue.record("Unexpected launchd command")
      return .init(status: -1, stdout: "")
    }
  }

  func probe(_ request: URLRequest) async throws -> DeviceTransportResponse {
    requests.append(request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    if request.url?.path == "/v1/audio/settings" {
      #expect(request.timeoutInterval == 3)
      return .init(statusCode: 200, body: Data(#"{"retention_days":0}"#.utf8))
    }
    #expect(request.timeoutInterval == 10)
    if request.url?.path == "/v1/status" {
      return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
        "hub": ["pid": probePID], "database": ["file": database.path],
      ]))
    }
    #expect(request.url?.path == "/v1/audio/sync/ack" && request.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
    let device = try #require(body?["device"] as? String)
    #expect(device.hasPrefix("switch-probe-") && UUID(uuidString: String(device.dropFirst("switch-probe-".count))) != nil)
    #expect(body?["deleted"] as? [String] == [])
    #expect(body?["purged_at"] == nil)
    return .init(statusCode: probeStatus, body: Data(#"{"acknowledged":true}"#.utf8))
  }

  func services(verificationTimeout: TimeInterval = 0) -> LaunchdRemoteSwitchServices {
    LaunchdRemoteSwitchServices(config: Config(dataDir: directory, bun: ""), startup: startup,
                               execute: execute, probe: probe, pidIsRunning: { _ in false }, verificationTimeout: verificationTimeout)
  }

  func install(distill: Bool) throws {
    try FileManager.default.createDirectory(at: startup.agents, withIntermediateDirectories: true)
    for job in LoginStartup.jobs {
      let path = startup.file(job, enabled: true)
      let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": "dev.record-anything." + job],
                                                     format: .xml, options: 0)
      try plist.write(to: path)
      if job != "collector" { registered["dev.record-anything." + job] = path.path }
    }
    try Data([1]).write(to: database)
    try Data("test-token".utf8).write(to: directory.appendingPathComponent("token"))
    try JSONSerialization.data(withJSONObject: ["distill": distill]).write(to: directory.appendingPathComponent("app-setup.json"))
  }
}

@Test @MainActor private func remoteSwitchLaunchdUsesWriteProbeOnlyAfterVerifyingIdentity() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let launchd = FakeSwitchLaunchd(directory: directory)
  try launchd.install(distill: true)
  let services = launchd.services()
  launchd.probePID = 999
  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) { try await services.verifyLocalHub() }
  #expect(launchd.requests.map { $0.url?.path } == ["/v1/status"])
  launchd.requests = []
  launchd.openedForWriting = false
  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) { try await services.verifyLocalHub() }
  #expect(launchd.requests.isEmpty)
  launchd.openedForWriting = true
  launchd.probePID = 2468
  launchd.probeStatus = 503
  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) { try await services.verifyLocalHub() }
  #expect(launchd.requests.map { $0.url?.path } == ["/v1/status", "/v1/audio/sync/ack"])
  launchd.probeStatus = 200
  try await services.verifyLocalHub()
}

@Test(arguments: [false, true])
@MainActor private func remoteSwitchLaunchdRecoversDefinitionsAndRelinksFormalPlist(distill: Bool) async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let launchd = FakeSwitchLaunchd(directory: directory)
  try launchd.install(distill: distill)
  let services = launchd.services()
  let saved = try await services.snapshot()
  #expect(saved.loginEnabled && saved.hub.loaded && saved.distillEnabled == distill && saved.audioRetentionDays == 0)
  await #expect(throws: RemoteSwitch.Failure.databaseInUse) { try await services.verifyClosedDatabase() }
  for job in LocalSwitchJob.allCases { try await services.stop(job) }
  try await services.verifyClosedDatabase()
  try await services.withdrawDefinitions()
  try await services.restore(saved, afterSwitchBack: false)
  #expect(launchd.registered.count == 2)
  for job in LocalSwitchJob.allCases { try await services.stop(job) }
  try await services.withdrawDefinitions()

  let formalHub = launchd.startup.file("hub", enabled: true)
  try await services.startHubForVerification(saved)
  #expect(launchd.registered[LocalSwitchJob.hub.label] == launchd.staged.path)
  launchd.failFormalBootstrap = true
  await #expect(throws: RemoteSwitch.Failure.servicesUnavailable) { try await services.restore(saved, afterSwitchBack: true) }
  #expect(FileManager.default.fileExists(atPath: launchd.staged.path))
  launchd.failFormalBootstrap = false
  try await services.restore(saved, afterSwitchBack: true)
  #expect(launchd.registered[LocalSwitchJob.hub.label] == formalHub.path)
  #expect((launchd.registered[LocalSwitchJob.distill.label] != nil) == distill)
  #expect(!FileManager.default.fileExists(atPath: launchd.staged.path))
  #expect(launchd.commands.contains { $0.first == "bootout" })
}

@Test private func remoteSwitchCommandSeparatesStderrAndReportsTimeout() throws {
  let read = try LaunchdRemoteSwitchServices.runProcess("/bin/sh", ["-c", "printf 'warning' >&2; exit 1"], 5)
  #expect(read.status == 1 && read.stdout.isEmpty)
  let write = try LaunchdRemoteSwitchServices.runProcess("/bin/sh", ["-c", "printf 'au\\n'; printf 'ar\\n' >&2"], 5)
  #expect(write.stdout == "au\n")
  #expect(throws: RemoteSwitch.Failure.commandTimedOut("sleep")) {
    try LaunchdRemoteSwitchServices.runProcess("/bin/sleep", ["2"], 0.05)
  }
}

@Test(arguments: ["save-cancelling", "stop-hub", "discard-staged", "bind-committed"])
@MainActor private func remoteSwitchContinuesInterruptedCancellation(step: String) async throws {
  let fixture = try SwitchFixture()
  let coordinator = fixture.coordinator()
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  fixture.failProbe = true
  fixture.crashAfter = step
  await #expect(throws: RemoteSwitch.Failure.recoveryFailed) {
    try await coordinator.switchBack { _ in true }
  }
  fixture.restart()
  let gate = RemoteSwitchWriteGate()
  try await fixture.coordinator(gate: gate).recover()
  #expect(fixture.current.phase == .committed && fixture.current.generation == 1)
  #expect(fixture.saved?.step == .committed && fixture.loaded.isEmpty && !gate.isPaused)
}

@Test private func remoteSwitchAudioUsesFreshRetentionSnapshotAfterRestart() throws {
  try withTempSwitchDirectory { directory in
    let fixture = try SwitchFixture()
    let persistence = DiskRemoteSwitchPersistence(directory: directory)
    var local = fixture.local
    local.audioRetentionDays = 0
    let checkpoint = RemoteSwitchCheckpoint(step: .committed, prepared: fixture.prepared, local: local,
                                            agentNeedsDirectConnection: false)
    try persistence.save(checkpoint)
    try JSONSerialization.data(withJSONObject: ["retention_days": 7])
      .write(to: directory.appendingPathComponent("collector-audio-state.json"))
    let remote = try #require(checkpoint.remote.remote)
    let folder = directory.appendingPathComponent(remote.dir).appendingPathComponent("audio-generation-1")
    let store = try AudioStore(dataDirectory: folder, key: SymmetricKey(size: .bits256))
    let start = Date().addingTimeInterval(-40 * 86_400)
    var done = AudioMetadata(start: start)
    done.t_end = LocalTime.iso(start)
    try done.transition(to: .closed, at: start)
    try done.transition(to: .done, at: start)
    try store.writeMetadata(done)
    let audio = AudioCoordinator(config: Config(dataDir: directory, bun: ""),
                                 initialStorage: (checkpoint.remote.route, store))
    audio.update(enabled: false)
    audio.shutdown()
    #expect(try store.conversations() == [done])
  }
}

// B2 第 2 轮审查回归：发布失败时撤掉目标代次的副本；退出前的最后输出不丢；路径经符号链接也算同一个。
@Test private func B2Round2FailedPublicationDropsTargetCopies() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = SymmetricKey(size: .bits256)
  let open: (URL) throws -> OutboxStore = { try OutboxStore(dataDirectory: $0, key: key) }
  let gate = RemoteSwitchWriteGate()
  let client = HubClient(config: Config(dataDir: directory, bun: ""), writeGate: gate, openOutbox: open)
  let prepared = try preparedBinding()
  try prepared.write(to: directory, replacing: .legacyLocal)
  let next = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
  client.enqueue([switchRecord()])
  gate.setPaused(true)
  _ = try await client.settleForSwitch()
  await #expect(throws: SwitchFault.interrupted) {
    try await client.publishSwitch(previousLocal: nil, from: prepared.route, to: next.route) { throw SwitchFault.interrupted }
  }
  #expect(try open(HubClient.outboxDirectory(in: directory, for: next.route)).count == 0)
  #expect(try open(directory).count == 1)
}

@Test private func B2Round2CommandKeepsOutputWrittenRightBeforeExit() throws {
  for _ in 0..<40 {
    let result = try LaunchdRemoteSwitchServices.runProcess("/bin/sh", ["-c", "sleep 0.02; printf 'pid = 42\\n'"], 5)
    #expect(result.stdout == "pid = 42\n")
  }
}

@Test private func B2Round2LaunchdPathsMatchThroughSymlinks() throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let real = directory.appendingPathComponent("real", isDirectory: true)
  try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
  let file = real.appendingPathComponent("job.plist")
  try Data().write(to: file)
  let link = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
  #expect(LaunchdRemoteSwitchServices.samePath(file.path, link.appendingPathComponent("job.plist")))
  #expect(!LaunchdRemoteSwitchServices.samePath(nil, file))
  #expect(!LaunchdRemoteSwitchServices.samePath(directory.appendingPathComponent("other.plist").path, file))
}

@Test @MainActor private func remoteSwitchRequiresExplicitEmptyHistoryBeforeStartingLocalHub() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let launchd = FakeSwitchLaunchd(directory: directory)
  try launchd.install(distill: false)
  let services = launchd.services(verificationTimeout: 2)
  var saved = try await services.snapshot()
  for job in LocalSwitchJob.allCases { try await services.stop(job) }
  try FileManager.default.removeItem(at: launchd.database)

  await #expect(throws: RemoteSwitch.Failure.localHubUnverified) {
    try await services.startHubForVerification(saved)
  }
  #expect(launchd.registered[LocalSwitchJob.hub.label] == nil)
  saved.allowEmptyHistory = true
  try await services.startHubForVerification(saved)
  #expect(launchd.registered[LocalSwitchJob.hub.label] == launchd.staged.path)
  let createDatabase = Task { @MainActor in
    try await Task.sleep(for: .milliseconds(30))
    try Data([1]).write(to: launchd.database)
  }
  defer { createDatabase.cancel() }
  try await services.verifyLocalHub()
  try await createDatabase.value
  #expect(launchd.requests.last?.url?.path == "/v1/audio/sync/ack")
}

@Test private func remoteSyncReplyReleasesGateAfterCoordinatorIsReleased() throws {
  try withTempSwitchDirectory { directory in
    let gate = RemoteSwitchWriteGate()
    var coordinator: AudioCoordinator? = AudioCoordinator(config: Config(dataDir: directory, bun: ""), writeGate: gate)
    try gate.begin()
    let reply = try #require(coordinator).syncReplyHandler(on: .local)
    weak let released = coordinator
    coordinator = nil
    #expect(released == nil)
    #expect(!gate.isIdle)
    reply(nil, nil)
    #expect(gate.isIdle)
  }
}

@Test private func remoteSyncDeletesOnlyExplicitTargetsAndExpiredCompletedAudio() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let prepared = try preparedBinding()
  let binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: prepared.remote)
  try prepared.write(to: directory, replacing: .legacyLocal)
  try binding.write(to: directory, replacing: prepared)
  let remote = try #require(binding.remote)

  let gate = RemoteSwitchWriteGate()
  let store = try AudioStore(dataDirectory: directory.appendingPathComponent(remote.dir)
    .appendingPathComponent("audio-generation-1"), key: SymmetricKey(size: .bits256))
  func closed(daysOld: Double, done: Bool = false) throws -> String {
    let start = Date().addingTimeInterval(-daysOld * 86_400)
    var meta = AudioMetadata(start: start)
    meta.t_end = LocalTime.iso(start)
    try meta.transition(to: .closed, at: start)
    if done { try meta.transition(to: .done, at: start) }
    try store.writeMetadata(meta)
    return meta.id
  }
  let keep = try closed(daysOld: 8)
  let explicit = try closed(daysOld: 1)
  let purge = try closed(daysOld: 20)
  _ = try closed(daysOld: 8, done: true)
  let coordinator = AudioCoordinator(config: Config(dataDir: directory, bun: ""), writeGate: gate,
                                     initialStorage: (binding.route, store))
  let reply = try JSONSerialization.data(withJSONObject: [
    "retention_days": 7, "delete_conversations": [explicit],
    "purge_before": LocalTime.iso(Date().addingTimeInterval(-15 * 86_400)),
  ])
  try gate.begin()
  coordinator.syncReplyHandler(on: binding.route)(reply, "mac-abcd2345")
  for _ in 0..<150 where !gate.isIdle { try await Task.sleep(for: .milliseconds(10)) }

  #expect(gate.isIdle)
  let remaining = try store.conversations(readOnly: true).map(\.id)
  #expect(remaining == [keep])
  #expect(!remaining.contains(purge))
}

@Test @MainActor private func historyBackupDeleteBlockedDuringReturnPreflight() async throws {
  let fixture = try SwitchFixture()
  let gate = RemoteSwitchWriteGate()
  let coordinator = fixture.coordinator(gate: gate)
  try await coordinator.commit(prepared: fixture.prepared, agentNeedsDirectConnection: false)
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let backup = directory.appendingPathComponent("history.db")
  try Data("synthetic backup".utf8).write(to: backup)
  let binding = fixture.current
  let remote = try #require(binding.remote)
  var state = HistoryImportJournal(generation: binding.generation)
  state.sourceCheckedGeneration = binding.generation
  state.attempt = .init(snapshot: "fixture", total: 0, pageSize: 40, privateCount: 0, finished: true)
  try HistoryImportJournalFile.write(JSONEncoder().encode(state), in: directory, for: remote)
  let history = HistoryImporter(directory: directory, gate: gate, operations: .init(
    binding: { fixture.current }, budget: { _ in throw SwitchFault.offline },
    send: { _, _, _ in throw SwitchFault.offline }, export: { _, _ in throw SwitchFault.offline },
    apply: { _ in throw SwitchFault.offline }
  ))
  #expect(try history.backupInfo().canDelete)
  await #expect(throws: RemoteSwitch.Failure.reconciliationIncomplete) {
    try await coordinator.switchBack(preflight: { _ in
      #expect(!gate.isPaused)
      #expect((try? history.backupInfo().canDelete) == false)
      do { try await history.deleteBackup(); Issue.record("Deletion started during return preflight") }
      catch HistoryImporter.Failure.deletionBlocked { }
      catch { Issue.record("Unexpected deletion error: \(error)") }
      #expect(FileManager.default.fileExists(atPath: backup.path))
      return false
    }, reconcile: { _ in Issue.record("Preflight failed"); return false })
  }
  #expect(try history.backupInfo().canDelete)
}

@Test private func localHistoryPreviewUsesReadOnlyCommandAndSurfacesUnreadableDatabase() async throws {
  let directory = try tempSwitchDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let entry = directory.appendingPathComponent("hub/src/cli.ts")
  try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("""
    test "$#" -eq 4 && test "$1" = history-export && test "$2" = --preview \\
      && test "$3" = --data-dir && test "$4" = "\(directory.path)" || exit 2
    printf '%s\\n' '{"total":7,"private_count":3}'
    """.utf8).write(to: entry)
  let config = Config(dataDir: directory, repo: directory.path, bun: "/bin/sh")
  let counts = try await LocalHistoryPreview.load(config: config)
  #expect(counts.total == 7 && counts.privateCount == 3)
  try Data("exit 1\n".utf8).write(to: entry)
  await #expect(throws: LocalHistoryPreview.Failure.unavailable) {
    try await LocalHistoryPreview.load(config: config)
  }
}

@Test private func rePairingCopiesSubmittedMarkersBeforePublishing() throws {
  try withTempSwitchDirectory { directory in
    let key = SymmetricKey(size: .bits256)
    let source = try OutboxStore(dataDirectory: directory.appendingPathComponent("old"), key: key)
    let target = try OutboxStore(dataDirectory: directory.appendingPathComponent("new"), key: key)
    let submitted = switchRecord(), unsent = switchRecord()
    for item in [submitted, unsent] { _ = try source.append(item) }
    try source.markSubmitted([submitted.id])
    try source.copyForSwitch(to: target, onlyUnsubmitted: false)
    #expect(target.count == 2)
    #expect(try target.switchableCount(onlyUnsubmitted: true) == 1)
  }
}
