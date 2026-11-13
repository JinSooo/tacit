import SwiftUI
import CollectorCore

/// AI 模型：三档分别选提供方、模型、地址；API key 只写进钥匙串，界面只显示是否已设置（AGENTS.md 2026-11-10）。
struct ModelSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var info: ModelSettingsInfo?
  @State private var saved: [String: ModelTierConfig] = [:]
  @State private var draft: [String: ModelTierConfig] = [:]
  @State private var error: String?
  @State private var saving = false
  @State private var tests: [String: TestState] = [:]
  @State private var localModels: [String: [String]] = [:]
  @State private var localModelErrors: [String: String] = [:]
  @State private var localModelLoading: Set<String> = []
  @State private var editingKey: String?
  @State private var removingKey: String?
  @State private var health: DistillHealth?
  @State private var healthError: String?

  enum TestState: Equatable { case running, ok(Double?), failed(String) }

  static let tiers = ["minute", "hour", "day"]
  /// 本机模型服务走 OpenAI 兼容接口，不需要 key。
  static let presets: [(id: String, label: String, url: String)] = [
    ("ollama", "本机 Ollama", "http://127.0.0.1:11434/v1"),
    ("lmstudio", "本机 LM Studio", "http://127.0.0.1:1234/v1"),
  ]

  var body: some View {
    SettingsForm {
      Section("整理状态") {
        if let health {
          switch health.state {
          case .working: SettingsRow("后台整理", value: "正常")
          case .waiting: SettingsRow("后台整理", value: "等待首次完成")
          case .failing(let reason): SettingsMessage(text: reason)
          }
          if let time = health.lastOkAt { SettingsRow("最近完成", value: String(time.prefix(16)).replacingOccurrences(of: "T", with: " ")) }
        }
        if let healthError { SettingsMessage(text: healthError) }
        HStack {
          Button("刷新状态") { Task { await loadHealth() } }
          Spacer()
          Button("查看用量与详细状态…") {
            if let url = store.api.statusPageURL() { NSWorkspace.shared.open(url) }
          }
        }
      }
      if let info {
        if let e = info.configError { SettingsMessage(text: "模型配置文件有问题，整理会失败，保存一次就能修好：\(e)") }
        ForEach(Self.tiers, id: \.self) { tier in tierSection(tier, info: info) }
        keysSection(info)
        if draft != saved {
          HStack {
            Spacer()
            Button("撤销修改") { draft = saved }.disabled(saving)
            Button(saving ? "正在保存…" : "保存") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving)
          }
        }
      } else if error == nil {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let error { SettingsMessage(text: error) }
    }
    .task { await load(); await loadHealth() }
    .sheet(item: Binding(get: { editingKey.map(KeyTarget.init) }, set: { editingKey = $0?.id })) { target in
      KeyEntrySheet(provider: target.id, label: label(target.id, info: info)) { await load() }
    }
    .confirmationDialog("删除 API key？", isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } })) {
      if let provider = removingKey { Button("删除", role: .destructive) { Task { await removeKey(provider); removingKey = nil } } }
      Button("取消", role: .cancel) { removingKey = nil }
    } message: { Text("使用这个提供商的模型将无法连接，直到重新填写 key。") }
  }

  struct KeyTarget: Identifiable { let id: String }

  // MARK: 每一档

  @ViewBuilder func tierSection(_ tier: String, info: ModelSettingsInfo) -> some View {
    let config = Binding(get: { draft[tier] ?? ModelTierConfig(provider: "codex-cli", model: "") }, set: { draft[tier] = $0 })
    let c = config.wrappedValue
    let provider = info.providers.first { $0.id == c.provider }
    let local = Self.isLoopback(c.baseUrl)
    Section {
      Picker("提供商", selection: Binding(get: { choice(c) }, set: { apply($0, to: config, info: info) })) {
        ForEach(info.providers, id: \.id) { Text($0.label).tag($0.id) }
        Divider()
        ForEach(Self.presets, id: \.id) { Text($0.label).tag($0.id) }
      }
      SettingsRow("模型") {
        HStack(spacing: 6) {
          TextField("模型", text: config.model, prompt: Text(placeholder(c.provider))).labelsHidden()
          if local, let models = localModels[c.baseUrl ?? ""], !models.isEmpty {
            Menu("本机模型") { ForEach(models, id: \.self) { m in Button(m) { config.wrappedValue.model = m } } }
              .fixedSize()
          }
          Button(tests[tier] == .running ? "正在测试…" : "测试连接") { Task { await test(tier) } }
            .disabled(tests[tier] == .running || c.model.isEmpty)
        }
      }
      if provider?.baseUrl == true {
        SettingsRow("地址") {
          TextField("地址", text: Binding(get: { c.baseUrl ?? "" }, set: { config.wrappedValue.baseUrl = $0.isEmpty ? nil : $0 }),
                    prompt: Text(c.provider == "anthropic" ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1")).labelsHidden()
        }
        if let url = c.baseUrl, !url.isEmpty, !local {
          SettingsMessage(text: "整理时，记录会发到这个地址。")
        }
        if local, c.provider == "openai-compatible", let url = c.baseUrl {
          HStack {
            if localModelLoading.contains(url) { Text("正在读取本机模型…").foregroundStyle(Palette.muted) }
            else if let error = localModelErrors[url] { SettingsMessage(text: error) }
            else if localModels[url] == [] { Text("服务已连接，但没有可用模型，请先在模型服务中下载或加载模型。").foregroundStyle(Palette.muted) }
            Spacer()
            Button("刷新模型") { Task { await loadLocalModels(url) } }.disabled(localModelLoading.contains(url))
          }
        }
        if local {
          Text("本机地址也可能转发到云端，实际运行位置由模型服务决定。").foregroundStyle(Palette.muted)
        }
      }
      if c.provider == "openai-compatible" {
        Picker("思考强度", selection: Binding(get: { c.reasoningEffort ?? "" }, set: { config.wrappedValue.reasoningEffort = $0.isEmpty ? nil : $0 })) {
          Text("跟随模型").tag("")
          Text("关闭").tag("none")
          Text("低").tag("low")
          Text("中").tag("medium")
          Text("高").tag("high")
        }
        Text("思考强度取决于服务和模型是否支持；不确定时选“跟随模型”。关闭可能更快，也可能降低整理质量。").foregroundStyle(Palette.muted)
      }
      switch tests[tier] {
      case .ok(let ms): Text(ms.map { String(format: "连接正常，用时 %.1f 秒", $0 / 1000) } ?? "连接正常").foregroundStyle(Palette.muted)
      case .failed(let e): SettingsMessage(text: e)
      case .running: Text("正在连接，最长等 1 分钟…").foregroundStyle(Palette.muted)
      case nil: EmptyView()
      }
    } header: {
      Text(info.tierInfo[tier]?.label ?? tier)
    } footer: {
      if let d = info.tierInfo[tier]?.description { Note(d) }
    }
    .task(id: c.baseUrl) { if local, c.provider == "openai-compatible", let url = c.baseUrl { await loadLocalModels(url) } }
    .onChange(of: c) { _, _ in tests[tier] = nil }
  }

  // MARK: API key

  @ViewBuilder func keysSection(_ info: ModelSettingsInfo) -> some View {
    let usedProviders = Set(draft.values.filter { !Self.isLoopback($0.baseUrl) }.map(\.provider))
    let keyProviders = info.providers.filter { $0.needsKey && (usedProviders.contains($0.id) || (info.keys[$0.id] ?? nil) == true) }
    if !keyProviders.isEmpty {
    Section {
      ForEach(keyProviders, id: \.id) { p in
        SettingsRow(p.label) {
          HStack(spacing: 8) {
            switch info.keys[p.id] ?? nil {
            case true?: Text("已设置").foregroundStyle(Palette.muted)
            case false?: Text("未设置").foregroundStyle(Palette.muted)
            case nil: Text("读不到钥匙串").foregroundStyle(Palette.attention)
            }
            Button("设置…") { editingKey = p.id }
            if (info.keys[p.id] ?? nil) == true { Button("删除…", role: .destructive) { removingKey = p.id } }
          }
        }
      }
    } header: {
      Text("API key")
    } footer: {
      Note("key 存在这台 Mac 的钥匙串里，设置后不再显示。同一个提供商共用一个 key。")
    }
    }
  }

  // MARK: 逻辑

  static func isLoopback(_ url: String?) -> Bool {
    guard let url, let u = URL(string: url), let host = u.host, ["http", "https"].contains(u.scheme ?? ""), u.user == nil, u.password == nil else { return false }
    if ["localhost", "::1", "[::1]"].contains(host) { return true }
    let parts = host.split(separator: ".")
    return parts.count == 4 && parts.first == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
  }

  func loadLocalModels(_ url: String) async {
    guard !localModelLoading.contains(url) else { return }
    localModelLoading.insert(url); localModelErrors[url] = nil; localModels[url] = nil
    defer { localModelLoading.remove(url) }
    do {
      let models = try await store.api.localModels(baseURL: url)
      try Task.checkCancellation()
      localModels[url] = models
    } catch is CancellationError {} catch {
      if !Task.isCancelled { localModelErrors[url] = error.localizedDescription }
    }
  }

  func choice(_ c: ModelTierConfig) -> String {
    if c.provider == "openai-compatible", let p = Self.presets.first(where: { $0.url == c.baseUrl }) { return p.id }
    return c.provider
  }

  func apply(_ id: String, to config: Binding<ModelTierConfig>, info: ModelSettingsInfo) {
    if let p = Self.presets.first(where: { $0.id == id }) {
      config.wrappedValue = ModelTierConfig(provider: "openai-compatible", model: "", baseUrl: p.url)
    } else {
      let supportsURL = info.providers.first { $0.id == id }?.baseUrl == true
      let keepURL = supportsURL && !Self.isLoopback(config.wrappedValue.baseUrl) ? config.wrappedValue.baseUrl : nil
      let keepModel = config.wrappedValue.provider == id ? config.wrappedValue.model : ""
      config.wrappedValue = ModelTierConfig(provider: id, model: keepModel, baseUrl: keepURL)
    }
    tests = [:]
  }

  func placeholder(_ provider: String) -> String {
    switch provider {
    case "anthropic": return "例如 claude-haiku-5-5"
    case "codex-cli": return "例如 gpt-6-luna"
    case "claude-cli": return "例如 claude-sonnet-5-5"
    default: return "模型名"
    }
  }

  func label(_ provider: String, info: ModelSettingsInfo?) -> String {
    info?.providers.first { $0.id == provider }?.label ?? provider
  }

  func load() async {
    do {
      let i = try await store.api.modelSettings()
      info = i
      // 只在没有未保存改动时刷新草稿，免得设置 key 后把正在改的内容冲掉。
      if draft == saved { draft = i.tiers }
      saved = i.tiers
      error = nil
    }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func loadHealth() async {
    do { health = try await store.api.distillHealth(); healthError = nil }
    catch is CancellationError {} catch { healthError = error.localizedDescription }
  }

  func save() async {
    saving = true; defer { saving = false }
    do { let i = try await store.api.saveModels(draft); info = i; saved = i.tiers; draft = i.tiers; error = nil }
    catch { self.error = error.localizedDescription }
  }

  func test(_ tier: String) async {
    guard let c = draft[tier] else { return }
    tests[tier] = .running
    do {
      let r = try await store.api.testModel(tier: tier, config: c)
      guard draft[tier] == c else { return }
      tests[tier] = r.ok ? .ok(r.ms) : .failed(r.error ?? "连接失败")
    } catch { if draft[tier] == c { tests[tier] = .failed(error.localizedDescription) } }
  }

  func removeKey(_ provider: String) async {
    do { try await store.api.deleteKey(provider: provider); await load() }
    catch { self.error = error.localizedDescription }
  }
}

/// 输入 API key：只写不读，输入框关掉就清空。
private struct KeyEntrySheet: View {
  @Environment(ViewerStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let provider: String
  let label: String
  let done: () async -> Void
  @State private var key = ""
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("设置 \(label) 的 API key").font(.system(size: TextSize.body, weight: .semibold))
      SecureField("API key", text: $key).frame(width: 360)
      Text("存在这台 Mac 的钥匙串里，设置后不再显示。").foregroundStyle(Palette.muted)
      if let error { SettingsMessage(text: error) }
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "正在保存…" : "保存") { Task { await save() } }
          .keyboardShortcut(.defaultAction).disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 400)
    .fixedSize(horizontal: false, vertical: true)
  }

  func save() async {
    busy = true; defer { busy = false }
    do {
      try await store.api.setKey(provider: provider, key: key.trimmingCharacters(in: .whitespaces))
      key = ""
      await done()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
