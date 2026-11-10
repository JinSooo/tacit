import SwiftUI
import CollectorCore

// 新用户不靠命令行也能走完主链路（AGENTS.md 2026-11-10）：设置里接入 AI 工具，"此刻"页在没准备好时给出清单。

struct AgentToolState: Decodable, Identifiable, Equatable {
  let id: String
  let label: String
  let installed: Bool
  let connected: Bool
  let partial: Bool
}

/// /v1/status 里判断整理是否正常需要的几项。
struct DistillHealth: Decodable, Equatable {
  struct LastError: Decodable, Equatable { let at: String; let error: String; let recovered: Bool }
  let lastOkAt: String?
  let lastError: LastError?

  enum State: Equatable { case working, waiting, failing(String) }
  var state: State {
    if let e = lastError, !e.recovered { return .failing(e.error) }
    return lastOkAt == nil ? .waiting : .working
  }
}

extension HubAPI {
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
    return try await get(R.self, "/v1/status").distill
  }
}

// MARK: 设置 → AI 工具

struct AgentSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var tools: [AgentToolState]?
  @State private var busy: String?
  @State private var note: String?
  @State private var error: String?

  var body: some View {
    SettingsForm {
      Section {
        if let tools {
          ForEach(tools) { t in
            LabeledContent(t.label) {
              HStack(spacing: 8) {
                Text(status(t)).foregroundStyle(t.partial ? Palette.attention : Palette.muted)
                if t.installed {
                  Button(busy == t.id ? (t.connected ? "正在断开…" : "正在连接…") : (t.connected ? "断开" : "连接")) {
                    Task { await set(t, !t.connected) }
                  }
                  .disabled(busy != nil)
                }
              }
            }
          }
        } else if error == nil {
          ProgressView().frame(maxWidth: .infinity)
        }
        if let note { SettingsMessage(text: note, warning: false) }
        if let error { SettingsMessage(text: error) }
      } footer: {
        Note("连接后，新开的会话会自动带入当前项目的进展，AI 也能随时查你的历史记录。每次读取都记在“AI 读取记录”里。")
      }
    }
    .task { await load() }
  }

  func status(_ t: AgentToolState) -> String {
    if !t.installed { return "这台 Mac 上没有安装" }
    if t.partial { return "没连好，重新连接一次" }
    return t.connected ? "已连接" : "未连接"
  }

  func load() async {
    do { tools = try await store.api.agentTools(); error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func set(_ t: AgentToolState, _ on: Bool) async {
    busy = t.id; note = nil; error = nil
    defer { busy = nil }
    do { let r = try await store.api.setAgent(t.id, connected: on); tools = r.tools; note = r.note }
    catch { self.error = error.localizedDescription }
  }
}

// MARK: 此刻 → 准备清单

/// 三件事都好了就不显示：系统权限、AI 模型能整理、至少接入一个 AI 工具。
struct SetupChecklist: View {
  @Environment(ViewerStore.self) private var store
  @State private var tools: [AgentToolState]?
  @State private var health: DistillHealth?

  var body: some View {
    let missing = store.capture.sources.filter { $0.enabled && $0.needsPermission }
    let model = health?.state
    let agentsReady = tools.map { $0.contains { $0.connected } }
    let ready = missing.isEmpty && model != nil && model != .waiting && !isFailing(model) && agentsReady == true
    Group {
      if !ready, health != nil || tools != nil {
        VStack(alignment: .leading, spacing: 0) {
          Text("还差几步").font(.system(size: TextSize.title, weight: .semibold)).padding(.bottom, 12)
          step(done: missing.isEmpty, title: "打开系统权限",
               detail: missing.isEmpty ? nil : "还缺：" + missing.compactMap(\.permissionName).joined(separator: "、")) {
            if let first = missing.first { Button("授权…") { store.perform(.requestPermission(first.id)) } }
          }
          Divider()
          step(done: model == .working, title: "让 AI 整理你的记录", detail: modelDetail(model)) {
            if isFailing(model) { Button("检查 AI 模型…") { open(.models) } }
          }
          Divider()
          step(done: agentsReady == true, title: "接入 Claude Code 或 Codex",
               detail: agentsReady == true ? nil : agentDetail) {
            if agentsReady != true, tools?.contains(where: \.installed) == true { Button("连接…") { open(.agents) } }
          }
        }
        .padding(16)
        .card()
      }
    }
    .task {
      while !Task.isCancelled {
        tools = try? await store.api.agentTools()
        health = try? await store.api.distillHealth()
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  var agentDetail: String {
    tools?.contains(where: \.installed) == true
      ? "接入后，新开的会话会自动知道你最近在做什么。"
      : "这台 Mac 上没找到 Claude Code 或 Codex，装好并登录后再回来连接。"
  }

  func isFailing(_ s: DistillHealth.State?) -> Bool { if case .failing = s { return true }; return false }

  func modelDetail(_ s: DistillHealth.State?) -> String? {
    switch s {
    case .waiting?: return "第一次整理会在 15 分钟内完成。"
    case .failing?: return "最近一次整理没有成功，多半是模型连不上。"
    default: return nil
    }
  }

  func open(_ group: SettingsGroup) {
    UserDefaults.standard.set(group.rawValue, forKey: "settings.group")
    store.section = .settings
  }

  func step<Action: View>(done: Bool, title: String, detail: String?, @ViewBuilder action: () -> Action) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      PhIcon(done ? "check-circle" : "circle-dashed", fill: done, size: TextSize.title)
        .foregroundStyle(done ? Palette.accent : Palette.faint)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(done ? Palette.muted : Palette.ink)
        if let detail { Text(detail).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted) }
      }
      Spacer(minLength: 12)
      if !done { action() }
    }
    .padding(.vertical, 10)
  }
}
