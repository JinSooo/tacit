import Foundation
import Observation
import enum CollectorCore.L10n
import struct CollectorCore.HubBinding
import class CollectorCore.RemotePairing
import struct CollectorCore.RemoteDeviceLink
import struct CollectorCore.DevicePairingInvitation
import enum CollectorCore.DeviceClientError
import enum CollectorCore.SelectedHubEndpoint
import struct CollectorCore.DistillHealth

@MainActor @Observable final class RemoteBackendSettingsModel {
  enum Step: Int {
    case choose = 1, target, confirm, sync, remote

    var title: String {
      switch self {
      case .choose: L10n.Settings.chooseConnection
      case .target: L10n.Settings.confirmTarget
      case .confirm: L10n.Settings.confirmSwitch
      case .sync: L10n.Settings.syncHistory
      case .remote: L10n.Settings.useRemote
      }
    }
  }

  enum Channel: String {
    case direct = "直连"
    case relay = "通过中转信箱"

    var title: String {
      L10n.text(zh: rawValue, en: self == .direct ? L10n.Settings.directConnection : L10n.Settings.viaRelay)
    }
  }

  /// 选到通道不等于后台在回应：只有本次状态请求拿到认证回执才算已连接。
  enum ChannelState: Equatable {
    case unavailable, unconfirmed(Channel), connected(Channel)

    init(_ connected: Channel?) { self = connected.map { .connected($0) } ?? .unavailable }
  }

  struct Target: Equatable {
    let name: String?
    let channel: Channel

    init(name: String?, channel: Channel) {
      self.name = name
      self.channel = channel
    }

    init(link: RemoteDeviceLink, usedMailbox: Bool? = nil) {
      self.init(name: link.hubName, channel: (usedMailbox ?? link.addresses.isEmpty) ? .relay : .direct)
    }
  }

  struct Context {
    var binding: HubBinding = .legacyLocal
    var link: RemoteDeviceLink?
    var checkpoint: RemoteSwitchCheckpoint.Step?
    var agentNeedsDirect = false
    var frozen = false
    var rePairing: RemotePairing.RePairingState = .idle
    /// 切回本机后保留的远端登记，可直接重新连接。
    var retained: [RemoteDeviceLink] = []
    var cleanupRequired = false
    var preparationUsesMailbox: Bool?

    var returning: Bool {
      if binding.phase == .switching_back { return true }
      return binding.phase == .committed && [.reconciling, .reconciled, .cancelling].contains(checkpoint)
    }
  }

  struct SwitchPreview {
    let history: LocalHistoryPreview
    let phones: [DeviceSettings.Device]
    let path: String
  }

  struct ReturnPreview {
    let pending: Int
    let empty: Bool

    var explanation: String {
      empty ? L10n.Settings.emptyLocalBackendNote : L10n.Settings.reconcileBeforeReturn
    }
  }

  struct Operations {
    var context: () throws -> Context
    var prepare: (String, URL?, RemotePairing.MailboxDelivered?) async throws -> RemotePairing.Prepared
    var prepareAgain: (String, URL?, RemotePairing.MailboxDelivered?) async throws -> RemotePairing.PreparedRePairing
    var preparedAgain: () async throws -> RemotePairing.PreparedRePairing?
    var previewSwitch: () async throws -> SwitchPreview
    var commit: (HubBinding, RemotePairing.Prepared?) async throws -> Void
    var commitAgain: (RemotePairing.PreparedRePairing) async throws -> Void
    var cancel: (HubBinding) async throws -> Void
    var reauthenticate: (URL?) async throws -> Void
    var channel: (HubBinding.Route) async throws -> ChannelState
    var status: () async throws -> RemoteBackendStatus
    var pause: (Bool) async throws -> Void
    var deleteBackup: () async throws -> Void
    var previewReturn: () async throws -> Int
    var switchBack: (Bool) async throws -> Void
    var cancelReturn: () async throws -> Void
    var recover: () async throws -> Void
    var reconnect: (RemoteDeviceLink, URL?) async throws -> RemotePairing.Prepared = { _, _ in throw RemotePairing.Failure.preparationExists }
    var cancelRePairing: () async throws -> Void = {}
    var retryIssue: (String) async throws -> Void = { _ in }
    var keepIssue: (String) async throws -> Void = { _ in }
    var dismissCleanup: () async throws -> Void = {}
  }

  @ObservationIgnored private let operations: Operations
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var prepared: RemotePairing.Prepared?
  @ObservationIgnored private var replacement: RemotePairing.PreparedRePairing?
  @ObservationIgnored private var checkedReplacement: HubBinding?
  private(set) var replacementExpiresAt: Date?
  private var replacementUnavailable = false
  var context = Context()
  var progress: HistoryImportProgress?
  var backup: HistoryBackupInfo?
  var status: RemoteBackendStatus?
  var channel: Channel?
  /// 通道已选好但后台还没回应。
  var unconfirmedChannel: Channel?
  var statusChecked = false
  var error: String?
  var busy = false
  var switchingBack = false
  var mailboxDelivered = false

  var step: Step?
  var repairing = false
  var target: Target?
  var preview: SwitchPreview?
  var returnPreview: ReturnPreview?
  var confirmDelete = false
  var showDetails = false {
    didSet { if !showDetails { issueError = nil } }
  }
  var issueError: String?
  var issueAction: String?
  private(set) var retainedAddressTarget: RemoteDeviceLink?
  var phonesConfirmed = false
  var manualAddress = ""
  var offerManualAddress = false
  var invitationText = "" {
    didSet {
      guard invitationText != oldValue else { return }
      error = nil
      offerManualAddress = false
      manualAddress = ""
      invitation = nil
      retainedAddressTarget = nil
      guard !invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      do {
        let parsed = try DevicePairingInvitation.parse(invitationText)
        invitation = parsed
        try validateInvitation(parsed)
      } catch {
        self.error = Self.message(for: error, fallback: L10n.Settings.validInviteRequired)
      }
    }
  }
  private(set) var invitation: DevicePairingInvitation?

  init(operations: Operations, now: @escaping () -> Date = Date.init) {
    self.operations = operations
    self.now = now
  }

  var isRemote: Bool { context.binding.route.remote != nil }
  var frozen: Bool { context.frozen }
  var recovering: Bool {
    if case .recovery = context.rePairing { return true }
    return context.checkpoint == .committing || context.returning || (context.binding.phase == .local && context.checkpoint != nil)
  }
  var canCancelRePairing: Bool { context.rePairing == .recovery(canCancel: true) && !busy }
  var recoveryMessage: String {
    if case .recovery = context.rePairing { return L10n.Settings.rePairInterrupted }
    return L10n.Settings.switchInterrupted
  }
  var cleanupNotice: String? {
    context.cleanupRequired || context.rePairing == .remoteCleanupRequired
      ? L10n.Settings.unfinishedPairingNote : nil
  }
  var canCheck: Bool {
    guard !busy else { return false }
    if retainedAddressTarget != nil { return DevicePairingInvitation.normalizeOrigin(manualAddress) != nil }
    guard let invitation, (try? validateInvitation(invitation)) != nil else { return false }
    return manualAddress.isEmpty || DevicePairingInvitation.normalizeOrigin(manualAddress) != nil
  }
  var canConfirm: Bool { !busy && preview.map { $0.phones.isEmpty || phonesConfirmed } == true }
  var replacementExpired: Bool {
    replacementUnavailable || replacementExpiresAt.map { $0 <= now() } == true
  }
  var canConfirmTarget: Bool { !busy && (!repairing || (replacement != nil && !replacementExpired)) }
  var replacementNotice: String? {
    replacementExpired ? L10n.Settings.expiredReplacementInvite : nil
  }
  var canChangePause: Bool { !busy && !recovering && progress?.isComplete == false }
  var canReturn: Bool { !busy && !recovering && !frozen && backup != nil }
  var canReauthenticate: Bool {
    !busy && (manualAddress.isEmpty || DevicePairingInvitation.normalizeOrigin(manualAddress) != nil)
  }
  var checkingMessage: String {
    mailboxDelivered ? L10n.Settings.awaitingRemoteConfirmation : L10n.Settings.checkingConnection
  }
  var canKeepIssue: Bool {
    !busy && !recovering && !frozen && progress?.isComplete == true &&
      progress?.hasPendingReceipt == false && backup?.canDelete == true
  }
  var canRetryIssue: Bool { canKeepIssue && channel != nil }
  var canDelete: Bool { !busy && !recovering && backup?.canDelete == true }
  var canManageBackend: Bool { !isRemote || (channel == .direct && !frozen && !recovering) }
  static var managementNotice: String { L10n.Settings.managementDirectNotice }
  static var modelsNotice: String { L10n.Settings.modelsDirectNotice }
  var directNotice: String? {
    if !canManageBackend { return Self.managementNotice }
    if channel == .direct && context.agentNeedsDirect { return L10n.Settings.agentDirectAddressMissing }
    return nil
  }
  var pendingAttention: Int? {
    guard let count = progress?.needsAttention, count > 0 else { return nil }
    return count
  }
  var onlineTitle: String {
    if frozen { return L10n.Settings.connectionInterrupted }
    if channel == nil {
      if unconfirmedChannel != nil { return L10n.Settings.remoteUnresponsive }
      return statusChecked ? L10n.Settings.connectionUnavailable : L10n.Settings.checkingConnection
    }
    let name = context.link?.hubName ?? L10n.Settings.remoteBackend
    return L10n.Settings.connectedTo(name)
  }
  var importNotice: String? {
    guard let progress, !progress.isComplete || progress.hasPendingReceipt else { return nil }
    if progress.isPaused { return L10n.Settings.historySyncPaused }
    if frozen { return L10n.Settings.resumeHistoryWhenConnected }
    if (statusChecked && channel == nil) || progress.errorCategory == "connection_or_storage_unavailable" {
      return L10n.Settings.resumeWhenConnected
    }
    if progress.errorCategory != nil { return L10n.Settings.historySyncProblem }
    return nil
  }
  var backupBlock: String? {
    guard let backup, backup.recovery != .emptyLocalBackend, !canDelete else { return nil }
    if switchingBack || context.returning { return L10n.Settings.deleteBlockedDuringReturn }
    if progress?.hasPendingReceipt == true { return L10n.Settings.deleteBlockedPendingReceipt }
    if progress?.isComplete != true { return L10n.Settings.deleteBlockedDuringSync }
    return L10n.Settings.backupInUse
  }

  func refreshContext() {
    do {
      let next = try operations.context()
      let routeChanged = next.binding.route != context.binding.route
      if routeChanged || next.frozen != context.frozen {
        channel = nil
        unconfirmedChannel = nil
        status = nil
        statusChecked = false
      }
      context = next
      if routeChanged {
        progress = nil
        backup = nil
        clearReplacement()
        checkedReplacement = nil
        repairing = false
        resetEntry()
        returnPreview = nil
        confirmDelete = false
        showDetails = false
      }
      guard !repairing else { return }
      switch next.binding.phase {
      case .local:
        if step != .choose { step = nil }
      case .preparing:
        target = prepared.map { Target(link: $0.collectorLink, usedMailbox: $0.usedMailbox) }
          ?? next.link.map { Target(link: $0, usedMailbox: next.preparationUsesMailbox) }
        if step != .confirm || next.checkpoint != nil { step = .target }
      case .committed, .switching_back:
        step = progress?.isComplete == true && !routeChanged ? .remote : .sync
      }
    } catch {
      self.error = Self.message(for: error, fallback: L10n.Settings.backendConnectionStatusUnavailable)
    }
  }

  func restoreReplacement() async {
    guard frozen, !busy else { return }
    if repairing {
      // A restored preparation has no in-memory invitation to supply its expiry.
      if replacementExpiresAt == nil, let replacement, !replacementUnavailable,
         let stillValid = try? await isCurrentReplacement(replacement), !stillValid, !busy {
        replacementUnavailable = true
      }
      return
    }
    guard checkedReplacement != context.binding else { return }
    let binding = context.binding
    do {
      let saved = try await operations.preparedAgain()
      guard !busy, frozen, context.binding == binding else { return }
      checkedReplacement = binding
      if let saved {
        replacement = saved
        if case .awaitingConfirmation(let expiresAt) = context.rePairing { replacementExpiresAt = expiresAt }
        target = Target(link: saved.collectorLink)
        repairing = true
        step = .target
      }
    } catch {
      guard context.binding == binding, !busy else { return }
      self.error = Self.message(for: error, fallback: L10n.Settings.recoverRePairFailed)
    }
  }

  private func isCurrentReplacement(_ candidate: RemotePairing.PreparedRePairing) async throws -> Bool {
    let saved = try await operations.preparedAgain()
    guard !Task.isCancelled, context.binding == candidate.previous, replacement == candidate else {
      throw CancellationError()
    }
    return saved == candidate
  }

  func waitForReplacementExpiry() async {
    guard let expiresAt = replacementExpiresAt else { return }
    do { try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSince(now())))) }
    catch { return }
    if replacementExpiresAt == expiresAt, expiresAt <= now() { replacementUnavailable = true }
  }

  func updateImport(_ progress: HistoryImportProgress?, backup: HistoryBackupInfo?) {
    self.progress = progress
    self.backup = backup
    if !repairing, isRemote { step = progress?.isComplete == true ? .remote : .sync }
  }

  func refreshStatus() async {
    let route = context.binding.route
    guard route.remote != nil, !frozen, !recovering, !busy else { return }
    let state = (try? await operations.channel(route)) ?? .unavailable
    guard !Task.isCancelled, context.binding.route == route, !frozen, !busy else { return }
    switch state {
    case .connected(let selected): channel = selected; unconfirmedChannel = nil
    case .unconfirmed(let selected): channel = nil; unconfirmedChannel = selected
    case .unavailable: channel = nil; unconfirmedChannel = nil
    }
    statusChecked = true
    guard channel != nil else { status = nil; return }
    let latest = try? await operations.status()
    guard !Task.isCancelled, context.binding.route == route, !frozen, !busy else { return }
    status = latest
  }

  func start(repairing: Bool = false) {
    clearReplacement()
    resetEntry()
    error = nil
    self.repairing = repairing
    step = .choose
  }

  private func validateInvitation(_ invitation: DevicePairingInvitation) throws {
    guard invitation.role == "admin" else { throw RemotePairing.Failure.adminInvitationRequired }
    if repairing, let remote = context.binding.remote, invitation.hubID != remote.hub_id {
      throw RemotePairing.Failure.differentHub
    }
  }

  func checkConnection() async {
    guard canCheck else { return }
    if let retainedAddressTarget {
      await reconnect(retainedAddressTarget, address: DevicePairingInvitation.normalizeOrigin(manualAddress))
      return
    }
    guard let checkedInvitation = invitation else { return }
    let text = invitationText
    let address = DevicePairingInvitation.normalizeOrigin(manualAddress)
    await run(fallback: L10n.Settings.remoteCheckFailed) {
      let delivered: RemotePairing.MailboxDelivered = { [weak self] in
        await self?.didDeliverInvitation()
      }
      do {
        if repairing {
          let ready = try await operations.prepareAgain(text, address, delivered)
          replacement = ready
          replacementExpiresAt = checkedInvitation.expiresAt
          target = Target(link: ready.collectorLink)
        } else {
          let ready = try await operations.prepare(text, address, delivered)
          prepared = ready
          target = Target(link: ready.collectorLink, usedMailbox: ready.usedMailbox)
        }
        resetEntry()
        step = .target
      } catch RemotePairing.Failure.remoteUnavailable {
        offerManualAddress = true
        throw RemotePairing.Failure.remoteUnavailable
      } catch {
        if Self.invitationUnavailable(error) { invitation = nil }
        throw error
      }
    }
  }

  private func didDeliverInvitation() { mailboxDelivered = true }

  func loadSwitchPreview() async {
    guard !repairing, target != nil, context.binding.phase == .preparing else { return }
    await run(fallback: L10n.Settings.readLocalSwitchDataFailed) {
      preview = try await operations.previewSwitch()
      phonesConfirmed = false
      step = .confirm
    }
  }

  func commit() async {
    guard canConfirm else { return }
    await run(fallback: L10n.Settings.switchBackendFailed, refreshConnection: true) {
      // Refresh the list before stopping the local service so newly paired phones aren't missed.
      let latest = try await operations.previewSwitch()
      if latest.phones.map(\.id) != preview?.phones.map(\.id) {
        preview = latest
        phonesConfirmed = false
        return
      }
      try await operations.commit(context.binding, prepared)
      prepared = nil
      preview = nil
    }
  }

  func commitReplacement() async {
    guard repairing, canConfirmTarget, let replacement else { return }
    await run(fallback: L10n.Settings.rePairFailed, refreshConnection: true) {
      if replacementExpiresAt == nil, try await isCurrentReplacement(replacement) == false {
        replacementUnavailable = true
        return
      }
      try await operations.commitAgain(replacement)
      clearReplacement()
      repairing = false
    }
  }

  func cancel() async {
    guard !busy else { return }
    if repairing && (replacement != nil || (context.rePairing != .idle && context.rePairing != .remoteCleanupRequired)) {
      await cancelReplacement()
      return
    }
    if context.binding.phase == .preparing {
      await run(fallback: L10n.Settings.cancelPairingFailed) {
        try await operations.cancel(context.binding)
        prepared = nil
        preview = nil
      }
    } else {
      error = nil
      if repairing { checkedReplacement = context.binding }
      repairing = false
      clearReplacement()
      step = nil
      resetEntry()
      refreshContext()
    }
  }

  func reauthenticate() async {
    guard canReauthenticate else { return }
    await run(fallback: L10n.Settings.reauthenticateFailed, refreshConnection: true) {
      try await operations.reauthenticate(DevicePairingInvitation.normalizeOrigin(manualAddress))
      repairing = false
      resetEntry()
    }
  }

  func changePause() async {
    guard canChangePause, let progress else { return }
    await run(fallback: L10n.Settings.changeSyncFailed) {
      try await operations.pause(!progress.isPaused)
    }
  }

  func deleteBackup() async {
    guard !busy else { return }
    defer { confirmDelete = false }
    guard canDelete else { return }
    await run(fallback: L10n.Settings.deleteBackupFailed) { try await operations.deleteBackup() }
  }

  func loadReturnPreview() async {
    guard canReturn, let backup else { return }
    await run(fallback: L10n.Settings.returnCountUnavailable) {
      let pending = try await operations.previewReturn()
      returnPreview = .init(pending: pending, empty: backup.recovery == .emptyLocalBackend)
    }
  }

  func switchBack() async {
    guard canReturn, let returnPreview else { return }
    switchingBack = true
    defer { switchingBack = false; self.returnPreview = nil }
    await run(fallback: L10n.Settings.switchBackFailed) {
      try await operations.switchBack(returnPreview.empty)
    }
  }

  func cancelInterruptedReturn() async {
    await run(fallback: L10n.Settings.cancelReturnFailed, refreshConnection: true) { try await operations.cancelReturn() }
  }

  func recover() async {
    await run(fallback: L10n.Settings.recoverSwitchFailed, refreshConnection: true) { try await operations.recover() }
  }

  func cancelRePairing() async {
    guard canCancelRePairing else { return }
    await cancelReplacement()
  }

  private func cancelReplacement() async {
    await run(fallback: L10n.Settings.cancelRePairFailed) {
      do { try await operations.cancelRePairing() }
      catch RemotePairing.Failure.remoteCleanupRequired {
        exitReplacement()
        throw RemotePairing.Failure.remoteCleanupRequired
      }
      exitReplacement()
    }
  }

  private func exitReplacement() {
    checkedReplacement = context.binding
    clearReplacement()
    repairing = false
    step = nil
    resetEntry()
  }

  /// 用切回本机时保留的登记重新连接，成功后仍需确认切换。
  func reconnect(_ link: RemoteDeviceLink, address: URL? = nil) async {
    guard !busy, !isRemote, context.binding.phase == .local else { return }
    await run(fallback: L10n.Settings.reconnectFailed) {
      do {
        let ready = try await operations.reconnect(link, address)
        repairing = false
        prepared = ready
        target = Target(link: ready.collectorLink, usedMailbox: ready.usedMailbox)
        resetEntry()
        step = .target
      } catch RemotePairing.Failure.retainedIdentityInvalid, DeviceClientError.deviceRemoved {
        resetEntry()
        step = .choose
        throw RemotePairing.Failure.retainedIdentityInvalid
      } catch RemotePairing.Failure.remoteUnavailable {
        retainedAddressTarget = link
        offerManualAddress = true
        step = .choose
        throw RemotePairing.Failure.remoteUnavailable
      }
    }
  }

  func retryIssue(_ id: String) async {
    guard canRetryIssue, progress?.issues.contains(where: { $0.id == id }) == true else { return }
    await changeIssue(L10n.Settings.schedulingRetry, fallback: L10n.Settings.retryRecordFailed) {
      try await operations.retryIssue(id)
    }
  }

  func keepIssue(_ id: String) async {
    guard canKeepIssue, progress?.issues.contains(where: { $0.id == id && $0.category != "kept_in_backup" }) == true else { return }
    await changeIssue(L10n.Settings.updatingRecordStatus, fallback: L10n.Settings.updateRecordStatusFailed) {
      try await operations.keepIssue(id)
    }
  }

  private func changeIssue(_ activity: String, fallback: String, _ action: () async throws -> Void) async {
    issueAction = activity
    issueError = nil
    busy = true
    defer { issueAction = nil; busy = false; refreshContext() }
    do { try await action() }
    catch is CancellationError {}
    catch { issueError = Self.message(for: error, fallback: fallback) }
  }

  func dismissCleanup() async {
    await run(fallback: L10n.Settings.dismissNoticeFailed) { try await operations.dismissCleanup() }
  }

  private func resetEntry() {
    invitationText = ""
    manualAddress = ""
    offerManualAddress = false
    mailboxDelivered = false
    retainedAddressTarget = nil
  }

  private func clearReplacement() {
    replacement = nil
    replacementExpiresAt = nil
    replacementUnavailable = false
  }

  private func run(fallback: String, refreshConnection: Bool = false, _ action: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    error = nil
    var completed = false
    do {
      try await action()
      completed = true
    } catch is CancellationError {} catch {
      self.error = Self.message(for: error, fallback: fallback)
    }
    mailboxDelivered = false
    refreshContext()
    busy = false
    if completed && refreshConnection { await refreshStatus() }
  }

  private static func invitationUnavailable(_ error: Error) -> Bool {
    switch error {
    case DeviceClientError.inviteExpired, DeviceClientError.operationError("pair", 403, _),
         DeviceClientError.operationError("pair", 409, _), DeviceClientError.operationError("pair", 410, _): true
    default: false
    }
  }

  static func message(for error: Error, fallback: String) -> String {
    if invitationUnavailable(error) { return L10n.Settings.inviteUnavailable }
    switch error {
    case RemotePairing.Failure.differentHub:
      return L10n.Settings.inviteWrongBackend
    case RemoteSwitch.Failure.reconciliationIncomplete:
      return L10n.Settings.returnWaitingForReconciliation
    case RemoteSwitch.Failure.commandTimedOut:
      return L10n.Settings.backendTimedOut
    case let failure as RemoteSwitch.Failure:
      return failure.localizedDescription
    case let failure as RemotePairing.Failure:
      return L10n.Settings.pairingError(failure)
    default:
      return fallback
    }
  }
}

struct RemoteBackendStatus: Decodable {
  struct Timezone: Decodable { let current: String; let warning: String? }
  struct Records: Decodable { let total: Int }
  struct Requests: Decodable {
    struct Request: Decodable { let status: String; let done: Int?; let total: Int? }
    let recent: [Request]
  }
  let timezone: Timezone?
  let records: Records?
  let distill: DistillHealth
  let configError: String?
  let requests: Requests?

  private enum Keys: String, CodingKey { case timezone, records, distill, configError, requests }

  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: Keys.self)
    timezone = try fields.decodeIfPresent(Timezone.self, forKey: .timezone)
    records = try fields.decodeIfPresent(Records.self, forKey: .records)
    distill = try fields.decode(DistillHealth.self, forKey: .distill)
    let details = try fields.nestedContainer(keyedBy: Keys.self, forKey: .distill)
    configError = try details.decodeIfPresent(String.self, forKey: .configError)
    requests = try details.decodeIfPresent(Requests.self, forKey: .requests)
  }

  var modelProgress: String? {
    guard let request = requests?.recent.first(where: { $0.status == "running" }),
          let done = request.done, let total = request.total, total > 0 else { return nil }
    return L10n.Settings.summarizedDays(done, total: total)
  }

  var modelSetupNotice: String? { configError == nil ? nil : L10n.Settings.setUpModelToStart }

  var timezoneNotice: String? {
    guard let timezone, timezone.warning != nil else { return nil }
    return L10n.Settings.remoteTimeZone(timezone.current)
  }
}
