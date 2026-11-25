import Foundation
import Observation
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
      case .choose: "选择连接"
      case .target: "确认目标"
      case .confirm: "确认切换"
      case .sync: "同步历史"
      case .remote: "使用远端"
      }
    }
  }

  enum Channel: String {
    case direct = "直连"
    case relay = "通过中转信箱"
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
      empty ? "本机备份已删除，切回只能建立空的本机后台。" : "切回前会核对本机备份与远端的删除和私密变更。"
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
        self.error = Self.message(for: error, fallback: "请粘贴有效的邀请链接。")
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
    if case .recovery = context.rePairing { return "上次重新配对尚未完成。" }
    return "上次后台切换尚未完成。"
  }
  var cleanupNotice: String? {
    context.cleanupRequired || context.rePairing == .remoteCleanupRequired
      ? "远端后台可能留有一条未完成的配对，请在远端后台的设备列表里移除。" : nil
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
    replacementExpired ? "邀请链接已过期，请返回并粘贴新链接。" : nil
  }
  var canChangePause: Bool { !busy && !recovering && progress?.isComplete == false }
  var canReturn: Bool { !busy && !recovering && !frozen && backup != nil }
  var canReauthenticate: Bool {
    !busy && (manualAddress.isEmpty || DevicePairingInvitation.normalizeOrigin(manualAddress) != nil)
  }
  var checkingMessage: String {
    mailboxDelivered ? "正在等待远端后台确认…" : "正在检查连接…"
  }
  var canKeepIssue: Bool {
    !busy && !recovering && !frozen && progress?.isComplete == true &&
      progress?.hasPendingReceipt == false && backup?.canDelete == true
  }
  var canRetryIssue: Bool { canKeepIssue && channel != nil }
  var canDelete: Bool { !busy && !recovering && backup?.canDelete == true }
  var canManageBackend: Bool { !isRemote || (channel == .direct && !frozen && !recovering) }
  static let managementNotice = "管理远端后台和使用 AI 工具需要直连。"
  static let modelsNotice = "修改远端后台的模型设置需要直连。"
  var directNotice: String? {
    if !canManageBackend { return Self.managementNotice }
    if channel == .direct && context.agentNeedsDirect { return "AI 工具尚未获得直连地址。" }
    return nil
  }
  var pendingAttention: Int? {
    guard let count = progress?.needsAttention, count > 0 else { return nil }
    return count
  }
  var onlineTitle: String {
    if frozen { return "连接已中断" }
    if channel == nil {
      if unconfirmedChannel != nil { return "远端后台没有回应" }
      return statusChecked ? "连接不可用" : "正在检查连接…"
    }
    let name = context.link?.hubName ?? "远端后台"
    let gap = name.first.map { $0.isASCII ? " " : "" } ?? ""
    return "已连接到\(gap)\(name)"
  }
  var importNotice: String? {
    guard let progress, !progress.isComplete || progress.hasPendingReceipt else { return nil }
    if progress.isPaused { return "历史同步已暂停。" }
    if frozen { return "恢复连接后继续同步历史。" }
    if (statusChecked && channel == nil) || progress.errorCategory == "connection_or_storage_unavailable" {
      return "等连接恢复后继续。"
    }
    if progress.errorCategory != nil { return "历史同步遇到问题，可在详细状态中查看。" }
    return nil
  }
  var backupBlock: String? {
    guard let backup, backup.recovery != .emptyLocalBackend, !canDelete else { return nil }
    if switchingBack || context.returning { return "切回期间不能删除备份。" }
    if progress?.hasPendingReceipt == true { return "还有记录未确认，暂时不能删除备份。" }
    if progress?.isComplete != true { return "历史同步完成后才能删除备份。" }
    return "备份仍在使用，暂时不能删除。"
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
      self.error = Self.message(for: error, fallback: "无法读取后台连接状态。")
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
      self.error = Self.message(for: error, fallback: "无法恢复上次的重新配对。")
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
    await run(fallback: "无法检查远端后台，请重试。") {
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
    await run(fallback: "无法读取本机记录或已配对设备，请重试。") {
      preview = try await operations.previewSwitch()
      phonesConfirmed = false
      step = .confirm
    }
  }

  func commit() async {
    guard canConfirm else { return }
    await run(fallback: "无法切换后台，请重试。", refreshConnection: true) {
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
    await run(fallback: "无法完成重新配对，请重试。", refreshConnection: true) {
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
      await run(fallback: "无法取消这次配对，请重试。") {
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
    await run(fallback: "无法用原连接恢复，请直连后台后重试或重新配对。", refreshConnection: true) {
      try await operations.reauthenticate(DevicePairingInvitation.normalizeOrigin(manualAddress))
      repairing = false
      resetEntry()
    }
  }

  func changePause() async {
    guard canChangePause, let progress else { return }
    await run(fallback: "无法更改历史同步状态，请重试。") {
      try await operations.pause(!progress.isPaused)
    }
  }

  func deleteBackup() async {
    guard !busy else { return }
    defer { confirmDelete = false }
    guard canDelete else { return }
    await run(fallback: "当前无法删除本机备份。") { try await operations.deleteBackup() }
  }

  func loadReturnPreview() async {
    guard canReturn, let backup else { return }
    await run(fallback: "无法读取可转回本机的记录数量，请重试。") {
      let pending = try await operations.previewReturn()
      returnPreview = .init(pending: pending, empty: backup.recovery == .emptyLocalBackend)
    }
  }

  func switchBack() async {
    guard canReturn, let returnPreview else { return }
    switchingBack = true
    defer { switchingBack = false; self.returnPreview = nil }
    await run(fallback: "无法切回这台 Mac，当前仍使用远端后台。") {
      try await operations.switchBack(returnPreview.empty)
    }
  }

  func cancelInterruptedReturn() async {
    await run(fallback: "无法取消切回，请重试。", refreshConnection: true) { try await operations.cancelReturn() }
  }

  func recover() async {
    await run(fallback: "无法恢复上次的后台切换，请重试。", refreshConnection: true) { try await operations.recover() }
  }

  func cancelRePairing() async {
    guard canCancelRePairing else { return }
    await cancelReplacement()
  }

  private func cancelReplacement() async {
    await run(fallback: "无法取消这次重新配对，请重试。") {
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
    await run(fallback: "无法重新连接这个远端后台，请重试。") {
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
    await changeIssue("正在安排重试…", fallback: "无法重试这条记录，请稍后再试。") {
      try await operations.retryIssue(id)
    }
  }

  func keepIssue(_ id: String) async {
    guard canKeepIssue, progress?.issues.contains(where: { $0.id == id && $0.category != "kept_in_backup" }) == true else { return }
    await changeIssue("正在更新记录状态…", fallback: "无法更改这条记录的状态，请稍后再试。") {
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
    await run(fallback: "无法关闭这条提示，请重试。") { try await operations.dismissCleanup() }
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
    if invitationUnavailable(error) { return "邀请链接已过期或已使用，请粘贴新链接。" }
    switch error {
    case RemotePairing.Failure.differentHub:
      return "请粘贴当前后台签发的邀请链接，连接其他后台前需先切回这台 Mac。"
    case RemoteSwitch.Failure.reconciliationIncomplete:
      return "远端的删除和私密变更尚未核对完成，当前仍使用远端后台。"
    case RemoteSwitch.Failure.commandTimedOut:
      return "后台服务等待超时，请查看详细状态。"
    case let failure as RemoteSwitch.Failure:
      return failure.localizedDescription
    case let failure as RemotePairing.Failure:
      return failure.localizedDescription
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
    return "已整理 \(done.formatted()) / \(total.formatted()) 天"
  }

  var modelSetupNotice: String? { configError == nil ? nil : "设置模型后开始整理。" }

  var timezoneNotice: String? {
    guard let timezone, timezone.warning != nil else { return nil }
    let gap = timezone.current.first.map { $0.isASCII ? " " : "" } ?? ""
    return "远端后台的时区是\(gap)\(timezone.current)，请管理员核对时间线使用的时区。"
  }
}
