import AppKit
import SwiftUI
// 只引入用到的类型：CollectorCore 里有个叫 Observation 的结构体，会挡住 @Observable 宏展开要找的 Observation 模块。
import struct CollectorCore.Project
import struct CollectorCore.PendingItem
import struct CollectorCore.Speaker
import struct CollectorCore.DataSourceStatus
import enum CollectorCore.MaintenanceTask
import struct CollectorCore.MicrophoneChoice

/// 采集端自己的运行状态，由 AppDelegate 提供给窗口显示。只含计数和开关，不含内容。
struct CaptureSnapshot: Equatable {
  enum State: Equatable { case recording, paused(Date), noPermission }
  struct Job: Equatable { var running = false; var text = "" }
  var state: State = .recording
  var queue = 0
  var sent = 0
  var hubError: String?
  /// 按注册表顺序的全部数据源。
  var sources: [DataSourceStatus] = []
  var audio: [String] = []
  /// 麦克风选项（与菜单栏子菜单一致）和当前设置值。
  var microphones: [MicrophoneChoice] = []
  var microphone = "builtin"
  var pluginsAvailable = false
  /// 采集端执行的维护任务（同步、导入）的状态。整理历史由 hub 的请求队列跟踪。
  var jobs: [MaintenanceTask: Job] = [:]
  /// 文件数据源监听的目录（相对主目录）。
  var fileDirectories: [String] = []
  /// ~/.zshrc 里有没有终端命令的记录钩子，以及上次修改失败的原因。
  var shellHook = false
  var shellHookError: String?

  func source(_ id: String) -> DataSourceStatus? { sources.first { $0.id == id } }
  var recordingEnabled: Bool { source("audio")?.enabled ?? false }
}

enum CaptureAction {
  case pauseHour, pauseTomorrow, resume, requestAX
  case setSource(String, Bool), requestPermission(String), runSource(String), installShellHook
  case maintenance(MaintenanceTask)
  case selectMicrophone(String)
  case setFileDirectories([String])
}

protocol CaptureControlling: AnyObject {
  func captureSnapshot() -> CaptureSnapshot
  func perform(_ action: CaptureAction)
  func pluginCommand(_ request: PluginRequest) async throws -> PluginResponse
}

enum Page: Hashable {
  case now, history, pending, audit, settings, project(String)
}

enum Route: Hashable {
  case thread(String)
  case project(String)
}

@MainActor @Observable final class ViewerStore {
  let api: HubAPI
  /// 本机补写、修正记录时用的设备名（与采集端一致）。
  let device: String
  weak var controls: CaptureControlling?

  var section: Page = .now { didSet { if oldValue != section { path = [] } } }
  var path: [Route] = []
  var projects: [Project] = []
  var pending: [PendingItem] = []
  var speakers: [Speaker] = []
  var sharedError: String?
  var capture = CaptureSnapshot()
  let preferences = SettingsPreferences()
  let extensions = ExtensionSettings()

  /// 历史记录当前看的那一天，以及要选中的记录（从证据、读取记录跳过来时用）。
  var historyDay = Calendar.current.startOfDay(for: Date())
  var historyFocus: String?
  var historySearch = ""
  /// 记录被删除、补写或修正后递增，各页据此重新读取。
  var revision = 0

  init(api: HubAPI, device: String, controls: CaptureControlling?) {
    self.api = api
    self.device = device
    self.controls = controls
  }

  func refreshShared() async {
    do {
      async let p = api.projects()
      async let q = api.pending()
      async let s = api.speakers()
      (projects, pending, speakers) = try await (p, q, s)
      sharedError = nil
    } catch is CancellationError {
    } catch { sharedError = error.localizedDescription }
  }

  func refreshCapture() { if let c = controls?.captureSnapshot(), c != capture { capture = c } }
  func perform(_ action: CaptureAction) { controls?.perform(action); refreshCapture() }

  func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }

  func showRecord(_ id: String, at date: Date?) {
    if let date { historyDay = Calendar.current.startOfDay(for: date) }
    historySearch = ""
    historyFocus = id
    section = .history
  }

  func searchHistory(_ text: String) {
    historySearch = text
    historyFocus = nil
    section = .history
  }

  func speakerNames(_ ids: [String]) -> [String] {
    ids.map { id in speakers.first { $0.id == id }?.display ?? id }
  }
}
