import AppKit
import SwiftUI
import CollectorCore

// 新用户不靠命令行也能走完主链路：设置里接入 AI 工具，今天的回顾在没准备好时给出清单。

struct AgentToolState: Decodable, Identifiable, Equatable {
  let id: String
  let label: String
  let installed: Bool
  let connected: Bool
  let partial: Bool

  var shouldConnect: Bool { installed && !connected }
}

struct AgentMCPConfig: Codable {
  let command: String
  let args: [String]

  /// 按常见写法排版：command 在 args 前，冒号后一个空格（JSONEncoder 的排序和 " : " 与各家文档示例对不上）。
  var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let quote = { (value: String) in (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\"" }
    let arguments = args.map { "        " + quote($0) }.joined(separator: ",\n")
    return "{\n  \"mcpServers\": {\n    \"tacit\": {\n      \"command\": \(quote(command)),\n      \"args\": [\n\(arguments)\n      ]\n    }\n  }\n}"
  }

  var arguments: String {
    args.map { argument in
      argument.range(of: #"^[a-zA-Z0-9_./:=-]+$"#, options: .regularExpression) != nil
        ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
  }
}

struct SetupReadiness {
  let health: DistillHealth
  let tools: [AgentToolState]?

  static func unfinishedItems(health: DistillHealth?, tools: [AgentToolState]?) -> Set<String> {
    var items = Set<String>()
    if let health, health.state != .working { items.insert("models") }
    if let tools, !tools.contains(where: \.connected) { items.insert("tools") }
    return items
  }
}

struct AgentSettingsData: Decodable {
  let tools: [AgentToolState]
  let otherMcp: AgentMCPConfig
}

extension HubAPI {
  func agentSettings() async throws -> AgentSettingsData {
    try await get(AgentSettingsData.self, "/v1/settings/agents")
  }

  func setupReadiness(includeLocalTools: Bool) async throws -> SetupReadiness {
    async let health = distillHealth()
    async let tools = includeLocalTools ? agentTools() : nil
    return try await SetupReadiness(health: health, tools: tools)
  }

  func agentTools() async throws -> [AgentToolState] {
    struct R: Decodable { let tools: [AgentToolState] }
    return try await get(R.self, "/v1/settings/agents").tools
  }
  /// 连接要调用 claude / codex 的命令行登记，给足时间。
  func setAgent(_ id: String, connected: Bool) async throws -> (tools: [AgentToolState], note: String?) {
    struct R: Decodable { let tools: [AgentToolState]; let note: String? }
    let r = try await call(R.self, "PUT", "/v1/settings/agents/\(id)", ["connected": connected], timeout: 120)
    return (r.tools, r.note)
  }
  func distillHealth() async throws -> DistillHealth {
    struct R: Decodable { let distill: DistillHealth }
    return try await get(R.self, "/v1/status", device: .init("status.get")).distill
  }
}

// MARK: 设置 → AI 工具

struct AgentSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var tools: [AgentToolState]?
  @State private var otherMCP: AgentMCPConfig?
  @State private var busy: String?
  @State private var note: String?
  @State private var error: String?
  @State private var showInstructions = false

  var body: some View {
    SettingsForm {
      Section {
        if let tools {
          AgentToolRows(tools: tools, busy: busy, connect: { tool in
            Task { await set(tool, tool.shouldConnect) }
          }, showInstructions: { showInstructions = true })
        } else if error == nil {
          ProgressView().frame(maxWidth: .infinity)
        }
        if let note { SettingsMessage(text: note, warning: false) }
        if let error { SettingsMessage(text: error) }
      } footer: {
        Note(L10n.Settings.toolsNote)
      }
    }
    .task { await load() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard busy == nil else { return }
      Task { await load() }
    }
    .sheet(isPresented: $showInstructions) {
      if let otherMCP { AgentConnectionInstructions(config: otherMCP) }
    }
  }

  func load() async {
    do {
      let settings = try await store.api.agentSettings()
      guard busy == nil else { return }
      tools = settings.tools
      otherMCP = settings.otherMcp
      error = nil
    }
    catch is CancellationError {}
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.agentOperationFailed) }
  }

  func set(_ t: AgentToolState, _ on: Bool) async {
    busy = t.id; note = nil; error = nil
    defer { busy = nil }
    do {
      let result = try await store.api.setAgent(t.id, connected: on)
      tools = result.tools
      note = result.note.map(L10n.Settings.agentNote).flatMap { $0.isEmpty ? nil : $0 }
    } catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.agentOperationFailed) }
  }
}

struct AgentToolRows: View {
  let tools: [AgentToolState]
  let busy: String?
  let connect: (AgentToolState) -> Void
  let showInstructions: () -> Void

  var body: some View {
    ForEach(tools, content: row)
    SettingsRow(L10n.Settings.otherAgentTools) {
      Button(L10n.Settings.agentInstructions, action: showInstructions)
        .accessibilityLabel(L10n.Settings.otherAgentInstructionsTitle)
    }
  }

  private func row(_ tool: AgentToolState) -> some View {
    SettingsRow(tool.label) {
      HStack(spacing: 8) {
        if tool.connected {
          Text(L10n.Settings.toolConnected).foregroundStyle(Palette.muted)
        } else if tool.partial {
          Text(L10n.Settings.toolPartiallyConnected)
            .foregroundStyle(Palette.attention)
        } else if !tool.installed {
          Text(L10n.Settings.toolNotInstalled).foregroundStyle(Palette.muted)
        }
        if tool.installed || tool.connected || tool.partial {
          Button(connectionAction(tool)) { connect(tool) }
            .disabled(busy != nil)
        }
      }
    }
  }

  private func connectionAction(_ tool: AgentToolState) -> String {
    if busy == tool.id { return tool.shouldConnect ? L10n.Settings.connecting : L10n.Settings.disconnecting }
    return tool.shouldConnect ? L10n.Settings.connect : L10n.Settings.disconnect
  }
}

struct AgentConnectionInstructions: View {
  @Environment(\.dismiss) private var dismiss
  let config: AgentMCPConfig

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.Settings.otherAgentInstructionsTitle)
        .font(.system(size: TextSize.title, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .vertical) {
        snippets
        ScrollView { snippets }
      }
      HStack(spacing: 12) {
        Text(L10n.Settings.reopenOtherAgent).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(L10n.Settings.close) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .font(.system(size: TextSize.body))
    .padding(24)
    .frame(width: 560)
    .frame(maxHeight: 600)
    .tint(Palette.accent)
  }

  private var snippets: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 12) {
          Text(L10n.Settings.otherAgentMCPInstructions)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          AgentCopyButton(code: config.json)
            .accessibilityHint(L10n.Settings.otherAgentMCPInstructions)
        }
        codeText(config.json)
          .padding(12)
          .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.Settings.otherAgentCommandInstructions).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
          commandRow(L10n.Settings.agentCommand, config.command)
          commandRow(L10n.Settings.agentArguments, config.arguments)
        }
        .padding(12)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
      }
    }
  }

  private func commandRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(label).foregroundStyle(Palette.muted).frame(width: 64, alignment: .leading)
      codeText(value)
      AgentCopyButton(code: value).accessibilityHint(label)
    }
  }

  private func codeText(_ value: String) -> some View {
    Text(verbatim: value).font(.system(size: TextSize.caption, design: .monospaced))
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AgentCopyButton: View {
  let code: String
  @State private var copied = false
  @State private var copyCount = 0

  var body: some View {
    Button(copied ? L10n.Settings.copied : L10n.Settings.copy) {
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(code, forType: .string)
      copyCount += 1
    }
    .task(id: copyCount) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(1.5))
      if !Task.isCancelled { copied = false }
    }
  }
}

// MARK: 回顾 → 准备清单

struct SetupChecklist: View {
  let backend: AppSetup.ChecklistStep?
  let backendChecked: Bool
  let health: DistillHealth?
  let tools: [AgentToolState]?
  let minuteModel: ModelTierConfig?
  @Environment(ViewerStore.self) private var store
  @AppStorage("setupChecklist.collapsedWith") private var collapsedWith = ""
  @State private var retrying = false
  @State private var retryError: String?
  @State private var testing = false
  @State private var testResult: String?

  private var permissions: (required: [DataSourceStatus], optionalSafari: DataSourceStatus?) {
    TimelineSetup.missingPermissions(in: store.capture.sources)
  }

  private var unfinished: Set<String> {
    var items = Set(permissions.required.map { "permission." + ($0.permissionName ?? $0.id) })
    if backend != nil, backendChecked { items.insert("backend") }
    items.formUnion(SetupReadiness.unfinishedItems(health: health, tools: tools))
    return items
  }

  private var remembered: Set<String> { Set(collapsedWith.split(separator: "|").map(String.init)) }

  private var completed: Set<String> {
    var items = Set(remembered.filter { $0.hasPrefix("permission.") && !unfinished.contains($0) })
    if backendChecked, backend == nil { items.insert("backend") }
    if health?.state == .working { items.insert("models") }
    if tools?.contains(where: \.connected) == true { items.insert("tools") }
    return items
  }

  private var modelMissing: Bool {
    guard health?.lastOkAt == nil, !store.isRemoteBackend, let provider = minuteModel?.provider, let tools else { return false }
    let tool = provider == "claude-cli" ? "claude-code" : provider == "codex-cli" ? "codex" : nil
    guard let tool else { return false }
    return tools.contains { $0.id == tool && !$0.installed }
  }

  var body: some View {
    let unfinished = unfinished
    let expanded = !backendChecked || TimelineSetup.isExpanded(unfinished: unfinished, collapsedWith: remembered)
    Group {
      if backend != nil || !unfinished.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          Button {
            Motion.animate { collapsedWith = expanded ? unfinished.sorted().joined(separator: "|") : "" }
          } label: {
            HStack(spacing: 8) {
              PhIcon("check-circle", size: 14)
              Text(L10n.Settings.setupChecklist)
              Spacer()
              DisclosureChevron(expanded: expanded, sideways: true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .disabled(!backendChecked)
          .buttonStyle(.accentLink).font(.system(size: TextSize.body))
          .accessibilityValue(expanded ? L10n.Settings.expanded : L10n.Settings.collapsed)
          if expanded { steps }
        }
      }
    }
    .onChange(of: [unfinished, completed], initial: true) {
      collapsedWith = TimelineSetup.rememberedCollapse(unfinished: unfinished, completed: completed, collapsedWith: remembered)
        .sorted().joined(separator: "|")
    }
    .onChange(of: minuteModel) { testResult = nil }
    .onChange(of: backend) { retryError = nil }
  }

  @ViewBuilder private var steps: some View {
    let permissions = permissions
    if let backend {
      switch backend {
      case .preparing:
        step(done: false, title: L10n.Settings.preparingBackend, detail: nil) { EmptyView() }
      case .failed(let message):
        if retrying {
          step(done: false, title: L10n.Settings.preparingBackend, detail: nil) { EmptyView() }
        } else {
          step(done: false, title: L10n.Settings.backgroundService, detail: retryError ?? message) {
            VStack(alignment: .trailing, spacing: 4) {
              Button(L10n.Settings.prepareAgain) { Task { await retry() } }
              OpenLogsButton().buttonStyle(.accentLink).font(.system(size: TextSize.caption))
            }.fixedSize()
          }
        }
      }
      Divider()
    }
    if permissions.required.isEmpty {
      step(done: true, title: L10n.Settings.grantSystemPermissions, detail: nil) { EmptyView() }
    } else {
      ForEach(permissions.required, id: \.id) { source in
        step(done: false, title: L10n.permission(source.permissionName ?? source.title), detail: nil) {
          Button(L10n.Settings.grantPermission) { store.perform(.requestPermission(source.id)) }
        }
      }
    }
    if let safari = permissions.optionalSafari {
      step(done: false, title: L10n.Settings.optionalFullDiskAccess, detail: L10n.Settings.safariPermissionNote) {
        Button(L10n.Settings.grantPermission) { store.perform(.requestPermission(safari.id)) }
      }
    }
    if let health {
      Divider()
      step(done: health.state == .working, title: L10n.Settings.setupModels, detail: modelDetail(health.state)) {
        VStack(alignment: .trailing, spacing: 4) {
          Button(modelMissing ? L10n.Settings.goToModelSettings : L10n.Settings.checkModels) { open(.models) }
          if !modelMissing, let minuteModel, store.canManageBackend {
            Button(testing ? L10n.Settings.testing : L10n.Settings.testConnection) {
              Task { await testConnection(minuteModel) }
            }.disabled(testing)
          }
        }.fixedSize()
      }
    }
    if let tools {
      let ready = tools.contains(where: \.connected)
      Divider()
      step(done: ready, title: L10n.Settings.setupTools, detail: ready ? nil : agentDetail(tools)) {
        if tools.contains(where: \.installed) { Button(L10n.Settings.connectEllipsis) { open(.agents) } }
      }
    }
  }

  private func retry() async {
    guard !retrying, let delegate = store.controls as? AppDelegate else { return }
    retrying = true
    retryError = nil
    defer { retrying = false }
    do { try await delegate.prepareBackendAgain() }
    catch { retryError = UserFacingError.message(for: error, fallback: L10n.Settings.setupFailure(.unknown)) }
  }

  private func testConnection(_ model: ModelTierConfig) async {
    guard !testing else { return }
    testing = true
    testResult = nil
    defer { testing = false }
    let result: String
    do {
      let response = try await store.api.testModel(tier: "minute", config: model)
      result = response.ok ? L10n.Settings.connectionOK : response.error.map { L10n.Settings.modelFailure($0, fallback: L10n.Settings.connectionFailed) } ?? L10n.Settings.connectionFailed
    } catch {
      result = UserFacingError.message(for: error, fallback: L10n.Settings.connectionFailed)
    }
    if minuteModel == model { testResult = result }
  }

  func agentDetail(_ tools: [AgentToolState]) -> String {
    tools.contains(where: \.installed)
      ? L10n.Settings.toolSearchNote
      : L10n.Settings.setupToolInstallNote
  }

  func modelDetail(_ s: DistillHealth.State) -> String? {
    if modelMissing { return L10n.Settings.noAvailableLocalModel }
    if let testResult { return testResult }
    switch s {
    case .waiting: return L10n.Settings.firstSummaryNote
    case .failing(let reason): return L10n.Settings.modelFailure(reason, fallback: L10n.Settings.summaryFailure)
    case .working: return nil
    }
  }

  func open(_ group: SettingsGroup) {
    UserDefaults.standard.set(group.rawValue, forKey: "settings.group")
    store.showSettings()
  }

  func step<Action: View>(done: Bool, title: String, detail: String?, @ViewBuilder action: () -> Action) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      // 完成的一步：虚线圈淡换成铜绿勾。
      PhIcon(done ? "check-circle" : "circle-dashed", fill: done, size: 16)
        .foregroundStyle(done ? Palette.accent : Palette.faint)
        .id(done).transition(.opacity)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(done ? Palette.muted : Palette.ink)
        if !done, let detail {
          Text(detail).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      if !done { action().font(.system(size: TextSize.body)) }
    }
    .padding(.vertical, 12)
    .animation(Motion.standard, value: done)
  }
}
