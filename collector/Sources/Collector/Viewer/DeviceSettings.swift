import AppKit
import SwiftUI
import enum CollectorCore.ViewerFormat
import enum CollectorCore.ViewerTime

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
  @State private var step = DeviceInvitationChoices.Step.type
  @State private var expandedDevice: String?

  var body: some View {
    let activeSession = session
    Section("设备") {
      if needsUpdate {
        SettingsMessage(text: "需要更新后台服务才能管理设备。", warning: false)
      } else {
        if let settings {
          ForEach(settings.displayedDevices) { device in
            DeviceSettingsRow(device: device, isCurrent: device.id == settings.currentDeviceId,
                              expanded: expandedDevice == device.id) {
              expandedDevice = expandedDevice == device.id ? nil : device.id
            } changeRole: { role in
              Task { await mutate(failure: "无法修改设备权限，请重试。") {
                try await store.api.updateDeviceRole(device.id, role: role.rawValue)
              } }
            } remove: {
              deviceToRemove = device
            }
            .disabled(busy)
          }
          Button("添加设备") {
            step = .type
            sheetOpen = true
          }
          .disabled(busy)
        }
        if let error {
          SettingsMessage(text: error)
          if settings == nil { Button("重试") { Task { await reload() } }.disabled(busy) }
        } else if settings == nil {
          Text("正在读取设备…").foregroundStyle(Palette.muted)
        }
      }
    }
    .task { await reload() }
    .alert("移除这台设备？", isPresented: Binding(
      get: { deviceToRemove != nil },
      set: { if !$0 { deviceToRemove = nil } }
    ), presenting: deviceToRemove) { device in
      Button("取消", role: .cancel) {}
      Button("移除", role: .destructive) {
        Task { await mutate(failure: "无法移除设备，请重试。") { try await store.api.removeDevice(device.id) } }
      }
    } message: { _ in
      Text("已保存的记录会保留，这台设备需要重新配对才能再连接。")
    }
    .sheet(isPresented: $sheetOpen, onDismiss: closeSheet) {
      if let activeSession {
        pairingSheet(activeSession)
          .task(id: activeSession.id) { await waitForDevice(activeSession) }
          .interactiveDismissDisabled()
      } else {
        DeviceInvitationChoices(step: step, busy: busy, error: sheetError) {
          step = .role
        } confirmAdmin: {
          step = .confirmAdmin
        } invite: { role, platform in
          Task { await createInvitation(role, platform: platform) }
        } cancel: {
          closeSheet()
        }
        .interactiveDismissDisabled(busy)
      }
    }
    .tint(Palette.accent)
  }

  private func pairingSheet(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加设备").font(.system(size: TextSize.title, weight: .semibold))
      if let connectedDevice {
        Text("已连接 \(connectedDevice)")
      } else {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          let remaining = max(0, Int(ceil(session.expires.timeIntervalSince(timeline.date))))
          VStack(alignment: .leading, spacing: 12) {
            if remaining > 0 {
              if let qr = session.qr {
                Image(decorative: qr, scale: 1)
                  .interpolation(.none)
                  .accessibilityHidden(true)
                  .frame(maxWidth: .infinity)
                if session.platform == "android" { Text("用手机扫描二维码") }
              } else {
                Text("二维码无法显示，请复制邀请链接。")
              }
              Text("剩余 \(remaining / 60) 分 \(remaining % 60) 秒")
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
              Text(verbatim: session.invitation.uri)
                .font(.system(size: TextSize.caption))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .accessibilityLabel("邀请链接")
              Button(copied ? "已复制" : "复制邀请链接") { copyInvitation(session) }
                .disabled(busy)
            } else {
              Text("邀请已过期")
              Button("重新生成") { Task { await createInvitation(session.role, platform: session.platform) } }
                .disabled(busy)
            }
          }
        }
        if let sheetError { SettingsMessage(text: sheetError) }
        HStack {
          Spacer()
          Button("取消") { Task { await cancelInvitation() } }
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
      self.error = (error as? HubError)?.actionMessage ?? "暂时无法读取设备。"
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
        throw HubError(message: "邀请有效期格式错误", status: 0)
      }
      let active = Session(invitation: invitation, expires: expires, role: role, platform: platform,
                           previousDevices: Set(before.devices.map(\.id)), qr: invitation.qrCode())
      copied = false
      session = active
      sheetOpen = true
    } catch {
      let message = (error as? HubError)?.actionMessage ?? "无法生成邀请，请重试。"
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
            sheetError = message
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
        sheetError = (error as? HubError)?.actionMessage ?? "无法取消邀请，请重试。"
      }
    }
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
      self.error = (error as? HubError)?.actionMessage ?? failure
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
    let lastConnection = device.lastSeen.flatMap(ViewerTime.parse).map { ViewerFormat.relative($0) } ?? "暂无连接"
    VStack(alignment: .trailing, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: device.platform == "android" ? "iphone" : "laptopcomputer")
          .frame(width: 20).foregroundStyle(Palette.muted).accessibilityHidden(true)
        Text(device.name).lineLimit(1)
        if isCurrent {
          Text("这台 Mac").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 8)
        Text(device.role?.title ?? "").frame(width: 36, alignment: .leading)
        Text(lastConnection)
          .monospacedDigit()
          .frame(minWidth: 84, alignment: .trailing)
          .foregroundStyle(Palette.muted)
          .accessibilityLabel("最近连接")
          .accessibilityValue(lastConnection)
        if canRemove || !roles.isEmpty {
          Button(action: toggle) {
            Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
          }
          .buttonStyle(.plain).foregroundStyle(Palette.accent)
          .focused($focused)
          .opacity(hovering || focused || expanded ? 1 : 0.001)
          .accessibilityLabel("\(device.name)的操作")
          .accessibilityValue(expanded ? "已展开" : "已折叠")
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
    .onHover { hovering = $0 }
    .contextMenu { actions(inline: false) }
  }

  @ViewBuilder private func actions(inline: Bool) -> some View {
    ForEach(roles, id: \.self) { role in
      Button { changeRole(role) } label: {
        Text("改为\(role.title)").foregroundStyle(inline ? Palette.accent : Palette.ink)
      }
    }
    if canRemove {
      if inline {
        Button(action: remove) { Text("移除").foregroundStyle(Palette.attention) }
      } else {
        Button("移除", role: .destructive, action: remove)
      }
    }
  }
}

struct DeviceInvitationChoices: View {
  enum Step { case type, role, confirmAdmin }

  let step: Step
  let busy: Bool
  let error: String?
  let selectMac: () -> Void
  let confirmAdmin: () -> Void
  let invite: (DeviceSettings.Role, String) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: TextSize.title, weight: .semibold))
      if step == .confirmAdmin {
        Text("这台设备将能删除记录和修改设置，邀请 5 分钟内有效。")
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error { SettingsMessage(text: error) }
      HStack(spacing: 8) {
        Spacer()
        Button("取消", action: cancel).keyboardShortcut(.cancelAction)
        switch step {
        case .type:
          Button("手机") { invite(.view, "android") }
          Button("另一台 Mac", action: selectMac)
        case .role:
          Button("查看") { invite(.view, "mac") }
          Button("管理", action: confirmAdmin)
        case .confirmAdmin:
          Button("生成邀请") { invite(.admin, "mac") }
            .buttonStyle(.accent).keyboardShortcut(.defaultAction)
        }
      }
      .disabled(busy)
    }
    .font(.system(size: TextSize.body))
    .padding(24).frame(width: 380)
    .tint(Palette.accent)
  }

  private var title: String {
    switch step {
    case .type: "添加设备"
    case .role: "选择权限"
    case .confirmAdmin: "授予管理权限？"
    }
  }
}
