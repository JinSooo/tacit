import AppKit
import SwiftUI
// 只引入用到的类型：CollectorCore 里有个叫 Observation 的结构体，会挡住 @Observable 宏展开要找的 Observation 模块。
import enum CollectorCore.CaptureFooterStatus
import struct CollectorCore.Project
import struct CollectorCore.LoginStartup
import struct CollectorCore.DistillRequestInfo
import struct CollectorCore.PendingItem
import struct CollectorCore.Speaker
import struct CollectorCore.DataSourceStatus
import enum CollectorCore.MaintenanceTask
import struct CollectorCore.MicrophoneChoice
import enum CollectorCore.UserFacingError
import enum CollectorCore.L10n

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

  func source(_ id: String) -> DataSourceStatus? { sources.first { $0.id == id } }
  var statusTitle: String {
    let displayState: CaptureFooterStatus.State
    switch state {
    case .recording: displayState = .recording
    case .paused(let until): displayState = .paused(until)
    case .noPermission: displayState = .noPermission
    }
    return CaptureFooterStatus.title(state: displayState, enabledSources: sources.filter(\.enabled).count)
  }
  var recordingEnabled: Bool { source("audio")?.enabled ?? false }
}

enum CaptureAction {
  case pauseHour, pauseTomorrow, resume, requestAX
  case setSource(String, Bool), requestPermission(String), runSource(String)
  case maintenance(MaintenanceTask)
  case selectMicrophone(String)
}

protocol CaptureControlling: AnyObject {
  func captureSnapshot() -> CaptureSnapshot
  func perform(_ action: CaptureAction)
  func pluginCommand(_ request: PluginRequest) async throws -> PluginResponse
}

enum Page: Hashable {
  case review, search, settings, project(String)
}

enum ViewerEntry {
  case timeline, settings, pending
  case timelineDay(Date)
  case record(String, Date)
}

enum Route: Hashable {
  case thread(String)
  case project(String)
  case threadStory(String)
  case reviewItem(Date, String)
  case reviewRecord(String)
  case runtime
}

@MainActor @Observable final class ViewerStore {
  let api: HubAPI
  let dataSource: any ViewerDataSource
  /// 本机补写、修正记录时用的设备名（与采集端一致）。
  let device: String
  weak var controls: CaptureControlling?

  var section: Page = .review { didSet { if oldValue != section { path = [] } } }
  var path: [Route] = []
  var projects: [Project] = []
  /// 侧栏右键和项目页“…”菜单共用一个确认框，放在根视图上，侧栏收起时也能弹出。
  var projectToRemove: Project?
  var removingProject = false
  var projectRemovalError: String?
  var pending: [PendingItem] = []
  var speakers: [Speaker] = []
  var sharedError: String?
  var capture = CaptureSnapshot()
  private(set) var extensions = ExtensionSettings()

  /// nil 时跟随今天，手动选中以往日期时保留选择。
  var reviewDay: Date?
  var timelineDensity = UserDefaults.standard.string(forKey: TimelineDensity.preferenceKey)
    .flatMap(TimelineDensity.init(rawValue:)) ?? .compact {
    didSet { UserDefaults.standard.set(timelineDensity.rawValue, forKey: TimelineDensity.preferenceKey) }
  }
  var timelineSearch = ""
  var timelinePendingExpanded = false
  let update = UpdateNotice()
  let activeDaysCache = ActiveDaysCache()
  /// 打开今天时间线时排的补整理：跨页面保留，避免来回切换重复请求。
  var catchUpRequest: DistillRequestInfo?
  @ObservationIgnored var catchUpRequestedAt: Date?
  @ObservationIgnored private var sharedRequest = 0
  @ObservationIgnored private var bindingRevision = 0
  /// 进入详细时间线后要定位的原始记录。
  var historyFocus: String?
  /// 记录被删除、补写或修正后递增，各页据此重新读取。
  var revision = 0 {
    didSet {
      if !suppressRevisionCallback { onRevision?() }
    }
  }
  @ObservationIgnored private var suppressRevisionCallback = false
  @ObservationIgnored var onRevision: (() -> Void)?
  @ObservationIgnored var onDeviceSettingsUpdate: ((DeviceSettings?, String?) -> Void)?

  let loginStartup: LoginStartup?
  private let needsDirectConnection: () -> Bool
  var agentNeedsDirectConnection: Bool { needsDirectConnection() }
  var remoteBackend: RemoteBackendSettingsModel?
  var isRemoteBackend: Bool { remoteBackend?.isRemote == true }
  var canManageBackend: Bool { remoteBackend?.canManageBackend ?? true }

  init(api: HubAPI, dataSource: (any ViewerDataSource)? = nil, device: String, controls: CaptureControlling?,
       loginStartup: LoginStartup? = nil, agentNeedsDirectConnection: @escaping () -> Bool = { false }) {
    self.api = api
    self.dataSource = dataSource ?? HTTPViewerDataSource(api: api)
    self.device = device
    self.controls = controls
    self.loginStartup = loginStartup
    self.needsDirectConnection = agentNeedsDirectConnection
  }

  /// 远程下推同步到达后刷新侧栏项目；有删除或重置时递增 revision 触发界面重读（不反触发本地写回调）。
  func applyRemoteSync(reloadViews: Bool) {
    if reloadViews {
      suppressRevisionCallback = true
      revision += 1
      suppressRevisionCallback = false
    }
    let binding = bindingRevision
    Task {
      if let latestProjects = try? await dataSource.projects(), binding == bindingRevision {
        projects = latestProjects
      }
    }
  }

  func resetForBindingChange() {
    bindingRevision += 1
    sharedRequest += 1
    remoteBackend?.refreshContext()
    if section != .settings { section = .review }
    path = []
    projects = []
    projectToRemove = nil
    removingProject = false
    projectRemovalError = nil
    pending = []
    speakers = []
    sharedError = nil
    extensions = ExtensionSettings()
    reviewDay = nil
    timelineSearch = ""
    timelinePendingExpanded = false
    catchUpRequest = nil
    catchUpRequestedAt = nil
    historyFocus = nil
    activeDaysCache.clear()
    suppressRevisionCallback = true
    revision += 1
    suppressRevisionCallback = false
  }

  func refreshShared() async {
    sharedRequest += 1
    let request = sharedRequest
    var projectError: String?
    do {
      let latestProjects = try await dataSource.projects()
      try Task.checkCancellation()
      guard request == sharedRequest else { return }
      projects = latestProjects
    } catch is CancellationError {
      return
    } catch {
      guard request == sharedRequest else { return }
      projectError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
    }
    do {
      async let q = api.pending()
      async let s = api.speakers()
      let latest = try await (q, s)
      try Task.checkCancellation()
      guard request == sharedRequest else { return }
      // 待确认多了或少了时，时间线顶部那一行和面板角标一起顺滑变化。
      let changed = pending.map(\.id) != latest.0.map(\.id)
      withAnimation(changed ? Motion.standard : nil) { (pending, speakers) = latest }
      sharedError = projectError
    } catch is CancellationError {
    } catch {
      guard request == sharedRequest else { return }
      sharedError = projectError ?? UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
    }
  }

  func didResolvePending(_ id: String) {
    sharedRequest += 1
    pending.removeAll { $0.id == id }
    if pending.isEmpty { timelinePendingExpanded = false }
    Task { await refreshShared() }
  }

  func refreshCapture() { if let c = controls?.captureSnapshot(), c != capture { capture = c } }
  func perform(_ action: CaptureAction) { controls?.perform(action); refreshCapture() }

  func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }

  func confirmProjectRemoval(_ project: Project) async {
    guard !removingProject else { return }
    projectRemovalError = nil
    removingProject = true
    defer { removingProject = false }
    do { try await removeProject(project.id) } catch { projectRemovalError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }

  func removeProject(_ id: String) async throws {
    try await api.removeProject(id)
    sharedRequest += 1
    projects.removeAll { $0.id == id }
    if section == .project(id) || path.contains(.project(id)) { showReview() }
    revision += 1
    await refreshShared()
  }

  func showReview(_ day: Date? = nil) {
    reviewDay = day.flatMap { Calendar.current.isDateInToday($0) ? nil : Calendar.current.startOfDay(for: $0) }
    path = []
    section = .review
    timelinePendingExpanded = false
    historyFocus = nil
  }

  func showPending() {
    showReview()
    timelinePendingExpanded = !pending.isEmpty
  }

  func showDayRecords(_ day: Date, record: String? = nil) {
    showReview(day)
    timelineDensity = .detailed
    historyFocus = record
  }

  func showSettings() {
    path = []
    section = .settings
  }

  func speakerNames(_ ids: [String]) -> [String] {
    ids.map { id in speakers.first { $0.id == id }?.display ?? id }
  }
}
