import AppKit
import SwiftUI
import CollectorCore

/// 数据源：左边列表，右边详情（AGENTS.md 2026-11-10：不平铺）。
struct SourcesSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @State private var selected: String?
  private var paused: Bool { if case .paused = store.capture.state { return true }; return false }

  var body: some View {
    let sources = store.capture.sources.filter { DataSourceCatalog.isVisible($0.id) }
    VStack(alignment: .leading, spacing: 0) {
      if let id = selected, let source = sources.first(where: { $0.id == id }) {
        HStack {
          Button { selected = nil } label: { Label("全部数据源", systemImage: "chevron.left") }
          Text(source.title).font(.system(size: TextSize.title, weight: .semibold))
          Spacer()
        }.padding(20)
        SourceDetail(source: source).id(source.id)
      } else {
        SettingsForm {
          // 数据源只有几个，一眼能看完：不放计数和筛选，出问题的行自己标红。
          ForEach(SourceCategory.allCases, id: \.self) { category in
            let rows = sources.filter { $0.category == category }
            if !rows.isEmpty {
              Section(category.title) {
                ForEach(rows) { source in sourceRow(source) }
              }
            }
          }
        }
      }
    }
  }

  func sourceRow(_ s: DataSourceStatus) -> some View {
    HStack(spacing: 16) {
      Button { selected = s.id } label: {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(s.title).foregroundStyle(Palette.ink)
            let status = s.overviewStatus(paused: paused)
            if !status.isEmpty {
              Text(status).font(.system(size: TextSize.caption))
                .foregroundStyle(s.needsAttention ? Palette.attention : Palette.muted)
            }
          }
          Spacer()
          if let last = s.lastRun {
            Text(ViewerFormat.clock(last)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
              .accessibilityLabel("上次运行 " + ViewerFormat.clock(last))
          }
          PhIcon("caret-right", size: 14).foregroundStyle(Palette.muted)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel([s.title, s.overviewStatus(paused: paused), "查看详情"].filter { !$0.isEmpty }.joined(separator: "，"))
      Toggle(s.title, isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) }))
        .labelsHidden().toggleStyle(.switch).accessibilityLabel("启用" + s.title).disabled(store.extensions.busy)
    }
  }
}

struct SourceDetail: View {
  @Environment(ViewerStore.self) private var store
  let source: DataSourceStatus

  /// 每个数据源读什么、不读什么。
  static let summaries: [String: String] = [
    "screen": "正在用的窗口：应用、标题、网址，以及窗口里新出现的文字。",
    "ocr": "读不到文字的应用在本机截图识别，截图只在内存里，识别完就丢掉。",
    "audio": "有你说话的对话在本机转成文字，原始音频加密留在本机。",
    "wechat": "微信在最前面时按会话记下看得到的消息；打开后“截图识字”不再重复读微信。",
    "agent-sessions": "Claude Code 和 Codex 的会话，只记你说的话和它最后的回答。",
    "browser": "Chrome、Arc、Safari 等浏览器的访问记录。",
  ]

  var body: some View {
    let s = source
    SettingsForm {
      Section {
        Toggle(isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) })) {
          Text(s.title).font(.system(size: TextSize.body, weight: .semibold))
          if let text = Self.summaries[s.id] { Text(text).foregroundStyle(Palette.muted) }
        }
        .toggleStyle(.switch).disabled(store.extensions.busy)
      }
      if s.enabled {
        Section {
          // 用不到这项权限（例如没装 Safari 历史）时不显示，免得写成“已授权”。
          if let name = s.permissionName, s.permission != .notNeeded {
            SettingsRow(name + "权限") {
              HStack(spacing: 8) {
                Text(permissionText(s.permission)).foregroundStyle(s.permission.satisfied ? Palette.muted : Palette.attention)
                if s.needsPermission { Button("授权…") { store.perform(.requestPermission(s.id)) } }
              }
            }
          }
          if !s.detail.isEmpty {
            SettingsRow("状态") { Text(s.detail).foregroundStyle(s.ok ? Palette.muted : Palette.attention) }
          }
          if s.running || s.lastRun != nil || s.canRunNow {
            SettingsRow("上次运行") {
              HStack(spacing: 8) {
                Text(s.running ? "正在运行…" : s.lastRun.map { ViewerFormat.clock($0) } ?? "还没运行过").foregroundStyle(Palette.muted)
                if s.canRunNow { Button("运行") { store.perform(.runSource(s.id)) }.disabled(s.running) }
              }
            }
          }
        }
      }
      if let plugin = store.extensions.plugins.first(where: { $0.id == s.id }) { ExtensionDetailSettings(plugin: plugin) }
      // 先配置、再启用；查看或修改配置不读取来源，也不申请系统权限。
      if s.id == "audio" { AudioSourceSettings() }
    }
  }

  func permissionText(_ p: SourcePermission) -> String {
    switch p {
    case .granted, .notNeeded: return "已授权"
    case .notDetermined, .denied: return "未授权"
    }
  }
}

/// 录音：麦克风、保留天数、清理。
private struct AudioSourceSettings: View {
  @Environment(ViewerStore.self) private var store
  @State private var days = 7
  @State private var keepForever = false
  @State private var saving = false
  @State private var savedDays: Int?
  @State private var error: String?
  @State private var status: String?
  @State private var confirmPurge = false

  var body: some View {
    let c = store.capture
    Section("输入设备") {
      Picker("麦克风", selection: Binding(get: { c.microphone }, set: { v in
        store.perform(.selectMicrophone(v))
        // 采集端在音频队列上写入设置，下一次快照才读得到；先按选中的显示。
        store.capture.microphone = v
      })) {
        ForEach(c.microphones.filter { $0.group == .mode }, id: \.self) { Text($0.title).tag($0.value) }
        Divider()
        ForEach(c.microphones.filter { $0.group != .mode }, id: \.self) { Text($0.title).tag($0.value).selectionDisabled(!$0.selectable) }
      }
      // c.audio：第 0 行今天的计数，第 1 行麦克风，之后是问题。按原始位置拆开，麦克风行可能被 statusLines 去掉。
      if let mic = c.audio.dropFirst().first.flatMap({ MicrophoneChoices.statusLines([$0]).first }) {
        Text(mic).foregroundStyle(Palette.muted)
      }
      ForEach(Array(c.audio.dropFirst(2).enumerated()), id: \.offset) { _, line in
        SettingsMessage(text: line, warning: !line.hasPrefix("正在"))
      }
    }
    Section {
      SettingsRow("原始音频保留") {
        Picker("原始音频保留", selection: $keepForever) {
          Text("按天清除").tag(false)
          Text("不自动清除").tag(true)
        }.labelsHidden().fixedSize()
      }
      if !keepForever {
        SettingsRow("保留天数") {
          HStack(spacing: 8) {
            TextField("保留天数", value: $days, format: .number.grouping(.never))
              .labelsHidden().accessibilityLabel("保留天数")
              .textFieldStyle(.roundedBorder).frame(width: 72).multilineTextAlignment(.trailing)
            Text("天").foregroundStyle(Palette.muted)
            Stepper("保留天数", value: $days, in: 1...365).labelsHidden()
          }
        }
      }
      if let savedDays, (keepForever ? 0 : days) != savedDays {
        HStack {
          Spacer()
          Button("撤销修改") { keepForever = savedDays == 0; days = savedDays == 0 ? 7 : savedDays }.disabled(saving)
          Button(saving ? "正在保存…" : "保存") { Task { await save() } }
            .keyboardShortcut(.defaultAction)
            .disabled(saving || (!keepForever && !(1...365).contains(days)))
        }
      }
      if let error { SettingsMessage(text: error) }
    } header: { Text("音频保留") } footer: {
      Note("只清原始音频，转好的文字一直保留。")
    }
    Section {
      HStack {
        Spacer()
        // 会丢东西的操作单独放在最下面，只染胭脂色。
        Button("删除全部原始音频…", role: .destructive) { confirmPurge = true }
          .buttonStyle(.borderless).foregroundStyle(Palette.attention)
      }
      if let status { SettingsMessage(text: status, warning: false) }
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
    do { let d = try await store.api.retentionDays(); keepForever = d == 0; days = d == 0 ? 7 : d; savedDays = d; error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
  func save() async {
    saving = true
    defer { saving = false }
    let value = keepForever ? 0 : days
    do { try await store.api.setRetentionDays(value); savedDays = value; status = nil; error = nil }
    catch { self.error = error.localizedDescription }
  }
  func purge() async {
    do { try await store.api.purgeAudio(); status = "已安排删除，各设备下次同步时清掉原始音频。"; error = nil }
    catch { self.error = error.localizedDescription }
  }
}
