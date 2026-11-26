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
        Picker(L10n.Settings.relayMailbox, selection: Binding(get: { selectedMode }, set: selectMode)) {
          Text(L10n.Settings.off).tag(RelaySettings.Mode.off)
          Text(L10n.Settings.yourMailbox).tag(RelaySettings.Mode.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(action != nil)

        if selectedMode == .custom { customFields }
        if settings.mode == .custom {
          if let savedAddress = settings.url, savedAddress != address {
            SettingsRow(L10n.Settings.currentAddress) {
              Text(verbatim: savedAddress).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
          }
          if let connection = L10n.Settings.relayConnection(settings) {
            SettingsRow(L10n.Settings.status) {
              Text(connection).foregroundStyle(Palette.attention)
            }
          }
          if let lastFetch = L10n.Settings.relayLastFetch(settings) {
            SettingsRow(L10n.Settings.lastMailboxFetch) { Text(lastFetch).monospacedDigit().foregroundStyle(Palette.muted) }
          }
          if let usage = L10n.Settings.relayUsage(settings) {
            SettingsRow(L10n.Settings.mailboxRequestsToday) {
              Text(usage.text).monospacedDigit().foregroundStyle(usage.limited ? Palette.attention : Palette.muted)
            }
          }
          if let pending = L10n.Settings.relayPending(settings) {
            SettingsRow(L10n.Settings.awaitingRetrieval) { Text(pending).monospacedDigit().foregroundStyle(Palette.muted) }
          }
        }
        if let retirement = L10n.Settings.relayRetirement(settings) {
          SettingsMessage(text: retirement, warning: false)
        }
      } else if refreshError == nil {
        Text(L10n.Settings.loadingRelaySettings).foregroundStyle(Palette.muted)
      }
      if let refreshError { SettingsMessage(text: refreshError) }
      if let actionError { SettingsMessage(text: actionError) }
      if testPassed { SettingsMessage(text: L10n.Settings.relayTestPassed, warning: false) }
    } header: { Text(L10n.Settings.relayMailbox) }
    footer: { Note(L10n.Settings.relayNote) }
    .tint(Palette.accent)
    .onChange(of: address) {
      actionError = nil
      testPassed = false
    }
    .onChange(of: code) { actionError = nil }
    .alert(L10n.Settings.disableRelayQuestion, isPresented: $confirmDisable) {
      Button(L10n.Settings.cancel, role: .cancel) {}
      Button(L10n.Settings.disableRelay, role: .destructive) { Task { await perform(.disable) } }
    } message: {
      Text(L10n.Settings.disableRelayNote)
    }
    .task(id: store.remoteBackend?.context.binding.route) {
      // 开通码属于旧后台，换后台时清掉；递增版本让旧请求的结果不再写回。
      settings = nil; draftAddress = nil; code = ""; confirmDisable = false
      refreshError = nil; actionError = nil; testPassed = false; configurationRevision += 1
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
      SettingsRow(L10n.Settings.relayAddress) {
        TextField(L10n.Settings.relayAddress, text: Binding(get: { address }, set: { draftAddress = $0 }),
                  prompt: Text("https://"))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 380)
      }
      SettingsRow(L10n.Settings.activationCode) {
        SecureField(L10n.Settings.activationCode, text: Binding(get: { code }, set: editCode), prompt: Text(L10n.Settings.optionalField))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 380)
      }
      HStack(spacing: 8) {
        Spacer()
        if settings?.mode == .custom, let saved = settings?.url, address != saved || !code.isEmpty {
          Button(L10n.Settings.revertChanges) {
            draftAddress = nil
            code = ""
            actionError = nil
            testPassed = false
          }
        }
        Button(action == .test ? L10n.Settings.testing : L10n.Settings.testConnection) { Task { await perform(.test) } }
        // 没改地址、没填开通码时没有可保存的，不显示“保存”。
        if settings?.mode != .custom || address != (settings?.url ?? "") || !code.isEmpty || action == .save {
          Button(action == .save ? L10n.Settings.saving : L10n.Settings.save) { Task { await perform(.save) } }
        }
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
    guard store.canManageBackend, !Task.isCancelled, action != .save, action != .disable else { return }
    let revision = configurationRevision
    do {
      let updated = try await store.api.relaySettings()
      guard !Task.isCancelled, revision == configurationRevision else { return }
      settings = updated
      refreshError = nil
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, revision == configurationRevision else { return }
      refreshError = settingsReadFailure(error, fallback: L10n.Settings.relaySettingsUnavailable, section: .relay)
    }
  }

  private func perform(_ operation: Action) async {
    guard store.canManageBackend, action == nil else { return }
    action = operation
    actionError = nil
    testPassed = false
    defer { action = nil }
    do {
      let updated: RelaySettings
      let started: Int
      if operation == .disable {
        configurationRevision += 1
        started = configurationRevision
        updated = try await store.api.disableRelay()
      } else {
        guard let validatedAddress = RelaySettingsText.validatedAddress(address) else {
          actionError = L10n.Settings.invalidRelayAddress
          return
        }
        if operation == .test {
          let result = try await store.api.testRelay(address: validatedAddress)
          testPassed = result.tacitRelay == 1
          if !testPassed { actionError = L10n.Settings.relayFailure(400) }
          return
        }
        configurationRevision += 1
        started = configurationRevision
        updated = try await store.api.saveRelay(address: validatedAddress, code: code)
      }
      // 等待期间换了后台，结果属于旧后台，不写回。
      guard started == configurationRevision else { return }
      settings = updated
      draftAddress = nil
      code = ""
      refreshError = nil
    } catch is CancellationError {
    } catch {
      let hubError = error as? HubError
      let fallback = L10n.Settings.relayFailure(hubError?.status)
      actionError = hubError?.actionMessage.map { L10n.Settings.serviceMessage($0, fallback: fallback) } ?? fallback
    }
  }
}
