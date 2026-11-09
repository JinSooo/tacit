import Foundation
import Testing
@testable import CollectorCore

@Test func idleMeetingAppsDoNotTriggerException() {
  var history = MeetingMicrophoneHistory()
  // 合成场景：微信、飞书常开，但当前只有非会议软件在使用麦克风。
  history.observe(inputBundles: ["dev.synthetic.recorder", "dev.record-anything.collector"], at: t0)
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)).isEmpty)
  history.observe(inputBundles: ["com.tencent.xinWeChat", "dev.synthetic.recorder"], at: t0.addingTimeInterval(3))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)) == ["com.tencent.xinWeChat"])
  // 查询失败或停止用麦克风后，空采样不能沿用上一次的使用状态。
  history.observe(inputBundles: [], at: t0.addingTimeInterval(6))
  #expect(history.apps(since: t0.addingTimeInterval(6), through: t0.addingTimeInterval(9)).isEmpty)
}

@Test func meetingMicrophoneWhitelistRetainsAllSupportedBundles() {
  for bundle in ["com.tencent.meeting", "com.tencent.wemeet", "com.ss.desktop.lark", "com.electron.lark",
                 "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
                 "com.tencent.xinWeChat", "com.tencent.xinwechat"] {
    var history = MeetingMicrophoneHistory()
    history.observe(inputBundles: [bundle, "dev.synthetic.recorder"], at: t0)
    #expect(history.apps(since: t0, through: t0) == [bundle])
  }
}

@Test func meetingMicrophoneWindowIncludesToleranceAndEndButExcludesOutside() {
  var history = MeetingMicrophoneHistory()
  history.observe(inputBundles: ["com.tencent.meeting"], at: t0.addingTimeInterval(-1.01))
  history.observe(inputBundles: ["com.tencent.xinWeChat"], at: t0.addingTimeInterval(-1))
  history.observe(inputBundles: ["us.zoom.xos", "com.tencent.xinWeChat"], at: t0.addingTimeInterval(3))
  history.observe(inputBundles: ["com.microsoft.teams2"], at: t0.addingTimeInterval(3.01))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)) == ["com.tencent.xinWeChat", "us.zoom.xos"])
}

@Test func meetingMicrophoneHistoryExpiresOnlyAfterNinetySeconds() {
  var history = MeetingMicrophoneHistory()
  history.observe(inputBundles: ["com.tencent.meeting"], at: t0)
  history.observe(inputBundles: ["us.zoom.xos"], at: t0.addingTimeInterval(90))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(90)) == ["com.tencent.meeting", "us.zoom.xos"])
  history.observe(inputBundles: [], at: t0.addingTimeInterval(90.01))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(91)) == ["us.zoom.xos"])
}
