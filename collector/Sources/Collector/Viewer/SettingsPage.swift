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
  @State private var confirmImportAll = false
  // 整理启用前的历史：默认最近 30 天，可改范围。
  @State private var backfillFrom = Calendar.current.date(byAdding: .day, value: -(DistillDateRange.defaultDays - 1), to: Date())!
  @State private var backfillTo = Date()
  @State private var requests: [DistillRequestInfo] = []
  @State private var requestError: String?

  var body: some View {
    let c = store.capture
    Form {
      Section {
        ForEach(c.sources) { SourceRow(source: $0) }
      } header: {
        Text("数据源")
      } footer: {
        if !c.pluginsAvailable { Text("插件需要 bun 和仓库路径（collector.json 的 bun、repo）").foregroundStyle(.secondary) }
      }
      maintenance(c)
      Section("录音") {
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
    .task {
      // 有排队或执行中的请求时 3 秒刷新一次，否则 30 秒。
      while !Task.isCancelled {
        await loadRequests()
        try? await Task.sleep(for: .seconds(requests.contains { !$0.finished } ? 3 : 30))
      }
    }
    .confirmationDialog("清理全部音频？", isPresented: $confirmPurge) {
      Button("清理", role: .destructive) { Task { await purge() } }
    } message: {
      Text("转写过的文字不受影响，还没转写的对话会丢失。清理在设备下次同步时执行，正在录制的对话不受影响。")
    }
    .confirmationDialog("导入全部历史？", isPresented: $confirmImportAll) {
      Button("导入") { store.perform(.maintenance(.importAll)) }
    } message: {
      Text("各插件从能读到的最早记录开始重新读取，已入库的自动去重。可能要几分钟。导入的内容可以搜索和被 Agent 查询，但不会自动提炼。")
    }
  }

  @ViewBuilder func maintenance(_ c: CaptureSnapshot) -> some View {
    Section("维护") {
      MaintenanceRow(title: MaintenanceTask.syncAll.title, status: c.jobs[.syncAll]?.text, extra: latest("round")?.statusText,
                     running: c.jobs[.syncAll]?.running == true) { store.perform(.maintenance(.syncAll)) }
      MaintenanceRow(title: MaintenanceTask.reimportRecent.title, status: c.jobs[.reimportRecent]?.text,
                     running: c.jobs[.reimportRecent]?.running == true) { store.perform(.maintenance(.reimportRecent)) }
      MaintenanceRow(title: MaintenanceTask.importAll.title, status: c.jobs[.importAll]?.text,
                     running: c.jobs[.importAll]?.running == true) { confirmImportAll = true }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(MaintenanceTask.backfill.title)
          Spacer()
          DatePicker("从", selection: $backfillFrom, in: ...backfillTo, displayedComponents: .date).labelsHidden()
          Text("至").foregroundStyle(.secondary)
          DatePicker("至", selection: $backfillTo, in: backfillFrom...Date(), displayedComponents: .date).labelsHidden()
          Button("整理") { Task { await requestBackfill() } }
            .controlSize(.small).disabled(latest("backfill").map { !$0.finished } ?? false)
        }
        if let r = latest("backfill") { Text(r.statusText).font(.caption).foregroundStyle(r.status == "failed" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)) }
        if let requestError { Text(requestError).font(.caption).foregroundStyle(.orange) }
      }
    }
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

/// 数据源一行：开关、权限状态和授权、上次运行、立即运行。
private struct SourceRow: View {
  @Environment(ViewerStore.self) private var store
  let source: DataSourceStatus

  var body: some View {
    let s = source
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(s.title).foregroundStyle(s.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        let line = subtitle
        if !line.isEmpty {
          Text(line).font(.caption).foregroundStyle(s.ok && !s.needsPermission ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)).lineLimit(2)
        }
      }
      Spacer()
      if s.needsPermission, let name = s.permissionName {
        Button("授权\(name)…") { store.perform(.requestPermission(s.id)) }.controlSize(.small)
      }
      if s.canRunNow {
        Button(s.running ? "运行中…" : "立即运行") { store.perform(.runSource(s.id)) }.controlSize(.small).disabled(s.running)
      }
      Toggle(s.title, isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) }))
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }

  var subtitle: String {
    let s = source
    guard s.enabled else { return "" }
    var parts: [String] = []
    if let name = s.permissionName {
      switch s.permission {
      case .granted: parts.append("\(name)已授权")
      case .notDetermined: parts.append("\(name)未授权")
      case .denied: parts.append("缺少\(name)权限")
      case .notNeeded: break
      }
    }
    if !s.detail.isEmpty { parts.append(s.detail) }
    if !s.running, let last = s.lastRun { parts.append("最近 \(ViewerFormat.clock(last))") }
    return parts.joined(separator: " · ")
  }
}

private struct MaintenanceRow: View {
  let title: String
  var status: String?
  var extra: String?
  var running: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        if let extra { Text("提炼：\(extra)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
      }
      Spacer()
      Button(running ? "进行中…" : "开始", action: action).controlSize(.small).disabled(running)
    }
  }
}
