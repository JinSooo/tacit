import SwiftUI
import CollectorCore

struct RelaySettingsSection: View {
  private enum Action: Equatable { case test, save, disable }

  @Environment(ViewerStore.self) private var store
  @State private var settings: RelaySettings?
  // nil 时显示后台服务保存的地址，开始编辑后只有用户操作才能清掉草稿。
  @State private var draftAddress: String?
  @State private var code = ""
  @State private var action: Action?
  @State private var configurationRevision = 0
  @State private var confirmDisable = false
  @State private var refreshError: String?
  @State private var actionError: String?
  @State private var testPassed = false

  var body: some View {
    Section {
      if let settings {
        Picker("中转信箱", selection: Binding(get: { selectedMode }, set: selectMode)) {
          Text("关闭").tag(RelaySettings.Mode.off)
          Text("自己的信箱").tag(RelaySettings.Mode.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(action != nil)

        if selectedMode == .custom { customFields }
        if settings.mode == .custom {
          if let savedAddress = settings.url, savedAddress != address {
            SettingsRow("当前地址") {
              Text(verbatim: savedAddress).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
          }
          if let connection = RelaySettingsText.connection(settings) {
            SettingsRow("状态") {
              Text(connection).foregroundStyle(settings.connected ? Palette.muted : Palette.attention)
            }
          }
          if let pending = RelaySettingsText.pending(settings) {
            Text(pending).monospacedDigit().foregroundStyle(Palette.muted)
          }
        }
        if let retirement = RelaySettingsText.retirement(settings) {
          SettingsMessage(text: retirement, warning: false)
        }
      } else if refreshError == nil {
        Text("正在读取信箱设置…").foregroundStyle(Palette.muted)
      }
      if let refreshError { SettingsMessage(text: refreshError) }
      if let actionError { SettingsMessage(text: actionError) }
      if testPassed { SettingsMessage(text: "连接测试通过。", warning: false) }
    } header: { Text("中转信箱") }
    footer: { Note("信箱只经手加密内容，能看到传输的时间和大小。") }
    .tint(Palette.accent)
    .onChange(of: address) {
      actionError = nil
      testPassed = false
    }
    .alert("关闭中转信箱？", isPresented: $confirmDisable) {
      Button("取消", role: .cancel) {}
      Button("关闭信箱", role: .destructive) { Task { await perform(.disable) } }
    } message: {
      Text("旧信箱将在 7 天后删除，外出的手机要等回到家里网络才能再同步。")
    }
    .task {
      while !Task.isCancelled {
        await refresh()
        await WindowVisibility.pause(.seconds(5))
      }
    }
  }

  private var selectedMode: RelaySettings.Mode {
    draftAddress == nil ? settings?.mode ?? .off : .custom
  }

  private var address: String { draftAddress ?? settings?.url ?? "" }

  private var customFields: some View {
    Group {
      SettingsRow("信箱地址") {
        TextField("信箱地址", text: Binding(get: { address }, set: { draftAddress = $0 }),
                  prompt: Text("https://"))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 380)
      }
      SettingsRow("开通码") {
        SecureField("开通码", text: Binding(get: { code }, set: editCode), prompt: Text("可留空"))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 380)
      }
      HStack(spacing: 8) {
        Spacer()
        Button(action == .test ? "正在测试…" : "测试连接") { Task { await perform(.test) } }
        Button(action == .save ? "正在保存…" : "保存") { Task { await perform(.save) } }
      }
    }
    .disabled(action != nil)
  }

  private func editCode(_ value: String) {
    // 输入开通码时也固定地址，避免刷新把同一份草稿带到别的信箱。
    if draftAddress == nil && !value.isEmpty { draftAddress = address }
    code = value
  }

  private func selectMode(_ mode: RelaySettings.Mode) {
    guard action == nil, mode != selectedMode else { return }
    switch mode {
    case .custom:
      draftAddress = address
    case .off:
      if settings?.mode == .custom {
        confirmDisable = true
      } else {
        draftAddress = nil
        code = ""
        actionError = nil
        testPassed = false
      }
    }
  }

  private func refresh() async {
    guard action != .save, action != .disable else { return }
    let revision = configurationRevision
    do {
      let updated = try await store.api.relaySettings()
      guard !Task.isCancelled, revision == configurationRevision else { return }
      settings = updated
      refreshError = nil
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, revision == configurationRevision else { return }
      refreshError = (error as? HubError)?.actionMessage ?? "暂时无法读取信箱设置。"
    }
  }

  private func perform(_ operation: Action) async {
    guard action == nil else { return }
    action = operation
    actionError = nil
    testPassed = false
    defer { action = nil }
    do {
      let updated: RelaySettings
      if operation == .disable {
        configurationRevision += 1
        updated = try await store.api.disableRelay()
      } else {
        guard let validatedAddress = RelaySettingsText.validatedAddress(address) else {
          actionError = RelaySettingsText.invalidAddress
          return
        }
        if operation == .test {
          let result = try await store.api.testRelay(address: validatedAddress)
          testPassed = result.tacitRelay == 1
          if !testPassed { actionError = RelaySettingsText.failure(status: 400) }
          return
        }
        configurationRevision += 1
        updated = try await store.api.saveRelay(address: validatedAddress, code: code)
      }
      settings = updated
      draftAddress = nil
      code = ""
      refreshError = nil
    } catch is CancellationError {
    } catch {
      let hubError = error as? HubError
      actionError = hubError?.actionMessage ?? RelaySettingsText.failure(status: hubError?.status)
    }
  }
}
