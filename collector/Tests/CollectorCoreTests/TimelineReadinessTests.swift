import Foundation
import Testing
@testable import CollectorCore

@Test func generatedOnlyResultHasNoPresenceEvenWithWallClockRange() {
  let start = Date(timeIntervalSince1970: 1000)
  let end = start.addingTimeInterval(2400)
  #expect(!TimelinePresence.hasDuration(activeSeconds: 0, start: start, end: end))
  #expect(!TimelinePresence.hasDuration(activeSeconds: 2400, start: start, end: start))
  #expect(!TimelinePresence.hasDuration(activeSeconds: 60, start: end, end: start))
  #expect(TimelinePresence.hasDuration(activeSeconds: 1, start: start, end: end))
}

@Test func setupReturnsUntilAllThreeRequirementsAreReadyAndDoesNotGuessOnErrors() {
  let pending: Set<String> = ["models", "permission.microphone"]
  #expect(TimelineSetup.isExpanded(unfinished: pending, collapsedWith: []))
  #expect(!TimelineSetup.isExpanded(unfinished: pending, collapsedWith: pending))
  #expect(TimelineSetup.isExpanded(unfinished: pending.union(["backend"]), collapsedWith: pending))
  #expect(TimelineSetup.rememberedCollapse(unfinished: pending.union(["backend"]), completed: [], collapsedWith: pending).isEmpty)
  #expect(TimelineSetup.rememberedCollapse(unfinished: ["permission.microphone"], completed: [], collapsedWith: pending) == pending)
  #expect(TimelineSetup.rememberedCollapse(unfinished: ["models"], completed: ["permission.microphone"], collapsedWith: pending) == ["models"])
  #expect(TimelineSetup.isExpanded(unfinished: pending, collapsedWith: ["models"]))
}

@Test func setupDoesNotWaitForSafariFullDiskAccess() {
  func denied(_ id: String, _ permission: String) -> DataSourceStatus {
    .init(id: id, title: id, kind: id == "browser" ? .plugin : .builtin, enabled: true,
          permission: .denied, permissionName: permission, lastRun: nil, detail: "", ok: false, canRunNow: false)
  }
  var screen = denied("screen", "辅助功能")
  var mic = denied("audio", "麦克风")
  var safari = denied("browser", "完全磁盘访问")
  #expect(TimelineSetup.missingPermissions(in: [screen, mic, safari]).required.map(\.id) == ["screen", "audio"])
  screen.permission = .granted
  mic.enabled = false
  let setup = TimelineSetup.missingPermissions(in: [screen, mic, safari])
  #expect(setup.required.isEmpty)
  #expect(setup.optionalSafari?.id == "browser")
  safari.permission = .granted
  #expect(TimelineSetup.missingPermissions(in: [safari]).optionalSafari == nil)
}

@Test(ChineseUITrait()) func captureTitleDistinguishesDisabledSourcesAndGlobalPause() {
  let until = Date(timeIntervalSince1970: 1000)
  #expect(CaptureFooterStatus.title(state: .recording, enabledSources: 0) == "未在记录")
  #expect(CaptureFooterStatus.title(state: .noPermission, enabledSources: 0) == "未在记录")
  #expect(CaptureFooterStatus.title(state: .recording, enabledSources: 2) == "正在记录")
  #expect(CaptureFooterStatus.title(state: .paused(until), enabledSources: 0) == "已暂停到 \(ViewerFormat.clock(until))")
  #expect(CaptureFooterStatus.title(state: .paused(until), enabledSources: 2) == "已暂停到 \(ViewerFormat.clock(until))")
  #expect(CaptureFooterStatus.title(state: .noPermission, enabledSources: 2) == "需要辅助功能权限")
}

@Test func nestedRecordTitleIsSuppressedOnlyForASingleMatchingRecord() {
  #expect(TimelinePresence.repeatsTitle(recordCount: 1, recordTitle: "海报草稿", segmentTitle: "海报草稿"))
  #expect(!TimelinePresence.repeatsTitle(recordCount: 2, recordTitle: "海报草稿", segmentTitle: "海报草稿"))
  #expect(!TimelinePresence.repeatsTitle(recordCount: 1, recordTitle: "海报草稿", segmentTitle: "完成试印"))
}

@Test func localDeliveryKeepsConnectionFailuresQuietDuringPreparationOrGrace() {
  for error in ["missing token", "unreachable"] {
    #expect(LocalBackendPreparation.deliveryError(error, preparing: true, inStartupGrace: false, setupFailed: false) == nil)
    #expect(LocalBackendPreparation.deliveryError(error, preparing: false, inStartupGrace: true, setupFailed: false) == nil)
    #expect(LocalBackendPreparation.deliveryError(error, preparing: false, inStartupGrace: false, setupFailed: false) == error)
    #expect(LocalBackendPreparation.deliveryError(error, preparing: false, inStartupGrace: true, setupFailed: true) == error)
  }
}
