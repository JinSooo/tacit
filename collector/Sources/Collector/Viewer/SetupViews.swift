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
  let manual: [AgentConfigSnippet]?

  var shouldConnect: Bool { installed && !connected }
}

struct AgentConfigSnippet: Decodable, Equatable {
  enum Kind: String, Decodable { case mcp, sessionStart = "session-start" }
  enum Action: String, Decodable { case create, add, replace, merge }

  let file: String
  let kind: Kind
  let action: Action
  let section: String?
  let code: String

  var instruction: String {
    L10n.Settings.agentConfigInstruction(file, section: section, action: action.rawValue, sessionStart: kind == .sessionStart)
  }
}

struct SetupReadiness {
  let health: DistillHealth
  let tools: [AgentToolState]?
}

extension HubAPI {
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
  @State private var busy: String?
  @State private var note: String?
  @State private var error: String?
  @State private var instructions: AgentToolState?

  var body: some View {
    SettingsForm {
      Section {
        if let tools {
          AgentToolRows(tools: tools, busy: busy, connect: { tool in
            Task { await set(tool, tool.shouldConnect) }
          }, showInstructions: { instructions = $0 })
        } else if error == nil {
          ProgressView().frame(maxWidth: .infinity)
        }
        if let note { SettingsMessage(text: note, warning: false) }
        if let error { SettingsMessage(text: error) }
      } footer: {
        Note(L10n.Settings.toolsNote)
      }
      GeneralPreferencesSection(context: true)
    }
    .task { await load() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard busy == nil else { return }
      Task { await load() }
    }
    .sheet(item: $instructions, onDismiss: { Task { await load() } }) { tool in
      AgentConnectionInstructions(tool: tool)
    }
  }

  func load() async {
    do {
      let states = try await store.api.agentTools()
      guard busy == nil else { return }
      tools = states
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
  let showInstructions: (AgentToolState) -> Void

  var body: some View {
    ForEach(tools.filter(\.installed), content: row)
    let others = tools.filter { !$0.installed }
    if !others.isEmpty {
      DisclosureGroup(L10n.Settings.otherAgentTools) {
        ForEach(others, content: row)
      }
    }
  }

  private func row(_ tool: AgentToolState) -> some View {
    SettingsRow(tool.label) {
      HStack(spacing: 8) {
        if tool.connected {
          Text(L10n.Settings.toolConnected).foregroundStyle(Palette.muted)
        } else if tool.partial {
          Text(tool.manual == nil ? L10n.Settings.toolPartiallyConnected : L10n.Settings.manualToolPartial)
            .foregroundStyle(Palette.attention)
        } else if !tool.installed {
          Text(L10n.Settings.toolNotInstalled).foregroundStyle(Palette.muted)
        }
        if tool.manual != nil {
          Button(L10n.Settings.agentInstructions) { showInstructions(tool) }
            .accessibilityLabel(L10n.Settings.agentInstructionsFor(tool.label))
        } else if tool.installed || tool.connected || tool.partial {
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
  let tool: AgentToolState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.Settings.agentInstructionsFor(tool.label))
        .font(.system(size: TextSize.title, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .vertical) {
        snippets
        ScrollView { snippets }
      }
      HStack(spacing: 12) {
        Text(L10n.Settings.reopenAgent(tool.label)).foregroundStyle(Palette.muted)
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
      ForEach(Array((tool.manual ?? []).enumerated()), id: \.offset) { _, snippet in
        AgentSnippetBlock(snippet: snippet)
      }
    }
  }
}

private struct AgentSnippetBlock: View {
  let snippet: AgentConfigSnippet
  @State private var copied = false
  @State private var copyCount = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        Text(snippet.instruction).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(copied ? L10n.Settings.copied : L10n.Settings.copy) {
          NSPasteboard.general.clearContents()
          copied = NSPasteboard.general.setString(snippet.code, forType: .string)
          copyCount += 1
        }
        .accessibilityHint(snippet.file)
      }
      Text(verbatim: snippet.code).font(.system(size: TextSize.caption, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
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

  private var missing: [DataSourceStatus] {
    var names = Set<String>()
    return store.capture.sources.filter {
      DataSourceCatalog.isVisible($0.id) && $0.needsPermission && names.insert($0.permissionName ?? $0.id).inserted
    }
  }

  private var unfinished: Set<String> {
    var items = Set(missing.map { "permission." + ($0.permissionName ?? $0.id) })
    if backend != nil, backendChecked { items.insert("backend") }
    if let health, health.state != .working { items.insert("models") }
    if let tools, !tools.contains(where: \.connected) { items.insert("tools") }
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
            }.padding(.vertical, 4)
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
    if missing.isEmpty {
      step(done: true, title: L10n.Settings.grantSystemPermissions, detail: nil) { EmptyView() }
    } else {
      ForEach(missing, id: \.id) { source in
        step(done: false, title: L10n.permission(source.permissionName ?? source.title), detail: nil) {
          Button(L10n.Settings.grantPermission) { store.perform(.requestPermission(source.id)) }
        }
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
