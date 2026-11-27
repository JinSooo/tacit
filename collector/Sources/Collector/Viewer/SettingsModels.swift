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
  @State private var healthUnavailable = false
  @State private var summaryFailureDetail: String?
  /// 三档用同一个模型时合成一组显示；用户点“按任务分别设置”后才展开三档。
  @State private var splitTiers = false

  enum TestState: Equatable { case running, ok(Double?), failed(String, detail: String?) }

  private struct SummaryFailureDetails: Decodable {
    let lastFailureDetail: [String: String?]?
  }

  private struct ConnectionTestPayload: Decodable {
    let ok: Bool
    let ms: Double?
    let error: String?
    let detail: String?
  }

  static let tiers = ["minute", "hour", "day"]
  private static let showsLocalModelOptions = false
  /// 本机模型服务走 OpenAI 兼容接口，不需要 key。
  static var presets: [(id: String, label: String, url: String)] { [
    ("ollama", L10n.Settings.localOllama, "http://127.0.0.1:11434/v1"),
    ("lmstudio", L10n.Settings.localLMStudio, "http://127.0.0.1:1234/v1"),
  ] }

  var body: some View {
    SettingsForm {
      if let info {
        if info.configError != nil {
          SettingsMessage(text: store.isRemoteBackend ? L10n.Settings.remoteModelRequired : L10n.Settings.invalidModelSettings)
        }
        if sharesOneModel {
          tierSection(Self.tiers[0], info: info, together: true).disabled(saving)
        } else {
          ForEach(Self.tiers, id: \.self) { tier in tierSection(tier, info: info) }.disabled(saving)
        }
        timelineSection
        otherKeysSection(info)
        if draft != saved || timelineDraft != timelineSaved {
          HStack {
            Spacer()
            Button(L10n.Settings.revertChanges) { draft = saved; timelineDraft = timelineSaved; splitTiers = !Self.same(saved) }.disabled(saving)
            Button(saving ? L10n.Settings.saving : L10n.Settings.save) { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving || !canSaveModels)
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
    .confirmationDialog(L10n.Settings.deleteAPIKeyQuestion, isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } })) {
      if let provider = removingKey { Button(L10n.Settings.delete, role: .destructive) { Task { await removeKey(provider); removingKey = nil } } }
      Button(L10n.Settings.cancel, role: .cancel) { removingKey = nil }
    } message: {
      if let provider = removingKey, !draft.values.contains(where: { $0.provider == provider && !Self.isLoopback($0.baseUrl) }) {
        Text(L10n.Settings.unusedAPIKey)
      } else {
        Text(L10n.Settings.apiKeyDeletionNote)
      }
    }
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
        Picker(L10n.Settings.summarizeTimeline, selection: draft.polish) {
          Text(L10n.Settings.afterActivity).tag(GeneralSettingsInfo.PolishTiming.afterSegment)
          Text(L10n.Settings.hourly).tag(GeneralSettingsInfo.PolishTiming.hourly)
          Text(L10n.Settings.nightly).tag(GeneralSettingsInfo.PolishTiming.nightly)
        }.disabled(saving)
        Text(L10n.Settings.timelinePolishNote).foregroundStyle(Palette.muted)
        Picker(L10n.Settings.dayOverview, selection: draft.overview) {
          Text(L10n.Settings.hourly).tag(GeneralSettingsInfo.OverviewTiming.hourly)
          Text(L10n.Settings.everyThreeHours).tag(GeneralSettingsInfo.OverviewTiming.everyThreeHours)
          Text(L10n.Settings.nightly).tag(GeneralSettingsInfo.OverviewTiming.nightly)
        }.disabled(saving)
        Picker(L10n.Settings.dailyUsageLimit, selection: Binding(
          get: { draft.limitText.wrappedValue != nil },
          set: { draft.limitText.wrappedValue = $0 ? timelineSaved?.limitText ?? "" : nil }
        )) {
          Text(L10n.Settings.unlimited).tag(false)
          Text(L10n.Settings.custom).tag(true)
        }.disabled(saving)
        if draft.limitText.wrappedValue != nil {
          SettingsRow(L10n.Settings.dailyMaximum) {
            HStack(spacing: 6) {
              TextField(L10n.Settings.dailyMaximum, text: Binding(
                get: { draft.limitText.wrappedValue ?? "" },
                set: { draft.limitText.wrappedValue = $0 }
              ), prompt: Text(L10n.Settings.limitExample)).labelsHidden().multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 120).disabled(saving)
              Text(L10n.Settings.tenThousandTokens).foregroundStyle(Palette.muted)
            }
          }
          Text(L10n.Settings.dailyUsageLimitNote).foregroundStyle(Palette.muted)
        }
        if let timelineError { SettingsMessage(text: timelineError) }
      } else if let timelineError {
        SettingsMessage(text: timelineError)
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    } header: {
      Text(L10n.Settings.timelineSummarySettings)
    } footer: {
      let usage = timelineSettings.flatMap { L10n.Settings.usageLine($0.modelUsage) }
      let details = store.isRemoteBackend ? nil : store.api.statusPageURL(section: "usage")
      if usage != nil || details != nil {
        HStack(alignment: .firstTextBaseline) {
          if let line = usage { Note(line).monospacedDigit() } else { Spacer() }
          if let details {
            Button(L10n.Settings.viewDetailedUsage) { NSWorkspace.shared.open(details) }.buttonStyle(.accentLink)
          }
        }
      }
    }
  }

  // MARK: 每一档

  /// 没有分开时只显示一组，改动同时写进三档。是否分开由 splitTiers 决定：读到的三档不一样时自动分开，
  /// 只有点“全部任务都用这一组”才合回去，免得打字时三档草稿碰巧一样就突然折起来。
  private var sharesOneModel: Bool {
    guard !splitTiers, let editing = draft[Self.tiers[0]] else { return false }
    return Self.tiers.allSatisfy { draft[$0] == editing }
  }
  private static func same(_ tiers: [String: ModelTierConfig]) -> Bool {
    guard let first = tiers[Self.tiers[0]] else { return true }
    return Self.tiers.allSatisfy { tiers[$0] == first }
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
      Picker(L10n.Settings.provider, selection: Binding(get: { choice(c) }, set: { apply($0, to: config, info: info) })) {
        if remote && c.provider.isEmpty { Text(L10n.Settings.selectProvider).tag("") }
        ForEach(info.availableProviders(remote: remote), id: \.id) { Text(L10n.Settings.providerName($0.id, fallback: $0.label)).tag($0.id) }
        if !remote && Self.showsLocalModelOptions {
          Divider()
          ForEach(Self.presets, id: \.id) { Text($0.label).tag($0.id) }
        }
      }
      SettingsRow(L10n.Settings.model) {
        HStack(spacing: 6) {
          TextField(L10n.Settings.model, text: config.model, prompt: Text(placeholder(c.provider))).labelsHidden()
          if localOptions, let models = localModels[c.baseUrl ?? ""], !models.isEmpty {
            Menu(L10n.Settings.localModels) { ForEach(models, id: \.self) { m in Button(m) { config.wrappedValue.model = m } } }
              .fixedSize()
          }
        }
      }
      if provider?.baseUrl == true {
        SettingsRow(L10n.Settings.address, alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            TextField(L10n.Settings.address, text: Binding(get: { c.baseUrl ?? "" }, set: { config.wrappedValue.baseUrl = $0.isEmpty ? nil : $0 }),
                      prompt: Text(c.provider == "anthropic" ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1")).labelsHidden()
            if let note = addressNote(c.baseUrl, local: local, remote: remote) {
              Text(note).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if localOptions, c.provider == "openai-compatible", let url = c.baseUrl {
          HStack {
            if localModelLoading.contains(url) { Text(L10n.Settings.loadingLocalModels).foregroundStyle(Palette.muted) }
            else if let error = localModelErrors[url] { SettingsMessage(text: error) }
            else if localModels[url] == [] { Text(L10n.Settings.noLocalModels).foregroundStyle(Palette.muted) }
            Spacer()
            Button(L10n.Settings.refreshModels) { Task { await loadLocalModels(url) } }.disabled(localModelLoading.contains(url))
          }
        }
      }
      // key 跟着用它的模型放：同一个提供商共用一个 key，分开设置时每一档都显示同一个。
      if let provider, provider.needsKey, !local { keyRow(provider, info: info) }
      if c.provider == "openai-compatible" {
        Picker(L10n.Settings.thinkingEffort, selection: Binding(get: { c.reasoningEffort ?? "" }, set: { config.wrappedValue.reasoningEffort = $0.isEmpty ? nil : $0 })) {
          Text(L10n.Settings.modelDefault).tag("")
          Text(L10n.Settings.off).tag("none")
          Text(L10n.Settings.low).tag("low")
          Text(L10n.Settings.medium).tag("medium")
          Text(L10n.Settings.high).tag("high")
        }
      }
      statusRow(tier, config: c, first: together || tier == Self.tiers[0])
    } header: {
      Text(together ? L10n.Settings.summaryModel : L10n.Settings.tierName(tier, fallback: info.tierInfo[tier]?.label ?? tier))
    } footer: {
      if together {
        HStack(alignment: .firstTextBaseline) {
          Note(L10n.Settings.sharedModelNote)
          Spacer()
          Button(L10n.Settings.separateModels) { splitTiers = true }.buttonStyle(.accentLink)
        }
      } else if tier == Self.tiers[0] {
        HStack(alignment: .firstTextBaseline) {
          if let detail = L10n.Settings.tierDescription(tier, fallback: info.tierInfo[tier]?.description) { Note(detail) }
          Spacer()
          // 分开后能合回去：三个任务都改成这一组，没保存前可以撤销。
          Button(L10n.Settings.shareModel) {
            for t in Self.tiers { draft[t] = c }
            tests = tests[Self.tiers[0]].map { [Self.tiers[0]: $0] } ?? [:]
            splitTiers = false
          }.buttonStyle(.accentLink)
        }
      } else if let detail = L10n.Settings.tierDescription(tier, fallback: info.tierInfo[tier]?.description) { Note(detail) }
    }
    .task(id: c.baseUrl) { if localOptions, c.provider == "openai-compatible", let url = c.baseUrl { await loadLocalModels(url) } }
    .onChange(of: c) { _, _ in tests[tier] = nil }
  }

  private func addressNote(_ url: String?, local: Bool, remote: Bool) -> String? {
    if remote { return L10n.Settings.remoteModelAddressNote }
    if local { return L10n.Settings.localModelAddressNote }
    if let url, !url.isEmpty { return L10n.Settings.modelAddressNote }
    return nil
  }

  /// 卡片最后一行：最近整理时间（或出的问题）和测试连接。整理状态是整体的，只放在第一组；问题放在出问题的那一档。
  @ViewBuilder private func statusRow(_ tier: String, config c: ModelTierConfig, first: Bool) -> some View {
    let state = health?.state
    let failingHere: String? = {
      guard case .failing(let reason)? = state else { return nil }
      if sharesOneModel { return reason }
      let target = health?.failingTier.flatMap { Self.tiers.contains($0) ? $0 : nil } ?? Self.tiers[0]
      return target == tier ? reason : nil
    }()
    let button = Button(tests[tier] == .running ? L10n.Settings.testing : L10n.Settings.testConnection) { Task { await test(tier) } }
      .disabled(testingConnection || c.provider.isEmpty || c.model.isEmpty)
    if let failingHere {
      SettingsMessage(text: L10n.Settings.modelFailure(failingHere, fallback: L10n.Settings.summaryFailure))
      if let summaryFailureDetail { ModelFailureDetail(text: summaryFailureDetail).id(summaryFailureDetail) }
    }
    if first, healthUnavailable {
      SettingsRow(L10n.Settings.latestSummary) { HStack(spacing: 12) { Text(L10n.Settings.currentlyUnavailable).foregroundStyle(Palette.attention); button } }
    } else if first, let time = health?.lastOkAt.flatMap(ViewerTime.parse) {
      SettingsRow(L10n.Settings.latestSummary) { HStack(spacing: 12) { Text(Fmt.dateTime(time)).foregroundStyle(Palette.muted); button } }
    } else if first, state == .waiting {
      SettingsRow(L10n.Settings.latestSummary) { HStack(spacing: 12) { Text(L10n.Settings.awaitingFirstSummary).foregroundStyle(Palette.muted); button } }
    } else {
      SettingsRow { button } label: { EmptyView() }
    }
    switch tests[tier] {
    case .ok(let ms):
      if sharesOneModel ? draft != saved : draft[tier] != saved[tier] {
        HStack(spacing: 12) {
          Text(L10n.Settings.connectionNeedsSave).foregroundStyle(Palette.muted)
          Button(L10n.Settings.save) { Task { await save() } }.disabled(saving || !canSaveModels)
        }
      } else {
        Text(ms.map { L10n.Settings.connectionDuration($0 / 1000) } ?? L10n.Settings.connectionOK).foregroundStyle(Palette.muted)
      }
    case .failed(let message, let detail):
      SettingsMessage(text: message)
      if let detail { ModelFailureDetail(text: detail).id(detail) }
    case .running: Text(L10n.Settings.connectionTestNote).foregroundStyle(Palette.muted)
    case nil: EmptyView()
    }
  }

  // MARK: API key

  @ViewBuilder private func keyRow(_ p: ModelSettingsInfo.ProviderInfo, info: ModelSettingsInfo) -> some View {
    let remote = store.isRemoteBackend
    SettingsRow("API key") {
      HStack(spacing: 8) {
        switch info.keys[p.id] ?? nil {
        case true?: Text(L10n.Settings.configured).foregroundStyle(Palette.muted)
        case false?: Text(L10n.Settings.notConfigured).foregroundStyle(Palette.attention)
        case nil: Text(remote ? L10n.Settings.apiKeyStatusUnavailable : L10n.Settings.keychainUnavailable).foregroundStyle(Palette.attention)
        }
        Button((info.keys[p.id] ?? nil) == true ? L10n.Settings.replaceEllipsis : L10n.Settings.setEllipsis) { editingKey = p.id }
        if (info.keys[p.id] ?? nil) == true { Button(L10n.Settings.deleteEllipsis, role: .destructive) { removingKey = p.id } }
      }
    }
  }

  /// 存了 key、但现在没有哪一档在用的提供商，单独列出来方便删除；平时没有这一组。
  @ViewBuilder func otherKeysSection(_ info: ModelSettingsInfo) -> some View {
    let used = Set(draft.values.filter { !Self.isLoopback($0.baseUrl) }.map(\.provider))
    let others = info.availableProviders(remote: store.isRemoteBackend).filter {
      $0.needsKey && !used.contains($0.id) && (info.keys[$0.id] ?? nil) == true
    }
    if !others.isEmpty {
      Section(L10n.Settings.otherAPIKeys) {
        ForEach(others, id: \.id) { p in
          SettingsRow(L10n.Settings.providerName(p.id, fallback: p.label)) {
            HStack(spacing: 8) {
              Button(L10n.Settings.deleteEllipsis, role: .destructive) { removingKey = p.id }
            }
          }
        }
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
      if !Task.isCancelled { localModelErrors[url] = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
    case "anthropic": return L10n.Settings.anthropicModelExample
    case "codex-cli": return L10n.Settings.codexModelExample
    case "claude-cli": return L10n.Settings.claudeModelExample
    default: return L10n.Settings.modelName
    }
  }

  func label(_ provider: String, info: ModelSettingsInfo?) -> String {
    L10n.Settings.providerName(provider, fallback: info?.providers.first { $0.id == provider }?.label ?? provider)
  }

  func load() async {
    guard store.canManageBackend, !Task.isCancelled else { return }
    do {
      let i = try await store.api.modelSettings()
      info = i
      // 只在没有未保存改动时刷新草稿，免得设置 key 后把正在改的内容冲掉。
      if draft == saved { draft = i.tiers; if !Self.same(i.tiers) { splitTiers = true } }
      saved = i.tiers
      error = nil
    }
    catch is CancellationError {}
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }

  func loadHealth() async {
    do {
      let current = try await store.api.distillHealth()
      healthUnavailable = false
      var detail: String?
      if let tier = current.failingTier, store.canManageBackend, !store.isRemoteBackend {
        let payload = try? await store.api.get(SummaryFailureDetails.self, "/v1/settings/models", device: .init("settings.models.get"))
        detail = payload?.lastFailureDetail?[tier] ?? nil
      }
      guard !Task.isCancelled else { return }
      health = current
      summaryFailureDetail = detail
    } catch is CancellationError {} catch {
      healthUnavailable = true
      summaryFailureDetail = nil
    }
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
      else { timelineSettings = settings; timelineError = nil }
    }
    catch is CancellationError {} catch { timelineError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
            error = L10n.Settings.invalidTokenLimit
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
    } catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
      let r = try await store.api.call(ConnectionTestPayload.self, "POST", "/v1/settings/models/test",
        ["tier": tier, "config": HubAPI.tierJSON(c)], timeout: 75, device: .init("settings.models.test"))
      guard draft[tier] == c else { return }
      let message = r.error.map { L10n.Settings.modelFailure($0, fallback: L10n.Settings.connectionFailed) } ?? L10n.Settings.connectionFailed
      tests[tier] = r.ok ? .ok(r.ms) : .failed(message, detail: store.isRemoteBackend ? nil : r.detail)
    } catch is CancellationError {} catch {
      if draft[tier] == c { tests[tier] = .failed(L10n.Settings.connectionFailed, detail: nil) }
    }
  }

  func removeKey(_ provider: String) async {
    guard store.canManageBackend else { return }
    do { try await store.api.deleteKey(provider: provider); await load() }
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}

private struct ModelFailureDetail: View {
  let text: String

  var body: some View {
    DisclosureGroup(L10n.Settings.viewModelFailure) {
      VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: text)
          .font(.system(size: TextSize.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(L10n.Settings.modelFailureLocalNote)
          .font(.system(size: TextSize.caption))
          .foregroundStyle(Palette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
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
      Text(L10n.Settings.setAPIKey(label)).font(.system(size: TextSize.body, weight: .semibold))
      SecureField("API key", text: $key).frame(width: 360)
      Text(store.isRemoteBackend ? L10n.Settings.remoteKeyNote : L10n.Settings.localKeyNote)
        .foregroundStyle(Palette.muted)
      if let error { SettingsMessage(text: error) }
      HStack {
        Spacer()
        Button(L10n.Settings.cancel, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? L10n.Settings.saving : L10n.Settings.save) { Task { await save() } }
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
    } catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}
