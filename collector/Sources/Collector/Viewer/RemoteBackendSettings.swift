import SwiftUI
import enum CollectorCore.ViewerTime

struct RemoteBackendSettingsSection: View {
  @Bindable var model: RemoteBackendSettingsModel
  let queue: Int
  let sent: Int
  let openModels: () -> Void

  var body: some View {
    Section("后台服务") {
      connectionRow
      if model.context.returning {
        SettingsMessage(text: "上次切回尚未完成。")
        Button("取消切回") { Task { await model.cancelInterruptedReturn() } }.disabled(model.busy)
      } else if model.recovering {
        SettingsMessage(text: model.recoveryMessage)
        actions {
          if model.context.rePairing == .recovery(canCancel: true) {
            Button("取消重新配对") { Task { await model.cancelRePairing() } }.disabled(!model.canCancelRePairing)
          }
          Button("恢复切换") { Task { await model.recover() } }.buttonStyle(.accent).disabled(model.busy)
        }
      } else if model.frozen && !model.repairing {
        frozenControls
      } else if let step = model.step {
        wizard(step)
      } else {
        ForEach(model.context.retained, id: \.hub_id) { link in
          Button("重新连接\(link.hubName ?? "远端后台")") { Task { await model.reconnect(link) } }
            .disabled(model.busy)
        }
        Button("连接远端后台") { model.start() }.disabled(model.busy)
        if model.busy { busyLine("正在检查连接…") }
      }
      if let notice = model.cleanupNotice {
        SettingsMessage(text: notice)
        Button("知道了") { Task { await model.dismissCleanup() } }.disabled(model.busy)
      }
      if let error = model.error { SettingsMessage(text: error) }
    }
    if model.isRemote, let backup = model.backup {
      Section("本机备份") { backupRows(backup) }
    }
  }

  private var connectionRow: some View {
    SettingsRow {
      if model.isRemote {
        if let channel = model.channel ?? model.unconfirmedChannel {
          Text(channel.rawValue).foregroundStyle(Palette.muted)
        } else if let name = model.context.link?.hubName {
          Text(name).foregroundStyle(Palette.muted)
        }
      }
    } label: {
      Text(model.isRemote ? model.onlineTitle : "这台 Mac")
    }
  }

  @ViewBuilder private var frozenControls: some View {
    SettingsMessage(text: "远端后台无法验证这台 Mac，新的记录会在本机等待保存。")
    SettingsRow("直连地址") {
      TextField("直连地址", text: $model.manualAddress, prompt: Text(verbatim: "https://tacit.example.com"))
        .labelsHidden().textFieldStyle(.roundedBorder).disabled(model.busy)
    }
    actions {
      Button("用原连接恢复") { Task { await model.reauthenticate() } }.disabled(!model.canReauthenticate)
      Button("重新配对") { model.start(repairing: true) }.buttonStyle(.accent).disabled(model.busy)
    }
    if model.busy { busyLine("正在验证原连接…") }
  }

  @ViewBuilder private func wizard(_ step: RemoteBackendSettingsModel.Step) -> some View {
    if model.repairing {
      Text(step == .target ? step.title : "重新配对").accessibilityAddTraits(.isHeader)
    } else if step.rawValue < 5 {
      // 第 5 步就是已连接的常态：首行“已连接到…”已经说明，不再单独占一行。
      SettingsRow(step.title) {
        if step.rawValue <= 3 {
          // 第 4、5 步是自动导入和连好后的常态，要用户动手的只有前 3 步。
          Text("第 \(step.rawValue) 步，共 3 步")
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
    SettingsRow("配对链接") {
      SecureField("配对链接", text: $model.invitationText, prompt: Text("粘贴配对链接"))
        .labelsHidden().textFieldStyle(.roundedBorder)
        .onSubmit { Task { await model.checkConnection() } }
        .disabled(model.busy)
    }
    if let invitation = model.invitation {
      SettingsRow("服务名称", value: invitation.hubName)
      ForEach(invitation.addresses, id: \.self) { origin in
        pathRow("地址", origin.absoluteString)
      }
      SettingsRow("有效期", value: Fmt.dateTime(invitation.expiresAt))
    }
    if model.offerManualAddress {
      SettingsRow("直连地址") {
        TextField("直连地址", text: $model.manualAddress, prompt: Text(verbatim: "https://tacit.example.com"))
          .labelsHidden().textFieldStyle(.roundedBorder).disabled(model.busy)
          .onSubmit { Task { await model.checkConnection() } }
      }
    }
    if model.busy {
      busyLine(model.checkingMessage)
    }
    actions {
      Button("取消") { Task { await model.cancel() } }.disabled(model.busy)
      Button(model.offerManualAddress ? "重试" : "检查连接") { Task { await model.checkConnection() } }
        .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canCheck)
    }
  }

  @ViewBuilder private var targetRows: some View {
    if let target = model.target {
      SettingsRow("服务名称", value: target.name ?? "远端后台")
      SettingsRow("连接方式", value: target.channel.rawValue)
      if let notice = model.replacementNotice { SettingsMessage(text: notice) }
      actions {
        Button(model.replacementExpired ? "返回" : "取消") {
          if model.replacementExpired { model.start(repairing: true) }
          else { Task { await model.cancel() } }
        }
        .disabled(model.busy)
        Button(model.repairing ? "重新配对" : "继续") {
          Task {
            if model.repairing { await model.commitReplacement() }
            else { await model.loadSwitchPreview() }
          }
        }
        .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canConfirmTarget)
      }
      .task(id: model.replacementExpiresAt) { await model.waitForReplacementExpiry() }
    } else {
      SettingsMessage(text: "无法读取已确认的远端后台。")
      Button("取消") { Task { await model.cancel() } }.disabled(model.busy)
    }
  }

  @ViewBuilder private var switchRows: some View {
    if let preview = model.preview {
      countRow("准备上传", preview.history.total)
      countRow("私密记录留在本机", preview.history.privateCount)
      VStack(alignment: .leading, spacing: 4) {
        Text("备份位置")
        Text(preview.path).font(.mono(TextSize.body)).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !preview.phones.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(preview.phones) { phone in
            Label { Text(phone.name) } icon: { PhIcon("device-mobile", size: 16) }
          }
          Toggle("我确认这些设备需要在远端后台重新配对", isOn: $model.phonesConfirmed)
            .disabled(model.busy)
        }
      }
      actions {
        Button("取消") { Task { await model.cancel() } }.disabled(model.busy)
        Button("切换后台") { Task { await model.commit() } }
          .buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
      }
    }
  }

  @ViewBuilder private var importRows: some View {
    if let progress = model.progress, let total = progress.total {
      ProgressView(value: Double(progress.confirmed), total: Double(max(1, total))) {
        Text("已确认 \(progress.confirmed.formatted()) / \(total.formatted()) 条").monospacedDigit()
      }
    } else {
      Text("正在统计历史记录…").foregroundStyle(Palette.muted)
    }
    if let progress = model.progress {
      countRow("已存在", progress.alreadyPresent, hidesZero: true)
      countRow("已跳过", progress.skipped, hidesZero: true)
      countRow("需要处理", progress.needsAttention, attention: model.pendingAttention != nil, hidesZero: true)
    }
    countRow("新记录等待保存", queue, hidesZero: true)
    if let notice = model.importNotice { SettingsMessage(text: notice, warning: false) }
    actions {
      Button("详细状态") { model.showDetails = true }
      Button(model.progress?.isPaused == true ? "继续同步" : "暂停同步") {
        Task { await model.changePause() }
      }
      .disabled(!model.canChangePause)
      switchBackButton
    }
  }

  private var switchBackButton: some View {
    Button("切回这台 Mac") { Task { await model.loadReturnPreview() } }.disabled(!model.canReturn)
  }

  @ViewBuilder private var remoteRows: some View {
    countRow("等待保存", queue, hidesZero: true)
    if let pending = model.pendingAttention {
      countRow("需要处理", pending, attention: true)
    }
    RemoteBackendModelStatusRows(status: model.status)
    actions {
      Button("详细状态") { model.showDetails = true }
      Button("设置模型") {
        if model.canManageBackend { openModels() }
      }
      .disabled(!model.canManageBackend || model.busy)
      switchBackButton
    }
  }

  @ViewBuilder private func backupRows(_ backup: HistoryBackupInfo) -> some View {
    if backup.recovery == .emptyLocalBackend {
      Text("本机备份已删除").foregroundStyle(Palette.muted)
    } else {
      SettingsRow("备份日期", value: Fmt.dateTime(backup.frozenAt))
      SettingsRow("占用", value: ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))
      countRow("私密记录", backup.privateCount)
      countRow("未上传记录", backup.unuploadedCount)
      SettingsRow("上次核对", value: backup.lastReconciledAt.map(Fmt.dateTime) ?? "尚未核对")
      Button {
        model.confirmDelete = true
      } label: {
        Text("删除本机备份…").foregroundStyle(model.canDelete ? Palette.attention : Palette.muted)
      }
      .buttonStyle(.borderless).disabled(!model.canDelete)
      if let block = model.backupBlock { Note(block) }
    }
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
      SettingsRow("整理", value: progress)
    } else {
      switch status?.distill.state {
      case .working: EmptyView()
      case .waiting: SettingsRow("整理", value: "等待首次完成")
      case .failing: SettingsMessage(text: "整理遇到问题，请检查模型设置。")
      case nil: SettingsRow("整理", value: "暂时无法读取")
      }
    }
    if let time = status?.distill.lastOkAt.flatMap(ViewerTime.parse) {
      SettingsRow("最近完成整理", value: Fmt.dateTime(time))
    }
    if let warning = status?.timezoneNotice { SettingsMessage(text: warning) }
  }
}

struct RemoteBackendDetails: View {
  let model: RemoteBackendSettingsModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("详细状态").font(.system(size: TextSize.title, weight: .semibold))
      SettingsForm {
        Section("远端后台") {
          SettingsRow("连接", value: model.onlineTitle)
          if let channel = model.channel ?? model.unconfirmedChannel { SettingsRow("连接方式", value: channel.rawValue) }
          if let total = model.status?.records?.total { countRow("已保存记录", total) }
          RemoteBackendModelStatusRows(status: model.status)
        }
        if let progress = model.progress {
          Section("历史同步") {
            countRow("已确认", progress.confirmed)
            countRow("需要处理", progress.needsAttention, attention: model.pendingAttention != nil)
            if let notice = model.importNotice { SettingsMessage(text: notice, warning: false) }
            if let category = progress.errorCategory { SettingsMessage(text: Self.issueText(category)) }
            if let error = model.issueError { SettingsMessage(text: error) }
            if let activity = model.issueAction {
              SettingsMessage(text: activity, warning: false)
            } else if progress.isComplete && progress.hasPendingReceipt {
              SettingsMessage(text: model.channel == nil ? "已安排重试。" : "正在重试记录…", warning: false)
            }
            if !progress.issues.isEmpty {
              SettingsMessage(text: "这些记录仍在本机备份中。", warning: false)
              ForEach(progress.issues, id: \.id) { issue in
                SettingsRow {
                  HStack(spacing: 8) {
                    if issue.category != "kept_in_backup" {
                      Button("留在备份") { Task { await model.keepIssue(issue.id) } }.disabled(!model.canKeepIssue)
                    }
                    Button("重试") { Task { await model.retryIssue(issue.id) } }.disabled(!model.canRetryIssue)
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(Self.issueText(issue.category))
                    Text(issue.id).font(.mono(TextSize.caption)).foregroundStyle(Palette.muted).textSelection(.enabled)
                  }
                }
              }
            }
          }
        }
      }
      Button("关闭", action: close).keyboardShortcut(.cancelAction).frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(24).frame(width: 560, height: 650)
    .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent)
  }

  static func issueText(_ category: String) -> String {
    switch category {
    case "record_conflict": "远端已有不同版本"
    case "device_collision": "记录所属设备冲突"
    case "correction_target": "找不到修正对应的原记录"
    case "private_record", "out_of_scope": "这条记录仅保留在本机"
    case "kept_in_backup": "已留在本机备份"
    case "receipt_invalid": "无法核对远端确认结果"
    case "snapshot_changed", "backup_unavailable", "local_history_command_failed": "无法读取本机备份"
    case "authorization_expired": "历史同步授权已到期"
    case "connection_or_storage_unavailable": "暂时无法连接远端后台或读取备份"
    case "batch_requires_connection_with_more_capacity", "batch_too_large", "record_too_large": "记录超出当前连接的容量"
    default: "远端后台未接受这条记录"
    }
  }
}

struct RemoteBackendConfirmation: View {
  enum Action {
    case switchBack(RemoteBackendSettingsModel.ReturnPreview)
    case deleteBackup
  }

  static let backupRecovery = "删除后只能建立空的本机后台，仍可连接远端查看已保存的记录。"

  let action: Action
  let cancel: () -> Void
  let confirm: () -> Void
  let busy: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch action {
      case .switchBack(let preview):
        heading("切回这台 Mac？")
        Text("已保存到远端的记录和整理结果会留在远端。")
        Text(preview.explanation).foregroundStyle(Palette.muted)
        countRow("可转回本机的待发记录", preview.pending)
        buttons("切回这台 Mac")
      case .deleteBackup:
        heading("删除本机备份？")
        Text("备份里仅存在于这台 Mac 的记录会永久删除。")
        Text(Self.backupRecovery).foregroundStyle(Palette.muted)
        buttons("删除本机备份", destructive: true)
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

  private func buttons(_ title: String, destructive: Bool = false) -> some View {
    HStack(spacing: 8) {
      Spacer()
      Button("取消", action: cancel).keyboardShortcut(.cancelAction)
      if destructive {
        Button(action: confirm) {
          Text(busy ? "正在删除…" : title).foregroundStyle(busy ? Palette.muted : Palette.attention)
        }
          .buttonStyle(.borderless)
      } else {
        Button(busy ? "正在核对…" : title, action: confirm).buttonStyle(.accent).keyboardShortcut(.defaultAction)
      }
    }.disabled(busy)
  }
}

/// 数量为 0 的辅助统计不占一行（hidesZero）；还没统计出来时仍显示“尚未统计”。
@ViewBuilder
private func countRow(_ title: String, _ count: Int?, attention: Bool = false, hidesZero: Bool = false) -> some View {
  if !(hidesZero && count == 0) {
  SettingsRow {
    Text(count.map { "\($0.formatted()) 条" } ?? "尚未统计")
      .monospacedDigit().foregroundStyle(attention ? Palette.attention : Palette.muted)
  } label: {
    Text(title).foregroundStyle(attention ? Palette.attention : Palette.ink)
  }
  }
}
