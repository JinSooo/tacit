import CollectorCore
import SwiftUI
import enum CollectorCore.ViewerTime

struct RemoteBackendSettingsSection<LocalRows: View>: View {
  @Bindable var model: RemoteBackendSettingsModel
  let queue: Int
  let sent: Int
  let openModels: () -> Void
  @ViewBuilder var localRows: () -> LocalRows

  var body: some View {
    Section {
      if model.isRemote {
        connectionRow
      } else {
        SettingsRow(L10n.Settings.currentBackend) {
          HStack(spacing: 8) {
            Text(L10n.Settings.thisMac).foregroundStyle(Palette.muted)
            if model.step == nil && !model.context.returning && !model.recovering && !model.frozen {
              Button(L10n.Settings.connectRemote) { model.start() }.disabled(model.busy)
            }
          }
        }
        // 连接向导打开时先收起地址、端口这些本机行，让向导紧跟在“当前后台”后面。
        if model.step == nil { localRows() }
      }
      if model.context.returning {
        SettingsMessage(text: L10n.Settings.returnInterrupted)
        Button(L10n.Settings.cancelReturn) { Task { await model.cancelInterruptedReturn() } }.disabled(model.busy)
      } else if model.recovering {
        SettingsMessage(text: model.recoveryMessage)
        actions {
          if model.context.rePairing == .recovery(canCancel: true) {
            Button(L10n.Settings.cancelRePairing) { Task { await model.cancelRePairing() } }.disabled(!model.canCancelRePairing)
          }
          Button(L10n.Settings.resumeSwitch) { Task { await model.recover() } }.buttonStyle(.accent).disabled(model.busy)
        }
      } else if model.frozen && !model.repairing {
        frozenControls
      } else if let step = model.step {
        wizard(step)
      } else {
        ForEach(model.context.retained, id: \.hub_id) { link in
          let name = link.hubName ?? L10n.Settings.remoteBackend
          Button(L10n.Settings.reconnect(name)) { Task { await model.reconnect(link) } }
            .disabled(model.busy)
        }
        if model.isRemote { Button(L10n.Settings.connectRemote) { model.start() }.disabled(model.busy) }
        if model.busy { busyLine(L10n.Settings.checkingConnection) }
      }
      if let notice = model.cleanupNotice {
        SettingsMessage(text: notice)
        Button(L10n.Settings.gotIt) { Task { await model.dismissCleanup() } }.disabled(model.busy)
      }
      if let error = model.error { SettingsMessage(text: error) }
    } header: { Text(L10n.Settings.backgroundService) } footer: {
      if !model.isRemote { Note(L10n.Settings.localPortNote) }
    }
    if model.isRemote, let backup = model.backup, backup.recovery != .emptyLocalBackend {
      Section(L10n.Settings.localBackup) { backupRows(backup) }
    }
  }

  private var connectionRow: some View {
    SettingsRow(model.onlineTitle) {
      if let channel = model.channel ?? model.unconfirmedChannel {
        Text(channel.title).foregroundStyle(Palette.muted)
      } else if let name = model.context.link?.hubName {
        Text(name).foregroundStyle(Palette.muted)
      }
    }
  }

  @ViewBuilder private var frozenControls: some View {
    SettingsMessage(text: L10n.Settings.remoteCannotVerifyMac)
    SettingsRow(L10n.Settings.directAddress) {
      TextField(L10n.Settings.directAddress, text: $model.manualAddress, prompt: Text(verbatim: "https://tacit.example.com"))
        .labelsHidden().textFieldStyle(.roundedBorder).disabled(model.busy)
    }
    actions {
      Button(L10n.Settings.restoreConnection) { Task { await model.reauthenticate() } }.disabled(!model.canReauthenticate)
      Button(L10n.Settings.rePair) { model.start(repairing: true) }.buttonStyle(.accent).disabled(model.busy)
    }
    if model.busy { busyLine(L10n.Settings.verifyingOriginalConnection) }
  }

  @ViewBuilder private func wizard(_ step: RemoteBackendSettingsModel.Step) -> some View {
    if model.repairing {
      Text(step == .target ? step.title : L10n.Settings.rePair).accessibilityAddTraits(.isHeader)
    } else if step.rawValue < 5 {
      // 第 5 步就是已连接的常态：首行“已连接到…”已经说明，不再单独占一行。
      SettingsRow(step.title) {
        if step.rawValue <= 3 {
          // 第 4、5 步是自动导入和连好后的常态，要用户动手的只有前 3 步。
          Text(L10n.Settings.setupStep(step.rawValue))
            .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
        }
      }
      .accessibilityAddTraits(.isHeader)
    }
    switch step {
    case .choose: invitationRows
    case .target: targetRows
    case .confirm: switchRows
    case .sync: importRows
    case .remote: remoteRows
    }
    if !model.repairing, let notice = model.directNotice {
      SettingsMessage(text: notice, warning: false).font(.system(size: TextSize.caption))
    }
  }

  @ViewBuilder private var invitationRows: some View {
    SettingsRow(L10n.Settings.inviteLink) {
      SecureField(L10n.Settings.inviteLink, text: $model.invitationText, prompt: Text(L10n.Settings.pasteInvite))
        .labelsHidden().textFieldStyle(.roundedBorder)
        .onSubmit { Task { await model.checkConnection() } }
        .disabled(model.busy)
    }
    if let invitation = model.invitation {
      SettingsRow(L10n.Settings.serviceName, value: invitation.hubName)
      ForEach(invitation.addresses, id: \.self) { origin in
        pathRow(L10n.Settings.address, origin.absoluteString)
      }
      SettingsRow(L10n.Settings.expires, value: Fmt.dateTime(invitation.expiresAt))
    }
    if model.offerManualAddress {
      SettingsRow(L10n.Settings.directAddress) {
        TextField(L10n.Settings.directAddress, text: $model.manualAddress, prompt: Text(verbatim: "https://tacit.example.com"))
          .labelsHidden().textFieldStyle(.roundedBorder).disabled(model.busy)
          .onSubmit { Task { await model.checkConnection() } }
      }
    }
    if model.busy {
      busyLine(model.checkingMessage)
    }
    actions {
      Button(L10n.Settings.cancel) { Task { await model.cancel() } }.disabled(model.busy)
      Button(model.offerManualAddress ? L10n.Settings.retry : L10n.Settings.checkConnection) { Task { await model.checkConnection() } }
        .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canCheck)
    }
  }

  @ViewBuilder private var targetRows: some View {
    if let target = model.target {
      SettingsRow(L10n.Settings.serviceName, value: target.name ?? L10n.Settings.remoteBackend)
      SettingsRow(L10n.Settings.connectionType, value: target.channel.title)
      if let notice = model.replacementNotice { SettingsMessage(text: notice) }
      actions {
        Button(model.replacementExpired ? L10n.Settings.back : L10n.Settings.cancel) {
          if model.replacementExpired { model.start(repairing: true) }
          else { Task { await model.cancel() } }
        }
        .disabled(model.busy)
        Button(model.repairing ? L10n.Settings.rePair : L10n.Settings.continueAction) {
          Task {
            if model.repairing { await model.commitReplacement() }
            else { await model.loadSwitchPreview() }
          }
        }
        .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canConfirmTarget)
      }
      .task(id: model.replacementExpiresAt) { await model.waitForReplacementExpiry() }
    } else {
      SettingsMessage(text: L10n.Settings.confirmedRemoteUnavailable)
      Button(L10n.Settings.cancel) { Task { await model.cancel() } }.disabled(model.busy)
    }
  }

  @ViewBuilder private var switchRows: some View {
    if let preview = model.preview {
      countRow(L10n.Settings.readyToUpload, preview.history.total)
      countRow(L10n.Settings.privateRecordsStayLocal, preview.history.privateCount)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.Settings.backupLocation)
        Text(preview.path).font(.mono(TextSize.body)).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !preview.phones.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(preview.phones) { phone in
            Label { Text(phone.name) } icon: { PhIcon("device-mobile", size: 16) }
          }
          Toggle(L10n.Settings.confirmRePairDevices, isOn: $model.phonesConfirmed)
            .disabled(model.busy)
        }
      }
      actions {
        Button(L10n.Settings.cancel) { Task { await model.cancel() } }.disabled(model.busy)
        Button(L10n.Settings.switchBackend) { Task { await model.commit() } }
          .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
      }
    }
  }

  @ViewBuilder private var importRows: some View {
    if let progress = model.progress, let total = progress.total {
      ProgressView(value: Double(progress.confirmed), total: Double(max(1, total))) {
        Text(L10n.Settings.confirmedRecords(progress.confirmed, total: total)).monospacedDigit()
      }
    } else {
      Text(L10n.Settings.countingHistory).foregroundStyle(Palette.muted)
    }
    if let progress = model.progress {
      countRow(L10n.Settings.alreadyPresent, progress.alreadyPresent, hidesZero: true)
      countRow(L10n.Settings.skipped, progress.skipped, hidesZero: true)
      countRow(L10n.Settings.needsAttention, progress.needsAttention, attention: model.pendingAttention != nil, hidesZero: true)
    }
    countRow(L10n.Settings.newRecordsWaitingToSave, queue, hidesZero: true)
    if let notice = model.importNotice { SettingsMessage(text: notice, warning: false) }
    actions {
      Button(L10n.Settings.detailedStatus) { model.showDetails = true }
      Button(model.progress?.isPaused == true ? L10n.Settings.resumeSync : L10n.Settings.pauseSync) {
        Task { await model.changePause() }
      }
      .disabled(!model.canChangePause)
      switchBackButton
    }
  }

  private var switchBackButton: some View {
    Button(L10n.Settings.switchBack) { Task { await model.loadReturnPreview() } }.disabled(!model.canReturn)
  }

  @ViewBuilder private var remoteRows: some View {
    countRow(L10n.Settings.waitingToSave, queue, hidesZero: true)
    if let pending = model.pendingAttention {
      countRow(L10n.Settings.needsAttention, pending, attention: true)
    }
    RemoteBackendModelStatusRows(status: model.status)
    actions {
      Button(L10n.Settings.detailedStatus) { model.showDetails = true }
      Button(L10n.Settings.setUpModels) {
        if model.canManageBackend { openModels() }
      }
      .disabled(!model.canManageBackend || model.busy)
      switchBackButton
    }
  }

  @ViewBuilder private func backupRows(_ backup: HistoryBackupInfo) -> some View {
    SettingsRow(L10n.Settings.backupDate, value: Fmt.dateTime(backup.frozenAt))
    SettingsRow(L10n.Settings.storageUsed, value: ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))
    countRow(L10n.Settings.privateRecords, backup.privateCount)
    countRow(L10n.Settings.notUploaded, backup.unuploadedCount)
    SettingsRow(L10n.Settings.lastReconciled, value: backup.lastReconciledAt.map(Fmt.dateTime) ?? L10n.Settings.notReconciled)
    actions {
      Button {
        model.confirmDelete = true
      } label: {
        Text(L10n.Settings.deleteLocalBackupEllipsis).foregroundStyle(model.canDelete ? Palette.attention : Palette.muted)
      }
      .buttonStyle(.borderless).disabled(!model.canDelete)
    }
    if let block = model.backupBlock { Note(block) }
  }

  private func pathRow(_ label: String, _ value: String) -> some View {
    SettingsRow(label) {
      Text(value).font(.mono(TextSize.body)).foregroundStyle(Palette.muted)
        .multilineTextAlignment(.trailing).textSelection(.enabled)
    }
  }

  private func actions(@ViewBuilder _ content: () -> some View) -> some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      content()
    }.accessibilityElement(children: .contain)
  }

  private func busyLine(_ message: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(message).foregroundStyle(Palette.muted)
    }
  }
}

private struct RemoteBackendModelStatusRows: View {
  let status: RemoteBackendStatus?
  var body: some View {
    if let notice = status?.modelSetupNotice {
      SettingsMessage(text: notice, warning: false).font(.system(size: TextSize.caption))
    } else if let progress = status?.modelProgress {
      SettingsRow(L10n.Settings.summarize, value: progress)
    } else {
      switch status?.distill.state {
      case .working: EmptyView()
      case .waiting: SettingsRow(L10n.Settings.summarize, value: L10n.Settings.awaitingFirstSummary)
      case .failing(let reason): SettingsMessage(text: L10n.Settings.modelFailure(reason, fallback: L10n.Settings.summaryFailure))
      case nil: SettingsRow(L10n.Settings.summarize, value: L10n.Settings.temporarilyUnavailable)
      }
    }
    if let time = status?.distill.lastOkAt.flatMap(ViewerTime.parse) {
      SettingsRow(L10n.Settings.latestSummary, value: Fmt.dateTime(time))
    }
    if let warning = status?.timezoneNotice { SettingsMessage(text: warning) }
  }
}

struct RemoteBackendDetails: View {
  let model: RemoteBackendSettingsModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.Settings.detailedStatus).font(.system(size: TextSize.title, weight: .semibold))
      SettingsForm {
        Section(L10n.Settings.remoteBackend) {
          SettingsRow(L10n.Settings.connect, value: model.onlineTitle)
          if let channel = model.channel ?? model.unconfirmedChannel { SettingsRow(L10n.Settings.connectionType, value: channel.title) }
          if let total = model.status?.records?.total { countRow(L10n.Settings.recordsSaved, total) }
          RemoteBackendModelStatusRows(status: model.status)
        }
        if let progress = model.progress {
          Section(L10n.Settings.historySync) {
            countRow(L10n.Settings.confirmed, progress.confirmed)
            countRow(L10n.Settings.needsAttention, progress.needsAttention, attention: model.pendingAttention != nil, hidesZero: true)
            if let notice = model.importNotice { SettingsMessage(text: notice, warning: false) }
            if let category = progress.errorCategory { SettingsMessage(text: Self.issueText(category)) }
            if let error = model.issueError { SettingsMessage(text: error) }
            if let activity = model.issueAction {
              SettingsMessage(text: activity, warning: false)
            } else if progress.isComplete && progress.hasPendingReceipt {
              SettingsMessage(text: model.channel == nil ? L10n.Settings.retryScheduled : L10n.Settings.retryingRecords, warning: false)
            }
            if !progress.issues.isEmpty {
              SettingsMessage(text: L10n.Settings.keptInLocalBackup, warning: false)
              ForEach(progress.issues, id: \.id) { issue in
                SettingsRow {
                  HStack(spacing: 8) {
                    if issue.category != "kept_in_backup" {
                      Button(L10n.Settings.keepInBackup) { Task { await model.keepIssue(issue.id) } }.disabled(!model.canKeepIssue)
                    }
                    Button(L10n.Settings.retry) { Task { await model.retryIssue(issue.id) } }.disabled(!model.canRetryIssue)
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(Self.issueText(issue.category))
                    HStack(spacing: 0) {
                      Text(L10n.Settings.recordID).font(.system(size: TextSize.caption))
                      Text(issue.id).font(.mono(TextSize.caption)).textSelection(.enabled)
                    }.foregroundStyle(Palette.muted)
                  }
                }
              }
            }
          }
        }
      }
      Button(L10n.Settings.close, action: close).keyboardShortcut(.cancelAction).frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(24).frame(width: 560, height: 650)
    .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
  }

  static func issueText(_ category: String) -> String {
    switch category {
    case "record_conflict": L10n.Settings.remoteRecordConflict
    case "device_collision": L10n.Settings.remoteDeviceCollision
    case "correction_target": L10n.Settings.correctionTargetMissing
    case "private_record", "out_of_scope": L10n.Settings.recordOnlyLocal
    case "kept_in_backup": L10n.Settings.recordKeptInBackup
    case "receipt_invalid": L10n.Settings.remoteReceiptInvalid
    case "snapshot_changed", "backup_unavailable", "local_history_command_failed": L10n.Settings.localBackupUnavailable
    case "authorization_expired": L10n.Settings.syncAuthorizationExpired
    case "connection_or_storage_unavailable": L10n.Settings.remoteOrBackupUnavailable
    case "batch_requires_connection_with_more_capacity", "batch_too_large", "record_too_large": L10n.Settings.syncRecordTooLarge
    default: L10n.Settings.remoteRecordRejected
    }
  }
}

struct RemoteBackendConfirmation: View {
  enum Action {
    case switchBack(RemoteBackendSettingsModel.ReturnPreview)
    case deleteBackup
  }

  static var backupRecovery: String { L10n.Settings.backupRecoveryNote }

  let action: Action
  let cancel: () -> Void
  let confirm: () -> Void
  let busy: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch action {
      case .switchBack(let preview):
        heading(L10n.Settings.switchBackQuestion)
        Text(L10n.Settings.remoteDataStays)
        Text(preview.explanation).foregroundStyle(Palette.muted)
        countRow(L10n.Settings.recordsToBringBack, preview.pending)
        buttons(L10n.Settings.switchBack, busyTitle: preview.empty ? L10n.Settings.switchingBack : L10n.Settings.reconciling)
      case .deleteBackup:
        heading(L10n.Settings.deleteLocalBackupQuestion)
        Text(L10n.Settings.deleteBackupNote)
        Text(Self.backupRecovery).foregroundStyle(Palette.muted)
        buttons(L10n.Settings.deleteLocalBackup, destructive: true)
      }
    }
    .padding(24).frame(width: 460, alignment: .leading)
    .font(.system(size: TextSize.body))
    .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
    .interactiveDismissDisabled(busy)
  }

  private func heading(_ title: String) -> some View {
    Text(title).font(.system(size: TextSize.title, weight: .semibold)).accessibilityAddTraits(.isHeader)
  }

  private func buttons(_ title: String, busyTitle: String = L10n.Settings.deleting, destructive: Bool = false) -> some View {
    HStack(spacing: 8) {
      Spacer()
      Button(L10n.Settings.cancel, action: cancel).keyboardShortcut(.cancelAction)
      if destructive {
        Button(action: confirm) {
          Text(busy ? busyTitle : title).foregroundStyle(busy ? Palette.muted : Palette.attention)
        }
          .buttonStyle(.borderless)
      } else {
        Button(busy ? busyTitle : title, action: confirm).buttonStyle(.accent).keyboardShortcut(.defaultAction)
      }
    }.disabled(busy)
  }
}

/// 数量为 0 的辅助统计不占一行（hidesZero）；还没统计出来时仍显示“尚未统计”。
@ViewBuilder
private func countRow(_ title: String, _ count: Int?, attention: Bool = false, hidesZero: Bool = false) -> some View {
  if !(hidesZero && count == 0) {
  SettingsRow {
    Text(count.map { L10n.Settings.recordCount($0, chineseUsesSystemLocale: true) } ?? L10n.Settings.notCounted)
      .monospacedDigit().foregroundStyle(attention ? Palette.attention : Palette.muted)
  } label: {
    Text(title).foregroundStyle(attention ? Palette.attention : Palette.ink)
  }
  }
}
