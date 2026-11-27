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
          Button { selected = nil } label: { Label(L10n.Settings.allSources, systemImage: "chevron.left") }
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
              .accessibilityLabel(L10n.Settings.lastRunAt(ViewerFormat.clock(last)))
          }
          PhIcon("caret-right", size: 14).foregroundStyle(Palette.muted)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel([s.title, s.overviewStatus(paused: paused), L10n.Settings.viewDetails].filter { !$0.isEmpty }.joined(separator: L10n.Settings.listSeparator))
      Toggle(s.title, isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) }))
        .labelsHidden().toggleStyle(.switch).accessibilityLabel(L10n.Settings.enableSource(s.title)).disabled(store.extensions.busy)
    }
  }
}

struct SourceDetail: View {
  @Environment(ViewerStore.self) private var store
  let source: DataSourceStatus

  /// 每个数据源读什么、不读什么。
  static var summaries: [String: String] { [
    "screen": L10n.Settings.screenSourceNote,
    "ocr": L10n.Settings.screenTextSourceNote,
    "audio": L10n.Settings.audioSourceNote,
    "wechat": L10n.Settings.wechatSourceNote,
    "agent-sessions": L10n.Settings.aiSessionSourceNote,
    "browser": L10n.Settings.browserSourceNote,
  ] }

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
            SettingsRow(L10n.Settings.permissionLabel(name)) {
              HStack(spacing: 8) {
                Text(permissionText(s.permission)).foregroundStyle(s.permission.satisfied ? Palette.muted : Palette.attention)
                if s.needsPermission { Button(L10n.Settings.grantPermission) { store.perform(.requestPermission(s.id)) } }
              }
            }
          }
          if !s.detail.isEmpty {
            SettingsRow(L10n.Settings.status) { Text(L10n.Settings.sourceStatus(s.detail, source: s.id, succeeded: s.ok)).foregroundStyle(s.ok ? Palette.muted : Palette.attention) }
          }
          if s.running || s.lastRun != nil || s.canRunNow {
            SettingsRow(L10n.Settings.lastRun) {
              HStack(spacing: 8) {
                Text(s.running ? L10n.Settings.running : s.lastRun.map { ViewerFormat.clock($0) } ?? L10n.Settings.neverRun).foregroundStyle(Palette.muted)
                if s.canRunNow { Button(L10n.Settings.run) { store.perform(.runSource(s.id)) }.disabled(s.running) }
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
    case .granted, .notNeeded: return L10n.Settings.permissionGranted
    case .notDetermined, .denied: return L10n.Settings.permissionMissing
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
    Section(L10n.Settings.inputDevice) {
      Picker(L10n.Settings.microphone, selection: Binding(get: { c.microphone }, set: { v in
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
        Text(L10n.Settings.recordingStatus(mic)).foregroundStyle(Palette.muted)
      }
      ForEach(Array(c.audio.dropFirst(2).enumerated()), id: \.offset) { _, line in
        SettingsMessage(text: L10n.Settings.recordingStatus(line), warning: !L10n.Settings.isDownloadingSpeechModel(line))
      }
    }
    Section {
      SettingsRow(L10n.Settings.originalAudioRetention) {
        Picker(L10n.Settings.originalAudioRetention, selection: $keepForever) {
          Text(L10n.Settings.clearAfterDays).tag(false)
          Text(L10n.Settings.neverClearAutomatically).tag(true)
        }.labelsHidden().fixedSize()
      }
      if !keepForever {
        SettingsRow(L10n.Settings.retentionDays) {
          HStack(spacing: 8) {
            TextField(L10n.Settings.retentionDays, value: $days, format: .number.grouping(.never))
              .labelsHidden().accessibilityLabel(L10n.Settings.retentionDays)
              .textFieldStyle(.roundedBorder).frame(width: 72).multilineTextAlignment(.trailing)
            Text(L10n.Settings.retentionUnit(days)).foregroundStyle(Palette.muted)
            Stepper(L10n.Settings.retentionDays, value: $days, in: 1...365).labelsHidden()
          }
        }
      }
      if let savedDays, retentionValue != savedDays {
        HStack {
          Spacer()
          Button(L10n.Settings.revertChanges) { keepForever = savedDays == 0; days = savedDays == 0 ? 7 : savedDays }.disabled(saving)
          Button(saving ? L10n.Settings.saving : L10n.Settings.save) { Task { await save() } }
            .keyboardShortcut(.defaultAction)
            .disabled(saving || retentionValue == nil)
        }
      }
      if let error { SettingsMessage(text: error) }
    } header: { Text(L10n.Settings.audioRetention) } footer: {
      Note(L10n.Settings.audioRetentionNote)
    }
    Section {
      HStack {
        Spacer()
        // 会丢东西的操作单独放在最下面，只染胭脂色。
        Button(L10n.Settings.deleteAudio, role: .destructive) { confirmPurge = true }
          .buttonStyle(.borderless).foregroundStyle(Palette.attention)
      }
      if let status { SettingsMessage(text: status, warning: false) }
    }
    .task { await load() }
    .confirmationDialog(L10n.Settings.confirmDeleteAudio, isPresented: $confirmPurge) {
      Button(L10n.Settings.delete, role: .destructive) { Task { await purge() } }
      Button(L10n.Settings.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Settings.deleteAudioNote)
    }
  }

  func load() async {
    do { let d = try await store.api.retentionDays(); keepForever = d == 0; days = d == 0 ? 7 : d; savedDays = d; error = nil }
    catch is CancellationError {}
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
  private var retentionValue: Int? {
    L10n.Settings.audioRetentionValue(keepForever: keepForever, days: days)
  }
  func save() async {
    guard let value = retentionValue else { return }
    saving = true
    defer { saving = false }
    do { try await store.api.setRetentionDays(value); savedDays = value; status = nil; error = nil }
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
  func purge() async {
    do { try await store.api.purgeAudio(); status = L10n.Settings.audioDeletionScheduled; error = nil }
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}
