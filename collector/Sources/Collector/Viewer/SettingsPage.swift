import SwiftUI
import CollectorCore

struct SettingsPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var days = 7
  @State private var savedDays: Int?
  @State private var error: String?
  @State private var status: String?
  @State private var confirmPurge = false
  @State private var hubLinkError: String?
  @Environment(\.openURL) private var openURL

  var body: some View {
    let c = store.capture
    Form {
      Section("采集") {
        ForEach(c.lines) { line in
          LabeledContent {
            Text(line.value).foregroundStyle(line.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          } label: {
            HStack(spacing: 8) {
              Circle().fill(line.ok ? Palette.factColors["decision"]! : .orange).frame(width: 7, height: 7)
              Text(line.title)
            }
          }
        }
        if case .noPermission = c.state { Button("授权辅助功能…") { store.perform(.requestAX) } }
        if c.lines.contains(where: { $0.id == "calendar" && !$0.ok }) { Button("授权日历…") { store.perform(.requestCalendar) } }
        Toggle("读不到文字时用 OCR", isOn: Binding(get: { c.ocrEnabled }, set: { _ in store.perform(.toggleOCR) }))
      }
      if !c.plugins.isEmpty {
        Section {
          ForEach(c.plugins) { p in LabeledContent(p.title) { Text(p.value).foregroundStyle(.secondary).monospacedDigit() } }
        } header: {
          HStack {
            Text("数据源")
            Spacer()
            Button("立即运行") { store.perform(.runPlugins) }.controlSize(.small)
          }
        }
      }
      Section("录音") {
        Toggle("录音", isOn: Binding(get: { c.recordingEnabled }, set: { _ in store.perform(.toggleRecording) }))
        ForEach(c.audio, id: \.self) { Text($0).foregroundStyle(.secondary) }
        LabeledContent("原始音频保留") {
          HStack(spacing: 8) {
            Stepper(value: $days, in: 1...365) { Text("\(days) 天").monospacedDigit() }
            if savedDays != nil, days != savedDays { Button("保存") { Task { await save() } }.controlSize(.small) }
          }
        }
        LabeledContent {
          Button("清理全部音频…", role: .destructive) { confirmPurge = true }
        } label: {
          Text("只删原始音频，转写过的文字不受影响").foregroundStyle(.secondary)
        }
        if let status { Text(status).foregroundStyle(.secondary) }
        if let error { Text(error).foregroundStyle(.red) }
      }
      Section("中枢") {
        LabeledContent("地址") { Text(store.api.base.absoluteString).font(.mono(12)).textSelection(.enabled) }
        LabeledContent("状态") {
          Text(store.sharedError ?? c.hubError ?? "已连接").foregroundStyle(store.sharedError == nil && c.hubError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        Button("中枢状态…") {
          if let url = store.api.statusPageURL() { hubLinkError = nil; openURL(url) } else { hubLinkError = "找不到 hub 的 token，hub 是否启动过？" }
        }
        if let hubLinkError { Text(hubLinkError).foregroundStyle(.orange) }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(Palette.paper)
    .navigationTitle("设置")
    .task { await load() }
    .confirmationDialog("清理全部音频？", isPresented: $confirmPurge) {
      Button("清理", role: .destructive) { Task { await purge() } }
    } message: {
      Text("转写过的文字不受影响，还没转写的对话会丢失。清理在设备下次同步时执行，正在录制的对话不受影响。")
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
    do { try await store.api.purgeAudio(); status = "已请求清理，设备下次同步时执行"; error = nil }
    catch { self.error = error.localizedDescription }
  }
}
