import CollectorCore
import Foundation

enum LocalSwitchJob: String, CaseIterable, Codable {
  case distill, hub
  var label: String { "dev.record-anything." + rawValue }
}

struct LocalSwitchSnapshot: Codable, Equatable {
  struct Definition: Codable, Equatable {
    let plist: Data
    let login: Bool
    let loaded: Bool
  }

  let hub: Definition
  let distill: Definition?
  let loginEnabled: Bool
  let distillEnabled: Bool
  var audioRetentionDays: Int? = nil
  var allowEmptyHistory: Bool? = nil

  subscript(job: LocalSwitchJob) -> Definition? { job == .hub ? hub : distill }
}

struct RemoteSwitchCheckpoint: Codable, Equatable {
  enum Step: String, Codable {
    case committing, committed, reconciling, reconciled, cancelling
  }

  static let currentVersion = 1
  var version = Self.currentVersion
  var step: Step
  let prepared: HubBinding
  var local: LocalSwitchSnapshot
  let agentNeedsDirectConnection: Bool
  var activeRemoteGeneration: Int? = nil

  var remote: HubBinding {
    HubBinding(generation: activeRemoteGeneration ?? prepared.generation + 1, target: .remote, phase: .committed, remote: prepared.remote)
  }
  var returned: HubBinding {
    HubBinding(generation: remote.generation + 1, target: .local, phase: .local)
  }

  func validate() throws {
    guard version == Self.currentVersion, prepared.phase == .preparing,
          prepared.generation <= 9_007_199_254_740_989,
          (prepared.generation + 1...9_007_199_254_740_990).contains(remote.generation) else { throw RemoteSwitch.Failure.invalidCheckpoint }
  }
}

protocol RemoteSwitchPersistence {
  func binding() throws -> HubBinding
  func publish(_ next: HubBinding, replacing previous: HubBinding) throws
  func checkpoint() throws -> RemoteSwitchCheckpoint?
  func save(_ checkpoint: RemoteSwitchCheckpoint) throws
  func clearCheckpoint() throws
  func hasAgentLink(for remote: HubBinding.Remote) -> Bool
  func clearAgentContext(for route: HubBinding.Route) throws
}

protocol RemoteSwitchServices {
  func snapshot() async throws -> LocalSwitchSnapshot
  func stop(_ job: LocalSwitchJob) async throws
  func verifyClosedDatabase() async throws
  func withdrawDefinitions() async throws
  func preflightReturn(_ local: LocalSwitchSnapshot) async throws
  func discardStagedHub() async throws
  func startHubForVerification(_ local: LocalSwitchSnapshot) async throws
  func verifyLocalHub() async throws
  func restore(_ local: LocalSwitchSnapshot, afterSwitchBack: Bool) async throws
}

/// The only write that changes the active target is persistence.publish. Recovery uses its
/// generation to tell a completed publication from an interrupted step in the checkpoint.
@MainActor final class RemoteSwitch {
  enum Failure: LocalizedError, Equatable {
    case busy, invalidCheckpoint, drainTimedOut, outboxNotPersisted, reconciliationIncomplete
    case servicesUnavailable, databaseInUse, localHubUnverified, recoveryFailed, commandTimedOut(String)

    var errorDescription: String? {
      switch self {
      case .busy: return "后台切换已经在进行。"
      case .invalidCheckpoint: return "无法核对上一次后台切换的状态。"
      case .drainTimedOut: return "后台仍有操作未确认，等待超时。"
      case .outboxNotPersisted: return "待发送记录尚未安全保存。"
      case .reconciliationIncomplete: return "远端删除和私密变更尚未核对完成。"
      case .servicesUnavailable: return "无法停止或恢复这台 Mac 的后台服务。"
      case .databaseInUse: return "本机数据库仍在使用或未安全关闭。"
      case .localHubUnverified: return "无法验证本机后台的身份或写入状态。"
      case .commandTimedOut(let command): return "\(command) 等待超时。"
      case .recoveryFailed: return "后台切换仍需恢复，已保留进度。"
      }
    }
  }

  typealias Reconcile = (_ remote: HubBinding.Route) async throws -> Bool

  struct Runtime {
    let gate: RemoteSwitchWriteGate
    var settled: () async throws -> Bool
    var suspendBonjour: (Bool) -> Void
    /// Serialize queued capture with publication. Copy eligible records before changing the binding.
    var publish: (HubBinding.Route?, HubBinding.Route, HubBinding.Route, @escaping () throws -> Void) async throws -> Void
    var bindingChanged: () async -> Void
    var finishCommit: (HubBinding.Route, HubBinding.Route) async throws -> Void
    var finishReturn: (HubBinding.Route, HubBinding.Route, HubBinding.Route) async throws -> Void
  }

  private let persistence: any RemoteSwitchPersistence
  private let services: any RemoteSwitchServices
  private let runtime: Runtime
  private let pairing: RemotePairing?
  private let drainTimeout: TimeInterval
  private var running = false
  private(set) var lastFailure: String?

  init(persistence: any RemoteSwitchPersistence, services: any RemoteSwitchServices,
       runtime: Runtime, pairing: RemotePairing? = nil, drainTimeout: TimeInterval = 30) {
    self.persistence = persistence
    self.services = services
    self.runtime = runtime
    self.pairing = pairing
    self.drainTimeout = drainTimeout
  }

  var agentNeedsDirectConnection: Bool {
    guard let remote = try? persistence.binding().route.remote else { return false }
    return !persistence.hasAgentLink(for: remote)
  }

  func commit(prepared: RemotePairing.Prepared) async throws {
    try await commit(prepared: prepared.binding, agentNeedsDirectConnection: prepared.agentNeedsDirectConnection)
  }

  func commit(prepared: HubBinding, agentNeedsDirectConnection: Bool) async throws {
    if let pairing {
      try await pairing.withPreparedCommit(prepared) {
        try await self.commitSwitch(prepared, agentNeedsDirectConnection: agentNeedsDirectConnection)
      }
    } else {
      try await commitSwitch(prepared, agentNeedsDirectConnection: agentNeedsDirectConnection)
    }
  }

  private func commitSwitch(_ prepared: HubBinding, agentNeedsDirectConnection: Bool) async throws {
    try begin()
    defer { running = false }
    guard prepared.phase == .preparing, try persistence.binding() == prepared,
          try persistence.checkpoint() == nil else { throw HubBinding.Failure.changed }
    runtime.gate.setPaused(true)
    do {
      // An app upgrade already in progress holds a lease and must finish before we snapshot.
      try await drain()
      let checkpoint = RemoteSwitchCheckpoint(step: .committing, prepared: prepared, local: try await services.snapshot(),
                                              agentNeedsDirectConnection: agentNeedsDirectConnection)
      try checkpoint.validate()
      try persistence.save(checkpoint)
      try await stopLocalServices()
      try await services.verifyClosedDatabase()
      try await services.withdrawDefinitions()
      runtime.suspendBonjour(true)
      try persistence.clearAgentContext(for: prepared.route)
      try await services.verifyClosedDatabase()
      let next = checkpoint.remote
      try await publish(nil, from: prepared.route, to: next.route) { [persistence] in
        try persistence.publish(next, replacing: prepared)
      }
      try await finishCommit(checkpoint)
    } catch {
      do { try await Task { @MainActor in try await recoverState() }.value }
      catch { throw record(.recoveryFailed) }
      if (try? persistence.binding().phase) == .committed { return }
      lastFailure = error.localizedDescription
      throw error
    }
  }

  func commitRePairing(_ prepared: RemotePairing.PreparedRePairing) async throws {
    try begin()
    defer { running = false }
    guard let pairing, let checkpoint = try persistence.checkpoint(), checkpoint.step == .committed,
          checkpoint.remote.route == prepared.previous.route else { throw Failure.invalidCheckpoint }
    runtime.gate.setPaused(true)
    do {
      try await drain()
      try persistence.clearAgentContext(for: prepared.previous.route)
      try await pairing.commitRePairing(prepared, publish: { from, to, commit in
        try await self.publish(nil, from: from, to: to, commit: commit)
      }, finish: { try await self.finishRePairing($0) })
      await runtime.bindingChanged()
      runtime.gate.setPaused(false)
    } catch RemotePairing.Failure.recoveryRequired {
      throw record(.recoveryFailed)
    } catch {
      runtime.gate.setPaused(false)
      throw error
    }
  }

  private func finishRePairing(_ prepared: RemotePairing.PreparedRePairing) async throws {
    guard var checkpoint = try persistence.checkpoint(), checkpoint.step == .committed,
          checkpoint.remote.route == prepared.previous.route || checkpoint.remote.route == prepared.binding.route else {
      throw Failure.invalidCheckpoint
    }
    checkpoint.activeRemoteGeneration = prepared.binding.generation
    try checkpoint.validate()
    try persistence.save(checkpoint)
    try await runtime.finishCommit(prepared.previous.route, prepared.binding.route)
  }

  /// Read-only prerequisites run with the remote route still writable. The reconciliation itself
  /// runs after draining writers so its result cannot be overtaken by an outgoing local write.
  func switchBack(allowEmptyHistory: Bool = false, preflight: Reconcile = { _ in true }, reconcile: Reconcile) async throws {
    try begin()
    runtime.gate.setReturning(true)
    defer { runtime.gate.setReturning(false); running = false }
    var returning: RemoteSwitchCheckpoint?
    do {
      let current = try persistence.binding()
      guard current.phase == .committed, var saved = try persistence.checkpoint(),
            saved.step == .committed, current.route == saved.remote.route else { throw Failure.invalidCheckpoint }
      try saved.validate()
      saved.local.allowEmptyHistory = allowEmptyHistory ? true : nil
      try await services.preflightReturn(saved.local)
      guard try await preflight(current.route) else { throw Failure.reconciliationIncomplete }
      try Task.checkCancellation()

      runtime.gate.setPaused(true)
      returning = saved
      try await drain()
      var checkpoint = saved
      checkpoint.step = .reconciling
      try persistence.save(checkpoint)
      guard try await reconcile(current.route) else { throw Failure.reconciliationIncomplete }
      try Task.checkCancellation()
      checkpoint.step = .reconciled
      try persistence.save(checkpoint)
      let switching = HubBinding(generation: current.generation, target: .remote, phase: .switching_back,
                                 remote: current.remote)
      try persistence.publish(switching, replacing: current)
      try await finishReturn(checkpoint, switching: switching)
    } catch {
      if let returning {
        // Cancellation of the request must still let rollback wait for the staged process to exit.
        do {
          try await Task { @MainActor in
            if try persistence.binding().route == returning.remote.route {
              try await cancelReturn(try persistence.checkpoint() ?? returning)
            } else {
              try await recoverState()
            }
          }.value
        } catch { throw record(.recoveryFailed) }
        if (try? persistence.binding().route) == returning.returned.route { return }
      }
      lastFailure = error.localizedDescription
      throw error
    }
  }

  /// Cancel an interrupted return before publication. A published local route is recovered in place.
  func cancelSwitchBack() async throws {
    try begin()
    defer { running = false }
    guard let checkpoint = try persistence.checkpoint(), checkpoint.step != .committing else {
      throw record(.invalidCheckpoint)
    }
    try checkpoint.validate()
    do {
      if (try? persistence.binding().route) == checkpoint.returned.route {
        // 本机路由已经发布：不能再退回远端，按启动恢复把切回收尾。
        try await Task { @MainActor in try await recoverState() }.value
      } else {
        try await Task { @MainActor in try await cancelReturn(checkpoint) }.value
      }
    } catch { lastFailure = error.localizedDescription; throw error }
  }

  func rePairingState() throws -> RemotePairing.RePairingState {
    try pairing?.rePairingState() ?? .idle
  }

  func cancelRePairing() async throws {
    try begin()
    defer { running = false }
    guard let pairing else { throw Failure.invalidCheckpoint }
    if case .recovery(canCancel: false) = try pairing.rePairingState() { throw Failure.invalidCheckpoint }
    do {
      try await pairing.cancelRePairing()
      runtime.gate.setPaused(false)
    } catch {
      if let state = try? pairing.rePairingState() {
        if case .recovery = state {} else { runtime.gate.setPaused(false) }
      }
      throw error
    }
  }

  func recover() async throws {
    try begin()
    defer { running = false }
    runtime.gate.setPaused(true)
    do {
      let repair = try rePairingState()
      try await pairing?.recoverRePairing(finish: { try await self.finishRePairing($0) })
      try await recoverState()
      try await pairing?.finishPreparedCommit()
      if case .recovery = repair { await runtime.bindingChanged() }
    } catch {
      runtime.gate.setPaused(true)
      runtime.suspendBonjour(true)
      lastFailure = error.localizedDescription
      throw error
    }
  }

  private func begin() throws {
    guard !running else { throw Failure.busy }
    running = true
    lastFailure = nil
  }

  private func drain() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + drainTimeout
    while true {
      if runtime.gate.isIdle, try await runtime.settled() { return }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.drainTimedOut }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private func stopLocalServices() async throws {
    for job in LocalSwitchJob.allCases { try await services.stop(job) }
  }

  private func publish(_ previousLocal: HubBinding.Route?, from: HubBinding.Route, to: HubBinding.Route,
                       commit: @escaping () throws -> Void) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + drainTimeout
    while true {
      do { try await runtime.publish(previousLocal, from, to, commit); return }
      catch Failure.busy {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.drainTimedOut }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  private func finishCommit(_ checkpoint: RemoteSwitchCheckpoint) async throws {
    try await pairing?.finishPreparedCommit()
    try await runtime.finishCommit(checkpoint.prepared.route, checkpoint.remote.route)
    try persistence.clearAgentContext(for: checkpoint.prepared.route)
    var finished = checkpoint
    finished.step = .committed
    try persistence.save(finished)
    await runtime.bindingChanged()
    runtime.gate.setPaused(false)
  }

  private func cancelReturn(_ checkpoint: RemoteSwitchCheckpoint) async throws {
    let current = try persistence.binding()
    guard current.route == checkpoint.remote.route,
          current.phase == .committed || current.phase == .switching_back else { throw Failure.invalidCheckpoint }
    runtime.gate.setPaused(true)
    runtime.suspendBonjour(true)
    var restored = checkpoint
    if current.phase == .switching_back {
      restored.step = .cancelling
      try persistence.save(restored)
      try await stopLocalServices()
      try await services.discardStagedHub()
      try persistence.publish(checkpoint.remote, replacing: current)
    }
    if restored.step != .committed {
      restored.step = .committed
      restored.local.allowEmptyHistory = nil
      try persistence.save(restored)
    }
    runtime.gate.setPaused(false)
  }

  private func finishReturn(_ checkpoint: RemoteSwitchCheckpoint, switching: HubBinding) async throws {
    let next = checkpoint.returned
    try await services.startHubForVerification(checkpoint.local)
    try await services.verifyLocalHub()
    try Task.checkCancellation()
    try persistence.clearAgentContext(for: switching.route)
    try await publish(checkpoint.prepared.route, from: switching.route, to: next.route) { [persistence] in
      try persistence.publish(next, replacing: switching)
    }
    try await finishPublishedReturn(checkpoint)
  }

  private func finishPublishedReturn(_ checkpoint: RemoteSwitchCheckpoint) async throws {
    try await services.restore(checkpoint.local, afterSwitchBack: true)
    try persistence.clearAgentContext(for: checkpoint.remote.route)
    try await runtime.finishReturn(checkpoint.prepared.route, checkpoint.remote.route, checkpoint.returned.route)
    await runtime.bindingChanged()
    try persistence.clearCheckpoint()
    runtime.suspendBonjour(false)
    runtime.gate.setPaused(false)
  }

  private func recoverState() async throws {
    let binding = try persistence.binding()
    guard let checkpoint = try persistence.checkpoint() else {
      guard binding.phase != .switching_back else { throw Failure.invalidCheckpoint }
      runtime.suspendBonjour(binding.route.remote != nil)
      runtime.gate.setPaused(false)
      return
    }
    try checkpoint.validate()
    runtime.gate.setPaused(true)
    switch binding.phase {
    case .preparing where binding == checkpoint.prepared && checkpoint.step == .committing,
         .local where binding.route == checkpoint.prepared.route && checkpoint.step == .committing:
      try await services.restore(checkpoint.local, afterSwitchBack: false)
      try persistence.clearCheckpoint()
      runtime.suspendBonjour(false)
      runtime.gate.setPaused(false)
    case .committed where binding.route == checkpoint.remote.route:
      runtime.suspendBonjour(true)
      switch checkpoint.step {
      case .committing: try await finishCommit(checkpoint)
      case .committed: runtime.gate.setPaused(false)
      case .reconciling, .reconciled, .cancelling: try await cancelReturn(checkpoint)
      }
    case .switching_back where binding.route == checkpoint.remote.route:
      guard [.reconciling, .reconciled, .cancelling].contains(checkpoint.step) else {
        throw Failure.invalidCheckpoint
      }
      // New withdrawals may have arrived while the app was down. Keep the remote active
      // and require fresh reconciliation on the next attempt.
      try await cancelReturn(checkpoint)
    case .local where binding.route == checkpoint.returned.route && checkpoint.step == .reconciled:
      try await finishPublishedReturn(checkpoint)
    default:
      throw Failure.invalidCheckpoint
    }
  }

  @discardableResult private func record(_ error: Failure) -> Failure {
    lastFailure = error.localizedDescription
    return error
  }
}
