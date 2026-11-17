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
  #expect(TimelineSetup.shouldShow(permissionsReady: false, modelReady: true, agentReady: true))
  #expect(TimelineSetup.shouldShow(permissionsReady: true, modelReady: false, agentReady: true))
  #expect(TimelineSetup.shouldShow(permissionsReady: true, modelReady: true, agentReady: false))
  #expect(!TimelineSetup.shouldShow(permissionsReady: true, modelReady: true, agentReady: true))
  #expect(!TimelineSetup.shouldShow(permissionsReady: false, modelReady: nil, agentReady: true))
  #expect(!TimelineSetup.shouldShow(permissionsReady: false, modelReady: true, agentReady: nil))
}

@Test func captureTitleDistinguishesDisabledSourcesAndGlobalPause() {
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
