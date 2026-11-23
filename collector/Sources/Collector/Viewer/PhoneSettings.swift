import AppKit
import SwiftUI
import enum CollectorCore.ViewerFormat
import enum CollectorCore.ViewerTime

struct PhoneSettingsSection: View {
  private struct Session: Identifiable {
    let id = UUID()
    let invitation: DeviceInvitation
    let expires: Date
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
  @State private var connectedPhone: String?
  @State private var copied = false
  @State private var phoneToRemove: DeviceSettings.Device?

  var body: some View {
    let activeSession = session
    Section("手机") {
      if needsUpdate {
        SettingsMessage(text: "需要更新后台服务才能配对手机。", warning: false)
      } else {
        if let settings {
          ForEach(settings.phones) { phone in
            SettingsRow {
              Button("移除") { phoneToRemove = phone }
                .foregroundStyle(Palette.attention)
                .disabled(busy)
            } label: {
              Text(phone.name)
              HStack(spacing: 8) {
                Text(phone.lastSeen.flatMap(ViewerTime.parse).map { "上次连接：\(ViewerFormat.relative($0))" } ?? "暂无连接记录")
                Text("已收到 \(phone.records.formatted()) 条记录")
              }
              .font(.system(size: TextSize.caption))
              .foregroundStyle(Palette.muted)
            }
          }
          Button("配对新手机") { Task { await createInvitation() } }
            .disabled(busy)
          if settings.lan.open, let address = settings.lan.addrs.first {
            Text("局域网地址：\(address)")
              .font(.system(size: TextSize.caption))
              .foregroundStyle(Palette.muted)
              .textSelection(.enabled)
          }
        }
        if let error {
          SettingsMessage(text: error)
          if settings == nil { Button("重试") { Task { await reload() } }.disabled(busy) }
        } else if settings == nil {
          Text("正在检查手机连接…").foregroundStyle(Palette.muted)
        }
      }
    }
    .task { await reload() }
    .alert("移除这台手机？", isPresented: Binding(
      get: { phoneToRemove != nil },
      set: { if !$0 { phoneToRemove = nil } }
    ), presenting: phoneToRemove) { phone in
      Button("取消", role: .cancel) {}
      Button("移除", role: .destructive) { Task { await remove(phone) } }
    } message: { _ in
      Text("已保存的记录会保留，这台手机需要重新配对才能再连接。")
    }
    .sheet(isPresented: $sheetOpen) {
      if let activeSession {
        pairingSheet(activeSession)
          .task(id: activeSession.id) { await waitForPhone(activeSession) }
          .interactiveDismissDisabled()
      }
    }
    .tint(Palette.accent)
  }

  private func pairingSheet(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("配对新手机").font(.system(size: TextSize.title, weight: .semibold))
      if let connectedPhone {
        Text("已连接 \(connectedPhone)")
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
                Text("用手机扫描二维码")
              } else {
                Text("二维码无法显示，请复制邀请文本。")
              }
              Text("剩余 \(remaining / 60) 分 \(remaining % 60) 秒")
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
              Text(verbatim: session.invitation.uri)
                .font(.system(size: TextSize.caption))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .accessibilityLabel("邀请文本")
              Button(copied ? "已复制" : "复制邀请文本") { copyInvitation(session) }
                .disabled(busy)
            } else {
              Text("邀请已过期")
              Button("重新生成") { Task { await createInvitation() } }
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
      self.error = "暂时无法读取手机连接。"
    }
  }

  private func createInvitation() async {
    guard !busy else { return }
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
      let invitation = try await store.api.createDeviceInvitation()
      guard let expires = ViewerTime.parse(invitation.expiresAt) else {
        throw HubError(message: "邀请有效期格式错误", status: 0)
      }
      let active = Session(invitation: invitation, expires: expires,
                           previousDevices: Set(before.devices.map(\.id)), qr: invitation.qrCode())
      copied = false
      session = active
      sheetOpen = true
    } catch {
      if sheetOpen { sheetError = "无法生成邀请，请重试。" }
      else { self.error = "无法生成邀请，请重试。" }
    }
  }

  private func waitForPhone(_ active: Session) async {
    // 第一次读打开邀请后的监听状态，之后只用两秒轮询确认配对结果。
    var updateDiscovery = true
    while !Task.isCancelled {
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
            // 邀请时长为 10 分钟。兼容精度只到整秒的配对时间。
            let issuedAt = Date(timeIntervalSince1970: floor(active.expires.timeIntervalSince1970) - 600)
            if result.pairing == nil, let phone = result.phones.first(where: {
              !active.previousDevices.contains($0.id) &&
                (ViewerTime.parse($0.pairedAt) ?? .distantPast) >= issuedAt
            }) {
              store.onDeviceSettingsUpdate?(result, nil)
              connectedPhone = phone.name
              try await Task.sleep(for: .milliseconds(1500))
              if session?.id == active.id { closeSheet() }
              return
            }
          }
        } catch is CancellationError {
          return
        } catch {
          // 连接暂时中断时，保留邀请并在下一轮再检查。
        }
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  private func cancelInvitation() async {
    guard !busy, connectedPhone == nil else { return }
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
        sheetError = "无法取消邀请，请重试。"
      }
    }
  }

  private func remove(_ phone: DeviceSettings.Device) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      try await store.api.removeDevice(phone.id)
      await loadSettings()
    } catch {
      self.error = "无法移除手机，请重试。"
    }
  }

  private func closeSheet() {
    sheetOpen = false
    session = nil
    connectedPhone = nil
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
