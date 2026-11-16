import Foundation
import Testing
@testable import CollectorCore

@Test func sourceOverviewSeparatesEnabledFromPermissionAndPause() {
  var source = DataSourceStatus(id: "screen", title: "屏幕文字", kind: .builtin, enabled: true,
    permission: .denied, permissionName: "辅助功能", lastRun: nil, detail: "", ok: true, canRunNow: false)
  #expect(SourceFilter.enabled.includes(source) && SourceFilter.attention.includes(source))
  #expect(source.overviewStatus(paused: false) == "需要辅助功能权限")
  source.permission = .granted
  #expect(!SourceFilter.attention.includes(source))
  #expect(source.overviewStatus(paused: true) == "已启用，记录暂停中")
  source.enabled = false
  #expect(source.overviewStatus(paused: true) == "已停用")
  #expect(!SourceFilter.enabled.includes(source))
}

@Test func catalogRegistersAllSourcesWithLegacyKeys() {
  let ids = DataSourceCatalog.all.map(\.id)
  #expect(ids == ["screen", "ocr", "clipboard", "audio", "files", "calendar", "wechat", "agent-sessions", "browser", "shell", "git"])
  #expect(Set(ids).count == ids.count)
  #expect(DataSourceCatalog.plugins.map(\.id) == ["agent-sessions", "browser", "shell", "git"])
  // 升级后沿用原来的开关键，用户之前关掉的 OCR / 录音不会被打开。
  #expect(DataSourceCatalog.descriptor("ocr")?.defaultsKey == "ocrEnabled")
  #expect(DataSourceCatalog.descriptor("audio")?.defaultsKey == "recordingEnabled")
  #expect(DataSourceCatalog.descriptor("git")?.defaultsKey == "source.git.enabled")
}

@Test func togglesPersistAndKeepLegacyValues() {
  let store = MemorySettings(["recordingEnabled": false])
  let toggles = SourceToggles(store: store)
  #expect(toggles.isEnabled("screen"))
  #expect(!toggles.isEnabled("ocr"))  // 默认关
  #expect(!toggles.isEnabled("wechat"))  // 微信对话默认关（AGENTS.md）
  #expect(!toggles.isEnabled("audio"))  // 旧键里的选择
  toggles.setEnabled("browser", false)
  toggles.setEnabled("ocr", true)
  #expect(store.values["source.browser.enabled"] as? Bool == false)
  #expect(store.values["ocrEnabled"] as? Bool == true)
  let reloaded = SourceToggles(store: store)
  #expect(!reloaded.isEnabled("browser") && reloaded.isEnabled("ocr"))
  #expect(!reloaded.isEnabled("unknown"))
}

@Test func cleanInstallEnablesPrimarySourcesAndHidesFrozenEntries() {
  let toggles = SourceToggles(store: MemorySettings())
  #expect(DataSourceCatalog.all.filter { toggles.isEnabled($0.id) }.map(\.id) == [
    "screen", "audio", "calendar", "agent-sessions", "browser",
  ])
  #expect(DataSourceCatalog.all.filter { DataSourceCatalog.isVisible($0.id) }.map(\.id) == [
    "screen", "ocr", "audio", "calendar", "wechat", "agent-sessions", "browser",
  ])
  #expect(!DataSourceCatalog.isVisible("ext-example"))
}

/// 记录每个数据源被调用了什么，验证停用的不启动、不申请权限。
private final class Probe {
  var events: [String] = []
  var permissionChecks = 0
  func source(_ id: String, permission: SourcePermission = .notNeeded, runnable: Bool = false) -> BlockSource {
    BlockSource(id) { s in
      s.permissionName = permission == .notNeeded ? nil : "权限"
      s.permissionCheck = { [unowned self] in self.permissionChecks += 1; return permission }
      s.request = { [unowned self] in self.events.append("\(id).request") }
      s.onEnable = { [unowned self] user in self.events.append("\(id).enable(\(user))") }
      s.onApply = { [unowned self] active in self.events.append("\(id).\(active ? "start" : "stop")") }
      s.last = { Date(timeIntervalSince1970: 100) }
      if runnable { s.run = { [unowned self] in self.events.append("\(id).run") } }
    }
  }
}

@Test func registryStartsOnlyEnabledSourcesAndHonorsPause() {
  let store = MemorySettings(["source.files.enabled": false])
  let registry = DataSourceRegistry(toggles: SourceToggles(store: store))
  let probe = Probe()
  // 注册顺序打乱，结果仍按目录顺序。
  registry.register(probe.source("files"))
  registry.register(probe.source("screen", permission: .denied))
  #expect(registry.sources.map(\.descriptor.id) == ["screen", "files"])

  registry.launch(paused: false)
  #expect(probe.events == ["screen.enable(false)", "screen.start", "files.stop"])

  probe.events = []
  registry.applyAll(paused: true)
  #expect(probe.events == ["screen.stop", "files.stop"])

  probe.events = []
  registry.setEnabled("files", true, paused: false)
  #expect(probe.events == ["files.enable(true)", "files.start"])
  #expect(store.values["source.files.enabled"] as? Bool == true)
  // 重复设置同一个值不触发启动。
  registry.setEnabled("files", true, paused: false)
  #expect(probe.events.count == 2)

  probe.events = []
  registry.setEnabled("screen", false, paused: false)
  #expect(probe.events == ["screen.stop"])
  // 暂停期间打开：记下开关并做首次准备，但不开始读取。
  probe.events = []
  registry.setEnabled("screen", true, paused: true)
  #expect(probe.events == ["screen.enable(true)", "screen.stop"])
}

@Test func statusesSkipPermissionProbeForDisabledSources() {
  let store = MemorySettings(["source.calendar.enabled": false])
  let registry = DataSourceRegistry(toggles: SourceToggles(store: store))
  let probe = Probe()
  registry.register(probe.source("calendar", permission: .denied, runnable: true))
  registry.register(probe.source("screen", permission: .denied))
  let rows = registry.statuses()
  #expect(probe.permissionChecks == 1)
  let calendar = rows.first { $0.id == "calendar" }!, screen = rows.first { $0.id == "screen" }!
  #expect(!calendar.enabled && !calendar.needsPermission && !calendar.canRunNow && calendar.lastRun == nil)
  #expect(calendar.detail == "已停用")
  #expect(screen.enabled && screen.needsPermission && screen.lastRun != nil)
  #expect(probe.events.isEmpty)
}

@Test func importWindowsAndPluginArguments() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(PluginImport.since(.reimportRecent, now: now) == now.addingTimeInterval(-7 * 86_400))
  #expect(PluginImport.since(.importAll, now: now) == PluginImport.allHistorySince)
  #expect(PluginImport.since(.syncAll, now: now) == nil)
  #expect(PluginImport.since(.backfill, now: now) == nil)
  #expect(PluginImport.rfc3339(PluginImport.allHistorySince) == "1990-01-01T00:00:00Z")
  #expect(PluginImport.arguments(plugin: "browser", since: PluginImport.allHistorySince) == ["--since", "1990-01-01T00:00:00Z"])
  #expect(PluginImport.arguments(plugin: "browser", since: nil) == [])
  // shell 只读缓冲，传 --since 会丢掉缓冲里更早的命令。
  #expect(PluginImport.arguments(plugin: "shell", since: now) == [])
  #expect(PluginImport.timeout(since: nil) == 180)
  #expect(PluginImport.timeout(since: now) == 1800)
}

@Test func distillRangeDefaultsToLast30DaysInclusive() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
  let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 1))!
  #expect(DistillDateRange.last(now: now, calendar: cal) == DistillDateRange(from: "2026-10-11", to: "2026-11-09"))
  let a = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!, b = cal.date(from: DateComponents(year: 2026, month: 2, day: 27))!
  // 起止颠倒时自动交换。
  #expect(DistillDateRange(start: a, end: b, calendar: cal) == DistillDateRange(from: "2026-02-27", to: "2026-03-01"))
}

@Test func decodesDistillRequestsAndStatusText() throws {
  let json = #"""
  {"requests":[
    {"id":"A","kind":"backfill","from":"2026-10-11","to":"2026-11-09","status":"running","created_at":"2026-11-09T03:00:00.000Z","started_at":"2026-11-09T03:00:01.000Z","progress":{"done":3,"total":10}},
    {"id":"B","kind":"round","status":"queued","created_at":"2026-11-09T02:00:00.000Z"},
    {"id":"C","kind":"backfill","from":"2026-11-01","to":"2026-11-02","status":"failed","created_at":"2026-11-08T02:00:00.000Z","error":"整理进程中断了"},
    {"id":"D","kind":"backfill","from":"2026-11-01","to":"2026-11-02","status":"done","created_at":"2026-11-07T02:00:00.000Z","progress":{"done":0,"total":0}}
  ]}
  """#
  struct R: Decodable { let requests: [DistillRequestInfo] }
  let r = try HubJSON.decoder().decode(R.self, from: Data(json.utf8)).requests
  #expect(r[0].statusText == "2026-10-11 至 2026-11-09：正在准备，已完成 3 天，共 10 天")
  #expect(!r[0].finished)
  #expect(r[1].statusText == "排队中，等后台整理进程处理")
  #expect(r[2].statusText.hasSuffix("没有成功：整理进程中断了") && r[2].finished)
  #expect(r[3].statusText.hasSuffix("完成，这段日期里没有要整理的记录"))
}

@Test func shellHookAddsAndRemovesOnlyItsOwnLine() {
  let repo = "/Users/合成/record anything"
  let original = "export PATH=$HOME/bin:$PATH\n# 用户自己的注释\nalias ll='ls -l'\n"
  let added = ShellHook.adding(to: original, repo: repo)
  #expect(ShellHook.installed(in: added))
  #expect(added.hasPrefix(original))
  #expect(added.contains("source \"/Users/合成/record anything/plugins/shell/hook.zsh\""))
  // 重复开启不重复加；关闭后和原文一字不差。
  #expect(ShellHook.adding(to: added, repo: repo) == added)
  #expect(ShellHook.removing(from: added) == original)
  // 注释掉的不算已加；仓库挪了位置时换成新路径，只留一行。
  #expect(!ShellHook.installed(in: "# source \"/old/plugins/shell/hook.zsh\"\n"))
  let moved = ShellHook.adding(to: "source \"/old/plugins/shell/hook.zsh\"\n", repo: repo)
  #expect(moved.components(separatedBy: "hook.zsh").count == 2 && moved.contains(repo))
  #expect(ShellHook.adding(to: "", repo: repo) == "# record-anything：记录终端命令\n" + ShellHook.line(repo: repo) + "\n")
  // 回归：旧版说明写进去的是带存在判断的一行，设置页曾误报"还没有记录钩子"，关掉时也删不掉。
  let legacy = original + "# record-anything：记录终端命令（卸载时删掉这两行）\n[ -f \"/old/plugins/shell/hook.zsh\" ] && source \"/old/plugins/shell/hook.zsh\"\n"
  #expect(ShellHook.installed(in: legacy))
  #expect(ShellHook.removing(from: legacy) == original)
}

@Test func installedExtensionDefaultsOffAndPersistsIndependently() {
  let memory = MemorySettings(), toggles = SourceToggles(store: MemorySettings())
  #expect(!toggles.isEnabled("ext-example"))
  let saved = SourceToggles(store: memory)
  saved.setEnabled("ext-example", true)
  #expect(SourceToggles(store: memory).isEnabled("ext-example"))
  #expect(!saved.isEnabled("ext-another"))
  #expect(saved.isEnabled("browser"))
  saved.setEnabled("ext-example", false)
  #expect(!SourceToggles(store: memory).isEnabled("ext-example"))
}

@Test func pauseAndUnregisterStopSourcesBeforeRemovingThem() {
  let registry = DataSourceRegistry(toggles: SourceToggles(store: MemorySettings()))
  let probe = Probe()
  registry.register(probe.source("browser"))
  registry.launch(paused: false)
  probe.events = []
  registry.applyAll(paused: true)
  #expect(probe.events == ["browser.stop"])
  probe.events = []
  registry.applyAll(paused: false)
  #expect(probe.events == ["browser.start"])
  probe.events = []
  registry.unregister("browser")
  #expect(probe.events == ["browser.stop"])
  #expect(registry.statuses().isEmpty)
}
