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
  init(_ title: String, @ViewBuilder content: () -> Content) where Label == SwiftUI.Text {
    label = Text(title); self.content = content()
  }
  init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
    self.label = label(); self.content = content()
  }
  init(_ title: String, value: String) where Label == SwiftUI.Text, Content == SwiftUI.Text {
    label = Text(title); content = Text(value).foregroundColor(Palette.muted)
  }
  var body: some View {
    HStack(alignment: .center, spacing: 16) {
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
  @State private var enabled = false
  @State private var installed = false
  @State private var mixed = false
  @State private var busy = false
  @State private var error: String?
  private var startup: LoginStartup {
    LoginStartup(home: FileManager.default.homeDirectoryForCurrentUser, dataDir: Config.load().dataDir)
  }
  var body: some View {
    Section {
      Toggle("登录后自动启动", isOn: Binding(get: { enabled }, set: { value in
        busy = true; error = nil
        Task {
          do { try startup.setEnabled(value) } catch { self.error = error.localizedDescription }
          refresh(); busy = false
        }
      })).toggleStyle(.switch).disabled(!installed || busy)
      if mixed { SettingsMessage(text: "部分启动项的设置不一致，重新打开这个开关可统一。") }
      if !installed { SettingsMessage(text: "启动配置不完整，请重新安装应用。") }
      if let error { SettingsMessage(text: error) }
    } header: { Text("启动与运行") }
    footer: { Note("登录这台 Mac 后在菜单栏运行，并启动保存与整理服务。关闭后本次继续运行，下次需手动打开应用。关闭主窗口不会停止记录。") }
    .task {
      while !Task.isCancelled { refresh(); try? await Task.sleep(for: .seconds(5)) }
    }
  }
  func refresh() { enabled = startup.enabled; installed = startup.installed; mixed = startup.mixed }
}

struct GeneralPreferencesSection: View {
  @Environment(ViewerStore.self) private var store
  let context: Bool
  var body: some View {
    @Bindable var p = store.preferences
    Section {
      if let d = Binding($p.draft) {
        if context {
          row("自动带入的长度上限", value: d.injectTokens, key: "inject_tokens", unit: "token")
          Text("调大可带入更多背景，也会占用更多 AI 上下文。超出时先舍弃较旧事项，不影响历史记录的保存和主动查询。")
            .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        } else {
          row("事项多久没动静就问“做完了吗”", value: d.askDoneDays, key: "ask_done_days", unit: "天")
          row("问了多久没回答就归档", value: d.archiveDays, key: "archive_days", unit: "天")
        }
        HStack {
          Button("恢复默认") { p.restore(context: context) }.disabled(p.busy)
          Spacer()
          if p.changed(context: context) {
            Button("撤销修改") { p.revert(context: context) }.disabled(p.busy)
            Button(p.busy ? "正在保存…" : "保存") { Task { await p.save(api: store.api, context: context) } }.disabled(p.busy)
          }
        }
      } else if p.error == nil { ProgressView() }
      if let error = p.error {
        SettingsMessage(text: error)
        Button("重试") { Task { await p.load(api: store.api) } }
      }
      if let message = p.message { SettingsMessage(text: message, warning: false) }
    } header: { Text(context ? "自动带入项目进展" : "事项整理") }
    footer: {
      Note(context
        ? "Claude Code、Codex 新会话开始时带入当前项目摘要。默认 800 token 是模型的文字计量预算（中文通常约数百字），并非按你的记录量计算；更早、更细的内容可由 AI 主动查询。"
        : "只算有历史记录的日子，最后活动和提问当天不算。归档后不再自动带入，也不再问，仍然搜得到。")
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
        SettingsRow("地址") { Text(store.api.base.absoluteString).font(.mono(TextSize.body)).textSelection(.enabled) }
        SettingsRow("状态") {
          let problem = store.sharedError ?? c.hubError
          Text(problem ?? (info == nil ? "正在检查…" : "已连接")).foregroundStyle(problem == nil ? Palette.muted : Palette.attention)
        }
        SettingsRow("等待保存", value: "\(c.queue) 条")
        SettingsRow("本次已保存", value: "\(c.sent) 条")
        SettingsRow("详细状态") {
          Button("在浏览器中打开") {
            if let url = store.api.statusPageURL() { openURL(url) } else { error = "后台服务尚未准备好，请稍后重试。" }
          }
        }
      } header: { Text("连接与保存") } footer: {
        Note("仅接受这台 Mac 上的连接。配对和加密完成前，其他设备不能接入。")
      }
      Section("连接设置") {
        SettingsRow("端口") {
          HStack(spacing: 8) {
            TextField("端口", text: $port).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
              .font(.mono(TextSize.body)).multilineTextAlignment(.trailing).disabled(info?.locked != false || busy)
            if let p = Int(port), p != info?.port, info?.locked == false {
              Button(busy ? "正在重启…" : "保存并重启") { Task { await apply(p) } }.disabled(busy || !(1024...65535).contains(p))
            }
          }
        }
        if info?.locked == true { SettingsMessage(text: "端口由环境变量 RA_PORT 固定，这里不能改。", warning: false) }
        if let message { SettingsMessage(text: message, warning: false) }
        if let error { SettingsMessage(text: error) }
        Text("仅在端口冲突时修改。保存后后台服务会重启，记录会自动接上。")
          .foregroundStyle(Palette.muted)
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
          SettingsRow("已暂停到 \(ViewerFormat.clock(until))") { Button("继续记录") { store.perform(.resume) } }
        default:
          SettingsRow("正在记录") {
            HStack {
              Button("暂停 1 小时") { store.perform(.pauseHour) }
              Button("暂停到明天") { store.perform(.pauseTomorrow) }
            }
          }
        }
      }
      Section {
        SettingsRow("密码和密钥", value: "存之前换成 [已脱敏]，原文不写进磁盘")
        SettingsRow("标为私密的内容", value: "不交给 AI 整理，也不自动带入")
        Text("已连接的 AI 工具主动查询时仍可读取私密记录；每次查询都留在“运行记录”中。").foregroundStyle(Palette.muted)
      } header: {
        Text("写入时")
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
    SettingsForm {
      Section {
        SettingsRow("运行记录") {
          Button("打开运行记录") { store.path.append(.runtime) }
        }
      }
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
        SettingsRow("日期范围") {
          HStack {
            DatePicker("从", selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
            Text("至").foregroundStyle(Palette.muted)
            DatePicker("至", selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
            Button("整理") { Task { await requestBackfill() } }.disabled(latest("backfill").map { !$0.finished } ?? false)
          }
        }
        if let r = latest("backfill") { SettingsMessage(text: r.statusText, warning: r.status == "failed") }
        if let requestError { SettingsMessage(text: requestError) }
        facts(what: "把所选日期里、开始整理之前就有的记录交给 AI，整理出事项、项目和每日回顾。", sources: "已有的记录，不重新采集",
              dedupe: "已经整理过的记录不会重复整理", distill: "会调用 AI 模型，同一段日期可以再整理一次")
      } header: {
        Text(MaintenanceTask.backfill.title)
      }
      Section {
        SettingsRow("密钥备份") {
          Button(keys == .running ? "正在读取…" : "复制") { Task { keys = await KeyBackup.copy() } }.disabled(keys == .running)
        }
        switch keys {
        case .copied: SettingsMessage(text: "已复制。粘贴到密码管理器里保存。", warning: false)
        case .failed(let message): SettingsMessage(text: message)
        default: EmptyView()
        }
        SettingsRow("记录与音频的数据目录") {
          Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Config.load().dataDir]) }
        }
      } header: { Text("数据与备份") } footer: {
        Note("只复制密钥，不含历史记录和录音。换电脑时，密钥和数据目录都要带上，缺一个都打不开。")
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
      SettingsRow {
        Button(job?.running == true ? "进行中…" : verb, action: action).disabled(job?.running == true)
      } label: {
        Text(task.title)
        if let text = job?.text, !text.isEmpty { Text(text) }
        if let extra { Text("整理：\(extra)") }
      }
      facts(what: what, sources: sources, dedupe: dedupe, distill: distill)
    }
  }

  /// AGENTS.md：每个维护操作写明做什么、读哪些来源、是否去重、是否整理。
  func facts(what: String, sources: String, dedupe: String, distill: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(what)
      DisclosureGroup("读取范围与处理方式") {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
          GridRow { Text("读取"); Text(sources) }
          GridRow { Text("去重"); Text(dedupe) }
          GridRow { Text("整理"); Text(distill) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
      }
    }
    .foregroundStyle(Palette.muted)
    .multilineTextAlignment(.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
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
      return .failed("钥匙串里有密钥没读到，备份不完整，所以没有复制。可以在终端运行 bun hub/src/cli.ts keys export 看是哪一把。")
    }
    let pb = NSPasteboard.general
    pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
    pb.setString(result.out, forType: .string)
    pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    pb.setString("", forType: .init("org.nspasteboard.TransientType"))
    return .copied
  }
}
