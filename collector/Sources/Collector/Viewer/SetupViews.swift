import SwiftUI
import CollectorCore

// 新用户不靠命令行也能走完主链路：设置里接入 AI 工具，今天的回顾在没准备好时给出清单。

struct AgentToolState: Decodable, Identifiable, Equatable {
  let id: String
  let label: String
  let installed: Bool
  let connected: Bool
  let partial: Bool
}

extension HubAPI {
  func agentTools() async throws -> [AgentToolState] {
    struct R: Decodable { let tools: [AgentToolState] }
    return try await get(R.self, "/v1/settings/agents").tools.filter { $0.id != "claude-desktop" }
  }
  /// 连接要调用 claude / codex 的命令行登记，给足时间。
  func setAgent(_ id: String, connected: Bool) async throws -> (tools: [AgentToolState], note: String?) {
    struct R: Decodable { let tools: [AgentToolState]; let note: String? }
    let r = try await call(R.self, "PUT", "/v1/settings/agents/\(id)", ["connected": connected], timeout: 120)
    return (r.tools.filter { $0.id != "claude-desktop" }, r.note)
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

  var body: some View {
    SettingsForm {
      Section {
        if let tools {
          ForEach(tools) { t in
            SettingsRow(t.label) {
              HStack(spacing: 8) {
                if let text = status(t) { Text(text).foregroundStyle(t.partial ? Palette.attention : Palette.muted) }
                if t.installed || t.connected || t.partial {
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
        Note("连接后，新会话会带入当前项目进展，AI 也能查你的历史记录；每次读取都记在运行记录里。")
      }
      GeneralPreferencesSection(context: true)
    }
    .task { await load() }
  }

  /// 连接与否由右边的“连接 / 断开”说明，这里只写按钮说明不了的。
  func status(_ t: AgentToolState) -> String? {
    if !t.installed { return "这台 Mac 上没有安装" }
    if t.partial { return "连接不完整，请重新连接。" }
    return nil
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

// MARK: 回顾 → 准备清单

/// 三件事都好了就不显示：系统权限、AI 模型能整理、至少接入一个 AI 工具。
/// 后台服务读不到时不显示，页面其他部分已经会报错。
struct SetupChecklist: View {
  let health: DistillHealth
  let tools: [AgentToolState]
  @Environment(ViewerStore.self) private var store
  @State private var expanded = false

  @ViewBuilder var body: some View {
    let missing = store.capture.sources.filter { DataSourceCatalog.isVisible($0.id) && $0.needsPermission }
    let modelReady = health.state == .working
    let agentsReady = tools.contains(where: \.connected)
    if TimelineSetup.shouldShow(permissionsReady: missing.isEmpty, modelReady: modelReady, agentReady: agentsReady) {
      VStack(alignment: .leading, spacing: 0) {
        Button { Motion.animate { expanded.toggle() } } label: {
          HStack(spacing: 8) {
            PhIcon("check-circle", size: 14)
            Text("还差几步")
            Spacer()
            DisclosureChevron(expanded: expanded, sideways: true)
          }.padding(.vertical, 4)
        }
        .buttonStyle(.accentLink).font(.system(size: TextSize.body))
        .accessibilityValue(expanded ? "已展开" : "已折叠")
        if expanded {
          step(done: missing.isEmpty, title: "打开系统权限", detail: permissionDetail(missing)) {
            if let first = missing.first { Button("授权…") { store.perform(.requestPermission(first.id)) } }
          }
          Divider()
          step(done: modelReady, title: "让 AI 整理你的记录", detail: modelDetail(health.state)) {
            Button("检查 AI 模型…") { open(.models) }
          }
          Divider()
          step(done: agentsReady, title: "连接你使用的 AI 工具", detail: agentsReady ? nil : agentDetail(tools)) {
            if tools.contains(where: \.installed) { Button("连接…") { open(.agents) } }
          }
        }
      }
    }
  }

  func permissionDetail(_ missing: [DataSourceStatus]) -> String? {
    var names: [String] = []
    for n in missing.compactMap(\.permissionName) where !names.contains(n) { names.append(n) }
    return names.isEmpty ? nil : "还缺" + names.joined(separator: "、") + "权限。"
  }

  func agentDetail(_ tools: [AgentToolState]) -> String {
    tools.contains(where: \.installed)
      ? "连接后，可以让 AI 查询你最近在做什么。"
      : "这台 Mac 上没找到 Claude Code 或 Codex，装好并登录后再回来连接。"
  }

  func modelDetail(_ s: DistillHealth.State) -> String? {
    switch s {
    case .waiting: return "第一次整理会在 15 分钟内完成。"
    case .failing(let reason): return reason
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
