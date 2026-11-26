import CollectorCore
import AppKit
import SwiftUI
import enum CollectorCore.ViewerFormat
import enum CollectorCore.ViewerTime

private func deviceMessage(_ error: Error, fallback: String) -> String {
  (error as? HubError)?.actionMessage.map { L10n.Settings.serviceMessage($0, fallback: fallback) } ?? fallback
}

/// 设置页读取失败：能让用户处理的照原话说，其他的在原句后补一句原因，并在诊断信息里记下固定类别。
func settingsReadFailure(_ error: Error, fallback: String, section: DiagnosticLog.SettingsSection) -> String {
  let hubError = error as? HubError
  DiagnosticLog.shared.record(.settingsReadFailed(section, reason: (hubError?.reason ?? .other).rawValue))
  if let action = hubError?.actionMessage { return L10n.Settings.serviceMessage(action, fallback: fallback) }
  let reason: String? = switch hubError?.reason {
  case .unreachable: L10n.Settings.reasonUnreachable
  case .timedOut: L10n.Settings.reasonTimedOut
  case .deviceLink: L10n.Settings.reasonDeviceLink
  case .badResponse: L10n.Settings.reasonBadResponse
  case .server: L10n.Settings.reasonServer
  case .other, nil: nil
  }
  return reason.map { L10n.Settings.unavailable(fallback, because: $0) } ?? fallback
}

struct DeviceSettingsSection: View {
  private struct Session: Identifiable {
    let id = UUID()
    let invitation: DeviceInvitation
    let expires: Date
    let role: DeviceSettings.Role
    let platform: String
    let previousDevices: Set<String>
    let qr: CGImage?
  }

  @Environment(ViewerStore.self) private var store
  @State private var settings: DeviceSettings?
  @State private var needsUpdate = false
  @State private var busy = false
  @State private var error: String?
  @State private var sheetError: String?
  @State private var session: Session?
  @State private var sheetOpen = false
  @State private var connectedDevice: String?
  @State private var copied = false
  @State private var deviceToRemove: DeviceSettings.Device?
  @State private var demotion: Demotion?
  private struct Demotion { let device: DeviceSettings.Device; let role: DeviceSettings.Role }
  @State private var step = DeviceInvitationChoices.Step.type
  @State private var expandedDevice: String?

  var body: some View {
    let activeSession = session
    Section(L10n.Settings.devices) {
      if needsUpdate {
        SettingsMessage(text: L10n.Settings.updateBackendForDevices, warning: false)
      } else {
        if let settings {
          ForEach(settings.displayedDevices) { device in
            DeviceSettingsRow(device: device, isCurrent: device.id == settings.currentDeviceId,
                              expanded: expandedDevice == device.id) {
              expandedDevice = expandedDevice == device.id ? nil : device.id
            } changeRole: { role in
              // 远程不能升回管理：取消管理权限前先确认，其他改动直接生效。
              if device.role == .admin && role != .admin { demotion = Demotion(device: device, role: role) }
              else { changeRole(device, role) }
            } remove: {
              deviceToRemove = device
            }
            .disabled(busy)
          }
          Button(L10n.Settings.addDevice) {
            step = .type
            sheetOpen = true
          }
          .disabled(busy)
        }
        if let error {
          SettingsMessage(text: error)
          if settings == nil { Button(L10n.Settings.retry) { Task { await reload() } }.disabled(busy) }
        } else if settings == nil {
          Text(L10n.Settings.loadingDevices).foregroundStyle(Palette.muted)
        }
      }
    }
    // 换后台时整页根视图也会重建（resetForBindingChange）；这里再把本组状态清干净，免得旧后台的弹窗或配对留下来。
    .task(id: store.remoteBackend?.context.binding.route) {
      settings = nil; error = nil; needsUpdate = false; expandedDevice = nil; deviceToRemove = nil; demotion = nil
      copied = false; step = .type
      closeSheet()
      await reload()
    }
    // 用 presenting：点按钮时 isPresented 先置 false 清掉 demotion，按钮里再读 @State 就是 nil。
    .alert(demotion.map { L10n.Settings.removeAdminQuestion($0.device.name) } ?? "", isPresented: Binding(
      get: { demotion != nil },
      set: { if !$0 { demotion = nil } }
    ), presenting: demotion) { pending in
      Button(L10n.Settings.cancel, role: .cancel) {}
      Button(L10n.Settings.changeRole(pending.role.title), role: .destructive) { changeRole(pending.device, pending.role) }
    } message: { _ in
      Text(L10n.Settings.demoteDeviceNote)
    }
    .alert(deviceToRemove.map { L10n.Settings.removeDeviceQuestion($0.name) } ?? "", isPresented: Binding(
      get: { deviceToRemove != nil },
      set: { if !$0 { deviceToRemove = nil } }
    ), presenting: deviceToRemove) { device in
      Button(L10n.Settings.cancel, role: .cancel) {}
      Button(L10n.Settings.remove, role: .destructive) {
        Task { await mutate(failure: L10n.Settings.removeDeviceFailed) { try await store.api.removeDevice(device.id) } }
      }
    } message: { _ in
      Text(L10n.Settings.removeDeviceNote)
    }
    .sheet(isPresented: $sheetOpen, onDismiss: closeSheet) {
      if let activeSession {
        pairingSheet(activeSession)
          .task(id: activeSession.id) { await waitForDevice(activeSession) }
          .interactiveDismissDisabled()
      } else {
        DeviceInvitationChoices(step: step, busy: busy, error: sheetError) {
          // Mac 上还没有能接收“查看”邀请的入口，另一台 Mac 只发管理邀请；配好后可在列表里改为查看。
          step = .confirmAdmin
          sheetError = nil
        } invite: { role, platform in
          Task { await createInvitation(role, platform: platform) }
        } cancel: {
          closeSheet()
        } back: {
          step = .type
          sheetError = nil
        }
        .interactiveDismissDisabled(busy)
      }
    }
    .tint(Palette.accent)
  }

  private func pairingSheet(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.Settings.addDevice).font(.system(size: TextSize.title, weight: .semibold))
      if let connectedDevice {
        Text(L10n.Settings.deviceConnected(connectedDevice))
      } else {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          let remaining = max(0, Int(ceil(session.expires.timeIntervalSince(timeline.date))))
          VStack(alignment: .leading, spacing: 12) {
            if remaining > 0 {
              if session.platform == "mac" {
                Text(L10n.Settings.macInviteNote)
                  .fixedSize(horizontal: false, vertical: true)
              } else if let qr = session.qr {
                Image(decorative: qr, scale: 1)
                  .interpolation(.none)
                  .accessibilityHidden(true)
                  .frame(maxWidth: .infinity)
                Text(L10n.Settings.scanQRCode)
              } else {
                Text(L10n.Settings.qrCodeUnavailable)
              }
              Text(DeviceInvitationChoices.countdown(remaining))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
              Text(verbatim: session.invitation.uri)
                .font(.system(size: TextSize.caption))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .accessibilityLabel(L10n.Settings.inviteLink)
              Button(copied ? L10n.Settings.copied : L10n.Settings.copyInviteLink) { copyInvitation(session) }
                .disabled(busy)
            } else {
              Text(L10n.Settings.inviteExpired)
              Button(L10n.Settings.generateAgain) { Task { await createInvitation(session.role, platform: session.platform) } }
                .disabled(busy)
            }
          }
        }
        if let sheetError { SettingsMessage(text: sheetError) }
        HStack {
          Spacer()
          Button(L10n.Settings.cancel) { Task { await cancelInvitation() } }
            .keyboardShortcut(.cancelAction)
            .disabled(busy)
        }
      }
    }
    .font(.system(size: TextSize.body))
    .padding(24)
    .frame(width: 380)
  }

  private func reload() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    await loadSettings()
  }

  private func loadSettings() async {
    guard store.canManageBackend, !Task.isCancelled else { return }
    do {
      let result = try await store.api.deviceSettings()
      try Task.checkCancellation()
      settings = result
      needsUpdate = result == nil
      error = nil
      store.onDeviceSettingsUpdate?(result, nil)
    } catch is CancellationError {
    } catch {
      settings = nil
      self.error = settingsReadFailure(error, fallback: L10n.Settings.devicesUnavailable, section: .devices)
    }
  }

  private func createInvitation(_ role: DeviceSettings.Role, platform: String) async {
    guard !busy, store.canManageBackend else { return }
    busy = true
    defer { busy = false }
    error = nil
    sheetError = nil
    do {
      // 创建前重新取基准，已有设备不能被当成这次配对的结果。
      guard let before = try await store.api.deviceSettings() else {
        needsUpdate = true
        closeSheet()
        store.onDeviceSettingsUpdate?(nil, nil)
        return
      }
      settings = before
      guard store.canManageBackend else { return }
      let invitation = try await store.api.createDeviceInvitation(role: role.rawValue)
      guard let expires = ViewerTime.parse(invitation.expiresAt) else {
        throw HubError(message: L10n.Settings.invalidInviteExpiry, status: 0)
      }
      let active = Session(invitation: invitation, expires: expires, role: role, platform: platform,
                           previousDevices: Set(before.devices.map(\.id)), qr: platform == "android" ? invitation.qrCode() : nil)
      copied = false
      session = active
      sheetOpen = true
    } catch {
      let message = deviceMessage(error, fallback: L10n.Settings.createInviteFailed)
      if sheetOpen { sheetError = message }
      else { self.error = message }
    }
  }

  private func waitForDevice(_ active: Session) async {
    // 第一次读打开邀请后的监听状态，之后只用两秒轮询确认配对结果。
    var updateDiscovery = true
    while !Task.isCancelled && store.canManageBackend {
      if !busy {
        do {
          let result = try await store.api.deviceSettings()
          guard !Task.isCancelled, session?.id == active.id else { return }
          if !busy {
            guard let result else {
              needsUpdate = true
              store.onDeviceSettingsUpdate?(nil, nil)
              closeSheet()
              return
            }
            settings = result
            if updateDiscovery {
              let sameInvitation = result.pairing.flatMap { ViewerTime.parse($0.expiresAt) } == active.expires
              let hubId = sameInvitation ? active.invitation.hubId : nil
              store.onDeviceSettingsUpdate?(result, hubId)
              updateDiscovery = false
            }
            // 兼容精度只到整秒的配对时间。
            let duration: TimeInterval = active.role == .admin ? 300 : 600
            let issuedAt = Date(timeIntervalSince1970: floor(active.expires.timeIntervalSince1970) - duration)
            if result.pairing == nil, let device = result.displayedDevices.first(where: {
              !active.previousDevices.contains($0.id) && $0.role == active.role &&
                $0.platform == active.platform &&
                (ViewerTime.parse($0.pairedAt) ?? .distantPast) >= issuedAt
            }) {
              store.onDeviceSettingsUpdate?(result, nil)
              connectedDevice = device.name
              try await Task.sleep(for: .milliseconds(1500))
              if session?.id == active.id { closeSheet() }
              return
            }
          }
        } catch is CancellationError {
          return
        } catch {
          if let message = (error as? HubError)?.actionMessage {
            sheetError = L10n.Settings.serviceMessage(message, fallback: L10n.Settings.devicesUnavailable)
            return
          }
          // 连接暂时中断时，保留邀请并在下一轮再检查。
        }
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  private func cancelInvitation() async {
    guard !busy, store.canManageBackend, connectedDevice == nil else { return }
    busy = true
    defer { busy = false }
    sheetError = nil
    do {
      try await store.api.cancelDeviceInvitation()
      closeSheet()
      await loadSettings()
    } catch {
      // 过期后服务端可能已清掉邀请，此时仍可退出弹窗。
      if let session, session.expires <= Date() {
        closeSheet()
        await loadSettings()
      } else {
        sheetError = deviceMessage(error, fallback: L10n.Settings.cancelInviteFailed)
      }
    }
  }

  private func changeRole(_ device: DeviceSettings.Device, _ role: DeviceSettings.Role) {
    Task { await mutate(failure: L10n.Settings.changeDeviceRoleFailed) {
      try await store.api.updateDeviceRole(device.id, role: role.rawValue)
    } }
  }

  private func mutate(failure: String, operation: () async throws -> Void) async {
    guard !busy, store.canManageBackend else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      try await operation()
      await loadSettings()
    } catch {
      self.error = deviceMessage(error, fallback: failure)
    }
  }

  private func closeSheet() {
    sheetOpen = false
    session = nil
    connectedDevice = nil
    sheetError = nil
  }

  private func copyInvitation(_ session: Session) {
    guard session.expires > Date() else { return }
    let clipboard = NSPasteboard.general
    let invitation = NSPasteboardItem()
    invitation.setString(session.invitation.uri, forType: .string)
    // 一次性配对码不进入 Tacit 的剪贴板记录。
    invitation.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    clipboard.clearContents()
    copied = clipboard.writeObjects([invitation])
    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
  }
}

struct DeviceSettingsRow: View {
  let device: DeviceSettings.Device
  let isCurrent: Bool
  let expanded: Bool
  let toggle: () -> Void
  let changeRole: (DeviceSettings.Role) -> Void
  let remove: () -> Void

  @State private var hovering = false
  @FocusState private var focused: Bool

  private var roles: [DeviceSettings.Role] { device.offeredRoles(isCurrent: isCurrent) }
  private var canRemove: Bool { device.canRemove(isCurrent: isCurrent) }

  var body: some View {
    let lastConnection = device.lastSeen.flatMap(ViewerTime.parse).map { ViewerFormat.relative($0) } ?? L10n.Settings.noRecentConnection
    VStack(alignment: .trailing, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: device.platform == "android" ? "iphone" : "laptopcomputer")
          .frame(width: 20).foregroundStyle(Palette.muted).accessibilityHidden(true)
        Text(device.name).lineLimit(1)
        if isCurrent {
          Text(L10n.Settings.thisMac).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 8)
        Text(device.role?.title ?? "").frame(width: 36, alignment: .leading)
        Text(lastConnection)
          .monospacedDigit()
          .frame(minWidth: 84, alignment: .trailing)
          .foregroundStyle(Palette.muted)
          .accessibilityLabel(L10n.Settings.lastConnection)
          .accessibilityValue(lastConnection)
        if canRemove || !roles.isEmpty {
          Button(action: toggle) {
            Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
          }
          .buttonStyle(.plain).foregroundStyle(hovering || focused || expanded ? Palette.ink : Palette.faint)
          .focused($focused)
          .accessibilityLabel(L10n.Settings.deviceActions(device.name))
          .accessibilityValue(expanded ? L10n.Settings.expanded : L10n.Settings.collapsed)
        } else {
          Color.clear.frame(width: 24, height: 20).accessibilityHidden(true)
        }
      }
      if expanded {
        HStack(spacing: 12) { actions(inline: true) }
          .buttonStyle(.plain)
          .padding(.trailing, 32)
      }
    }
    .font(.system(size: TextSize.body))
    .contentShape(Rectangle())
    .hoverState($hovering)
    .contextMenu { actions(inline: false) }
  }

  @ViewBuilder private func actions(inline: Bool) -> some View {
    ForEach(roles, id: \.self) { role in
      Button { changeRole(role) } label: {
        Text(L10n.Settings.changeRole(role.title)).foregroundStyle(inline ? Palette.accent : Palette.ink)
      }
    }
    if canRemove {
      if inline {
        Button(action: remove) { Text(L10n.Settings.remove).foregroundStyle(Palette.attention) }
      } else {
        Button(L10n.Settings.remove, role: .destructive, action: remove)
      }
    }
  }
}

struct DeviceInvitationChoices: View {
  enum Step { case type, confirmAdmin }

  let step: Step
  let busy: Bool
  let error: String?
  let selectMac: () -> Void
  let invite: (DeviceSettings.Role, String) -> Void
  let cancel: () -> Void
  let back: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: TextSize.title, weight: .semibold))
      if step == .confirmAdmin {
        Text(L10n.Settings.grantMacAdminNote)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error { SettingsMessage(text: error) }
      HStack(spacing: 8) {
        if step != .type { Button(L10n.Settings.back, action: back) }
        Spacer()
        Button(L10n.Settings.cancel, action: cancel).keyboardShortcut(.cancelAction)
        switch step {
        case .type:
          Button(L10n.Settings.phone) { invite(.view, "android") }
          Button(L10n.Settings.anotherMac, action: selectMac)
        case .confirmAdmin:
          Button(L10n.Settings.generateInvite) { invite(.admin, "mac") }
            .buttonStyle(.accent).keyboardShortcut(.defaultAction)
        }
      }
      .disabled(busy)
    }
    .font(.system(size: TextSize.body))
    .padding(24).frame(width: 380)
    .tint(Palette.accent)
  }

  static func countdown(_ remaining: Int) -> String {
    let (minutes, seconds) = max(0, remaining).quotientAndRemainder(dividingBy: 60)
    return L10n.Settings.inviteCountdown(minutes: minutes, seconds: seconds)
  }

  private var title: String {
    switch step {
    case .type: L10n.Settings.addDevice
    case .confirmAdmin: L10n.Settings.grantAdminQuestion
    }
  }
}
