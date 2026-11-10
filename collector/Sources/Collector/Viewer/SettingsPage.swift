import AppKit
import SwiftUI
import CollectorCore

/// 设置页按分组导航（AGENTS.md 2026-11-10）：左边是分组，右边是该组的内容。
enum SettingsGroup: String, CaseIterable, Identifiable {
  case general, sources, models, hub, privacy, maintenance
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return "通用"
    case .sources: return "数据源"
    case .models: return "AI 模型"
    case .hub: return "中枢与连接"
    case .privacy: return "隐私"
    case .maintenance: return "维护"
    }
  }
  var icon: String {
    switch self {
    case .general: return "sliders-horizontal"
    case .sources: return "database"
    case .models: return "cpu"
    case .hub: return "plugs-connected"
    case .privacy: return "shield-check"
    case .maintenance: return "wrench"
    }
  }
}

struct SettingsPage: View {
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
        case .models: ModelSettingsView()
        case .hub: HubSettingsView()
        case .privacy: PrivacySettingsView()
        case .maintenance: MaintenanceSettingsView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle("设置")
  }
}

/// 设置页里统一的表单外观。
struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
  }
}

/// 分组下方的说明。macOS 的分组表单默认把它靠右放，这里统一靠左。
struct Note: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
  }
}

/// 加载失败、保存失败时的一行提示。
struct SettingsMessage: View {
  let text: String
  var warning = true
  var body: some View {
    Text(text).font(.callout).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
  }
}

// MARK: 通用

struct GeneralSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var saved: GeneralSettingsInfo?
  @State private var draft: GeneralSettingsInfo?
  @State private var error: String?

  var body: some View {
    SettingsForm {
      if let d = Binding($draft) {
        Section {
          row("自动注入上限", value: d.injectTokens, key: "inject_tokens", step: 100, unit: "token")
        } footer: {
          Note("新开 Claude Code、Codex 会话时，自动放进去的当前项目背景最多这么长。更早、更细的内容由 Agent 自己查。")
        }
        Section {
          row("问“做完了吗”", value: d.askDoneDays, key: "ask_done_days", step: 1, unit: "天没动静后")
          row("自动归档", value: d.archiveDays, key: "archive_days", step: 1, unit: "天没人回答后")
        } footer: {
          Note("线程一段时间没有新活动，会放进待确认列表问你做完了没有；一直没回答就自动归档，不再注入，仍然可以查。")
        }
        if draft != saved {
          HStack {
            Spacer()
            Button("还原") { draft = saved }
            Button("保存") { Task { await save() } }.keyboardShortcut(.defaultAction)
          }
        }
      } else if error == nil {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let error { SettingsMessage(text: error) }
    }
    .task { await load() }
  }

  func row(_ title: String, value: Binding<Int>, key: String, step: Int, unit: String) -> some View {
    let range = draft?.ranges[key].flatMap { $0.count == 2 ? $0[0]...$0[1] : nil } ?? 1...10_000
    return LabeledContent(title) {
      HStack(spacing: 8) {
        Text("\(value.wrappedValue) \(unit)").monospacedDigit()
        Stepper(title, value: value, in: range, step: step).labelsHidden()
      }
    }
  }

  func load() async {
    do { let g = try await store.api.generalSettings(); saved = g; draft = g; error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
  func save() async {
    guard let draft else { return }
    do { let g = try await store.api.saveGeneral(draft); saved = g; self.draft = g; error = nil }
    catch { self.error = error.localizedDescription }
  }
}

// MARK: 中枢与连接

struct HubSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var info: HubPortSettings?
  @State private var port = ""
  @State private var busy = false
  @State private var message: String?
  @State private var error: String?

  var body: some View {
    let c = store.capture
    SettingsForm {
      Section {
        LabeledContent("地址") { Text(store.api.base.absoluteString).font(.mono(12)).textSelection(.enabled) }
        LabeledContent("状态") {
          let problem = store.sharedError ?? c.hubError
          Text(problem ?? "已连接").foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        LabeledContent("端口") {
          HStack(spacing: 8) {
            TextField("端口", text: $port).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
              .multilineTextAlignment(.trailing).disabled(info?.locked != false || busy)
            if let p = Int(port), p != info?.port, info?.locked == false {
              Button(busy ? "正在重启…" : "应用") { Task { await apply(p) } }.disabled(busy || !(1024...65535).contains(p))
            }
          }
        }
        if info?.locked == true { SettingsMessage(text: "端口由环境变量 RA_PORT 固定，这里不能改。", warning: false) }
        if let message { SettingsMessage(text: message, warning: false) }
        if let error { SettingsMessage(text: error) }
        Button("打开中枢状态页…") {
          if let url = store.api.statusPageURL() { openURL(url) } else { error = "找不到 hub 的 token，hub 是否启动过？" }
        }
      } footer: {
        Note("中枢目前只接受本机连接。手机等其他设备要等配对和加密做好之后才能接入。")
      }
    }
    .task {
      // 端口可能在中枢网页上改过：定时刷新，但不覆盖正在输入的内容。
      while !Task.isCancelled {
        if !busy, info == nil || port == String(info!.port) { await load() }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  func load() async {
    do { let h = try await store.api.hubSettings(); info = h; port = String(h.port); error = nil }
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
      message = "中枢正在用端口 \(p) 重启…"
      for _ in 0..<30 {
        try? await Task.sleep(for: .seconds(1))
        if let h = try? await store.api.hubSettings(), h.port == p {
          info = h; port = String(p); message = "已切换到端口 \(p)。"
          await store.refreshShared()
          return
        }
      }
      error = "30 秒内没连上端口 \(p) 上的中枢，看一下中枢日志（数据目录 logs/hub.log）。"
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
          LabeledContent("已暂停到 \(ViewerFormat.clock(until))") { Button("继续记录") { store.perform(.resume) } }
        default:
          LabeledContent("正在记录") {
            HStack {
              Button("暂停 1 小时") { store.perform(.pauseHour) }
              Button("暂停到明天") { store.perform(.pauseTomorrow) }
            }
          }
        }
      }
      Section {
        Text(blockedApps.joined(separator: "、")).frame(maxWidth: .infinity, alignment: .leading)
      } header: {
        Text("不记录的应用")
      } footer: {
        Note("这些应用在前台时什么都不读。")
      }
      Section("其他不记录的内容") {
        LabeledContent("浏览器隐私窗口", value: "按窗口标题识别")
        LabeledContent("剪贴板", value: "密码管理器标记过的内容")
        LabeledContent("文件", value: "隐藏目录、密码管理器的目录")
      }
      Section {
        LabeledContent("密钥", value: "写入前替换成 [已脱敏]，原文不落盘")
        LabeledContent("标为 private 的内容", value: "不交给模型提炼，不自动注入")
      } header: {
        Text("写入时")
      }
    }
  }

  /// 黑名单里的应用：装了的显示本机名字（跟系统语言），没装的用常见名字。
  static let knownNames: [String: String] = [
    "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
    "com.bitwarden.desktop": "Bitwarden", "com.lastpass.LastPass": "LastPass",
    "com.dashlane.dashlanephonefinal": "Dashlane", "me.proton.pass.electron": "Proton Pass",
    "com.apple.keychainaccess": "钥匙串访问", "com.apple.Passwords": "密码",
  ]
  var blockedApps: [String] {
    let names = CapturePolicy.blockedBundles.map { id in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { AppNames.systemLanguageName($0) } ?? Self.knownNames[id] ?? id
    }
    return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }
}

// MARK: 维护

struct MaintenanceSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var confirmImportAll = false
  @State private var backfillFrom = Calendar.current.date(byAdding: .day, value: -(DistillDateRange.defaultDays - 1), to: Date())!
  @State private var backfillTo = Date()
  @State private var requests: [DistillRequestInfo] = []
  @State private var requestError: String?

  var body: some View {
    let c = store.capture
    SettingsForm {
      if !c.pluginsAvailable {
        SettingsMessage(text: "未配置 bun 或仓库路径（collector.json 的 bun、repo），插件类数据源无法运行，下面前三项只对内置数据源生效。")
      }
      operation(.syncAll, job: c.jobs[.syncAll], extra: latest("round")?.statusText,
                what: "把还没发出的记录发给中枢，并让文件、日历和各插件马上读一次新内容，然后请提炼马上跑一轮。",
                sources: "全部已启用的数据源", dedupe: "已入库的不会重复", distill: "立即提炼新内容") {
        store.perform(.maintenance(.syncAll))
      }
      operation(.reimportRecent, job: c.jobs[.reimportRecent],
                what: "让插件从 7 天前开始重新读一遍，补上漏采的记录。",
                sources: "AI 会话、浏览器、Git 提交（终端命令没有历史可读）", dedupe: "已入库的不会重复", distill: "按平常节奏提炼") {
        store.perform(.maintenance(.reimportRecent))
      }
      operation(.importAll, job: c.jobs[.importAll],
                what: "让插件从能读到的最早记录开始导入，可能要几分钟。导入的内容可以搜索，也能被 Agent 查到。",
                sources: "AI 会话、浏览器、Git 提交", dedupe: "已入库的不会重复", distill: "不自动提炼，要提炼用下面的“整理启用前的历史”") {
        confirmImportAll = true
      }
      Section {
        LabeledContent("日期范围") {
          HStack {
            DatePicker("从", selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
            Text("至").foregroundStyle(.secondary)
            DatePicker("至", selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
            Button("整理") { Task { await requestBackfill() } }.disabled(latest("backfill").map { !$0.finished } ?? false)
          }
        }
        if let r = latest("backfill") { SettingsMessage(text: r.statusText, warning: r.status == "failed") }
        if let requestError { SettingsMessage(text: requestError) }
      } header: {
        Text(MaintenanceTask.backfill.title)
      } footer: {
        facts(what: "把选定日期里已经入库、但启用提炼之前的记录交给模型，整理出线程、项目和日记。", sources: "中枢里已有的记录（不重新采集）",
              dedupe: "已经整理进线程的记录不会重复整理", distill: "会调用模型，可以对同一范围重复执行")
      }
    }
    .task {
      // 有排队或执行中的请求时 3 秒刷新一次，否则 30 秒。
      while !Task.isCancelled {
        await loadRequests()
        try? await Task.sleep(for: .seconds(requests.contains { !$0.finished } ? 3 : 30))
      }
    }
    .confirmationDialog("导入全部历史？", isPresented: $confirmImportAll) {
      Button("导入") { store.perform(.maintenance(.importAll)) }
      Button("取消", role: .cancel) {}
    } message: {
      Text("各插件从能读到的最早记录开始重新读取，已入库的自动去重。可能要几分钟。导入的内容不会自动提炼。")
    }
  }

  func operation(_ task: MaintenanceTask, job: CaptureSnapshot.Job?, extra: String? = nil,
                 what: String, sources: String, dedupe: String, distill: String, action: @escaping () -> Void) -> some View {
    Section {
      LabeledContent {
        Button(job?.running == true ? "进行中…" : "开始", action: action).disabled(job?.running == true)
      } label: {
        Text(task.title)
        if let text = job?.text, !text.isEmpty { Text(text) }
        if let extra { Text("提炼：\(extra)") }
      }
    } footer: {
      facts(what: what, sources: sources, dedupe: dedupe, distill: distill)
    }
  }

  func facts(what: String, sources: String, dedupe: String, distill: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(what)
      Text("读取：\(sources)　去重：\(dedupe)　提炼：\(distill)").foregroundStyle(.tertiary)
    }
    .multilineTextAlignment(.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
  }

  func latest(_ kind: String) -> DistillRequestInfo? { requests.first { $0.kind == kind } }
  func loadRequests() async {
    do { requests = try await store.api.distillRequests(); requestError = nil }
    catch is CancellationError {}
    catch { requestError = error.localizedDescription }
  }
  func requestBackfill() async {
    do {
      try await store.api.requestDistill(kind: "backfill", range: DistillDateRange(start: backfillFrom, end: backfillTo))
      await loadRequests()
    } catch { requestError = error.localizedDescription }
  }
}
