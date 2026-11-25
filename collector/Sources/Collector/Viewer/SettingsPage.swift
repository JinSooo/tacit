import AppKit
import SwiftUI
import CollectorCore

/// 设置页按分组导航（AGENTS.md 2026-11-10）：左边是分组，右边是该组的内容。
enum SettingsGroup: String, CaseIterable, Identifiable {
  case general, sources, models, agents, hub, privacy, maintenance
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return "通用"
    case .sources: return "数据源"
    case .models: return "AI 模型"
    case .agents: return "AI 工具"
    case .hub: return "后台与连接"
    case .privacy: return "隐私"
    case .maintenance: return "维护"
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
            directConnectionRequired(RemoteBackendSettingsModel.managementNotice)
          }
        case .agents:
          if store.canManageBackend {
            AgentSettingsView().id(store.remoteBackend?.context.binding.route)
          } else {
            directConnectionRequired("连接 AI 工具需要直连远端后台。")
          }
        case .hub: HubSettingsView { group = .models }
        case .privacy: PrivacySettingsView()
        case .maintenance: MaintenanceSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle("设置")
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
        Button("前往后台与连接") { group = .hub }
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
  var body: some View {
    SettingsForm {
      LoginStartupSection()
      Section("关于") {
        SettingsRow("Tacit", value: "版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"))
        SettingsRow("构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "本地")
      }
    }
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
      Toggle("登录后自动启动", isOn: Binding(get: { enabled }, set: { value in
        busy = true; error = nil
        Task {
          do { try startup?.setEnabled(value) } catch { self.error = error.localizedDescription }
          refresh(); busy = false
        }
      })).toggleStyle(.switch).disabled(!installed || busy)
      if mixed { SettingsMessage(text: "部分启动项的设置不一致，重新打开这个开关可统一。") }
      if !installed { SettingsMessage(text: "启动配置不完整，请重新安装应用。") }
      if let error { SettingsMessage(text: error) }
    } header: { Text("启动与运行") }
    footer: { Note("登录这台 Mac 后在菜单栏运行，并启动保存与整理服务。关闭后本次继续运行，下次需手动打开应用。关闭主窗口不会停止记录。") }
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
        row("自动带入的长度上限", value: d.injectTokens, key: "inject_tokens", unit: "token")
        // 已经是默认值、又没改动时，这一行什么都没有，不占位。
        if !p.isDefault(context: context) || p.changed(context: context) {
        HStack {
          // 已经是默认值时“恢复默认”没有用处，不出现。
          if !p.isDefault(context: context) {
            Button("恢复默认") { p.restore(context: context) }.disabled(p.busy)
          }
          Spacer()
          if p.changed(context: context) {
            Button("撤销修改") { p.revert(context: context) }.disabled(p.busy)
            Button(p.busy ? "正在保存…" : "保存") { Task { await p.save(api: store.api, context: context) } }.disabled(p.busy)
          }
        }
        }
      } else if p.error == nil { ProgressView() }
      if let error = p.error {
        SettingsMessage(text: error)
        Button("重试") { Task { await p.load(api: store.api) } }
      }
      if let message = p.message { SettingsMessage(text: message, warning: false) }
    } header: { Text("自动带入项目进展") }
    footer: {
      Note("新会话按这个长度带入当前项目的进展，超出时先舍弃较旧的事项；更早、更细的内容 AI 会自己查。")
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

let localBackendPortNote = "端口只在冲突时改，保存后后台服务会自动重启，记录会接着保存。"

struct HubSettingsView: View {
  let openModels: () -> Void
  @Environment(ViewerStore.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var info: HubPortSettings?
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
          SettingsRow("当前后台", value: "这台 Mac")
          localRows(c)
        } header: { Text("后台服务") } footer: { Note(localBackendPortNote) }
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
        if !store.isRemoteBackend, !busy, info == nil || port == String(info?.port ?? 0) { await load() }
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
    SettingsRow("地址") {
      Text(store.api.base.host ?? "").font(.mono(TextSize.body)).textSelection(.enabled)
    }
    let edited = info.map { !$0.locked && port != String($0.port) } ?? false
    let validPort = Int(port).flatMap { (1024...65535).contains($0) ? $0 : nil }
    SettingsRow("端口") {
      HStack(spacing: 8) {
        TextField("端口", text: $port).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
          .font(.mono(TextSize.body)).multilineTextAlignment(.trailing).disabled(info?.locked != false || busy)
        if edited, let info {
          Button("撤销") {
            port = String(info.port)
            message = nil
            error = nil
          }
          .disabled(busy)
          Button(busy ? "正在重启…" : "保存并重启") {
            if let validPort { Task { await apply(validPort) } }
          }
          .disabled(busy || validPort == nil || validPort == info.port)
        }
      }
    }
    if edited && validPort == nil {
      SettingsMessage(text: "端口要是 1024–65535 之间的整数。")
    }
    SettingsRow("详细状态") {
      Button("在浏览器中打开") {
        if let url = store.api.statusPageURL() { openURL(url) } else { error = "后台服务尚未准备好，请稍后重试。" }
      }
    }
    if c.queue > 0 { SettingsRow("等待保存", value: "\(Fmt.count(c.queue)) 条") }
    // 连得上就不占一行，只有检查中或出问题时才说。
    if let problem = store.sharedError ?? c.hubError {
      SettingsRow("状态") { Text(problem).foregroundStyle(Palette.attention) }
    } else if info == nil {
      SettingsRow("状态", value: "正在检查…")
    }
    if info?.locked == true { SettingsMessage(text: "端口由环境变量 RA_PORT 固定，这里不能改。", warning: false) }
    if let message { SettingsMessage(text: message, warning: false) }
    if let error { SettingsMessage(text: error) }
  }

  func load() async {
    let previousPort = port
    do {
      let h = try await store.api.hubSettings()
      info = h
      if port == previousPort { port = String(h.port) }
      error = nil
    }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  /// 中枢写入 hub.json 后退出，launchd 用新端口拉起；采集端每次请求都现读 hub.json，跟着换过去。
  func apply(_ p: Int) async {
    busy = true; message = nil; error = nil
    defer { busy = false }
    do {
      let restarting = try await store.api.setHubPort(p)
      guard restarting else { await load(); return }
      message = "后台服务正在重启…"
      for _ in 0..<30 {
        try? await Task.sleep(for: .seconds(1))
        if let h = try? await store.api.hubSettings(), h.port == p {
          info = h; port = String(p); message = "端口已更新。"
          await store.refreshShared()
          return
        }
      }
      error = "30 秒内没连上后台服务，可以在维护里复制诊断信息排查。"
    } catch { self.error = error.localizedDescription }
  }
}

// MARK: 隐私（只读展示）

struct PrivacySettingsView: View {
  @Environment(ViewerStore.self) private var store

  var body: some View {
    let c = store.capture
    SettingsForm {
      Section("暂停记录") {
        switch c.state {
        case .paused(let until):
          SettingsRow("已暂停到 \(ViewerFormat.clock(until))") { Button("继续记录") { store.perform(.resume) } }
        default:
          SettingsRow(c.statusTitle) {
            // 数据源全关时本来就没在记录，暂停按钮没有用处。
            if c.sources.contains(where: \.enabled) {
              HStack {
                Button("暂停 1 小时") { store.perform(.pauseHour) }
                Button("暂停到明天") { store.perform(.pauseTomorrow) }
              }
            }
          }
        }
      }
      Section {
        SettingsRow("密码和密钥", value: "保存前换成 [已脱敏]，原文不写进磁盘")
        SettingsRow("标为私密的内容", value: "不交给 AI 整理，也不自动带入")
        SettingsRow("删除的记录", value: "在线的设备马上清掉，离线的下次连上时清掉")
      } header: {
        Text("处理规则")
      } footer: {
        Note("已连接的 AI 工具主动查询时仍能读到私密记录，每次查询都记在运行记录里。")
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
    let localPrefix = store.isRemoteBackend ? "这台 Mac 的" : ""
    SettingsForm {
      Section {
        SettingsRow("运行记录") {
          Button("打开") { store.path.append(.runtime) }
        }
        DiagnosticSettingsRow()
      }
      if !c.pluginsAvailable {
        Section {
          SettingsMessage(text: "安装不完整，AI 会话和浏览器等数据源暂时不能运行。重新安装 Tacit 就能修好。")
        }
      }
      operation(.syncAll, verb: "同步", job: c.jobs[.syncAll], extra: latest("round")?.statusText,
                what: "把还没保存的记录送到后台服务，让开着的数据源读一次新内容，再整理一轮。",
                detail: "读取所有开着的数据源，已有的不会重复，随后整理一轮。") {
        store.perform(.maintenance(.syncAll))
      }
      operation(.reimportRecent, verb: "导入", job: c.jobs[.reimportRecent],
                what: "从 7 天前重新读一遍 AI 会话和浏览器，补上漏掉的记录。",
                detail: "读取 AI 会话、浏览器，已有的不会重复，按平常的节奏整理。") {
        store.perform(.maintenance(.reimportRecent))
      }
      operation(.importAll, verb: "导入", job: c.jobs[.importAll],
                what: "导入能读到的全部 AI 会话和浏览器历史，可能要几分钟，导入后能搜到、AI 工具也能查到。",
                detail: "已有的不会重复，不自动整理，需要时用下面的“整理启用前的历史”。") {
        store.perform(.maintenance(.importAll))
      }
      Section {
        SettingsRow(MaintenanceTask.backfill.title) {
          Button("整理") { Task { await requestBackfill() } }
            .disabled(!store.canManageBackend || latest("backfill").map { !$0.finished } == true)
        }
        SettingsRow("日期范围") {
          HStack {
            DatePicker("从", selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
            Text("至").foregroundStyle(Palette.muted)
            DatePicker("至", selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
          }
          .disabled(!store.canManageBackend)
        }
        if store.canManageBackend {
          if let r = latest("backfill") { SettingsMessage(text: r.statusText, warning: r.status == "failed") }
          if let requestError { SettingsMessage(text: requestError) }
        } else {
          SettingsMessage(text: "整理远端后台的历史记录需要直连。", warning: false)
        }
        facts(what: "把所选日期里还没整理的历史交给 AI，整理出事项、项目和每日时间线。",
              detail: "读已有记录，不重新采集；整理过的不重复；会调用 AI 模型。")
      }
      Section {
        SettingsRow("\(localPrefix)密钥备份") {
          // 同其他复制按钮：复制后按钮写“已复制”，1.5 秒后复原（docs/ui.md）。
          Button(keys == .running ? "正在读取…" : keys == .copied ? "已复制" : "复制") {
            Task {
              keys = await KeyBackup.copy()
              if keys == .copied { try? await Task.sleep(for: .seconds(1.5)); if keys == .copied { keys = .idle } }
            }
          }.disabled(keys == .running)
        }
        if case .failed(let message) = keys { SettingsMessage(text: message) }
        SettingsRow("\(localPrefix)记录与音频的数据目录") {
          Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Config.load().dataDir]) }
        }
      } header: { Text("数据与备份") } footer: {
        Note("只含密钥，不含记录和录音；换电脑时要和数据目录一起带走才能打开。")
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
        Button(job?.running == true ? "进行中…" : verb, action: action).disabled(job?.running == true)
      } label: {
        Text(task.title)
        if let text = job?.text, !text.isEmpty { Text(text) }
        if let extra { Text("整理：\(extra)") }
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
    catch { requestError = error.localizedDescription }
  }
  func requestBackfill() async {
    guard store.canManageBackend else { return }
    do {
      try await store.api.requestDistill(kind: "backfill", range: DistillDateRange(start: backfillFrom, end: backfillTo))
      await loadRequests()
    } catch { requestError = error.localizedDescription }
  }
}

/// 密钥备份：调用 `cli.ts keys export`（和命令行同一份格式），拷到剪贴板时标成"隐藏内容"，
/// 本机的剪贴板记录和剪贴板管理器都会跳过它（Policy.swift 的 ConcealedType）。不写文件。
enum KeyBackup {
  enum State: Equatable { case idle, running, copied, failed(String) }

  static func copy() async -> State {
    let config = Config.load()
    guard let repo = config.repo, FileManager.default.isExecutableFile(atPath: config.bun) else {
      return .failed("安装不完整，请重新安装 Tacit 再试。")
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
      return .failed("有密钥没读到，备份不完整，所以没有复制；可以复制上面的诊断信息排查。")
    }
    let pb = NSPasteboard.general
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
    pb.setString(result.out, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    return .copied
  }
}
