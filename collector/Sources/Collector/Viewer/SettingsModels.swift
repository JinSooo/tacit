import SwiftUI
import CollectorCore

/// AI 模型：三档分别选提供方、模型、地址；API key 只写进钥匙串，界面只显示是否已设置（AGENTS.md 2026-11-10）。
struct ModelSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var info: ModelSettingsInfo?
  @State private var saved: [String: ModelTierConfig] = [:]
  @State private var draft: [String: ModelTierConfig] = [:]
  @State private var timelineSaved: TimelineDraft?
  @State private var timelineDraft: TimelineDraft?
  @State private var timelineSettings: GeneralSettingsInfo?
  @State private var timelineError: String?
  @State private var error: String?
  @State private var saving = false
  @State private var tests: [String: TestState] = [:]
  @State private var testingConnection = false
  @State private var localModels: [String: [String]] = [:]
  @State private var localModelErrors: [String: String] = [:]
  @State private var localModelLoading: Set<String> = []
  @State private var editingKey: String?
  @State private var removingKey: String?
  @State private var health: DistillHealth?
  @State private var healthError: String?
  /// 三档用同一个模型时合成一组显示；用户点“按任务分别设置”后才展开三档。
  @State private var splitTiers = false

  enum TestState: Equatable { case running, ok(Double?), failed(String) }

  static let tiers = ["minute", "hour", "day"]
  private static let showsLocalModelOptions = false
  /// 本机模型服务走 OpenAI 兼容接口，不需要 key。
  static let presets: [(id: String, label: String, url: String)] = [
    ("ollama", "本机 Ollama", "http://127.0.0.1:11434/v1"),
    ("lmstudio", "本机 LM Studio", "http://127.0.0.1:1234/v1"),
  ]

  var body: some View {
    SettingsForm {
      if showsStatus {
      Section("整理状态") {
        if let health {
          // 正常时只写最近一次整理的时间，不写“正常”。
          switch health.state {
          case .working: EmptyView()
          case .waiting: SettingsRow("后台整理", value: "等待首次完成")
          case .failing(let reason):
            SettingsMessage(text: store.isRemoteBackend ? "整理遇到问题，请检查远端模型设置。" : reason)
          }
          if let time = health.lastOkAt {
            SettingsRow("最近整理", value: ViewerTime.parse(time).map(Fmt.dateTime) ?? time)
          }
        }
        if let healthError { SettingsMessage(text: healthError) }
        if !store.isRemoteBackend {
          HStack {
            Spacer()
            Button("查看用量与详细状态…") {
              if let url = store.api.statusPageURL() { NSWorkspace.shared.open(url) }
            }
          }
        }
      }
      }
      if let info {
        if let e = info.configError {
          SettingsMessage(text: store.isRemoteBackend ? "请填写远端后台使用的 API 模型。" : "模型配置文件有问题，整理会失败，保存一次就能修好：\(e)")
        }
        if sharesOneModel {
          tierSection(Self.tiers[0], info: info, together: true).disabled(saving)
        } else {
          ForEach(Self.tiers, id: \.self) { tier in tierSection(tier, info: info) }.disabled(saving)
        }
        timelineSection
        keysSection(info)
        if draft != saved || timelineDraft != timelineSaved {
          HStack {
            Spacer()
            Button("撤销修改") { draft = saved; timelineDraft = timelineSaved }.disabled(saving)
            Button(saving ? "正在保存…" : "保存") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving || !canSaveModels)
          }
        }
      } else if error == nil {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let error { SettingsMessage(text: error) }
    }
    .task {
      // 整理状态和用量自己跟上，不让人点“刷新”；第一次没读到的设置也在这里重试。
      while !Task.isCancelled {
        if info == nil { await load() }
        await loadTimeline()
        await loadHealth()
        await WindowVisibility.pause(.seconds(30))
      }
    }
    .sheet(item: Binding(get: { editingKey.map(KeyTarget.init) }, set: { editingKey = $0?.id })) { target in
      KeyEntrySheet(provider: target.id, label: label(target.id, info: info)) { await load() }
    }
    .confirmationDialog("删除 API key？", isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } })) {
      if let provider = removingKey { Button("删除", role: .destructive) { Task { await removeKey(provider); removingKey = nil } } }
      Button("取消", role: .cancel) { removingKey = nil }
    } message: { Text("使用这个提供商的模型将无法连接，直到重新填写 key。") }
  }

  struct KeyTarget: Identifiable { let id: String }

  private struct TimelineDraft: Equatable {
    var polish: GeneralSettingsInfo.PolishTiming
    var overview: GeneralSettingsInfo.OverviewTiming
    var limitText: String?

    init(_ settings: GeneralSettingsInfo) {
      polish = settings.timelinePolish
      overview = settings.timelineOverview
      limitText = settings.dailyTokenLimit.map(DailyTokenLimit.inputText)
    }
  }

  @ViewBuilder private var timelineSection: some View {
    Section {
      if let draft = Binding($timelineDraft) {
        Picker("整理时间线", selection: draft.polish) {
          Text("每段结束后").tag(GeneralSettingsInfo.PolishTiming.afterSegment)
          Text("每小时").tag(GeneralSettingsInfo.PolishTiming.hourly)
          Text("只在晚上").tag(GeneralSettingsInfo.PolishTiming.nightly)
        }.disabled(saving)
        Text("越晚整理用量越少，草稿始终实时出现").foregroundStyle(Palette.muted)
        Picker("当天概述", selection: draft.overview) {
          Text("每小时").tag(GeneralSettingsInfo.OverviewTiming.hourly)
          Text("每 3 小时").tag(GeneralSettingsInfo.OverviewTiming.everyThreeHours)
          Text("只在晚上").tag(GeneralSettingsInfo.OverviewTiming.nightly)
        }.disabled(saving)
        Picker("每天用量上限", selection: Binding(
          get: { draft.limitText.wrappedValue != nil },
          set: { draft.limitText.wrappedValue = $0 ? timelineSaved?.limitText ?? "" : nil }
        )) {
          Text("不限").tag(false)
          Text("自定义").tag(true)
        }.disabled(saving)
        if draft.limitText.wrappedValue != nil {
          SettingsRow("每天最多") {
            HStack(spacing: 6) {
              TextField("每天最多", text: Binding(
                get: { draft.limitText.wrappedValue ?? "" },
                set: { draft.limitText.wrappedValue = $0 }
              )).labelsHidden().multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 120).disabled(saving)
              Text("万 token").foregroundStyle(Palette.muted)
            }
          }
        }
        Text("达到后当天暂停整理，明天 0 点恢复，草稿照常出现").foregroundStyle(Palette.muted)
      } else if let timelineError {
        SettingsMessage(text: timelineError)
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    } header: {
      Text("时间线整理")
    } footer: {
      if let line = timelineSettings?.modelUsage.line { Note(line).monospacedDigit() }
    }
  }

  // MARK: 每一档

  /// 远端后台没有状态页入口；正常又没有完成时间时这一组没有内容，不留空卡片。
  private var showsStatus: Bool {
    if healthError != nil || !store.isRemoteBackend { return true }
    guard let health else { return false }
    if case .working = health.state { return health.lastOkAt != nil }
    return true
  }

  /// 已保存的三档完全一样、用户也没要求分开时，只显示一组，改动同时写进三档。
  private var sharesOneModel: Bool {
    // 草稿也要三档相同：有没保存的分档改动时不能折起来藏住它。
    guard !splitTiers, let first = saved[Self.tiers[0]], let editing = draft[Self.tiers[0]] else { return false }
    return Self.tiers.allSatisfy { saved[$0] == first && draft[$0] == editing }
  }

  @ViewBuilder func tierSection(_ tier: String, info: ModelSettingsInfo, together: Bool = false) -> some View {
    let remote = store.isRemoteBackend
    let config = Binding(get: { draft[tier] ?? ModelTierConfig(provider: remote ? "" : "codex-cli", model: "") },
                         set: { value in
                           if together { for t in Self.tiers { draft[t] = value } } else { draft[tier] = value }
                         })
    let c = config.wrappedValue
    let provider = info.providers.first { $0.id == c.provider }
    let local = Self.isLoopback(c.baseUrl)
    let localOptions = !remote && Self.showsLocalModelOptions && local
    Section {
      Picker("提供商", selection: Binding(get: { choice(c) }, set: { apply($0, to: config, info: info) })) {
        if remote && c.provider.isEmpty { Text("选择提供商").tag("") }
        ForEach(info.availableProviders(remote: remote), id: \.id) { Text($0.label).tag($0.id) }
        if !remote && Self.showsLocalModelOptions {
          Divider()
          ForEach(Self.presets, id: \.id) { Text($0.label).tag($0.id) }
        }
      }
      SettingsRow("模型") {
        HStack(spacing: 6) {
          TextField("模型", text: config.model, prompt: Text(placeholder(c.provider))).labelsHidden()
          if localOptions, let models = localModels[c.baseUrl ?? ""], !models.isEmpty {
            Menu("本机模型") { ForEach(models, id: \.self) { m in Button(m) { config.wrappedValue.model = m } } }
              .fixedSize()
          }
          Button(tests[tier] == .running ? "正在测试…" : "测试连接") { Task { await test(tier) } }
            .disabled(testingConnection || c.provider.isEmpty || c.model.isEmpty)
        }
      }
      if provider?.baseUrl == true {
        SettingsRow("地址") {
          TextField("地址", text: Binding(get: { c.baseUrl ?? "" }, set: { config.wrappedValue.baseUrl = $0.isEmpty ? nil : $0 }),
                    prompt: Text(c.provider == "anthropic" ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1")).labelsHidden()
        }
        if let url = c.baseUrl, !url.isEmpty, !local {
          SettingsMessage(text: "整理时，记录会发到这个地址。", warning: false)
        }
        if localOptions, c.provider == "openai-compatible", let url = c.baseUrl {
          HStack {
            if localModelLoading.contains(url) { Text("正在读取本机模型…").foregroundStyle(Palette.muted) }
            else if let error = localModelErrors[url] { SettingsMessage(text: error) }
            else if localModels[url] == [] { Text("服务已连接，但没有可用模型，请先在模型服务中下载或加载模型。").foregroundStyle(Palette.muted) }
            Spacer()
            Button("刷新模型") { Task { await loadLocalModels(url) } }.disabled(localModelLoading.contains(url))
          }
        }
        if remote {
          Text("模型地址须能从远端后台访问，localhost 指远端后台所在的机器。").foregroundStyle(Palette.muted)
        } else if local {
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
        Text("不确定时选“跟随模型”。").foregroundStyle(Palette.muted)
      }
      switch tests[tier] {
      case .ok(let ms): Text(ms.map { String(format: "连接正常，用时 %.1f 秒", $0 / 1000) } ?? "连接正常").foregroundStyle(Palette.muted)
      case .failed(let e): SettingsMessage(text: e)
      case .running: Text("正在连接，最长等 1 分钟…").foregroundStyle(Palette.muted)
      case nil: EmptyView()
      }
    } header: {
      Text(together ? "整理模型" : info.tierInfo[tier]?.label ?? tier)
    } footer: {
      if together {
        HStack(alignment: .firstTextBaseline) {
          Note("实时整理、每小时汇总和每日时间线都用它。")
          Spacer()
          Button("按任务分别设置") { splitTiers = true }.buttonStyle(.accentLink)
        }
      } else if let d = info.tierInfo[tier]?.description { Note(d) }
    }
    .task(id: c.baseUrl) { if localOptions, c.provider == "openai-compatible", let url = c.baseUrl { await loadLocalModels(url) } }
    .onChange(of: c) { _, _ in tests[tier] = nil }
  }

  // MARK: API key

  @ViewBuilder func keysSection(_ info: ModelSettingsInfo) -> some View {
    let usedProviders = Set(draft.values.filter { !Self.isLoopback($0.baseUrl) }.map(\.provider))
    let remote = store.isRemoteBackend
    let keyProviders = info.availableProviders(remote: remote).filter {
      $0.needsKey && (remote || usedProviders.contains($0.id) || (info.keys[$0.id] ?? nil) == true)
    }
    if !keyProviders.isEmpty {
    Section {
      ForEach(keyProviders, id: \.id) { p in
        SettingsRow(p.label) {
          HStack(spacing: 8) {
            switch info.keys[p.id] ?? nil {
            case true?: Text("已设置").foregroundStyle(Palette.muted)
            case false?: Text("未设置").foregroundStyle(Palette.muted)
            case nil: Text(remote ? "无法读取密钥状态" : "读不到钥匙串").foregroundStyle(Palette.attention)
            }
            Button((info.keys[p.id] ?? nil) == true ? "更换…" : "设置…") { editingKey = p.id }
            if (info.keys[p.id] ?? nil) == true { Button("删除…", role: .destructive) { removingKey = p.id } }
          }
        }
      }
    } header: {
      Text("API key")
    } footer: {
      Note(remote ? "密钥加密保存在远端后台，设置后不再显示。" : "key 存在这台 Mac 的钥匙串里，设置后不再显示。同一个提供商共用一个 key。")
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
    if Self.showsLocalModelOptions, c.provider == "openai-compatible", let p = Self.presets.first(where: { $0.url == c.baseUrl }) { return p.id }
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
    guard store.canManageBackend, !Task.isCancelled else { return }
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

  private func applyTimeline(_ settings: GeneralSettingsInfo) {
    timelineSettings = settings
    let current = TimelineDraft(settings)
    if timelineDraft == timelineSaved { timelineDraft = current }
    timelineSaved = current
    timelineError = nil
  }

  private func loadTimeline() async {
    guard store.canManageBackend, !Task.isCancelled else { return }
    let previous = timelineSaved
    do {
      let settings = try await store.api.generalSettings()
      guard timelineSaved == previous, !saving || previous == nil else { return }
      if timelineDraft == timelineSaved { applyTimeline(settings) }
      else { timelineSettings = settings }
    }
    catch is CancellationError {} catch { timelineError = error.localizedDescription }
  }

  private var canSaveModels: Bool {
    !store.isRemoteBackend || draft == saved || Self.tiers.allSatisfy { tier in
      guard let config = draft[tier], !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      return info?.availableProviders(remote: true).contains(where: { $0.id == config.provider }) == true
    }
  }

  func save() async {
    guard store.canManageBackend, canSaveModels else { return }
    saving = true; defer { saving = false }
    error = nil
    var values: [String: Any] = [:]
    if let timelineDraft, timelineDraft != timelineSaved {
      if timelineDraft.polish != timelineSaved?.polish { values["timeline_polish"] = timelineDraft.polish.rawValue }
      if timelineDraft.overview != timelineSaved?.overview { values["timeline_overview"] = timelineDraft.overview.rawValue }
      if timelineDraft.limitText != timelineSaved?.limitText {
        if let text = timelineDraft.limitText {
          guard let range = timelineSettings?.ranges["daily_token_limit"], range.count == 2, range[0] <= range[1],
                let tokens = DailyTokenLimit.tokens(from: text, range: range[0]...range[1]) else {
            error = "请输入有效的用量上限，最多四位小数。"
            return
          }
          values["daily_token_limit"] = tokens
        } else {
          values["daily_token_limit"] = NSNull()
        }
      }
    }
    do {
      if draft != saved {
        let i = try await store.api.saveModels(draft)
        info = i; saved = i.tiers; draft = i.tiers
      }
      if !values.isEmpty, store.canManageBackend {
        let settings = try await store.api.saveGeneral(values)
        timelineDraft = TimelineDraft(settings)
        applyTimeline(settings)
      }
    } catch { self.error = error.localizedDescription }
  }

  func test(_ tier: String) async {
    guard store.canManageBackend else { return }
    // 远端后台同一时间只接受一次连接测试，本页也只放行一个。
    guard let c = draft[tier], !testingConnection else { return }
    testingConnection = true
    defer {
      testingConnection = false
      if tests[tier] == .running { tests[tier] = nil }
    }
    tests[tier] = .running
    do {
      let r = try await store.api.testModel(tier: tier, config: c)
      guard draft[tier] == c else { return }
      tests[tier] = r.ok ? .ok(r.ms) : .failed(r.error ?? "连接失败")
    } catch { if draft[tier] == c { tests[tier] = .failed(error.localizedDescription) } }
  }

  func removeKey(_ provider: String) async {
    guard store.canManageBackend else { return }
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
      Text(store.isRemoteBackend ? "密钥加密保存在远端后台，设置后不再显示。" : "存在这台 Mac 的钥匙串里，设置后不再显示。")
        .foregroundStyle(Palette.muted)
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
    guard store.canManageBackend else { return }
    busy = true; defer { busy = false }
    do {
      try await store.api.setKey(provider: provider, key: key.trimmingCharacters(in: .whitespaces))
      key = ""
      await done()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
