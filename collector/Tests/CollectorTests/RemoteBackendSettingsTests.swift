import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import Collector
@testable import CollectorCore

@MainActor private final class WizardFixture {
  let identity: HubBinding.Remote
  let link: RemoteDeviceLink
  var context = RemoteBackendSettingsModel.Context()
  var phones: [DeviceSettings.Device] = []
  var prepareError: Error?
  var returnError: Error?
  var didDeliver: () -> Void = {}
  var didCommit: () -> Void = {}
  var beforePause: () async -> Void = {}
  var beforeDelete: () async -> Void = {}
  var reportDelivery = false
  var now = Date()
  var selectedChannel: RemoteBackendSettingsModel.Channel? = .direct
  var channelState: RemoteBackendSettingsModel.ChannelState?
  var reconnected: [String] = []
  var reconnectError: Error?
  var reconnectUsesMailbox: Bool?
  var rePairCommitError: Error?
  var retryError: Error?
  var beforeRetry: () async -> Void = {}
  var rePairingCancelled = false
  var retried: [String] = []
  var kept: [String] = []
  var pauses: [Bool] = []
  var lastAddress: URL?
  var returns: [Bool] = []
  var cancelled = false
  var deleted = false
  var recovered = false
  var replacementCommits = 0
  var replacement: RemotePairing.PreparedRePairing?

  init() throws {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 37, count: 32)).publicKey
    identity = try HubBinding.Remote(hubID: DeviceProtocol.hubID(for: key),
                                     hubPublicKey: DeviceProtocol.base64URLEncode(key.rawRepresentation))
    link = try RemoteDeviceLink(identity: identity, deviceID: "mac-abcd2345",
                                addresses: [URL(string: "https://notes.example.com")!], hubName: "山雀工作室")
  }

  func invite(role: String = "admin", expires: TimeInterval = 240) throws -> String {
    let body = try JSONSerialization.data(withJSONObject: [
      "v": 1, "name": "山雀工作室", "hub_id": identity.hub_id, "pk": identity.hub_pk,
      "addrs": ["https://notes.example.com"], "code": DeviceProtocol.base64URLEncode(Data(repeating: 24, count: 16)),
      "expires_at": DeviceProtocol.formatRFC3339(Date().addingTimeInterval(expires)), "role": role
    ])
    return "tacit://pair?d=" + DeviceProtocol.base64URLEncode(body)
  }

  func binding(_ phase: HubBinding.Phase, generation: Int) -> HubBinding {
    .init(generation: generation, target: phase == .local ? .local : .remote, phase: phase,
          remote: phase == .local ? nil : identity)
  }

  func progress(complete: Bool = false, paused: Bool = false, pending: Bool = false, hasIssue: Bool = true,
                error: String? = nil) -> HistoryImportProgress {
    .init(confirmed: complete ? (hasIssue ? 1683 : 1684) : 967, total: 1684, alreadyPresent: 83, skipped: 4,
          issues: hasIssue ? [.init(id: "01JQ2JTWQ0TBBMTT90BMKSXX74", category: "record_conflict")] : [], privateCount: 19,
          lastReconciledAt: nil, isPaused: paused, isComplete: complete, hasPendingReceipt: pending, errorCategory: error)
  }

  func backup(empty: Bool = false, allowed: Bool = false) -> HistoryBackupInfo {
    let date = Date(timeIntervalSince1970: 1_795_482_000)
    return .init(frozenAt: date, bytes: 159_646_720, privateCount: 19, unuploadedCount: 7,
                 lastReconciledAt: date, recovery: empty ? .emptyLocalBackend : .frozenLocalHistory, canDelete: allowed)
  }

  func status(unconfigured: Bool = true) throws -> RemoteBackendStatus {
    try HubJSON.decoder().decode(RemoteBackendStatus.self, from: Data("""
      {"timezone":{"current":"UTC","warning":"fictional warning"},"records":{"total":1967},
       "distill":{"config_error":\(unconfigured ? "\"missing model\"" : "null"),"last_ok_at":null,
       "requests":{"recent":[{"status":"running","done":7,"total":12}]}}}
      """.utf8))
  }

  func savedReplacement() throws -> RemotePairing.PreparedRePairing {
    struct Wire: Encodable {
      let previous: HubBinding
      let binding: HubBinding
      let collectorLink: RemoteDeviceLink
      let agentDeviceID: String
      let expiresAt: Date
    }
    let wire = Wire(previous: context.binding, binding: binding(.committed, generation: 2), collectorLink: link,
                    agentDeviceID: "agent-abcd2345", expiresAt: Date().addingTimeInterval(240))
    return try JSONDecoder().decode(RemotePairing.PreparedRePairing.self, from: JSONEncoder().encode(wire))
  }

  func model() -> RemoteBackendSettingsModel {
    let model = RemoteBackendSettingsModel(operations: .init(
      context: { self.context },
      prepare: { _, address, delivered in
        self.lastAddress = address
        if self.reportDelivery {
          await delivered?()
          self.didDeliver()
        }
        if let error = self.prepareError { throw error }
        let binding = self.binding(.preparing, generation: 0)
        self.context.binding = binding
        self.context.link = self.link
        return .init(binding: binding, collectorLink: self.link, agentLink: nil, agentDeviceID: "agent-abcd2345",
                     relay: nil, invitationHubName: "链接里未验证的名称")
      },
      prepareAgain: { _, address, delivered in
        self.lastAddress = address
        if self.reportDelivery {
          await delivered?()
          self.didDeliver()
        }
        if let error = self.prepareError { throw error }
        return try self.savedReplacement()
      },
      preparedAgain: { self.replacement },
      previewSwitch: {
        .init(history: .init(total: 1684, privateCount: 19), phones: self.phones,
              path: "/Users/demo/Library/Application Support/Tacit/history.db")
      },
      commit: { _, _ in
        self.context.binding = self.binding(.committed, generation: 1)
        self.context.checkpoint = .committed
        self.didCommit()
      },
      commitAgain: { prepared in
        if let error = self.rePairCommitError {
          self.context.rePairing = .recovery(canCancel: true)
          throw error
        }
        self.replacementCommits += 1
        self.context.binding = prepared.binding
        self.context.frozen = false
        self.didCommit()
      },
      cancel: { _ in
        self.cancelled = true
        self.context.binding = self.binding(.local, generation: 0)
      },
      reauthenticate: { _ in self.context.frozen = false },
      channel: { _ in self.channelState ?? .init(self.selectedChannel) },
      status: { try self.status() },
      pause: {
        self.pauses.append($0)
        await self.beforePause()
      },
      deleteBackup: {
        self.deleted = true
        await self.beforeDelete()
      },
      previewReturn: { 27 },
      switchBack: { empty in
        self.returns.append(empty)
        if let error = self.returnError { throw error }
        self.context = .init(binding: self.binding(.local, generation: 2))
      },
      cancelReturn: {
        self.context.binding = self.binding(.committed, generation: 1)
        self.context.checkpoint = .committed
      },
      recover: {
        self.recovered = true
        self.context.checkpoint = nil
        self.context.rePairing = .idle
      },
      reconnect: { link, address in
        self.lastAddress = address
        self.reconnected.append(link.hub_id)
        if let error = self.reconnectError { throw error }
        let binding = self.binding(.preparing, generation: 0)
        self.context = .init(binding: binding, link: link, preparationUsesMailbox: self.reconnectUsesMailbox)
        return .init(binding: binding, collectorLink: link, agentLink: nil, agentDeviceID: "agent-abcd2345",
                     relay: nil, invitationHubName: "山雀工作室", usedMailbox: self.reconnectUsesMailbox)
      },
      cancelRePairing: {
        self.rePairingCancelled = true
        self.context.rePairing = .idle
      },
      retryIssue: {
        self.retried.append($0)
        await self.beforeRetry()
        if let error = self.retryError { throw error }
      },
      keepIssue: { self.kept.append($0) },
      dismissCleanup: { self.context.cleanupRequired = false }
    ), now: { self.now })
    model.refreshContext()
    return model
  }

  func connectWithPhones() {
    phones = [
      .init(id: "android-summer", name: "小满的手机", platform: "android", pairedAt: "", lastSeen: nil,
            records: 823, pendingChanges: 0, role: .view),
      .init(id: "android-field", name: "外出录音手机", platform: "android", pairedAt: "", lastSeen: nil,
            records: 127, pendingChanges: 0, role: .collect)
    ]
  }

  func useRemote(frozen: Bool = false) {
    context = .init(binding: binding(.committed, generation: 1), link: link, checkpoint: .committed, frozen: frozen)
  }

  func viewer(_ model: RemoteBackendSettingsModel) -> ViewerStore {
    let api = HubAPI(base: { URL(string: "http://127.0.0.1:1")! }, token: { nil },
                     hubRoute: { model.context.binding.route })
    let store = ViewerStore(api: api, device: "mac", controls: nil)
    store.remoteBackend = model
    return store
  }
}

@MainActor @Test func remoteWizardPairingChecksInvitationAndWaitsForAuthenticatedTarget() async throws {
  let fixture = try WizardFixture()
  let model = fixture.model()
  model.start()
  #expect(model.step == .choose)
  #expect(!model.canCheck)
  model.invitationText = try fixture.invite(role: "view")
  #expect(model.error == "请使用有管理权限的邀请链接")
  #expect(!model.canCheck)
  model.invitationText = try fixture.invite(expires: -30)
  #expect(model.error == "邀请链接已过期或已使用，请粘贴新链接。")
  #expect(!model.canCheck)
  model.invitationText = try fixture.invite()
  fixture.prepareError = DeviceClientError.operationError(op: "pair", status: 403, message: "invite_invalid")
  await model.checkConnection()
  #expect(model.error == "邀请链接已过期或已使用，请粘贴新链接。")
  #expect(!model.canCheck)
  model.invitationText = try fixture.invite(expires: 241)
  fixture.prepareError = RemotePairing.Failure.remoteUnavailable
  await model.checkConnection()
  #expect(model.error == "找不到远端后台")
  #expect(model.offerManualAddress)
  model.manualAddress = "some words"
  #expect(!model.canCheck)
  model.manualAddress = "https://manual.example.com"
  #expect(model.canCheck)
  fixture.prepareError = nil
  fixture.reportDelivery = true
  fixture.didDeliver = { [weak model] in
    #expect(model?.checkingMessage == "正在等待远端后台确认…")
    #expect(model?.step == .choose)
    #expect(model?.canCheck == false)
  }
  await model.checkConnection()
  #expect(fixture.lastAddress?.host == "manual.example.com")
  #expect(model.step == .target)
  #expect(model.canConfirmTarget)
  #expect(model.target?.name == "山雀工作室")
  #expect(model.target?.channel == .direct)
  #expect(!model.mailboxDelivered)
  #expect(model.invitationText.isEmpty)
  await model.cancel()
  #expect(fixture.cancelled)
  #expect(model.step == nil)
}

@MainActor @Test func remoteWizardRequiresAcknowledgmentForEveryAffectedPhone() async throws {
  let fixture = try WizardFixture()
  fixture.connectWithPhones()
  fixture.context = .init(binding: fixture.binding(.preparing, generation: 0), link: fixture.link)
  let model = fixture.model()
  #expect(model.step == .target)
  await model.loadSwitchPreview()
  #expect(model.step == .confirm)
  #expect(model.preview?.history.total == 1684)
  #expect(model.preview?.history.privateCount == 19)
  #expect(model.preview?.phones.map(\.id) == ["android-summer", "android-field"])
  #expect(!model.canConfirm)
  model.phonesConfirmed = true
  #expect(model.canConfirm)
  fixture.phones.removeLast()
  await model.commit()
  #expect(model.step == .confirm)
  #expect(!model.phonesConfirmed)
  #expect(!model.isRemote)
  model.phonesConfirmed = true
  await model.commit()
  #expect(model.isRemote)
  #expect(model.step == .sync)
}

@MainActor @Test(arguments: [false, true])
func remoteWizardKeepsSettingsAndShowsSyncAfterBindingReset(repairing: Bool) async throws {
  let fixture = try WizardFixture()
  if repairing { fixture.useRemote(frozen: true) }
  let model = fixture.model()
  let store = fixture.viewer(model)
  store.showSettings()
  store.path = [.runtime]
  store.timelineSearch = "旧后台的内容"
  fixture.didCommit = { [weak fixture, weak store, weak model] in
    guard let fixture, let store, let model else { return }
    store.resetForBindingChange()
    model.updateImport(fixture.progress(), backup: fixture.backup())
  }
  model.start(repairing: repairing)
  model.invitationText = try fixture.invite()
  await model.checkConnection()
  if repairing {
    await model.commitReplacement()
  } else {
    await model.loadSwitchPreview()
    await model.commit()
  }
  #expect(store.section == .settings)
  #expect(store.path.isEmpty)
  #expect(store.timelineSearch.isEmpty)
  #expect(model.step == .sync)
  #expect(model.progress?.confirmed == 967)
  store.section = .search
  store.resetForBindingChange()
  #expect(store.section == .review)
}

@MainActor @Test func remoteWizardManagementRequiresDirectConnection() async throws {
  let fixture = try WizardFixture()
  let model = fixture.model()
  let store = fixture.viewer(model)
  #expect(store.canManageBackend)
  fixture.useRemote()
  model.refreshContext()
  #expect(!store.canManageBackend)
  #expect(model.directNotice == RemoteBackendSettingsModel.managementNotice)

  for channel: RemoteBackendSettingsModel.Channel? in [nil, .relay, .direct] {
    fixture.selectedChannel = channel
    await model.refreshStatus()
    #expect(store.canManageBackend == (channel == .direct))
    #expect((model.directNotice == nil) == (channel == .direct))
  }
  fixture.context.frozen = true
  model.refreshContext()
  #expect(!store.canManageBackend)
}

@MainActor @Test func remoteWizardDisablesExpiredReplacementBeforeSubmitting() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote(frozen: true)
  let model = fixture.model()
  model.start(repairing: true)
  model.invitationText = try fixture.invite()
  await model.checkConnection()
  #expect(model.step == .target)
  #expect(model.canConfirmTarget)
  fixture.now = try #require(model.replacementExpiresAt)
  #expect(!model.canConfirmTarget)
  #expect(model.replacementNotice?.contains("粘贴新链接") == true)
  await model.commitReplacement()
  #expect(fixture.replacementCommits == 0)
  model.start(repairing: true)
  #expect(model.step == .choose)
  #expect(model.replacementNotice == nil)
}

@MainActor @Test func remoteWizardRejectsAnExpiredRestoredReplacementBeforeSubmitting() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote(frozen: true)
  fixture.replacement = try fixture.savedReplacement()
  let model = fixture.model()
  await model.restoreReplacement()
  #expect(model.canConfirmTarget)
  fixture.replacement = nil
  await model.commitReplacement()
  #expect(fixture.replacementCommits == 0)
  #expect(!model.canConfirmTarget)
  #expect(model.replacementNotice?.contains("粘贴新链接") == true)
}

@MainActor @Test func remoteWizardEmphasizesOnlyNonzeroPendingCounts() throws {
  let fixture = try WizardFixture()
  fixture.useRemote()
  let model = fixture.model()
  model.updateImport(fixture.progress(hasIssue: false), backup: fixture.backup())
  #expect(model.pendingAttention == nil)
  model.updateImport(fixture.progress(), backup: fixture.backup())
  #expect(model.step == .sync)
  #expect(model.pendingAttention == 1)
  model.updateImport(fixture.progress(complete: true), backup: fixture.backup())
  #expect(model.step == .remote)
  #expect(model.pendingAttention == 1)
  #expect(try fixture.status().modelSetupNotice == "设置模型后开始整理。")
  #expect(try fixture.status(unconfigured: false).modelSetupNotice == nil)
}

@MainActor @Test func remoteWizardAwaitsPauseAndBackupDeletionWithoutReentry() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote()
  let model = fixture.model()
  model.updateImport(fixture.progress(), backup: fixture.backup())
  let pausing = Task { await model.changePause() }
  let pauseRelease: CheckedContinuation<Void, Never> = await withCheckedContinuation { started in
    fixture.beforePause = { await withCheckedContinuation { started.resume(returning: $0) } }
  }
  #expect(model.busy)
  #expect(!model.canChangePause)
  await model.changePause()
  #expect(fixture.pauses == [true])
  pauseRelease.resume()
  await pausing.value
  #expect(!model.busy)

  model.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  model.confirmDelete = true
  let deleting = Task { await model.deleteBackup() }
  let deleteRelease: CheckedContinuation<Void, Never> = await withCheckedContinuation { started in
    fixture.beforeDelete = { await withCheckedContinuation { started.resume(returning: $0) } }
  }
  #expect(model.busy)
  #expect(model.confirmDelete)
  #expect(!model.canDelete)
  await model.deleteBackup()
  #expect(model.confirmDelete)
  deleteRelease.resume()
  await deleting.value
  #expect(!model.busy)
  #expect(!model.confirmDelete)
}

@MainActor @Test func remoteWizardDisplaysHistoryAndBackendStatusSeparately() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote()
  let model = fixture.model()
  #expect(!model.canChangePause)
  model.updateImport(fixture.progress(paused: true, pending: true), backup: fixture.backup())
  #expect(model.step == .sync)
  #expect(model.importNotice == "历史同步已暂停。")
  #expect(model.canChangePause)
  #expect(!model.canDelete)
  #expect(model.backupBlock == "还有记录未确认，暂时不能删除备份。")
  await model.changePause()
  #expect(fixture.pauses == [false])
  model.updateImport(fixture.progress(), backup: fixture.backup())
  fixture.selectedChannel = nil
  await model.refreshStatus()
  #expect(model.importNotice == "等连接恢复后继续")
  #expect(model.backupBlock == "历史同步完成后才能删除备份。")
  await model.deleteBackup()
  #expect(!fixture.deleted)
  model.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  fixture.selectedChannel = .relay
  await model.refreshStatus()
  #expect(model.step == .remote)
  #expect(!model.canChangePause)
  #expect(model.onlineTitle == "已连接到山雀工作室")
  #expect(model.directNotice == RemoteBackendSettingsModel.managementNotice)
  #expect(model.status?.modelSetupNotice != nil)
  #expect(model.status?.timezoneNotice?.contains("UTC") == true)
  #expect(try fixture.status(unconfigured: false).modelProgress == "已整理 7 / 12 天")
  #expect(model.canDelete)
  await model.deleteBackup()
  #expect(fixture.deleted)
}

@MainActor @Test func remoteWizardReturnRequiresPreviewAndKeepsRemoteOnIncompleteReconciliation() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote()
  let model = fixture.model()
  #expect(!model.canReturn)
  model.updateImport(fixture.progress(complete: true), backup: fixture.backup(empty: true))
  #expect(model.canReturn)
  #expect(!model.canDelete)
  await model.loadReturnPreview()
  #expect(model.returnPreview?.pending == 27)
  #expect(model.returnPreview?.empty == true)
  #expect(model.returnPreview?.explanation == "本机备份已删除，切回只能建立空的本机后台。")
  fixture.returnError = RemoteSwitch.Failure.reconciliationIncomplete
  await model.switchBack()
  #expect(model.returnPreview == nil)
  #expect(model.error == "远端的删除和私密变更尚未核对完成，当前仍使用远端后台。")
  #expect(model.isRemote)
  #expect(fixture.returns == [true])
}

@MainActor @Test func remoteWizardRestoresFromExistingCheckpointsAndReplacement() async throws {
  let fixture = try WizardFixture()
  #expect(fixture.model().step == nil)
  fixture.context = .init(binding: fixture.binding(.preparing, generation: 0), link: fixture.link, checkpoint: .committing)
  let interrupted = fixture.model()
  #expect(interrupted.recovering)
  #expect(interrupted.step == .target)
  await interrupted.recover()
  #expect(!interrupted.recovering)
  #expect(fixture.recovered)

  fixture.useRemote()
  let syncing = fixture.model()
  syncing.updateImport(fixture.progress(paused: true), backup: fixture.backup())
  #expect(syncing.step == .sync)
  #expect(syncing.progress?.isPaused == true)
  let complete = fixture.model()
  complete.updateImport(fixture.progress(complete: true), backup: fixture.backup())
  #expect(complete.step == .remote)
  fixture.context.binding = fixture.binding(.switching_back, generation: 1)
  fixture.context.checkpoint = .reconciled
  let returning = fixture.model()
  #expect(returning.recovering)
  await returning.cancelInterruptedReturn()
  #expect(!returning.recovering)
  #expect(returning.isRemote)

  fixture.useRemote(frozen: true)
  let frozen = fixture.model()
  #expect(frozen.onlineTitle == "连接已中断")
  #expect(!frozen.canReturn)
  frozen.start(repairing: true)
  frozen.invitationText = try fixture.invite()
  #expect(frozen.canCheck)
  await frozen.checkConnection()
  #expect(frozen.step == .target)
  fixture.replacement = try fixture.savedReplacement()
  let restored = fixture.model()
  await restored.restoreReplacement()
  #expect(restored.repairing)
  #expect(restored.step == .target)
  await restored.commitReplacement()
  #expect(restored.isRemote)
  #expect(!restored.frozen)
  #expect(restored.step == .sync)
  #expect(restored.context.binding.generation == 2)

  fixture.useRemote(frozen: true)
  let old = fixture.model()
  await old.reauthenticate()
  #expect(!old.frozen)
}

// 2026-11-24 向导第 1 轮审查回归（第 1、2、7、8 条）：保留的远端能重新连接，
// 重新配对中断能恢复或取消，通道无回执不算已连接，失败项可逐条处理。
@MainActor @Test func remoteWizardReconnectsRetainedRemoteRecoversRePairingAndHandlesIssues() async throws {
  let fixture = try WizardFixture()
  fixture.context = .init(binding: fixture.binding(.local, generation: 2), retained: [fixture.link])
  let local = fixture.model()
  await local.reconnect(fixture.link)
  #expect(fixture.reconnected == [fixture.identity.hub_id])
  #expect(local.step == .target)
  #expect(local.target?.name == "山雀工作室")
  await local.loadSwitchPreview()
  #expect(local.step == .confirm)

  fixture.useRemote(frozen: true)
  fixture.context.rePairing = .recovery(canCancel: false)
  let published = fixture.model()
  #expect(published.recovering)
  #expect(published.recoveryMessage == "上次重新配对尚未完成。")
  #expect(!published.canCancelRePairing)
  await published.cancelRePairing()
  #expect(!fixture.rePairingCancelled)
  fixture.context.rePairing = .recovery(canCancel: true)
  let unpublished = fixture.model()
  #expect(unpublished.canCancelRePairing)
  await unpublished.cancelRePairing()
  #expect(fixture.rePairingCancelled)
  #expect(!unpublished.recovering)
  fixture.context.rePairing = .remoteCleanupRequired
  #expect(fixture.model().cleanupNotice != nil)

  fixture.useRemote()
  fixture.channelState = .unconfirmed(.relay)
  let waiting = fixture.model()
  await waiting.refreshStatus()
  #expect(waiting.channel == nil)
  #expect(waiting.onlineTitle == "远端后台没有回应")
  #expect(!waiting.canManageBackend)
  #expect(waiting.status == nil)
  fixture.channelState = .connected(.direct)
  await waiting.refreshStatus()
  #expect(waiting.channel == .direct)
  #expect(waiting.canManageBackend)

  waiting.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  await waiting.retryIssue("01JQ2JTWQ0TBBMTT90BMKSXX74")
  await waiting.keepIssue("01JQ2JTWQ0TBBMTT90BMKSXX74")
  #expect(fixture.retried == ["01JQ2JTWQ0TBBMTT90BMKSXX74"])
  #expect(fixture.kept == ["01JQ2JTWQ0TBBMTT90BMKSXX74"])
  let kept = HistoryImportProgress(confirmed: 1683, total: 1684, alreadyPresent: 0, skipped: 0,
    issues: [.init(id: "01JQ2JTWQ0TBBMTT90BMKSXX74", category: "kept_in_backup")], privateCount: 0,
    lastReconciledAt: nil, isPaused: false, isComplete: true, hasPendingReceipt: false, errorCategory: nil)
  waiting.updateImport(kept, backup: fixture.backup())
  #expect(waiting.pendingAttention == nil)
}

@Test func remoteWizardModelsDecodeUnconfiguredServerAndHideCLIProviders() throws {
  let info = try HubJSON.decoder().decode(ModelSettingsInfo.self, from: Data("""
    {"tiers":null,"config_error":"missing model","keys":{"anthropic":false,"openai-compatible":false},
     "tier_info":{},"providers":[{"id":"anthropic","label":"Anthropic","needs_key":true,"base_url":true},
       {"id":"openai-compatible","label":"OpenAI 兼容 API","needs_key":true,"base_url":true},
       {"id":"codex-cli","label":"Codex","needs_key":false,"base_url":false}]}
    """.utf8))
  #expect(info.tiers.isEmpty)
  #expect(info.availableProviders(remote: true).map(\.id) == ["anthropic", "openai-compatible"])
  #expect(info.availableProviders(remote: false).last?.id == "codex-cli")
}

private enum ImportSnapshotFailure: Error { case retry }

@MainActor @Test func renderRemoteBackendSettingsSnapshots() async throws {
  guard let path = ProcessInfo.processInfo.environment["TACIT_WIZARD_SNAPSHOTS"] else { return }
  let output = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let fixture = try WizardFixture()

  func render(_ name: String, _ content: some View) throws {
    for scheme: ColorScheme in [.light, .dark] {
      let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
      let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
      host.appearance = appearance
      let size = host.fittingSize
      host.frame = CGRect(origin: .zero, size: size)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = appearance
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      appearance.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: bitmap)
      }
      window.contentView = nil
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      let variant = scheme == .light ? "light" : "dark"
      try data.write(to: output.appendingPathComponent("\(name)-\(variant).png"))
    }
  }

  func renderSection(_ name: String, _ model: RemoteBackendSettingsModel, height: CGFloat = 360) throws {
    try render(name, SettingsForm {
      RemoteBackendSettingsSection(model: model, queue: 27, sent: 184, openModels: {}) { EmptyView() }
    }
    .frame(width: 640, height: height)
    .font(.system(size: TextSize.body))
    .foregroundStyle(Palette.ink).background(Palette.paper).tint(Palette.accent))
  }

  let choose = fixture.model()
  choose.start()
  choose.invitationText = try fixture.invite()
  try renderSection("01-choose-connection", choose)
  await choose.checkConnection()
  try renderSection("02-confirm-target", choose)

  fixture.connectWithPhones()
  await choose.loadSwitchPreview()
  try renderSection("03-confirm-switch", choose, height: 470)

  choose.phonesConfirmed = true
  await choose.commit()
  let sync = choose
  sync.updateImport(fixture.progress(pending: true), backup: fixture.backup())
  await sync.refreshStatus()
  try renderSection("04-sync-history", sync, height: 760)
  sync.busy = true
  try renderSection("04-pause-in-progress", sync, height: 760)
  sync.busy = false
  sync.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  try renderSection("05-use-remote", sync, height: 740)
  fixture.selectedChannel = .relay
  await sync.refreshStatus()
  try renderSection("05-use-remote-relay", sync, height: 820)
  fixture.selectedChannel = nil
  await sync.refreshStatus()
  let store = fixture.viewer(sync)
  try render("05-use-remote-offline", HubSettingsView(openModels: {})
    .environment(store).frame(width: 640, height: 740)
    .font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).background(Palette.paper))

  fixture.useRemote(frozen: true)
  let frozen = fixture.model()
  try renderSection("06-frozen-repair", frozen)
  frozen.start(repairing: true)
  try renderSection("07-repair-link", frozen)
  frozen.invitationText = try fixture.invite()
  await frozen.checkConnection()
  fixture.now = try #require(frozen.replacementExpiresAt)
  try renderSection("07-repair-expired", frozen, height: 425)

  fixture.context = .init(binding: fixture.binding(.local, generation: 2), retained: [fixture.link])
  try renderSection("10-local-reconnect", fixture.model(), height: 200)
  fixture.reconnectError = RemotePairing.Failure.retainedIdentityInvalid
  let revoked = fixture.model()
  await revoked.reconnect(fixture.link)
  try renderSection("14-retained-revoked", revoked, height: 350)
  fixture.reconnectError = nil
  fixture.context.cleanupRequired = true
  try renderSection("15-cleanup-notice", fixture.model(), height: 300)
  fixture.context.cleanupRequired = false
  fixture.reconnectUsesMailbox = true
  let viaRelay = fixture.model()
  await viaRelay.reconnect(fixture.link)
  try renderSection("16-retained-via-relay", viaRelay, height: 300)
  fixture.useRemote(frozen: true)
  fixture.context.rePairing = .recovery(canCancel: true)
  try renderSection("11-repair-recovery", fixture.model(), height: 200)
  fixture.useRemote()
  fixture.channelState = .unconfirmed(.relay)
  let waiting = fixture.model()
  waiting.updateImport(fixture.progress(complete: true), backup: fixture.backup())
  await waiting.refreshStatus()
  try renderSection("12-remote-unconfirmed", waiting, height: 740)
  waiting.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  try render("13-details-issues", RemoteBackendDetails(model: waiting, close: {}))
  waiting.updateImport(fixture.progress(complete: true, pending: true), backup: fixture.backup())
  try render("17-retry-pending", RemoteBackendDetails(model: waiting, close: {}))
  fixture.channelState = .connected(.direct)
  await waiting.refreshStatus()
  waiting.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  fixture.retryError = ImportSnapshotFailure.retry
  if let issue = waiting.progress?.issues.first { await waiting.retryIssue(issue.id) }
  try render("18-retry-error", RemoteBackendDetails(model: waiting, close: {}))
  fixture.retryError = nil
  fixture.channelState = nil

  fixture.context = .init(binding: fixture.binding(.local, generation: 2), retained: [fixture.link])
  fixture.reconnectError = RemotePairing.Failure.remoteUnavailable
  let moved = fixture.model()
  await moved.reconnect(fixture.link)
  try renderSection("19-retained-manual-address", moved, height: 400)
  fixture.reconnectError = nil

  try render("08-switch-back-confirmation", RemoteBackendConfirmation(action: .switchBack(.init(pending: 27, empty: true)),
                                                                        cancel: {}, confirm: {}, busy: false))
  try render("09-delete-backup-confirmation", RemoteBackendConfirmation(action: .deleteBackup,
                                                                          cancel: {}, confirm: {}, busy: false))
  try render("09-delete-backup-in-progress", RemoteBackendConfirmation(action: .deleteBackup,
                                                                       cancel: {}, confirm: {}, busy: true))
}

// 2026-11-24 终审回归：失效身份提示新管理邀请，并打开粘贴入口。
@MainActor @Test func finalReviewRevokedRetainedWizardShowsAdminInvitationEntry() async throws {
  let fixture = try WizardFixture()
  fixture.context.retained = [fixture.link]
  fixture.reconnectError = DeviceClientError.deviceRemoved(message: nil)
  let model = fixture.model()
  await model.reconnect(fixture.link)
  #expect(model.step == .choose)
  #expect(model.error?.contains("管理邀请链接") == true)
  model.invitationText = try fixture.invite()
  await model.checkConnection()
  #expect(model.step == .target)
}

// 2026-11-24 终审回归：确认页和发布前恢复页的取消都会撤销这次重配。
@MainActor @Test(arguments: [false, true])
func finalReviewWizardCancelsReplacementFromEitherPage(interrupted: Bool) async throws {
  let fixture = try WizardFixture()
  fixture.useRemote(frozen: true)
  let model = fixture.model()
  model.start(repairing: true)
  model.invitationText = try fixture.invite()
  await model.checkConnection()
  #expect(model.step == .target)
  if interrupted {
    fixture.rePairCommitError = RemotePairing.Failure.recoveryRequired
    await model.commitReplacement()
    #expect(model.canCancelRePairing)
    await model.cancelRePairing()
  } else {
    await model.cancel()
  }
  #expect(fixture.rePairingCancelled)
  #expect(!model.repairing && model.frozen && !model.recovering)
  #expect(model.step != .target)
}

// 2026-11-24 终审回归：远端地址更换可手填，信箱认证后的确认页仍显示信箱。
@MainActor @Test func finalReviewRetainedWizardUsesAuthenticatedChannelAndManualAddress() async throws {
  let fixture = try WizardFixture()
  fixture.context.retained = [fixture.link]
  fixture.reconnectError = RemotePairing.Failure.remoteUnavailable
  let model = fixture.model()
  await model.reconnect(fixture.link)
  #expect(model.offerManualAddress && !model.canCheck)
  model.manualAddress = "https://replacement.example.com"
  fixture.reconnectError = nil
  fixture.reconnectUsesMailbox = true
  await model.checkConnection()
  #expect(fixture.lastAddress?.host == "replacement.example.com")
  #expect(model.target?.channel == .relay)
  #expect(fixture.model().target?.channel == .relay)
}

// 2026-11-24 终审回归：操作只在对应状态可用，等待和失败都在详情中展示。
@MainActor @Test func finalReviewWizardReportsIssueActionInDetails() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote()
  let model = fixture.model()
  let id = try #require(fixture.progress().issues.first?.id)
  model.updateImport(fixture.progress(), backup: fixture.backup(allowed: true))
  await model.refreshStatus()
  #expect(!model.canRetryIssue && !model.canKeepIssue)
  model.updateImport(fixture.progress(complete: true, pending: true), backup: fixture.backup(allowed: true))
  #expect(!model.canRetryIssue && !model.canKeepIssue)
  fixture.channelState = .unconfirmed(.relay)
  await model.refreshStatus()
  #expect(model.importNotice == "等连接恢复后继续")
  model.updateImport(fixture.progress(complete: true), backup: fixture.backup(allowed: true))
  #expect(model.importNotice == nil)
  #expect(model.canKeepIssue && !model.canRetryIssue)
  fixture.channelState = .connected(.direct)
  await model.refreshStatus()
  fixture.beforeRetry = { [weak model] in
    #expect(model?.issueAction != nil)
    #expect(model?.canRetryIssue == false)
  }
  fixture.retryError = RemotePairing.Failure.remoteUnavailable
  await model.retryIssue(id)
  #expect(model.issueError == "找不到远端后台")
  #expect(model.issueAction == nil && model.error == nil)
}

// 2026-11-24 终审回归：恢复连接后马上获取通道，清理提醒可以关闭。
@MainActor @Test func finalReviewWizardRefreshesAfterRecoveryAndDismissesCleanup() async throws {
  let fixture = try WizardFixture()
  fixture.useRemote(frozen: true)
  fixture.context.cleanupRequired = true
  let model = fixture.model()
  await model.reauthenticate()
  #expect(model.channel == .direct && model.statusChecked)
  #expect(model.cleanupNotice != nil)
  await model.dismissCleanup()
  #expect(model.cleanupNotice == nil)
}

// 2026-11-24 虚拟机联调回归：上次保存的窗口比当前屏幕大或跑到屏幕外时，打开时收进可见区域。
@MainActor @Test func viewerWindowFitsSavedFrameIntoVisibleScreen() {
  let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
  let fitted = ViewerWindow.fit(NSRect(x: 300, y: -40, width: 2200, height: 1000), in: visible)
  #expect(fitted == visible)
  let small = NSRect(x: 1300, y: 600, width: 1200, height: 700)
  #expect(ViewerWindow.fit(small, in: visible) == NSRect(x: 240, y: 200, width: 1200, height: 700))
  let inside = NSRect(x: 100, y: 100, width: 1100, height: 700)
  #expect(ViewerWindow.fit(inside, in: visible) == inside)
}
