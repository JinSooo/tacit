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
    case .hub: return "后台服务"
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
        case .agents: AgentSettingsView()
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
  @Environment(ViewerStore.self) private var store
  @State private var saved: GeneralSettingsInfo?
  @State private var draft: GeneralSettingsInfo?
  @State private var error: String?

  var body: some View {
    SettingsForm {
      if let d = Binding($draft) {
        Section {
          row("自动带入的上限", value: d.injectTokens, key: "inject_tokens", step: 100, unit: "token")
        } footer: {
          Note("新开 Claude Code、Codex 会话时，带入当前项目进展的最大长度。更早、更细的内容 AI 会自己查。")
        }
        Section {
          row("问我“做完了吗”", value: d.askDoneDays, key: "ask_done_days", step: 1, unit: "天没动静后")
          row("自动归档", value: d.archiveDays, key: "archive_days", step: 1, unit: "天没回答后")
        } footer: {
          Note("归档的事项不再自动带入，仍然可以搜到。")
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
        LabeledContent("地址") { Text(store.api.base.absoluteString).font(.mono(TextSize.body)).textSelection(.enabled) }
        LabeledContent("状态") {
          let problem = store.sharedError ?? c.hubError
          Text(problem ?? "正在运行").foregroundStyle(problem == nil ? Palette.muted : Palette.attention)
        }
        LabeledContent("端口") {
          HStack(spacing: 8) {
            TextField("端口", text: $port).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
              .font(.mono(TextSize.body)).multilineTextAlignment(.trailing).disabled(info?.locked != false || busy)
            if let p = Int(port), p != info?.port, info?.locked == false {
              Button(busy ? "正在重启…" : "应用") { Task { await apply(p) } }.disabled(busy || !(1024...65535).contains(p))
            }
          }
        }
        if info?.locked == true { SettingsMessage(text: "端口由环境变量 RA_PORT 固定，这里不能改。", warning: false) }
        if let message { SettingsMessage(text: message, warning: false) }
        if let error { SettingsMessage(text: error) }
        LabeledContent("运行状态") {
          Button("在浏览器中打开…") {
            if let url = store.api.statusPageURL() { openURL(url) } else { error = "后台服务还没启动过，重新运行一次 install.sh。" }
          }
        }
      } footer: {
        Note("目前只接受这台 Mac 上的连接，手机等其他设备要等配对和加密做好之后才能接入。")
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
      message = "正在用端口 \(p) 重启…"
      for _ in 0..<30 {
        try? await Task.sleep(for: .seconds(1))
        if let h = try? await store.api.hubSettings(), h.port == p {
          info = h; port = String(p); message = "已切换到端口 \(p)。"
          await store.refreshShared()
          return
        }
      }
      error = "30 秒内没连上端口 \(p)。日志在数据目录的 logs/hub.log。"
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
        LabeledContent("剪贴板", value: "从密码管理器复制的内容")
        LabeledContent("文件", value: "隐藏目录、密码管理器的目录")
      }
      Section {
        LabeledContent("密码和密钥", value: "存之前换成 [已脱敏]，原文不写进磁盘")
        LabeledContent("标为私密的内容", value: "不交给 AI 整理，也不自动带入")
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
  @State private var backfillFrom = Calendar.current.date(byAdding: .day, value: -(DistillDateRange.defaultDays - 1), to: Date())!
  @State private var backfillTo = Date()
  @State private var requests: [DistillRequestInfo] = []
  @State private var requestError: String?
  @State private var keys: KeyBackup.State = .idle

  var body: some View {
    let c = store.capture
    SettingsForm {
      if !c.pluginsAvailable {
        SettingsMessage(text: "找不到 bun 或安装目录，插件类数据源暂时不能运行。重新运行一次 install.sh 就能修好。")
      }
      operation(.syncAll, verb: "同步", job: c.jobs[.syncAll], extra: latest("round")?.statusText,
                what: "把还没送到后台服务的记录送过去，让文件、日历和各插件读一次新内容，再整理一轮。",
                sources: "所有开着的数据源", dedupe: "已有的不会重复", distill: "随后整理一轮") {
        store.perform(.maintenance(.syncAll))
      }
      operation(.reimportRecent, verb: "导入", job: c.jobs[.reimportRecent],
                what: "让插件从 7 天前开始重新读一遍，补上漏掉的记录。",
                sources: "AI 会话、浏览器、Git 提交，终端命令没有历史可读", dedupe: "已有的不会重复", distill: "按平常的节奏整理") {
        store.perform(.maintenance(.reimportRecent))
      }
      operation(.importAll, verb: "导入", job: c.jobs[.importAll],
                what: "让插件从能读到的最早记录开始导入，可能要几分钟。导入的内容能搜到，AI 工具也能查到。",
                sources: "AI 会话、浏览器、Git 提交", dedupe: "已有的不会重复", distill: "不自动整理，需要时用下面的“整理启用前的历史”") {
        store.perform(.maintenance(.importAll))
      }
      Section {
        LabeledContent("日期范围") {
          HStack {
            DatePicker("从", selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
            Text("至").foregroundStyle(Palette.muted)
            DatePicker("至", selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
            Button("整理") { Task { await requestBackfill() } }.disabled(latest("backfill").map { !$0.finished } ?? false)
          }
        }
        if let r = latest("backfill") { SettingsMessage(text: r.statusText, warning: r.status == "failed") }
        if let requestError { SettingsMessage(text: requestError) }
      } header: {
        Text(MaintenanceTask.backfill.title)
      } footer: {
        facts(what: "把所选日期里、开始整理之前就有的记录交给 AI，整理出事项、项目和日记。", sources: "已有的记录，不重新采集",
              dedupe: "已经整理过的记录不会重复整理", distill: "会调用 AI 模型，同一段日期可以再整理一次")
      }
      Section {
        LabeledContent("密钥备份") {
          Button(keys == .running ? "正在读取…" : "拷贝") { Task { keys = await KeyBackup.copy() } }.disabled(keys == .running)
        }
        switch keys {
        case .copied: SettingsMessage(text: "已拷贝。粘贴到密码管理器里保存。", warning: false)
        case .failed(let message): SettingsMessage(text: message)
        default: EmptyView()
        }
      } footer: {
        Note("记录和音频都加了密，钥匙串里的两把密钥丢了就打不开。换电脑或重装系统时用这份备份恢复。")
      }
    }
    .task {
      // 有排队或执行中的请求时 3 秒刷新一次，否则 30 秒。
      while !Task.isCancelled {
        await loadRequests()
        try? await Task.sleep(for: .seconds(requests.contains { !$0.finished } ? 3 : 30))
      }
    }
  }

  func operation(_ task: MaintenanceTask, verb: String, job: CaptureSnapshot.Job?, extra: String? = nil,
                 what: String, sources: String, dedupe: String, distill: String, action: @escaping () -> Void) -> some View {
    Section {
      LabeledContent {
        Button(job?.running == true ? "进行中…" : verb, action: action).disabled(job?.running == true)
      } label: {
        Text(task.title)
        if let text = job?.text, !text.isEmpty { Text(text) }
        if let extra { Text("整理：\(extra)") }
      }
    } footer: {
      facts(what: what, sources: sources, dedupe: dedupe, distill: distill)
    }
  }

  /// AGENTS.md：每个维护操作写明做什么、读哪些来源、是否去重、是否整理。
  func facts(what: String, sources: String, dedupe: String, distill: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(what)
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
        GridRow { Text("读取"); Text(sources) }
        GridRow { Text("去重"); Text(dedupe) }
        GridRow { Text("整理"); Text(distill) }
      }
    }
    .foregroundStyle(Palette.muted)
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

/// 密钥备份：调用 `cli.ts keys export`（和命令行同一份格式），拷到剪贴板时标成"隐藏内容"，
/// 本机的剪贴板记录和剪贴板管理器都会跳过它（Policy.swift 的 ConcealedType）。不写文件。
enum KeyBackup {
  enum State: Equatable { case idle, running, copied, failed(String) }

  static func copy() async -> State {
    let config = Config.load()
    guard let repo = config.repo, FileManager.default.isExecutableFile(atPath: config.bun) else {
      return .failed("找不到 bun 或安装目录，重新运行一次 install.sh 再试。")
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
      return .failed("钥匙串里有密钥没读到，备份不完整，所以没有拷贝。可以在终端运行 bun hub/src/cli.ts keys export 看是哪一把。")
    }
    let pb = NSPasteboard.general
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
    pb.setString(result.out, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    return .copied
  }
}
