import AppKit
import SwiftUI
import CollectorCore

/// 设置页按分组导航（AGENTS.md 2026-11-10）：左边是分组，右边是该组的内容。
enum SettingsGroup: String, CaseIterable, Identifiable {
  case general, sources, models, agents, hub, privacy, maintenance
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return L10n.Settings.general
    case .sources: return L10n.Settings.sources
    case .models: return L10n.Settings.aiModels
    case .agents: return L10n.Settings.aiTools
    case .hub: return L10n.Settings.backendAndConnection
    case .privacy: return L10n.Settings.privacy
    case .maintenance: return L10n.Settings.maintenance
    }
  }
  var icon: String {
    switch self {
    case .general: return "sliders-horizontal"
    case .sources: return "database"
    case .models: return "cpu"
    case .agents: return "plugs-connected"
    case .hub: return "globe"
    case .privacy: return "shield-check"
    case .maintenance: return "wrench"
    }
  }
}

struct SettingsPage: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage("settings.group") private var group: SettingsGroup = .general

  var body: some View {
    HStack(spacing: 0) {
      List(selection: Binding(get: { group }, set: { if let g = $0 { group = g } })) {
        ForEach(SettingsGroup.allCases) { g in
          Label { Text(g.title) } icon: { PhIcon(g.icon, size: 16).frame(width: 18) }.tag(g)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .frame(width: 180)
      Divider()
      Group {
        switch group {
        case .general: GeneralSettingsView()
        case .sources: SourcesSettingsView()
        case .models:
          if store.canManageBackend {
            ModelSettingsView().id(store.remoteBackend?.context.binding.route)
          } else {
            directConnectionRequired(RemoteBackendSettingsModel.modelsNotice)
          }
        case .agents:
          if store.canManageBackend {
            AgentSettingsView().id(store.remoteBackend?.context.binding.route)
          } else {
            directConnectionRequired(L10n.Settings.agentDirectNotice)
          }
        case .hub: HubSettingsView { group = .models }
        case .privacy: PrivacySettingsView()
        case .maintenance: MaintenanceSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle(L10n.Settings.settings)
    .task(id: store.remoteBackend?.context.binding.route) {
      guard let model = store.remoteBackend, model.isRemote else { return }
      while !Task.isCancelled {
        await model.refreshStatus()
        await WindowVisibility.pause(.seconds(15))
      }
    }
  }

  private func directConnectionRequired(_ message: String) -> some View {
    SettingsForm {
      Section {
        SettingsMessage(text: message, warning: false)
        Button(L10n.Settings.openBackendSettings) { group = .hub }
      }
    }
    .tint(Palette.accent)
  }
}

/// 设置页里统一的表单外观。
struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    // 滚动区域占满整栏、内容居中限宽：只限制 Form 自身宽度时，标题栏下的滚动边缘效果只盖住中间一段。
    GeometryReader { geo in
      Form { content }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, max(0, (geo.size.width - 760) / 2), for: .scrollContent)
    }
  }
}

/// macOS Form 会把 LabeledContent 的交互内容合并进静态 AX 文本；显式保留子控件。
struct SettingsRow<Label: View, Content: View>: View {
  let label: Label
  let content: Content
  var alignment: VerticalAlignment = .center
  /// 右侧内容带一行小字说明时用 .firstTextBaseline，让标签对齐输入框而不是整块的中线。
  init(_ title: String, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) where Label == SwiftUI.Text {
    label = Text(title); self.content = content(); self.alignment = alignment
  }
  init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
    self.label = label(); self.content = content()
  }
  init(_ title: String, value: String) where Label == SwiftUI.Text, Content == SwiftUI.Text {
    label = Text(title); content = Text(value).foregroundColor(Palette.muted)
  }
  var body: some View {
    HStack(alignment: alignment, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) { label }
      Spacer(minLength: 12)
      content
    }.accessibilityElement(children: .contain)
  }
}

/// 分组下方的说明。macOS 的分组表单默认把它靠右放，这里统一靠左。
struct Note: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).foregroundStyle(Palette.muted).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
  }
}

/// 加载失败、保存失败时的一行提示。
struct SettingsMessage: View {
  let text: String
  var warning = true
  var body: some View {
    // 错误原文可能较长（例如 key 的格式要求），要能换行显示全，不能截成"…"。
    Text(text).foregroundStyle(warning ? Palette.attention : Palette.muted)
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: 通用

struct GeneralSettingsView: View {
  @EnvironmentObject private var language: LanguageStore
  @Environment(ViewerStore.self) private var store

  var body: some View {
    SettingsForm {
      LoginStartupSection()
      Section {
        SettingsRow(L10n.Settings.displayLanguage) {
          Picker(L10n.Settings.displayLanguage, selection: $language.preference) {
            ForEach(LanguagePreference.allCases, id: \.self) { preference in
              Text(L10n.Settings.languageOption(preference)).tag(preference)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .accessibilityLabel(L10n.Settings.displayLanguage)
        }
      } header: {
        Text(L10n.Settings.language)
      } footer: {
        Note(L10n.Settings.languageNote)
      }
      Section(L10n.Settings.about) {
        SettingsVersionRow(notice: store.update)
        SettingsRow(L10n.Settings.build, value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L10n.Settings.localBuild)
      }
    }
    .tint(Palette.accent)
  }
}

private struct LoginStartupSection: View {
  @Environment(ViewerStore.self) private var store
  @State private var enabled = false
  @State private var installed = false
  @State private var mixed = false
  @State private var busy = false
  @State private var error: String?
  private var startup: LoginStartup? { store.loginStartup }
  var body: some View {
    Section {
      Toggle(L10n.Settings.startAtLogin, isOn: Binding(get: { enabled }, set: { value in
        busy = true; error = nil
        Task {
          do { try startup?.setEnabled(value) } catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
          refresh(); busy = false
        }
      })).toggleStyle(.switch).disabled(!installed || busy)
      if mixed { SettingsMessage(text: L10n.Settings.mixedStartup) }
      if !installed { SettingsMessage(text: L10n.Settings.startupIncomplete) }
      if let error { SettingsMessage(text: error) }
    } header: { Text(L10n.Settings.startup) }
    footer: { Note(L10n.Settings.startupNote) }
    .task {
      while !Task.isCancelled { refresh(); await WindowVisibility.pause(.seconds(5)) }
    }
  }
  func refresh() { enabled = startup?.enabled == true; installed = startup?.installed == true; mixed = startup?.mixed == true }
}

struct GeneralPreferencesSection: View {
  @Environment(ViewerStore.self) private var store
  let context: Bool
  var body: some View {
    @Bindable var p = store.preferences
    Section {
      if let d = Binding($p.draft) {
        // 自动归档天数由系统按默认值处理，不在设置页开放（2026-11-25）；context 只剩 true 一种。
        row(L10n.Settings.sessionContextLimit, value: d.injectTokens, key: "inject_tokens", unit: "token")
        // 已经是默认值、又没改动时，这一行什么都没有，不占位。
        if !p.isDefault(context: context) || p.changed(context: context) {
        HStack {
          // 已经是默认值时“恢复默认”没有用处，不出现。
          if !p.isDefault(context: context) {
            Button(L10n.Settings.restoreDefaults) { p.restore(context: context) }.disabled(p.busy)
          }
          Spacer()
          if p.changed(context: context) {
            Button(L10n.Settings.revertChanges) { p.revert(context: context) }.disabled(p.busy)
            Button(p.busy ? L10n.Settings.saving : L10n.Settings.save) { Task { await p.save(api: store.api, context: context) } }.disabled(p.busy)
          }
        }
        }
      } else if p.error == nil { ProgressView() }
      if let error = p.error {
        SettingsMessage(text: error)
        Button(L10n.Settings.retry) { Task { await p.load(api: store.api) } }
      }
      if let message = p.message { SettingsMessage(text: message, warning: false) }
    } header: { Text(L10n.Settings.sessionContext) }
    footer: {
      Note(L10n.Settings.sessionContextNote)
    }
    .task { await p.load(api: store.api) }
  }
  func row(_ title: String, value: Binding<Int>, key: String, unit: String) -> some View {
    let limits = store.preferences.draft?.ranges[key] ?? [1, 90]
    return SettingsRow(title) {
      HStack(spacing: 8) {
        TextField(title, value: value, format: .number.grouping(.never))
          .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 72).multilineTextAlignment(.trailing)
          .accessibilityLabel(title)
        Text(unit).foregroundStyle(Palette.muted)
        Stepper(title, value: value, in: limits[0]...limits[1], step: context ? 100 : 1).labelsHidden()
      }
    }
  }
}

// MARK: 后台服务

struct HubSettingsView: View {
  let openModels: () -> Void
  @Environment(ViewerStore.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var info: HubPortSettings?
  @State private var offline = false
  @State private var baselinePort = ""
  @State private var port = ""
  @State private var busy = false
  @State private var message: String?
  @State private var error: String?

  var body: some View {
    let c = store.capture
    let model = store.remoteBackend
    SettingsForm {
      if let model {
        RemoteBackendSettingsSection(model: model, queue: c.queue, sent: c.sent, openModels: openModels) {
          localRows(c)
        }
      } else if !store.isRemoteBackend {
        Section {
          SettingsRow(L10n.Settings.currentBackend, value: L10n.Settings.thisMac)
          localRows(c)
        } header: { Text(L10n.Settings.backgroundService) } footer: { Note(L10n.Settings.localPortNote) }
      }
      if store.canManageBackend {
        // 分组表单要直接拿到 Section：不在外面套 .id，换后台时由各分组自己按路由重读（2026-11-24 套 .id 曾让分组错位、标题重复）。
        DeviceSettingsSection()
        RelaySettingsSection()
      }
    }
    .tint(Palette.accent)
    .task {
      while !Task.isCancelled {
        model?.refreshContext()
        await model?.restoreReplacement()
        if !store.isRemoteBackend, !busy { await load() }
        await WindowVisibility.pause(.seconds(5))
      }
    }
    .sheet(isPresented: Binding(get: { model?.showDetails == true }, set: { model?.showDetails = $0 })) {
      if let model { RemoteBackendDetails(model: model) { model.showDetails = false } }
    }
    .sheet(isPresented: Binding(get: { model?.returnPreview != nil }, set: { if !$0 { model?.returnPreview = nil } })) {
      if let model, let preview = model.returnPreview {
        RemoteBackendConfirmation(action: .switchBack(preview), cancel: { model.returnPreview = nil },
                                  confirm: { Task { await model.switchBack() } }, busy: model.switchingBack)
      }
    }
    .sheet(isPresented: Binding(get: { model?.confirmDelete == true }, set: { model?.confirmDelete = $0 })) {
      if let model {
        RemoteBackendConfirmation(action: .deleteBackup, cancel: { model.confirmDelete = false },
                                  confirm: { Task { await model.deleteBackup() } }, busy: model.busy)
      }
    }
  }

  @ViewBuilder private func localRows(_ c: CaptureSnapshot) -> some View {
    SettingsRow(L10n.Settings.address) {
      Text(store.api.base.host ?? "").font(.mono(TextSize.body)).textSelection(.enabled)
    }
    let config = (store.controls as? AppDelegate)?.config
    let localEditable = config?.allowsLocalHub == true && config?.fixedPort == nil && ProcessInfo.processInfo.environment["RA_PORT"] == nil
    let editable = !store.isRemoteBackend && (info?.locked == false || (offline && localEditable && AppSetup.activity != .running))
    let edited = editable && port != baselinePort
    let validPort = Int(port).flatMap { (1024...65535).contains($0) ? $0 : nil }
    SettingsRow(L10n.Settings.port) {
      HStack(spacing: 8) {
        TextField(L10n.Settings.port, text: $port).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
          .font(.mono(TextSize.body)).multilineTextAlignment(.trailing).disabled(!editable || busy)
        if edited {
          Button(L10n.Settings.revertChanges) {
            port = baselinePort
            message = nil
            error = nil
          }
          .disabled(busy)
          Button(busy ? L10n.Settings.restarting : offline ? L10n.Settings.prepareAgain : L10n.Settings.saveAndRestart) {
            if let validPort { Task { await apply(validPort) } }
          }
          .disabled(busy || validPort == nil)
        }
      }
    }
    if edited && validPort == nil {
      SettingsMessage(text: L10n.Settings.invalidPort)
    }
    SettingsRow(L10n.Settings.webView) {
      Button(L10n.Settings.openInBrowser) {
        if let url = store.api.statusPageURL() { openURL(url) } else { error = L10n.Settings.backendNotReady }
      }
    }
    if c.queue > 0 { SettingsRow(L10n.Settings.waitingToSave, value: L10n.Settings.recordCount(c.queue)) }
    // 连得上就不占一行，只有检查中或出问题时才说。
    if !offline, let problem = store.sharedError ?? c.hubError {
      SettingsRow(L10n.Settings.status) { Text(L10n.Settings.backgroundIssue(problem)).foregroundStyle(Palette.attention) }
    } else if offline, let config {
      switch AppSetup.checklistStep(in: config.dataDir, reachable: false) {
      case .preparing: SettingsRow(L10n.Settings.status, value: L10n.Settings.preparingBackend)
      case .failed(let status): SettingsRow(L10n.Settings.status, value: status)
      case nil: EmptyView()
      }
    } else if info == nil {
      SettingsRow(L10n.Settings.status, value: L10n.Settings.checking)
    }
    if info?.locked == true || (offline && !localEditable) { SettingsMessage(text: L10n.Settings.portLocked, warning: false) }
    if let message { SettingsMessage(text: message, warning: false) }
    if let error { SettingsMessage(text: error) }
  }

  func load() async {
    if !store.isRemoteBackend, let delegate = store.controls as? AppDelegate, delegate.config.allowsLocalHub {
      let config = delegate.config
      let reachable = AppSetup.activity == .running ? false : await AppSetup.isReachable(config.hubURL)
      guard !Task.isCancelled else { return }
      if !reachable {
        offline = true
        info = nil
        updateBaseline(config.hubURL.port.map(String.init) ?? "47823")
        return
      }
    }
    do {
      let h = try await store.api.hubSettings()
      offline = false
      info = h
      updateBaseline(String(h.port))
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
    }
  }

  private func updateBaseline(_ value: String) {
    if port == baselinePort { port = value }
    baselinePort = value
  }

  /// 中枢写入 hub.json 后退出，launchd 用新端口拉起；采集端每次请求都现读 hub.json，跟着换过去。
  func apply(_ p: Int) async {
    busy = true; message = nil; error = nil
    defer { busy = false }
    do {
      if offline, let delegate = store.controls as? AppDelegate {
        try await delegate.prepareBackendAgain(port: p)
        port = String(p)
        await load()
        if info?.port == p { message = L10n.Settings.portUpdated }
        return
      }
      let restarting = try await store.api.setHubPort(p)
      guard restarting else { await load(); return }
      message = L10n.Settings.backendRestarting
      for _ in 0..<30 {
        try? await Task.sleep(for: .seconds(1))
        if let h = try? await store.api.hubSettings(), h.port == p {
          info = h; baselinePort = String(p); port = baselinePort; message = L10n.Settings.portUpdated
          await store.refreshShared()
          return
        }
      }
      message = nil
      error = L10n.Settings.backendRestartTimeout
    } catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}

// MARK: 隐私（只读展示）

struct PrivacySettingsView: View {
  @Environment(ViewerStore.self) private var store

  var body: some View {
    let c = store.capture
    SettingsForm {
      Section(L10n.Settings.pauseRecording) {
        switch c.state {
        case .paused(let until):
          SettingsRow(L10n.Settings.pausedUntil(ViewerFormat.clock(until))) { Button(L10n.Settings.resumeRecording) { store.perform(.resume) } }
        default:
          SettingsRow(c.statusTitle) {
            // 数据源全关时本来就没在记录，暂停按钮没有用处。
            if c.sources.contains(where: \.enabled) {
              HStack {
                Button(L10n.Settings.pauseOneHour) { store.perform(.pauseHour) }
                Button(L10n.Settings.pauseUntilTomorrow) { store.perform(.pauseTomorrow) }
              }
            }
          }
        }
      }
      Section {
        SettingsRow(L10n.Settings.passwordsAndKeys, value: L10n.Settings.redactionRule)
        SettingsRow(L10n.Settings.privateContent, value: L10n.Settings.privateDefaultRule)
        SettingsRow(L10n.Settings.deletedRecords, value: L10n.Settings.deletionRule)
      } header: {
        Text(L10n.Settings.handlingRules)
      } footer: {
        Note(L10n.Settings.privateSearchNote)
      }
    }
  }


}

// MARK: 维护

struct MaintenanceSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var backfillFrom = Calendar.current.date(byAdding: .day, value: -(DistillDateRange.defaultDays - 1), to: Date())!
  @State private var backfillTo = Date()
  @State private var requests: [DistillRequestInfo] = []
  @State private var requestError: String?
  @State private var keys: KeyBackup.State = .idle

  var body: some View {
    let c = store.capture
    let remote = store.isRemoteBackend
    SettingsForm {
      Section {
        SettingsRow(L10n.Settings.runLog) {
          Button(L10n.Settings.open) { store.path.append(.runtime) }
        }
        DiagnosticSettingsRow()
      }
      if !c.pluginsAvailable {
        Section {
          SettingsMessage(text: L10n.Settings.missingSources)
        }
      }
      operation(.syncAll, verb: L10n.Settings.sync, job: c.jobs[.syncAll], extra: latest("round")?.statusText,
                what: L10n.Settings.syncAllWhat,
                detail: L10n.Settings.syncAllDetail) {
        store.perform(.maintenance(.syncAll))
      }
      operation(.reimportRecent, verb: L10n.Settings.importRecords, job: c.jobs[.reimportRecent],
                what: L10n.Settings.reimportWhat,
                detail: L10n.Settings.reimportDetail) {
        store.perform(.maintenance(.reimportRecent))
      }
      operation(.importAll, verb: L10n.Settings.importRecords, job: c.jobs[.importAll],
                what: L10n.Settings.importAllWhat,
                detail: L10n.Settings.importAllDetail) {
        store.perform(.maintenance(.importAll))
      }
      Section {
        SettingsRow(MaintenanceTask.backfill.title) {
          Button(L10n.Settings.summarize) { Task { await requestBackfill() } }
            .disabled(!store.canManageBackend || latest("backfill").map { !$0.finished } == true)
        }
        SettingsRow(L10n.Settings.dateRange) {
          HStack {
            DatePicker(L10n.Settings.from, selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
            Text(L10n.Settings.to).foregroundStyle(Palette.muted)
            DatePicker(L10n.Settings.to, selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
          }
          .disabled(!store.canManageBackend)
        }
        if store.canManageBackend {
          if let r = latest("backfill") { SettingsMessage(text: r.statusText, warning: r.status == "failed") }
          if let requestError { SettingsMessage(text: requestError) }
        } else {
          SettingsMessage(text: L10n.Settings.backfillDirectNotice, warning: false)
        }
        facts(what: L10n.Settings.backfillWhat,
              detail: L10n.Settings.backfillDetail)
      }
      Section {
        SettingsRow(L10n.Settings.keyBackup(onThisMac: remote)) {
          // 同其他复制按钮：复制后按钮写“已复制”，1.5 秒后复原（docs/ui.md）。
          Button(keys == .running ? L10n.Settings.loading : keys == .copied ? L10n.Settings.copied : L10n.Settings.copy) {
            Task {
              keys = .running
              keys = await KeyBackup.copy()
              if keys == .copied { try? await Task.sleep(for: .seconds(1.5)); if keys == .copied { keys = .idle } }
            }
          }.disabled(keys == .running)
        }
        if case .failed(let message) = keys { SettingsMessage(text: message) }
        SettingsRow(L10n.Settings.dataFolder(onThisMac: remote)) {
          Button(L10n.Settings.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([Config.load().dataDir]) }
        }
      } header: { Text(L10n.Settings.dataAndBackups) } footer: {
        Note(L10n.Settings.keyBackupNote)
      }
    }
    .task(id: store.canManageBackend) {
      guard store.canManageBackend else { return }
      // 有排队或执行中的请求时 3 秒刷新一次，否则 30 秒。
      while !Task.isCancelled {
        await loadRequests()
        await WindowVisibility.pause(.seconds(requests.contains { !$0.finished } ? 3 : 30))
      }
    }
    // 同步全部结束时会提交一次整理，马上读一次，免得下面的“整理”最多晚 30 秒才跟上。
    .onChange(of: store.capture.jobs[.syncAll]?.running) { _, running in
      if running == false { Task { await loadRequests() } }
    }
  }

  func operation(_ task: MaintenanceTask, verb: String, job: CaptureSnapshot.Job?, extra: String? = nil,
                 what: String, detail: String, action: @escaping () -> Void) -> some View {
    Section {
      SettingsRow {
        Button(job?.running == true ? L10n.Settings.inProgress : verb, action: action).disabled(job?.running == true)
      } label: {
        Text(task.title)
        if let text = job?.text, !text.isEmpty { Text(L10n.Settings.operationStatus(text)) }
        if let extra { Text(L10n.Settings.summaryStatus(extra)) }
      }
      facts(what: what, detail: detail)
    }
  }

  /// AGENTS.md：每个维护操作写明做什么、读哪些来源、是否去重、是否整理。
  /// 一句做什么，下面一行写读哪些来源、是否去重、是否整理；四项都直接看得到，不用再点开。
  func facts(what: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(what)
      Text(detail).font(.system(size: TextSize.caption))
    }
    .foregroundStyle(Palette.muted)
    .multilineTextAlignment(.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }

  func latest(_ kind: String) -> DistillRequestInfo? { requests.first { $0.kind == kind } }
  func loadRequests() async {
    guard store.canManageBackend, !Task.isCancelled else { return }
    do { requests = try await store.api.distillRequests(); requestError = nil }
    catch is CancellationError {}
    catch { requestError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
  func requestBackfill() async {
    guard store.canManageBackend else { return }
    do {
      try await store.api.requestDistill(kind: "backfill", range: DistillDateRange(start: backfillFrom, end: backfillTo))
      await loadRequests()
    } catch { requestError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}

/// 密钥备份：调用 `cli.ts keys export`（和命令行同一份格式），拷到剪贴板时标成"隐藏内容"，
/// 本机的剪贴板记录和剪贴板管理器都会跳过它（Policy.swift 的 ConcealedType）。不写文件。
enum KeyBackup {
  enum State: Equatable { case idle, running, copied, failed(String) }

  static func copy() async -> State {
    let config = Config.load()
    guard let repo = config.repo, FileManager.default.isExecutableFile(atPath: config.bun) else {
      return .failed(L10n.Settings.reinstallTacit)
    }
    let result: (status: Int32, out: String) = await Task.detached {
      let p = Process(), out = Pipe()
      p.executableURL = URL(fileURLWithPath: config.bun)
      p.arguments = ["\(repo)/hub/src/cli.ts", "keys", "export"]
      p.standardOutput = out; p.standardError = FileHandle.nullDevice
      do { try p.run() } catch { return (-1, "") }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
    guard result.status == 0, !result.out.isEmpty else {
      return .failed(L10n.Settings.keyBackupFailed)
    }
    let pb = NSPasteboard.general
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
    pb.setString(result.out, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    return .copied
  }
}
