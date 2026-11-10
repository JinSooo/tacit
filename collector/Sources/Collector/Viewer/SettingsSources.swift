import AppKit
import SwiftUI
import CollectorCore

/// 数据源：左边列表，右边详情（AGENTS.md 2026-11-10：不平铺）。
struct SourcesSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage("settings.source") private var selected = "screen"

  var body: some View {
    let sources = store.capture.sources
    HStack(spacing: 0) {
      List(selection: Binding(get: { selected }, set: { if let s = $0 { selected = s } })) {
        ForEach(sources) { s in
          HStack(spacing: 8) {
            Text(s.title).foregroundStyle(s.enabled ? Palette.ink : Palette.muted)
            Spacer()
            // 状态正常不上色；关着的写"已关闭"，出问题的才用胭脂色标出来。
            if !s.enabled { Text("已关闭").foregroundStyle(Palette.muted) }
            else if !(s.ok && !s.needsPermission) { PhIcon("warning-circle", size: 14).foregroundStyle(Palette.attention) }
          }
          .tag(s.id)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .frame(width: 190)
      Divider()
      if let s = sources.first(where: { $0.id == selected }) ?? sources.first {
        SourceDetail(source: s).id(s.id)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

struct SourceDetail: View {
  @Environment(ViewerStore.self) private var store
  let source: DataSourceStatus

  /// 每个数据源读什么、不读什么。
  static let summaries: [String: String] = [
    "screen": "正在用的窗口：应用、标题、网址，以及窗口里新出现的文字。",
    "ocr": "有些应用读不到文字（例如微信、Zed），就在本机截图识别。截图只留在内存里，识别完就丢掉。",
    "clipboard": "复制的文字。从密码管理器复制的跳过；复制图片只记一句“复制了图片”。",
    "audio": "麦克风和系统声音。有你说话的对话在本机转成文字；原始音频加密存在本机，到期自动删除。",
    "files": "下面这些文件夹里新出现的文件。只记文件名、位置和下载来源，不读文件内容。",
    "calendar": "已经结束的日程：标题、地点和参会人。录音也靠它判断你是不是在开会。",
    "wechat": "微信在最前面时，读聊天区里看到的消息，按会话分开记。没打开的会话、没往上翻的历史记不到。打开后“截图识字”不再重复读微信。",
    "agent-sessions": "Claude Code 和 Codex 的会话，只记你说的话和它最后的回答。",
    "browser": "Chrome、Arc、Safari 等浏览器的访问记录。",
    "shell": "在终端里运行的命令、所在目录、是否成功和用时。",
    "git": "在终端和 AI 会话里用过的代码仓库，记它们的新提交。",
  ]

  var body: some View {
    let s = source
    SettingsForm {
      Section {
        Toggle(isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) })) {
          Text(s.title).font(.system(size: TextSize.body, weight: .semibold))
          if let text = Self.summaries[s.id] { Text(text).foregroundStyle(Palette.muted) }
        }
        .toggleStyle(.switch)
      }
      if s.enabled {
        Section {
          if let name = s.permissionName {
            LabeledContent(name + "权限") {
              HStack(spacing: 8) {
                Text(permissionText(s.permission)).foregroundStyle(s.permission.satisfied ? Palette.muted : Palette.attention)
                if s.needsPermission { Button("授权…") { store.perform(.requestPermission(s.id)) } }
              }
            }
          }
          if !s.detail.isEmpty {
            LabeledContent("状态") { Text(s.detail).foregroundStyle(s.ok ? Palette.muted : Palette.attention) }
          }
          if s.running || s.lastRun != nil || s.canRunNow {
            LabeledContent("上次运行") {
              HStack(spacing: 8) {
                Text(s.running ? "正在运行…" : s.lastRun.map { ViewerFormat.clock($0) } ?? "还没运行过").foregroundStyle(Palette.muted)
                if s.canRunNow { Button("运行") { store.perform(.runSource(s.id)) }.disabled(s.running) }
              }
            }
          }
        }
        switch s.id {
        case "shell": ShellHookSettings()
        case "audio": AudioSourceSettings()
        case "files": FileDirectorySettings()
        default: EmptyView()
        }
      }
    }
  }

  func permissionText(_ p: SourcePermission) -> String {
    switch p {
    case .granted, .notNeeded: return "已授权"
    case .notDetermined: return "未授权"
    case .denied: return "没有打开"
    }
  }
}

/// 终端命令：开关同时管 ~/.zshrc 里那一行；开关开着但那一行不在时（例如老用户），给一个按钮补上。
private struct ShellHookSettings: View {
  @Environment(ViewerStore.self) private var store
  var body: some View {
    let c = store.capture
    Section {
      LabeledContent("~/.zshrc") {
        if c.shellHook { Text("已加上，新开的终端窗口开始记录").foregroundStyle(Palette.muted) }
        else { Button("加上记录钩子") { store.perform(.installShellHook) } }
      }
      if let e = c.shellHookError { SettingsMessage(text: e) }
    } footer: {
      Note("关掉这个数据源时，会把这一行从 ~/.zshrc 里删掉。")
    }
  }
}

/// 录音：麦克风、保留天数、清理。
private struct AudioSourceSettings: View {
  @Environment(ViewerStore.self) private var store
  @State private var days = 7
  @State private var savedDays: Int?
  @State private var error: String?
  @State private var status: String?
  @State private var confirmPurge = false

  var body: some View {
    let c = store.capture
    Section {
      Picker("麦克风", selection: Binding(get: { c.microphone }, set: { v in
        store.perform(.selectMicrophone(v))
        // 采集端在音频队列上写入设置，下一次快照才读得到；先按选中的显示。
        store.capture.microphone = v
      })) {
        ForEach(c.microphones.filter { $0.group == .mode }, id: \.self) { Text($0.title).tag($0.value) }
        Divider()
        ForEach(c.microphones.filter { $0.group != .mode }, id: \.self) { Text($0.title).tag($0.value).selectionDisabled(!$0.selectable) }
      }
      ForEach(MicrophoneChoices.statusLines(Array(c.audio.dropFirst())), id: \.self) { Text($0).foregroundStyle(Palette.muted) }
    }
    Section {
      LabeledContent("原始音频保留") {
        HStack(spacing: 8) {
          Text("\(days) 天").monospacedDigit()
          Stepper("原始音频保留", value: $days, in: 1...365).labelsHidden()
          if savedDays != nil, days != savedDays { Button("保存") { Task { await save() } } }
        }
      }
      LabeledContent("原始音频") {
        Button("全部删除…") { confirmPurge = true }
      }
      if let status { SettingsMessage(text: status, warning: false) }
      if let error { SettingsMessage(text: error) }
    } footer: {
      Note("只删原始音频，转写出来的文字不受影响。")
    }
    .task { await load() }
    .confirmationDialog("删除全部原始音频？", isPresented: $confirmPurge) {
      Button("删除", role: .destructive) { Task { await purge() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后不能恢复。转好的文字会保留，还没转成文字的对话会丢失；正在录的这一段不受影响。")
    }
  }

  func load() async {
    do { let d = try await store.api.retentionDays(); days = d; savedDays = d; error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
  func save() async {
    do { try await store.api.setRetentionDays(days); savedDays = days; status = "已保存"; error = nil }
    catch { self.error = error.localizedDescription }
  }
  func purge() async {
    do { try await store.api.purgeAudio(); status = "Mac 下次同步时删除"; error = nil }
    catch { self.error = error.localizedDescription }
  }
}

/// 文件：监听哪些目录。只接受主目录下的目录。
private struct FileDirectorySettings: View {
  @Environment(ViewerStore.self) private var store
  @State private var error: String?

  var body: some View {
    let dirs = store.capture.fileDirectories
    Section {
      ForEach(dirs, id: \.self) { d in
        LabeledContent {
          Button { set(dirs.filter { $0 != d }) } label: { PhIcon("minus-circle", size: 15) }
            .buttonStyle(.borderless).help("移除").accessibilityLabel("移除 \(d)")
        } label: {
          Text("~/" + d).font(.mono(TextSize.body))
        }
      }
      if dirs.isEmpty { Text("没有记录任何文件夹").foregroundStyle(Palette.muted) }
      HStack {
        Button("添加文件夹…") { add(dirs) }
        if dirs != FileSourcePolicy.directories { Button("恢复默认") { set(FileSourcePolicy.directories) } }
      }
      if let error { SettingsMessage(text: error) }
    } header: {
      Text("记录这些文件夹")
    } footer: {
      Note("里面的子文件夹也会记录。隐藏文件夹和密码管理器的文件夹不记录。")
    }
  }

  func set(_ dirs: [String]) {
    error = nil
    store.perform(.setFileDirectories(dirs))
    store.capture.fileDirectories = FileDirectories.normalized(dirs)
  }

  func add(_ dirs: [String]) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    panel.prompt = "添加"
    // 不用 runModal：模态循环期间采集端的定时器（屏幕、剪贴板、发送）全部停摆，选择框开多久就漏采多久。
    let handle: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      guard let rel = FileSourcePolicy.relative(url.path, home: FileManager.default.homeDirectoryForCurrentUser.path) else {
        error = "只能选个人文件夹里的文件夹，不能是个人文件夹本身、资源库或隐藏文件夹。"; return
      }
      if let parent = FileDirectories.covering(rel, in: dirs) {
        error = parent == rel ? "~/\(rel) 已经在记录了。" : "~/\(rel) 在 ~/\(parent) 里面，已经在记录了。"; return
      }
      set(dirs + [rel])
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handle) } else { panel.begin(completionHandler: handle) }
  }
}
